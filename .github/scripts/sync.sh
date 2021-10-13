export HOMEBREW_CHANGE_ARCH_TO_ARM=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
brew_cellar=$(brew --cellar)
brew_repo="$(brew --repository)"
core_repo="$(brew --repository homebrew/core)"
deps_file="$GITHUB_WORKSPACE/.github/deps/${ImageOS:?}_${ImageVersion:?}"

# configure git
git config --local user.email 1589480+BrewTestBot@users.noreply.github.com
git config --local user.name BrewTestBot
git config --local pull.rebase true

# Install PHP if not found, this will install all the dependencies
brew install php 2>/dev/null || true

# Update dependency formulae
for formula in apr apr-util argon2 aspell autoconf curl freetds gd gettext glib gmp icu4c krb5 libffi libpq libsodium libzip oniguruma openldap openssl@1.1 pcre2 sqlite tidy-html5 unixodbc; do
  mkdir -p /tmp/libs/"$formula" /tmp/formulae
  sudo cp "$core_repo/Formula/$formula.rb" /tmp/formulae/
  formula_cellar="$(brew info "$formula" | grep "$brew_cellar" | cut -d ' ' -f 1 | tail -n 1)"
  if ! [ -d "$formula_cellar"/lib ]; then
    continue
  fi
  curl -o "$core_repo/Formula/$formula.rb" -sL https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/"$formula".rb
  find "$formula_cellar"/lib -maxdepth 1 -name \*.dylib -print0 | xargs -I{} -0 cp -a {} /tmp/libs/"$formula"/
done

# Get updated formulae and reinstall them, and update brew.
IFS=" " read -r -a formulae <<< "$(git -C "$core_repo" diff --name-only | cut -d '/' -f 2 | sed -e 's/\.[^.]*$//' | tr '\n' ' ')"
git -C "$core_repo" add . && git -C "$core_repo" stash && git -C "$core_repo" pull origin master
git -C "$brew_repo" pull origin master
brew reinstall "${formulae[@]}" || true

# Check update formulae for library changes
rm -f "$deps_file"
touch "$deps_file"
for formula in "${formulae[@]}"; do
  formula_cellar="$(brew info "$formula" | grep "$brew_cellar" | cut -d ' ' -f 1 | tail -n 1)"
  if ! [ -d "$formula_cellar"/lib ]; then
    continue
  fi
  printf "\n--- %s ---\n" "$formula"
  old_build_info=$(grep -Eo "(^  revision|^    rebuild) [0-9]+" -Eo /tmp/formulae/"$formula".rb | tr -d ' \n')
  new_build_info=$(grep -Eo "(^  revision|^    rebuild) [0-9]+" -Eo "$core_repo/Formula/$formula.rb" | tr -d ' \n')
  old_hash=$(echo "$old_build_info $(find /tmp/libs/"$formula"/ -maxdepth 1 -name '*.dylib' -exec basename {} \;)" | openssl sha256)
  new_hash=$(echo "$new_build_info $(find "$formula_cellar"/lib -maxdepth 1 -name '*.dylib' -exec basename {} \;)" | openssl sha256)
  echo "old hash: $old_hash"
  echo "new hash: $new_hash"
  if [ "$old_hash" != "$new_hash" ]; then
    echo "$formula" | sudo tee -a "$deps_file"
  fi
done

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
