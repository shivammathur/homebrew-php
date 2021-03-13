unbottle() {
  if [[ "$PHP_VERSION" =~ php$|php@7.[2-4] ]]; then
    printf "  bottle do\n    root_url \"%s\"\n" "$HOMEBREW_BINTRAY_URL" > /tmp/bottle
    sed -Ei '/    rebuild.*/d' ./Formula/"$PHP_VERSION".rb
    sed -Ei '/    sha256.*/d' ./Formula/"$PHP_VERSION".rb
    sed -Ei '/  revision.*/d' ./Formula/"$PHP_VERSION".rb
    sed -i -e "/bottle do/r /tmp/bottle" -e "//d" ./Formula/"$PHP_VERSION".rb
    sudo rm -f /tmp/bottle
  else
    if [[ "$PHP_VERSION" =~ php@8.[1-9] ]]; then
      url="$(grep -e "^  url.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
      checksum=$(curl -sSL "$url" | shasum -a 256 | cut -d' ' -f 1)
      commit="$(basename "$(curl -sL https://api.github.com/repos/php/php-src/commits/master | grep -Eo "php/php-src/git/trees/[a-f0-9]+" | head -n 1)")"
      sed -i -e "s/^  sha256.*/  sha256 \"$checksum\"/g" ./Formula/"$PHP_VERSION".rb
      sed -i -e "s|commit.*|commit=$commit\"|g" ./Formula/"$PHP_VERSION".rb
    fi
    sed -Ei '/    rebuild.*/d' ./Formula/"$PHP_VERSION".rb
    sed -Ei '/    sha256.*/d' ./Formula/"$PHP_VERSION".rb
    sed -Ei '/  revision.*/d' ./Formula/"$PHP_VERSION".rb
  fi
}

check_url() {
  new_url="$(grep -e "^  url.*" ./Formula/"$PHP_VERSION".rb | cut -d\" -f 2)"
  old_url="$(grep -e "^  url.*" /tmp/"$PHP_VERSION".rb | cut -d\" -f 2)"
  echo "new_url: $new_url"
  echo "old_url: $old_url"
  if [ "$new_url" = "$old_url" ]; then
    sudo cp /tmp/"$PHP_VERSION".rb Formula/"$PHP_VERSION".rb
  fi
}

fetch() {
  sudo cp "Formula/$PHP_VERSION.rb" "/tmp/$PHP_VERSION.rb"
  if [[ "$PHP_VERSION" =~ php$|php@7.[2-4] ]]; then
    status_code=$(sudo curl -w "%{http_code}" -o "/tmp/$PHP_VERSION.rb.new" -sL "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/$PHP_VERSION.rb")
    if [ "$status_code" = "200" ]; then
      url="$(grep -e "^  url.*" /tmp/"$PHP_VERSION".rb.new | cut -d\" -f 2)"
      mirror="$(grep -e "^  mirror.*" /tmp/"$PHP_VERSION".rb.new | cut -d\" -f 2)"
      checksum="$(grep -e "^  sha256.*" /tmp/"$PHP_VERSION".rb.new | cut -d\" -f 2)"
      sed -i -e "s|^  url.*|  url \"$url\"|g" ./Formula/"$PHP_VERSION".rb
      sed -i -e "s|^  mirror.*|  mirror \"$mirror\"|g" ./Formula/"$PHP_VERSION".rb
      sed -i -e "s|^  sha256.*|  sha256 \"$checksum\"|g" ./Formula/"$PHP_VERSION".rb
    else
      sudo cp "/tmp/$PHP_VERSION.rb" "Formula/$PHP_VERSION.rb"
    fi
  fi
  unbottle
}

create_package() {
  package="${PHP_VERSION//@/:}"
  curl \
  --user "$HOMEBREW_BINTRAY_USER":"$HOMEBREW_BINTRAY_KEY" \
  --header "Content-Type: application/json" \
  --data " \
  {\"name\": \"$package\", \
  \"vcs_url\": \"$GITHUB_REPOSITORY\", \
  \"licenses\": [\"MIT\"], \
  \"public_download_numbers\": true, \
  \"public_stats\": true \
  }" \
  https://api.bintray.com/packages/"$HOMEBREW_BINTRAY_USER"/"$HOMEBREW_BINTRAY_REPO" >/dev/null 2>&1 || true
}

create_package
fetch
if [[ "$GITHUB_MESSAGE" != *--build-"$PHP_VERSION" ]] &&
   [[ "$GITHUB_MESSAGE" != *--build-all* ]]; then
  check_url
fi
