# shivammathur/homebrew-php

<a href="https://github.com/shivammathur/homebrew-php" title="Homebrew tap to install PHP"><img alt="Build status" src="https://github.com/shivammathur/homebrew-php/workflows/Update%20and%20Build%20Formulae/badge.svg"></a>
<a href="https://github.com/shivammathur/homebrew-php/blob/master/LICENSE" title="license"><img alt="LICENSE" src="https://img.shields.io/badge/license-MIT-428f7e.svg"></a>
<a href="https://github.com/shivammathur/homebrew-php/tree/master/Formula" title="Formulae for PHP versions"><img alt="PHP Versions Supported" src="https://img.shields.io/badge/php-%3E%3D%205.6-8892BF.svg"></a>

> Homebrew tap for PHP releases.

## PHP Support

|PHP Version|Formula|
|--- |--- |
`PHP 5.6`|`php@5.6`|
`PHP 7.0`|`php@7.0`|
`PHP 7.1`|`php@7.1`|
`PHP 7.2`|`php@7.2`|
`PHP 7.3`|`php@7.3`|
`PHP 7.4`|`php` or `php@7.4`|
`PHP 8.0`|`php@8.0`|
`PHP 8.1.0-dev`|`php@8.1`|

## Usage

### Update brew

Update brew and the formulae before installing PHP.

```zsh
brew update
```

### Add the tap

Fetch the formulae in this tap.

```bash
brew tap shivammathur/php
```

### Install PHP

*See [PHP Support](#php-support) for available formulae.*

For example, to install `PHP 7.3`.

```zsh
# Install PHP 7.3
brew install shivammathur/php/php@7.3

# Link PHP 7.3
brew link --overwrite --force php@7.3
```

### Upgrade your PHP version

Upgrade your PHP version to the latest patch release.

For example, to upgrade `PHP 7.3`.

```zsh
brew upgrade shivammathur/php/php@7.3
```

### Switch between PHP versions

If you have multiple PHP versions installed, you can switch between them easily.

For example, to switch to `PHP 7.3`.

```zsh
brew link --overwrite --force php@7.3
```

## License

The code in this project is licensed under the [MIT license](http://choosealicense.com/licenses/mit/).
Please see the [license file](LICENSE) for more information.

Formulae for PHP versions which are supported currently in the PHP release cycle are synced from [homebrew-core](https://github.com/Homebrew/homebrew-core) tap and their license can be found [here](LICENSE_HOMEBREW).


## Contributions

Contributions are welcome!
Please see [Contributor's Guide](.github/CONTRIBUTING.md "shivammathur/homebrew-php contribution guide") before you start.
If you face any issues while using this or want to suggest a feature/improvement, create an issue [here](https://github.com/shivammathur/homebrew-php/issues "Issues reported").


## Related Projects

- [shivammathur/homebrew-extensions](https://github.com/shivammathur/homebrew-extensions "Tap for PHP extensions")
- [shivammathur/homebrew-phalcon](https://github.com/shivammathur/homebrew-phalcon "Tap for psr and phalcon extensions")
- [shivammathur/setup-php](https://github.com/shivammathur/setup-php "Setup PHP in GitHub Actions")
