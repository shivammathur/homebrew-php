brew_url_prefix='https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula'
mkdir -p Formula
curl -o Formula/"$2".rb "$brew_url_prefix"/"$2".rb
