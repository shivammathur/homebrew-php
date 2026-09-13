class PhpAT86 < Formula
  desc "General-purpose scripting language"
  homepage "https://www.php.net/"
  url "https://github.com/php/php-src/archive/ae62043aa340871abfeea8568565d23d8b42f35a.tar.gz?commit=ae62043aa340871abfeea8568565d23d8b42f35a"
  version "8.6.0"
  sha256 "c0f0ac6238db047c34cd38ab9968b2b43846ce44824122184af86ec1ee29273b"
  license "PHP-3.01"
  license all_of: [
    "PHP-3.01",

    # Extra licenses not documented in README.REDIST.BINS
    "Zend-2.0", # Zend/LICENSE
    "BSL-1.0",  # Zend/asm/LICENSE
    "MIT",      # ext/date/lib/LICENSE.rst

    # Extra licenses documented in README.REDIST.BINS ignoring unbundled pcre2lib (3) and gd (13)
    # ref: https://github.com/php/php-src/blob/master/README.REDIST.BINS
    "Apache-1.0",            # 10
    "Apache-2.0",            # 20
    "bcrypt-Solar-Designer", # 5
    "BSD-2-Clause-Darwin",   # 1
    "BSD-2-Clause",          # 14, 18, 19, 21; also TSRM/LICENSE
    "BSD-3-Clause",          # 4, 6, 11, 12, 15, 22
    "BSD-4-Clause-UC",       # 9
    "ISC",                   # 10
    "LGPL-2.1-only",         # 2
    "LGPL-2.1-or-later",     # 16
    "OLDAP-2.8",             # 17
    "TCL",                   # 7
    "Zlib",                  # 8
  ]
  revision 1
  compatibility_version 1

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    rebuild 134
    sha256 arm64_golden_gate: "e1a5bc0849c50fb9de8299da1a07762fc2c079d13940faf7893a095559094f25"
    sha256 arm64_tahoe:       "4c0546170cb60ae2de23640e0fd7b6ffb85b3e1ff0a3dedafb11b7d1b6b795e2"
    sha256 arm64_sequoia:     "abf158e20712b2afe6a701c03b94b52db1d3d6cd97547ffa347c09897381ddf9"
    sha256 arm64_linux:       "98c0314a757fca231d7ea9e0833001f3c4b0f5a6965345c6a0dc71715dbd0c49"
    sha256 x86_64_linux:      "0003b51cf76cd6164de1095495a231dcc7da1d78645e04eeb0f9d2d1475c31b2"
  end

  keg_only :versioned_formula

  depends_on "bison" => :build
  depends_on "httpd" => [:build, :test]
  depends_on "pkgconf" => :build
  depends_on "re2c" => :build
  depends_on "apr"
  depends_on "apr-util"
  depends_on "argon2"
  depends_on "autoconf"
  depends_on "capstone"
  depends_on "curl"
  depends_on "freetds"
  depends_on "gd"
  depends_on "gmp"
  depends_on "icu4c@78"
  depends_on "libpq"
  depends_on "libsodium"
  depends_on "libzip"
  depends_on "net-snmp"
  depends_on "oniguruma"
  depends_on "openldap"
  depends_on "openssl@3"
  depends_on "pcre2"
  depends_on "sqlite"
  depends_on "tidy-html5"
  depends_on "unixodbc"

  uses_from_macos "cyrus-sasl" => :build
  uses_from_macos "bzip2"
  uses_from_macos "libedit"
  uses_from_macos "libffi"
  uses_from_macos "libxml2"
  uses_from_macos "libxslt"

  on_macos do
    depends_on "gettext"
  end

  on_linux do
    depends_on "zlib-ng-compat"
  end

  deny_network_access! [:postinstall]

  def install
    # buildconf required due to system library linking bug patch
    system "./buildconf", "--force"

    inreplace "configure" do |s|
      s.gsub! "$APXS_HTTPD -V 2>/dev/null | grep 'threaded:.*yes' >/dev/null 2>&1",
              "false"
      s.gsub! "APXS_LIBEXECDIR='$(INSTALL_ROOT)'$($APXS -q LIBEXECDIR)",
              "APXS_LIBEXECDIR='$(INSTALL_ROOT)#{lib}/httpd/modules'"
      s.gsub! "-z $($APXS -q SYSCONFDIR)",
              "-z ''"

      # apxs will interpolate the @ in the versioned prefix: https://bz.apache.org/bugzilla/show_bug.cgi?id=61944
      s.gsub! "LIBEXECDIR='$APXS_LIBEXECDIR'",
              "LIBEXECDIR='" + "#{lib}/httpd/modules".gsub("\\", "\\\\").gsub("@", "\\@") + "'"
    end

    # Update error message in apache sapi to better explain the requirements
    # of using Apache http in combination with php if the non-compatible MPM
    # has been selected. Homebrew has chosen not to support being able to
    # compile a thread safe version of PHP and therefore it is not
    # possible to recompile as suggested in the original message
    inreplace "sapi/apache2handler/sapi_apache2.c",
              "You need to recompile PHP.",
              "Homebrew PHP does not support a thread-safe php binary. " \
              "To use the PHP apache sapi please change " \
              "your httpd config to use the prefork MPM"

    inreplace "sapi/fpm/php-fpm.conf.in", ";daemonize = yes", "daemonize = no"

    config_path = etc/"php/#{version.major_minor}"
    # Prevent system pear config from inhibiting pear install
    (config_path/"pear.conf").delete if (config_path/"pear.conf").exist?

    # Prevent homebrew from hardcoding path to sed shim in phpize script
    ENV["lt_cv_path_SED"] = "sed"

    # Identify build provider in php -v output and phpinfo()
    ENV["PHP_BUILD_PROVIDER"] = "Shivam Mathur"

    # system pkg-config missing
    if OS.mac?
      sdk_path = MacOS.sdk_for_formula(self).path
      ENV["SASL_CFLAGS"] = "-I#{sdk_path}/usr/include/sasl"
      ENV["SASL_LIBS"] = "-lsasl2"

      # Each extension needs a direct reference to the sdk path or it won't find the headers
      headers_path = "=#{sdk_path}/usr"
      gettext_path = "=#{formula_opt_prefix("gettext")}"
    else
      ENV["BZIP_DIR"] = formula_opt_prefix("bzip2")
    end

    # `_www` only exists on macOS.
    fpm_user = OS.mac? ? "_www" : "www-data"
    fpm_group = OS.mac? ? "_www" : "www-data"

    args = %W[
      --prefix=#{prefix}
      --localstatedir=#{var}
      --sysconfdir=#{config_path}
      --with-config-file-path=#{config_path}
      --with-config-file-scan-dir=#{config_path}/conf.d
      --with-pear=#{pkgshare}/pear
      --enable-bcmath
      --enable-calendar
      --enable-dba
      --enable-exif
      --enable-ftp
      --enable-fpm
      --enable-gd
      --enable-intl
      --enable-mbregex
      --enable-mbstring
      --enable-mysqlnd
      --enable-pcntl
      --enable-phpdbg
      --enable-phpdbg-readline
      --enable-shmop
      --enable-soap
      --enable-sockets
      --enable-sysvmsg
      --enable-sysvsem
      --enable-sysvshm
      --with-apxs2=#{formula_opt_bin("httpd")}/apxs
      --with-bz2#{headers_path}
      --with-capstone
      --with-curl
      --with-external-gd
      --with-external-pcre
      --with-ffi
      --with-fpm-user=#{fpm_user}
      --with-fpm-group=#{fpm_group}
      --with-gettext#{gettext_path}
      --with-gmp=#{formula_opt_prefix("gmp")}
      --with-iconv#{headers_path}
      --with-layout=GNU
      --with-ldap-sasl
      --with-ldap=#{formula_opt_prefix("openldap")}
      --with-libxml
      --with-libedit
      --with-mhash#{headers_path}
      --with-mysql-sock=/tmp/mysql.sock
      --with-mysqli=mysqlnd
      --with-ndbm#{headers_path}
      --with-openssl
      --with-password-argon2
      --with-pdo-dblib=#{formula_opt_prefix("freetds")}
      --with-pdo-mysql=mysqlnd
      --with-pdo-odbc=unixODBC,#{formula_opt_prefix("unixodbc")}
      --with-pdo-pgsql=#{formula_opt_prefix("libpq")}
      --with-pdo-sqlite
      --with-pgsql=#{formula_opt_prefix("libpq")}
      --enable-pic
      --with-snmp=#{formula_opt_prefix("net-snmp")}
      --with-sodium
      --with-sqlite3
      --with-tidy=#{formula_opt_prefix("tidy-html5")}
      --with-unixODBC
      --with-xsl
      --with-zip
      --with-zlib
    ]

    if OS.mac?
      args << "--enable-dtrace"
    else
      args << "--disable-dtrace"
      args << "--without-ndbm"
      args << "--without-gdbm"
    end

    system "./configure", *args
    system "make"
    system "make", "install"

    # Allow pecl to install outside of Cellar
    extension_dir = Utils.safe_popen_read(bin/"php-config", "--extension-dir").chomp
    orig_ext_dir = File.basename(extension_dir)
    inreplace bin/"php-config", lib/"php", prefix/"pecl"
    inreplace ["php.ini-development", "php.ini-production"] do |s|
      s.gsub! %r{; ?extension_dir = "\./"}, "extension_dir = \"#{HOMEBREW_PREFIX}/lib/php/pecl/#{orig_ext_dir}\""

      # Use OpenSSL cert bundle
      openssl = Formula["openssl@3"]
      s.gsub!(/; ?openssl\.cafile=/, "openssl.cafile = \"#{openssl.pkgetc}/cert.pem\"")
      s.gsub!(/; ?openssl\.capath=/, "openssl.capath = \"#{openssl.pkgetc}/certs\"")
    end

    config_files = {
      "php.ini-development"   => "php.ini",
      "php.ini-production"    => "php.ini-production",
      "sapi/fpm/php-fpm.conf" => "php-fpm.conf",
      "sapi/fpm/www.conf"     => "php-fpm.d/www.conf",
    }
    config_files.each_value do |dst|
      dst_default = config_path/"#{dst}.default"
      rm dst_default if dst_default.exist?
    end
    config_path.install config_files
    (config_path/"conf.d").mkpath

    unless (var/"log/php-fpm.log").exist?
      (var/"log").mkpath
      touch var/"log/php-fpm.log"
    end
  end

  post_install_steps do
    set_permissions ["pear/.channels", "pear/.channels/.alias"], "0755", base: :pkgshare, recursive: false
    set_permissions [
      "pear/.depdblock",
      "pear/.filemap",
      "pear/.depdb",
      "pear/.lock",
      "pear/.channels/*",
      "pear/.channels/.alias/*",
    ], "0644", base: :pkgshare, recursive: false

    # Custom location for extensions installed via pecl
    mkdir_p "lib/php/pecl", base: :homebrew_prefix
    unless_path_exists "pecl", base: :prefix do
      symlink "lib/php/pecl", "pecl", source_base: :homebrew_prefix, target_base: :prefix
    end

    # fix pear config to install outside cellar
    run "/bin/cp", args: %w[-R {{pkgshare}}/pear/. {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}]
    run "pear", base: :bin, args: %w[config-set php_ini {{etc}}/php/{{version.major_minor}}/php.ini system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}"
    run "pear", base: :bin, args: %w[config-set php_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}} system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/doc"
    run "pear", base: :bin,
                args: %w[config-set doc_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/doc system]
    run "/bin/sh", args: ["-ec", <<~SH, "--", "{{bin}}", "{{HOMEBREW_PREFIX}}/lib/php/pecl"]
      extension_dir="$("$1/php-config" --extension-dir)"
      ext_dir="$2/${extension_dir##*/}"
      mkdir -p "$ext_dir"
      exec "$1/pear" config-set ext_dir "$ext_dir" system
    SH
    run "pear", base: :bin, args: %w[config-set bin_dir {{opt_prefix}}/bin system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/data"
    run "pear", base: :bin,
                args: %w[config-set data_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/data system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/cfg"
    run "pear", base: :bin,
                args: %w[config-set cfg_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/cfg system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/htdocs"
    run "pear", base: :bin,
                args: %w[config-set www_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/htdocs system]
    run "pear", base: :bin, args: %w[config-set man_dir {{HOMEBREW_PREFIX}}/share/man system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/test"
    run "pear", base: :bin,
                args: %w[config-set test_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}/test system]
    run "pear", base: :bin, args: %w[config-set php_bin {{opt_prefix}}/bin/php system]

    run "pear", base: :bin, args: ["update-channels"]
  end

  def caveats
    <<~EOS
      To enable PHP in Apache add the following to httpd.conf and restart Apache:
          LoadModule php_module #{opt_lib}/httpd/modules/libphp.so

          <FilesMatch \\.php$>
              SetHandler application/x-httpd-php
          </FilesMatch>

      Finally, check DirectoryIndex includes index.php
          DirectoryIndex index.php index.html

      The php.ini and php-fpm.ini file can be found in:
          #{etc}/php/#{version.major_minor}/
    EOS
  end

  service do
    run [opt_sbin/"php-fpm", "--nodaemonize"]
    run_type :immediate
    keep_alive true
    error_log_path var/"log/php-fpm.log"
    working_dir var
  end

  test do
    assert_match(/^Zend OPcache$/, shell_output("#{bin}/php -i"), "Zend OPCache extension not loaded")

    # Test related to libxml2 and https://github.com/Homebrew/homebrew-core/issues/28398
    require "utils/linkage"
    libpq = formula_opt_lib("libpq")/shared_library("libpq")
    assert Utils.binary_linked_to_library?(bin/"php", libpq), "No linkage with Homebrew #{libpq.basename}!"

    system sbin/"php-fpm", "-t"
    system bin/"phpdbg", "-V"
    system bin/"php-cgi", "-m"

    port = free_port
    port_fpm = free_port
    expected_output = /^Hello world!$/

    (testpath/"index.php").write <<~PHP
      <?php
      echo 'Hello world!' . PHP_EOL;
      var_dump(ldap_connect());
      $session = new SNMP(SNMP::VERSION_1, '127.0.0.1', 'public');
      var_dump(@$session->get('sysDescr.0'));
    PHP

    main_config = <<~EOS
      Listen #{port}
      ServerName localhost:#{port}
      DocumentRoot "#{testpath}"
      ErrorLog "#{testpath}/httpd-error.log"
      ServerRoot "#{formula_opt_prefix("httpd")}"
      PidFile "#{testpath}/httpd.pid"
      Mutex file:#{testpath} default
      LoadModule authz_core_module lib/httpd/modules/mod_authz_core.so
      LoadModule unixd_module lib/httpd/modules/mod_unixd.so
      LoadModule dir_module lib/httpd/modules/mod_dir.so
      DirectoryIndex index.php
    EOS

    (testpath/"httpd.conf").write <<~EOS
      #{main_config}
      LoadModule mpm_prefork_module lib/httpd/modules/mod_mpm_prefork.so
      LoadModule php_module #{lib}/httpd/modules/libphp.so
      <FilesMatch \\.(php|phar)$>
        SetHandler application/x-httpd-php
      </FilesMatch>
    EOS

    (testpath/"fpm.conf").write <<~INI
      [global]
      daemonize=no
      [www]
      listen = 127.0.0.1:#{port_fpm}
      pm = dynamic
      pm.max_children = 5
      pm.start_servers = 2
      pm.min_spare_servers = 1
      pm.max_spare_servers = 3
    INI

    (testpath/"httpd-fpm.conf").write <<~EOS
      #{main_config}
      LoadModule mpm_event_module lib/httpd/modules/mod_mpm_event.so
      LoadModule proxy_module lib/httpd/modules/mod_proxy.so
      LoadModule proxy_fcgi_module lib/httpd/modules/mod_proxy_fcgi.so
      <FilesMatch \\.(php|phar)$>
        SetHandler "proxy:fcgi://127.0.0.1:#{port_fpm}"
      </FilesMatch>
    EOS

    begin
      pid = spawn formula_opt_bin("httpd")/"httpd", "-X", "-f", "#{testpath}/httpd.conf"
      sleep 10
      assert_match expected_output, shell_output("curl -s 127.0.0.1:#{port}")

      Process.kill("TERM", pid)
      Process.wait(pid)

      fpm_pid = spawn sbin/"php-fpm", "-y", "fpm.conf"
      pid = spawn formula_opt_bin("httpd")/"httpd", "-X", "-f", "#{testpath}/httpd-fpm.conf"
      sleep 10
      assert_match expected_output, shell_output("curl -s 127.0.0.1:#{port}")
    ensure
      if pid
        Process.kill("TERM", pid)
        Process.wait(pid)
      end
      if fpm_pid
        Process.kill("TERM", fpm_pid)
        Process.wait(fpm_pid)
      end
    end
  end
end
