brew_old_url_prefix='https://raw.githubusercontent.com/eXolnet/homebrew-deprecated/master/Formula'
brew_new_url_prefix='https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula'

mkdir -p Formula
if [ $1 = 'old' ]; then	
	curl -o Formula/"$2".rb "$brew_old_url_prefix"/"$2".rb
fi
if [ $1 = 'new' ]; then
	curl -o Formula/"$2".rb "$brew_new_url_prefix"/"$2".rb
fi
