# shivammathur/homebrew-php

<a href="https://github.com/shivammathur/homebrew-php" title="Homebrew tap to install PHP"><img alt="Build status" src="https://github.com/shivammathur/homebrew-php/workflows/Update%20and%20Build%20Formulae/badge.svg"></a>
<a href="https://github.com/shivammathur/homebrew-php/blob/master/LICENSE" title="license"><img alt="LICENSE" src="https://img.shields.io/badge/license-MIT-428f7e.svg"></a>
<a href="https://github.com/shivammathur/homebrew-php/tree/master/Formula" title="license"><img alt="PHP Versions Supported" src="https://img.shields.io/badge/php-%3E%3D%205.6-8892BF.svg"></a>

> Homebrew tap for PHP releases.

## PHP Support

|PHP Version|formula|
|--- |--- |
`PHP 5.6`|`php@5.6`|
`PHP 7.0`|`php@7.0`|
`PHP 7.1`|`php@7.1`|
`PHP 7.2`|`php@7.2`|
`PHP 7.3`|`php@7.2`|
`PHP 7.4`|`php` or `php@7.4`|
`PHP 8.0.0-dev`|`php@8.0`|

PHP formulae which are supported on `homebrew-core` tap are synced with each PHP patch release and maintained after they are deprecated.

## Usage

**Update `brew`**

```bash
brew update
```

**Add the tap**

```bash
brew tap shivammathur/homebrew-php
```

**Install**
*See [PHP Support](#php-support) for available formulae.*

To install latest PHP version.

```bash
brew install shivammathur/php/php
brew link --overwrite --force php
```

To install a specific PHP version, for example `7.2`.

```bash
brew install shivammathur/php/php@7.2
brew link --overwrite --force php@7.2
```

## License
The code in this project is licensed under the [MIT license](http://choosealicense.com/licenses/mit/).
Please see the [license file](LICENSE) for more information.

Some formulae in [Formula](Formula) directory are fetched from [homebrew-core](https://github.com/Homebrew/homebrew-core) tap and their license can be found [here](LICENSE_HOMEBREW).


## Related Projects

- [shivammathur/homebrew-extensions](https://github.com/shivammathur/homebrew-extensions "Tap for PHP extensions")
- [shivammathur/homebrew-phalcon](https://github.com/shivammathur/homebrew-extensions "Tap for psr and phalcon extensions")
- [shivammathur/setup-php](https://github.com/shivammathur/setup-php "Setup PHP in GitHub Actions")
