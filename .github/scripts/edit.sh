get_release() {
  local url=https://www.php.net/releases/feed.php
  if [ "$PHP_SOURCE" = "github" ]; then
    url=https://github.com/php/php-src/tags
  fi
  curl -sL "$url" | grep -Po -m 1 "php-$PHP_MM.[0-9]+" | head -n 1
}

get_support_state() {
  local formula=$1
  if grep -Eq '^  url.*shivammathur/php-src-backports' ./Formula/"$formula".rb; then
    echo 'backports'
  elif grep -q 'php.net/distributions' ./Formula/"$formula".rb; then
    echo 'active'
  else
    echo 'nightly'
  fi
}

check_changes() {
  new_url="$(grep -e "^  url.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
  old_url="$(grep -e "^  url.*" /tmp/"$PHP_VERSION".rb | cut -d\" -f 2)"
  new_checksum="$(grep -e "^  sha256.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
  old_checksum="$(grep -e "^  sha256.*" /tmp/"$PHP_VERSION".rb | cut -d\" -f 2)"
  new_version="$(brew info --formula Formula/"$PHP_VERSION".rb | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+" | head -1)"
  old_version="$(brew info --formula /tmp/"$PHP_VERSION".rb | grep -Eo "[0-9]+\.[0-9]+\.[0-9]+" | head -1)"
  echo "new_url: $new_url"
  echo "old_url: $old_url"
  echo "new_checksum: $new_checksum"
  echo "old_checksum: $old_checksum"
  echo "new_version: $new_version"
  echo "old_version: $old_version"
  if [ "$new_version" != "$old_version" ]; then
    sed -Ei '/^  revision.*/d' ./Formula/"$PHP_VERSION".rb
  fi
  if [ "$new_url" = "$old_url" ] && [ "$new_checksum" = "$old_checksum" ]; then
    sudo cp /tmp/"$PHP_VERSION".rb Formula/"$PHP_VERSION".rb
  fi
}

fetch() {
  sudo cp "Formula/$PHP_VERSION.rb" "/tmp/$PHP_VERSION.rb"
  support_state=$(get_support_state "$PHP_VERSION")
  if [ "$support_state" = "backports" ]; then
    commit=$(git ls-remote https://github.com/shivammathur/php-src-backports | grep "refs/tags/$(echo "$PHP_VERSION" | grep -Eo "[0-9]+.[0-9]+").*{}" | sed "s/\s*refs.*//")
    sed -i -e "s|archive.*|archive/$commit.tar.gz\"|g" ./Formula/"$PHP_VERSION".rb
    url="$(grep -e "^  url.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
    checksum=$(curl -sSL "$url" | shasum -a 256 | cut -d' ' -f 1)
    sed -i -e "s|^  sha256.*|  sha256 \"$checksum\"|g" ./Formula/"$PHP_VERSION".rb
  elif [ "$support_state" = "active" ]; then
    PHP_MM=$(grep -Po -m 1 "php-[0-9]+.[0-9]+" ./Formula/"$PHP_VERSION".rb | cut -d '-' -f 2)
    OLD_PHP_SEMVER=$(grep -Po -m 1 "php-$PHP_MM.[0-9]+" ./Formula/"$PHP_VERSION".rb)
    NEW_PHP_SEMVER=$(get_release "$PHP_MM")
    NEW_PHP_SEMVER=$(printf "%s\n%s" "$NEW_PHP_SEMVER" "$OLD_PHP_SEMVER" | sort -V | tail -1)
    if [ "$NEW_PHP_SEMVER" != "$OLD_PHP_SEMVER" ]; then
      sed -i -e "s|$OLD_PHP_SEMVER|$NEW_PHP_SEMVER|g" ./Formula/"$PHP_VERSION".rb
      url="$(grep -e "^  url.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
      checksum=$(curl -sSL "$url" | shasum -a 256 | cut -d' ' -f 1)
      sed -i -e "s|^  sha256.*|  sha256 \"$checksum\"|g" ./Formula/"$PHP_VERSION".rb
    fi
  elif [ "$support_state" = "nightly" ]; then
    master_header=$(curl -fsSL https://raw.githubusercontent.com/php/php-src/master/main/php_version.h) || return 1
    master_version=$(printf '%s\n' "$master_header" | sed -nE 's/^#define PHP_VERSION "([0-9]+\.[0-9]+)\..*/\1/p')
    if [ -z "$master_version" ]; then
      echo "Failed to determine the PHP master version" >&2
      return 1
    fi
    PHP_MM=$(echo "$PHP_VERSION" | grep -Eo '[0-9]+\.[0-9]+')
    if [ "$PHP_MM" = "$master_version" ]; then
      branch=master
    else
      branch_header=$(curl -fsSL "https://raw.githubusercontent.com/php/php-src/PHP-$PHP_MM/main/php_version.h") || return 1
      branch_version=$(printf '%s\n' "$branch_header" | sed -nE 's/^#define PHP_VERSION "([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
      case "$branch_version" in
        "$PHP_MM.0") branch="PHP-$PHP_MM" ;;
        # Stay on the initial release when the series branch advances to .1-dev.
        "$PHP_MM."*) branch="PHP-$PHP_MM.0" ;;
        *)
          echo "Failed to determine the PHP-$PHP_MM version" >&2
          return 1
          ;;
      esac
    fi
    ref=$(git ls-remote --exit-code --heads https://github.com/php/php-src "refs/heads/$branch") || return 1
    commit=$(printf '%s\n' "$ref" | cut -f 1)
    if [[ ! "$commit" =~ ^[a-f0-9]{40}$ ]]; then
      echo "Failed to find a commit for $branch" >&2
      return 1
    fi
    url="https://github.com/php/php-src/archive/$commit.tar.gz?commit=$commit"
    checksum=$(set -o pipefail; curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f 1) || return 1
    sed -i -e "s|^  sha256.*|  sha256 \"$checksum\"|g" ./Formula/"$PHP_VERSION".rb
    sed -i -e "s|^  url.*|  url \"$url\"|g" ./Formula/"$PHP_VERSION".rb
  fi
}

if [[ "$GITHUB_MESSAGE" =~ --skip-"$PHP_VERSION"( |$) ]]; then
  echo "Skipping PHP $PHP_VERSION"
  exit 0;
fi

if [[ "$GITHUB_MESSAGE" = *--bump-revision* ]]; then
  echo "Bumping revision $PHP_VERSION"
  brew bump-revision ./Formula/"$PHP_VERSION".rb -v --write-only
  exit 0;
fi

fetch || exit 1
if [[ "$GITHUB_MESSAGE" != *--build-"$PHP_VERSION" ]] &&
   [[ "$GITHUB_MESSAGE" != *--build-all* ]]; then
  check_changes
fi
