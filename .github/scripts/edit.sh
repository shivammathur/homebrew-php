get_release() {
  if [ "$PHP_SOURCE" = "github" ]; then
    curl -sL "https://github.com/php/php-src/tags" | grep -Po -m 1 "php-$PHP_MM.[0-9]+$" | head -n 1
  else
    curl -sL "https://www.php.net/releases/feed.php" | grep -Po -m 1 "php-$PHP_MM.[0-9]+" | head -n 1
  fi
}

unbottle() {
  sed -Ei '/^    rebuild.*/d' ./Formula/"$PHP_VERSION".rb
  sed -Ei '/^    sha256.*:.*/d' ./Formula/"$PHP_VERSION".rb
}

check_changes() {
  new_url="$(grep -e "^  url.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
  old_url="$(grep -e "^  url.*" /tmp/"$PHP_VERSION".rb | cut -d\" -f 2)"
  new_checksum="$(grep -e "^  sha256.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
  old_checksum="$(grep -e "^  sha256.*" /tmp/"$PHP_VERSION".rb | cut -d\" -f 2)"
  new_version="$(brew info --formula ./Formula/"$PHP_VERSION".rb | grep -Eo "[0-9]+.[0-9]+.[0-9]+")"
  old_version="$(brew info --formula /tmp/"$PHP_VERSION".rb | grep -Eo "[0-9]+.[0-9]+.[0-9]+")"
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
  if [[ "$PHP_VERSION" =~ php@(5.6|7.[0-2]) ]]; then
    url="$(grep -e "^  url.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
    checksum=$(curl -sSL "$url" | shasum -a 256 | cut -d' ' -f 1)
    commit=$(git ls-remote https://github.com/shivammathur/php-src-backports | grep "refs/tags/${PHP_VERSION/php@}.*{}" | sed "s/\s*refs.*//")
    sed -i -e "s|^  sha256.*|  sha256 \"$checksum\"|g" ./Formula/"$PHP_VERSION".rb
    sed -i -e "s|commit.*|commit=$commit\"|g" ./Formula/"$PHP_VERSION".rb
  elif [[ "$PHP_VERSION" =~ php$|php@7.[3-4] ]]; then
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
  elif [[ "$PHP_VERSION" =~ php@8.[1-9] ]]; then
    commit="$(curl -sL https://api.github.com/repos/php/php-src/commits/master | sed -n 's|^  "sha":.*"\([a-f0-9]*\)",|\1|p')"
    url="https://github.com/php/php-src/archive/$commit.tar.gz?commit=$commit"
    checksum=$(curl -sSL "$url" | shasum -a 256 | cut -d' ' -f 1)
    sed -i -e "s|^  sha256.*|  sha256 \"$checksum\"|g" ./Formula/"$PHP_VERSION".rb
    sed -i -e "s|^  url.*|  url \"$url\"|g" ./Formula/"$PHP_VERSION".rb
  fi
  unbottle
}

fetch
if [[ "$GITHUB_MESSAGE" != *--build-"$PHP_VERSION" ]] &&
   [[ "$GITHUB_MESSAGE" != *--build-all* ]]; then
  check_changes
fi
