export HOMEBREW_CHANGE_ARCH_TO_ARM=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
core_repo="$(brew --repository homebrew/core)"
deps_file="$GITHUB_WORKSPACE/.github/deps/${ImageOS:?}_${ImageVersion:?}"

# configure git
git config --local user.email 1589480+BrewTestBot@users.noreply.github.com
git config --local user.name BrewTestBot
git config --local pull.rebase true

# Install PHP if not found, this will install all the dependencies
brew install php

# Update dependency formulae
for formula in apr apr-util argon2 aspell autoconf curl freetds gd gettext glib gmp icu4c krb5 libffi libpq libsodium libzip oniguruma openldap openssl@1.1 pcre2 sqlite tidy-html5 unixodbc; do
  mkdir -p /tmp/libs/"$formula" /tmp/formulae
  sudo cp "$core_repo/Formula/$formula.rb" /tmp/formulae/
  formula_prefix="$(brew --prefix "$formula")"
  if ! [ -d "$formula_prefix"/lib ]; then
    continue
  fi
  curl -o "$core_repo/Formula/$formula.rb" -sL https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/"$formula".rb
  find "$formula_prefix"/lib -maxdepth 1 -name \*.dylib -print0 | xargs -I{} -0 cp -a {} /tmp/libs/"$formula"/
done

# Get updated formulae
(
  cd "$core_repo" || exit
  git diff --name-only | cut -d '/' -f 2 | sed -e 's/\.[^.]*$//' | sudo tee /tmp/deps_updated
)

# Check update formulae for library changes
rm -f "$deps_file"
touch "$deps_file"
while read -r formula; do
  formula_prefix="$(brew --prefix "$formula")"
  if ! [ -d "$formula_prefix"/lib ]; then
    continue
  fi
  printf "\n--- %s ---\n" "$formula"
  brew reinstall "$formula" 2>/dev/null 1>&2 || true
  formula_prefix="$(brew --prefix "$formula")"
  old_build_info=$(grep -Eo "(^  revision|^    rebuild) [0-9]+" -Eo /tmp/formulae/"$formula".rb | tr -d ' \n')
  new_build_info=$(grep -Eo "(^  revision|^    rebuild) [0-9]+" -Eo "$core_repo/Formula/$formula.rb" | tr -d ' \n')
  old_hash=$(echo "$old_build_info $(find /tmp/libs/"$formula"/ -maxdepth 1 -name '*.dylib' -exec basename {} \;)" | openssl sha256)
  new_hash=$(echo "$new_build_info $(find "$formula_prefix"/lib -maxdepth 1 -name '*.dylib' -exec basename {} \;)" | openssl sha256)
  echo "old hash: $old_hash"
  echo "new hash: $new_hash"
  if [ "$old_hash" != "$new_hash" ]; then
    echo "$formula" | sudo tee -a "$deps_file"
  fi
done </tmp/deps_updated

# Push changes
ls ./.github/deps/*
if [ "$(git status --porcelain=v1 2>/dev/null | wc -l)" != "0" ]; then
  git stash
  git pull -f https://"$GITHUB_REPOSITORY_OWNER":"$GITHUB_TOKEN"@github.com/"$GITHUB_REPOSITORY".git master
  git stash apply
  git add .
  git commit -m "Update PHP dependencies on ${ImageOS:?} ${ImageVersion:?} runner"
  git push -f https://"$GITHUB_REPOSITORY_OWNER":"$GITHUB_TOKEN"@github.com/"$GITHUB_REPOSITORY".git master || true
fi
