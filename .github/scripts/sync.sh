git config --local user.email homebrew-test-bot@lists.sfconservancy.org
git config --local user.name BrewTestBot
git config --local pull.rebase true

for formula in apr apr-util argon2 aspell autoconf curl freetds gd gettext glib gmp icu4c krb5 libffi libpq libsodium libzip oniguruma openldap openssl@1.1 pcre2 sqlite tidy-html5 unixodbc; do
  curl -o "$(brew --prefix)/Homebrew/Library/Taps/homebrew/homebrew-core/Formula/$formula.rb" -sL https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/$formula.rb &
  to_wait+=( $! )
done
wait "${to_wait[@]}"
(
  cd "$(brew --prefix)/Homebrew/Library/Taps/homebrew/homebrew-core" || exit
  git diff --name-only | cut -d '/' -f 2 | sed -e 's/\.[^.]*$//' | sudo tee "$GITHUB_WORKSPACE/.github/deps/${ImageOS:?}_${ImageVersion:?}"
)
ls ./.github/deps/*
if [ "$(git status --porcelain=v1 2>/dev/null | wc -l)" != "0" ]; then
  git stash
  git pull -f https://"$GITHUB_REPOSITORY_OWNER":"$GITHUB_TOKEN"@github.com/"$GITHUB_REPOSITORY".git master
  git stash apply
  git add .
  git commit -m "Update PHP dependencies on ${ImageOS:?} ${ImageVersion:?} runner"
  git push -f https://"$GITHUB_REPOSITORY_OWNER":"$GITHUB_TOKEN"@github.com/"$GITHUB_REPOSITORY".git master || true
fi
