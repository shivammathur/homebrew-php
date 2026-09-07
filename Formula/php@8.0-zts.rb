class PhpAT80Zts < Formula
  desc "General-purpose scripting language"
  homepage "https://www.php.net/"
  url "https://github.com/shivammathur/php-src-backports/archive/1bb9988fd6c151c783653e3a2257c1a0897e6633.tar.gz"
  version "8.0.30"
  sha256 "1969f16cab5dbf112b0f1115279d061f29f63d8910cc56c497cff59c853f9f6c"
  license "PHP-3.01"
  revision 8

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    sha256 arm64_tahoe:   "8c608e9a9c697a0ae6388c77be70e542dd23c08a670a3c8034b503fb6c347550"
    sha256 arm64_sequoia: "b59c19cda3a7bef521a5f384a8ed1b733206e1042dd739d573427a97a2413c23"
    sha256 arm64_sonoma:  "6deccbd159703be71786d0ef2ba52a1795a45215820e166dc2528dc04866bf71"
    sha256 arm64_linux:   "c2d73c02b1bde34d336c3a193cfa1605cd1f555ff37c974197c7c96734e0d731"
    sha256 x86_64_linux:  "b3801595ce3525e14f20bd1a893f61f1cd5ae1771d090c68e7fcd89625d0e317"
  end

  keg_only :versioned_formula

  # This PHP version is not supported upstream as of 2023-11-26.
  # Although, this was built with back-ported security patches,
  # we recommended to use a currently supported PHP version.
  # For more details, refer to https://www.php.net/eol.php
  deprecate! date: "2023-11-26", because: :deprecated_upstream

  depends_on "bison" => :build
  depends_on "httpd" => [:build, :test]
  depends_on "pkgconf" => :build
  depends_on "re2c" => :build
  depends_on "apr"
  depends_on "apr-util"
  depends_on "argon2"
  depends_on "aspell"
  depends_on "autoconf"
  depends_on "curl"
  depends_on "freetds"
  depends_on "gd"
  depends_on "gmp"
  depends_on "icu4c@78"
  depends_on "krb5"
  depends_on "libpq"
  depends_on "libsodium"
  depends_on "libzip"
  depends_on "oniguruma"
  depends_on "openldap"
  depends_on "openssl@3"
  depends_on "pcre2"
  depends_on "sqlite"
  depends_on "tidy-html5"
  depends_on "unixodbc"

  uses_from_macos "xz" => :build
  uses_from_macos "bzip2"
  uses_from_macos "libedit"
  uses_from_macos "libffi"
  uses_from_macos "libxml2"
  uses_from_macos "libxslt"

  on_macos do
    depends_on "gettext"
    # PHP build system incorrectly links system libraries
    patch :DATA
  end

  on_linux do
    depends_on "zlib-ng-compat"
  end

  def install
    # PHP 8.0 still has K&R-style bcmath/intl sources that fail under C23.
    ENV.append "CFLAGS", "-std=gnu17"

    # Work around for building with Xcode 15.3
    if DevelopmentTools.clang_build_version >= 1500
      ENV.append "CFLAGS", "-Wno-incompatible-function-pointer-types"
      ENV.append "LDFLAGS", "-lresolv"
    end

    # Work around to support `icu4c` 75, which needs C++17.
    ENV["ICU_CXXFLAGS"] = "-std=c++17"

    # buildconf required due to system library linking bug patch
    system "./buildconf", "--force"

    inreplace "configure" do |s|
      s.gsub! "APACHE_THREADED_MPM=`$APXS_HTTPD -V 2>/dev/null | grep 'threaded:.*yes'`",
              "APACHE_THREADED_MPM="
      s.gsub! "APXS_LIBEXECDIR='$(INSTALL_ROOT)'`$APXS -q LIBEXECDIR`",
              "APXS_LIBEXECDIR='$(INSTALL_ROOT)#{lib}/httpd/modules'"
      s.gsub! "-z `$APXS -q SYSCONFDIR`",
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

    config_path = etc/"php/#{php_version}"
    # Prevent system pear config from inhibiting pear install
    (config_path/"pear.conf").delete if (config_path/"pear.conf").exist?

    # Prevent homebrew from hardcoding path to sed shim in phpize script
    ENV["lt_cv_path_SED"] = "sed"

    # Identify build provider in phpinfo()
    ENV["PHP_BUILD_PROVIDER"] = "Shivam Mathur"

    # system pkg-config missing
    ENV["KERBEROS_CFLAGS"] = " "
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
      --disable-zend-signals
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
      --enable-phpdbg-webhelper
      --enable-shmop
      --enable-soap
      --enable-sockets
      --enable-sysvmsg
      --enable-sysvsem
      --enable-sysvshm
      --enable-zts
      --with-apxs2=#{formula_opt_bin("httpd")}/apxs
      --with-bz2#{headers_path}
      --with-curl
      --with-external-gd
      --with-external-pcre
      --with-ffi
      --with-fpm-user=#{fpm_user}
      --with-fpm-group=#{fpm_group}
      --with-gettext#{gettext_path}
      --with-gmp=#{formula_opt_prefix("gmp")}
      --with-iconv#{headers_path}
      --with-kerberos
      --with-layout=GNU
      --with-ldap=#{formula_opt_prefix("openldap")}
      --with-libxml
      --with-libedit
      --with-mhash#{headers_path}
      --with-mysql-sock=/tmp/mysql.sock
      --with-mysqli=mysqlnd
      --with-ndbm#{headers_path}
      --with-openssl
      --with-password-argon2=#{formula_opt_prefix("argon2")}
      --with-pdo-dblib=#{formula_opt_prefix("freetds")}
      --with-pdo-mysql=mysqlnd
      --with-pdo-odbc=unixODBC,#{formula_opt_prefix("unixodbc")}
      --with-pdo-pgsql=#{formula_opt_prefix("libpq")}
      --with-pdo-sqlite
      --with-pgsql=#{formula_opt_prefix("libpq")}
      --with-pic
      --with-pspell=#{formula_opt_prefix("aspell")}
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
      args << "--with-ldap-sasl"
      args << "--with-os-sdkpath=#{sdk_path}"
    else
      args << "--disable-dtrace"
      args << "--without-ldap-sasl"
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
    run "/bin/cp", args: %w[-R {{pkgshare}}/pear/. {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts]
    run "pear", base: :bin, args: %w[config-set php_ini {{etc}}/php/{{version.major_minor}}-zts/php.ini system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts"
    run "pear", base: :bin,
                args: %w[config-set php_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/doc"
    run "pear", base: :bin,
                args: %w[config-set doc_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/doc system]
    run "/bin/sh", args: ["-ec", <<~SH, "--", "{{bin}}", "{{HOMEBREW_PREFIX}}/lib/php/pecl"]
      extension_dir="$("$1/php-config" --extension-dir)"
      ext_dir="$2/${extension_dir##*/}"
      mkdir -p "$ext_dir"
      exec "$1/pear" config-set ext_dir "$ext_dir" system
    SH
    run "pear", base: :bin, args: %w[config-set bin_dir {{opt_prefix}}/bin system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/data"
    run "pear", base: :bin,
                args: %w[config-set data_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/data system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/cfg"
    run "pear", base: :bin,
                args: %w[config-set cfg_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/cfg system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/htdocs"
    run "pear", base: :bin,
                args: %w[config-set www_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/htdocs system]
    run "pear", base: :bin, args: %w[config-set man_dir {{HOMEBREW_PREFIX}}/share/man system]
    mkdir_p "{{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/test"
    run "pear", base: :bin,
                args: %w[config-set test_dir {{HOMEBREW_PREFIX}}/share/pear@{{version.major_minor}}-zts/test system]
    run "pear", base: :bin, args: %w[config-set php_bin {{opt_prefix}}/bin/php system]

    run "pear", base: :bin, args: ["update-channels"], print_stdout: true

    mkdir_p "php/{{version.major_minor}}-zts/conf.d", base: :etc

    run "php", base: :bin, args: [
      "-n", "-r", <<~'PHP',
        list(, $php_config, $opt_prefix, $config_path) = $argv;
        exec(escapeshellarg($php_config) . ' --extension-dir', $output, $status);
        if ($status !== 0) {
            exit($status);
        }
        $php_ext_dir = $opt_prefix . '/lib/php/' . basename(implode("\n", $output));
        foreach (array_slice($argv, 4) as $extension) {
            $path = $config_path . '/conf.d/ext-' . $extension . '.ini';
            $type = $extension === 'opcache' ? 'zend_extension' : 'extension';
            $library = $php_ext_dir . '/' . $extension . '.so';
            if (file_exists($path)) {
                $content = file_get_contents($path);
                if ($content === false) {
                    exit(1);
                }
                $content = preg_replace_callback('/' . $type . '=.*$/m', function () use ($type, $library) {
                    return $type . '=' . $library;
                }, $content, -1, $count);
                if ($count === 0) {
                    fwrite(STDERR, 'Cannot update ' . $type . ' in ' . $path . "\n");
                    exit(1);
                }
            } else {
                $content = '[' . $extension . "]\n" . $type . '="' . $library . "\"\n";
            }
            if (file_put_contents($path, $content) === false) {
                exit(1);
            }
        }
      PHP
      "--",
      "{{bin}}/php-config",
      "{{opt_prefix}}",
      "{{etc}}/php/{{version.major_minor}}-zts",
      "opcache"
    ]
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
          #{etc}/php/#{php_version}/
    EOS
  end

  def php_version
    version.to_s.split(".")[0..1].join(".") + "-zts"
  end

  service do
    run [opt_sbin/"php-fpm", "--nodaemonize"]
    run_type :immediate
    keep_alive true
    error_log_path var/"log/php-fpm.log"
    working_dir var
  end

  test do
    assert_match(/^Zend OPcache$/, shell_output("#{bin}/php -i"),
      "Zend OPCache extension not loaded")
    # Test related to libxml2 and
    # https://github.com/Homebrew/homebrew-core/issues/28398
    assert_includes (bin/"php").dynamically_linked_libraries,
                    (formula_opt_lib("libpq")/shared_library("libpq", 5)).to_s

    system "#{sbin}/php-fpm", "-t"
    system bin/"phpdbg", "-V"
    system bin/"php-cgi", "-m"
    # Prevent SNMP extension to be added
    refute_match(/^snmp$/, shell_output("#{bin}/php -m"),
      "SNMP extension doesn't work reliably with Homebrew on High Sierra")
    begin
      port = free_port
      port_fpm = free_port

      expected_output = /^Hello world!$/
      (testpath/"index.php").write <<~PHP
        <?php
        echo 'Hello world!' . PHP_EOL;
        var_dump(ldap_connect());
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

__END__
diff --git a/build/php.m4 b/build/php.m4
index 3624a33a8e..d17a635c2c 100644
--- a/build/php.m4
+++ b/build/php.m4
@@ -425,7 +425,7 @@ dnl
 dnl Adds a path to linkpath/runpath (LDFLAGS).
 dnl
 AC_DEFUN([PHP_ADD_LIBPATH],[
-  if test "$1" != "/usr/$PHP_LIBDIR" && test "$1" != "/usr/lib"; then
+  if test "$1" != "$PHP_OS_SDKPATH/usr/$PHP_LIBDIR" && test "$1" != "/usr/lib"; then
     PHP_EXPAND_PATH($1, ai_p)
     ifelse([$2],,[
       _PHP_ADD_LIBPATH_GLOBAL([$ai_p])
@@ -470,7 +470,7 @@ dnl
 dnl Add an include path. If before is 1, add in the beginning of INCLUDES.
 dnl
 AC_DEFUN([PHP_ADD_INCLUDE],[
-  if test "$1" != "/usr/include"; then
+  if test "$1" != "$PHP_OS_SDKPATH/usr/include"; then
     PHP_EXPAND_PATH($1, ai_p)
     PHP_RUN_ONCE(INCLUDEPATH, $ai_p, [
       if test "$2"; then
diff --git a/configure.ac b/configure.ac
index 36c6e5e3e2..71b1a16607 100644
--- a/configure.ac
+++ b/configure.ac
@@ -190,6 +190,14 @@ PHP_ARG_WITH([libdir],
   [lib],
   [no])

+dnl Support systems with system libraries/includes in e.g. /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.14.sdk.
+PHP_ARG_WITH([os-sdkpath],
+  [for system SDK directory],
+  [AS_HELP_STRING([--with-os-sdkpath=NAME],
+    [Ignore system libraries and includes in NAME rather than /])],
+  [],
+  [no])
+
 PHP_ARG_ENABLE([rpath],
   [whether to enable runpaths],
   [AS_HELP_STRING([--disable-rpath],
