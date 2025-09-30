class PhpAT80Debug < Formula
  desc "General-purpose scripting language"
  homepage "https://www.php.net/"
  url "https://github.com/shivammathur/php-src-backports/archive/4f0b7adf91b6398d1591f613893f90c33da9e0e9.tar.gz"
  version "8.0.30"
  sha256 "2f9e07b59658cd52fa6631c3a42c2a5dfd5802ce3255f5aed2d4f1a3d060bfcb"
  license "PHP-3.01"
  revision 7

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    rebuild 2
    sha256 arm64_sequoia: "442e1a5bd1a89c1876b3d9f509396b0ac07bb5649fc443ebb269357ccc48be8a"
    sha256 arm64_sonoma:  "41f8681e4a600b61a19c47e170ac12bcea8cb879b4f885a6de9c4010a5b8720f"
    sha256 arm64_ventura: "f28d1abd7620f58796c99a8782de3a07ef12538f88c42ad6fe7dfde86641cb7b"
    sha256 ventura:       "2ca5ce0f2bb4b35612c020e4a1ee75c16d660c23ba503394ef5ecae3bc9a4f4b"
    sha256 arm64_linux:   "f9a46dd545ff7839714d1e967685d08acea59267c3e2718adb202952d72e59be"
    sha256 x86_64_linux:  "19c98c07a0d67b179b89b546d4c0e91eba2233fde59949ce714e6d3d59cc77f8"
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
  depends_on "gettext"
  depends_on "gmp"
  depends_on "icu4c@77"
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
  uses_from_macos "zlib"

  on_macos do
    depends_on "gcc" => :build # must never be a runtime dependency
  end

  # https://github.com/Homebrew/homebrew-core/issues/235820
  # https://clang.llvm.org/docs/UsersManual.html#gcc-extensions-not-implemented-yet
  fails_with :clang do
    cause "Performs worse due to lack of general global register variables"
  end

  # Backport fixes for curl on macOS.
  # Remove after the next patch release.
  patch :DATA

  def install
    # Work around for building with Xcode 15.3
    if DevelopmentTools.clang_build_version >= 1500
      ENV.append "CFLAGS", "-Wno-incompatible-function-pointer-types"
      ENV.append "LDFLAGS", "-lresolv"
    end

    if OS.mac? && ENV.compiler.to_s.start_with?("gcc")
      ENV.append "CFLAGS", "-Wno-incompatible-pointer-types"
      inreplace "ext/gd/gd.c", "func_p)()", "func_p)(...)"
      inreplace "ext/standard/scanf.c", "zend_long (*fn)()", "zend_long (*fn)(...)"
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

    config_path = etc/"php/#{version.major_minor}-debug"
    # Prevent system pear config from inhibiting pear install
    (config_path/"pear.conf").delete if (config_path/"pear.conf").exist?

    # Prevent homebrew from hardcoding path to sed shim in phpize script
    ENV["lt_cv_path_SED"] = "sed"

    # Identify build provider in phpinfo()
    ENV["PHP_BUILD_PROVIDER"] = "Shivam Mathur"

    # system pkg-config missing
    ENV["KERBEROS_CFLAGS"] = " "
    if OS.mac?
      ENV["SASL_CFLAGS"] = "-I#{MacOS.sdk_path_if_needed}/usr/include/sasl"
      ENV["SASL_LIBS"] = "-lsasl2"
    else
      ENV["SQLITE_CFLAGS"] = "-I#{Formula["sqlite"].opt_include}"
      ENV["SQLITE_LIBS"] = "-lsqlite3"
      ENV["BZIP_DIR"] = Formula["bzip2"].opt_prefix
    end

    # Each extension that is built on Mojave needs a direct reference to the
    # sdk path or it won't find the headers
    headers_path = "=#{MacOS.sdk_path_if_needed}/usr" if OS.mac?

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
      --disable-intl
      --enable-bcmath
      --enable-calendar
      --enable-dba
      --enable-debug
      --enable-exif
      --enable-ftp
      --enable-fpm
      --enable-gd
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
      --with-apxs2=#{Formula["httpd"].opt_bin}/apxs
      --with-bz2#{headers_path}
      --with-curl
      --with-external-gd
      --with-external-pcre
      --with-ffi
      --with-fpm-user=#{fpm_user}
      --with-fpm-group=#{fpm_group}
      --with-gettext=#{Formula["gettext"].opt_prefix}
      --with-gmp=#{Formula["gmp"].opt_prefix}
      --with-iconv#{headers_path}
      --with-kerberos
      --with-layout=GNU
      --with-ldap=#{Formula["openldap"].opt_prefix}
      --with-libxml
      --with-libedit
      --with-mhash#{headers_path}
      --with-mysql-sock=/tmp/mysql.sock
      --with-mysqli=mysqlnd
      --with-ndbm#{headers_path}
      --with-openssl
      --with-password-argon2=#{Formula["argon2"].opt_prefix}
      --with-pdo-dblib=#{Formula["freetds"].opt_prefix}
      --with-pdo-mysql=mysqlnd
      --with-pdo-odbc=unixODBC,#{Formula["unixodbc"].opt_prefix}
      --with-pdo-pgsql=#{Formula["libpq"].opt_prefix}
      --with-pdo-sqlite
      --with-pgsql=#{Formula["libpq"].opt_prefix}
      --with-pic
      --with-pspell=#{Formula["aspell"].opt_prefix}
      --with-sodium
      --with-sqlite3
      --with-tidy=#{Formula["tidy-html5"].opt_prefix}
      --with-unixODBC
      --with-xsl
      --with-zip
      --with-zlib
    ]

    if OS.mac?
      args << "--enable-dtrace"
      args << "--with-ldap-sasl"
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
    extension_dir = Utils.safe_popen_read("#{bin}/php-config", "--extension-dir").chomp
    orig_ext_dir = File.basename(extension_dir)
    inreplace bin/"php-config", lib/"php", prefix/"pecl"
    %w[development production].each do |mode|
      inreplace "php.ini-#{mode}", %r{; ?extension_dir = "\./"},
        "extension_dir = \"#{HOMEBREW_PREFIX}/lib/php/pecl/#{orig_ext_dir}\""
    end

    # Use OpenSSL cert bundle
    openssl = Formula["openssl@3"]
    %w[development production].each do |mode|
      inreplace "php.ini-#{mode}", /; ?openssl\.cafile=/,
        "openssl.cafile = \"#{openssl.pkgetc}/cert.pem\""
      inreplace "php.ini-#{mode}", /; ?openssl\.capath=/,
        "openssl.capath = \"#{openssl.pkgetc}/certs\""
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

    cd "ext/intl" do
      system bin/"phpize"
      if OS.mac?
        # rubocop:disable all
        ENV["CC"] = "/usr/bin/clang"
        ENV["CXX"] = "/usr/bin/clang++"
        # rubocop:enable all
      end
      system "./configure", "--with-php-config=#{bin}/php-config"
      system "make"
      system "make", "install", "EXTENSION_DIR=#{lib}/php/#{orig_ext_dir}"
    end
  end

  def post_install
    pear_prefix = pkgshare/"pear"
    pear_files = %W[
      #{pear_prefix}/.depdblock
      #{pear_prefix}/.filemap
      #{pear_prefix}/.depdb
      #{pear_prefix}/.lock
    ]

    %W[
      #{pear_prefix}/.channels
      #{pear_prefix}/.channels/.alias
    ].each do |f|
      chmod 0755, f
      pear_files.concat(Dir["#{f}/*"])
    end

    chmod 0644, pear_files

    # Custom location for extensions installed via pecl
    pecl_path = HOMEBREW_PREFIX/"lib/php/pecl"
    pecl_path.mkpath
    ln_s pecl_path, prefix/"pecl" unless (prefix/"pecl").exist?
    extension_dir = Utils.safe_popen_read("#{bin}/php-config", "--extension-dir").chomp
    php_basename = File.basename(extension_dir)
    php_ext_dir = opt_prefix/"lib/php"/php_basename

    # fix pear config to install outside cellar
    pear_path = HOMEBREW_PREFIX/"share/pear@#{version.major_minor}-debug"
    cp_r pkgshare/"pear/.", pear_path
    {
      "php_ini"  => etc/"php/#{version.major_minor}-debug/php.ini",
      "php_dir"  => pear_path,
      "doc_dir"  => pear_path/"doc",
      "ext_dir"  => pecl_path/php_basename,
      "bin_dir"  => opt_bin,
      "data_dir" => pear_path/"data",
      "cfg_dir"  => pear_path/"cfg",
      "www_dir"  => pear_path/"htdocs",
      "man_dir"  => HOMEBREW_PREFIX/"share/man",
      "test_dir" => pear_path/"test",
      "php_bin"  => opt_bin/"php",
    }.each do |key, value|
      value.mkpath if /(?<!bin|man)_dir$/.match?(key)
      system bin/"pear", "config-set", key, value, "system"
    end

    system bin/"pear", "update-channels"

    %w[
      intl
      opcache
    ].each do |e|
      ext_config_path = etc/"php/#{version.major_minor}-debug/conf.d/ext-#{e}.ini"
      extension_type = (e == "opcache") ? "zend_extension" : "extension"
      if ext_config_path.exist?
        inreplace ext_config_path,
          /#{extension_type}=.*$/, "#{extension_type}=#{php_ext_dir}/#{e}.so"
      else
        ext_config_path.write <<~EOS
          [#{e}]
          #{extension_type}="#{php_ext_dir}/#{e}.so"
        EOS
      end
    end
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
          #{etc}/php/#{version.major_minor}-debug/
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
    assert_match(/^Zend OPcache$/, shell_output("#{bin}/php -i"),
      "Zend OPCache extension not loaded")
    # Test related to libxml2 and
    # https://github.com/Homebrew/homebrew-core/issues/28398
    assert_includes (bin/"php").dynamically_linked_libraries,
                    (Formula["libpq"].opt_lib/shared_library("libpq", 5)).to_s

    (testpath/"test.php").write <<~PHP
      <?php
      $formatter = new NumberFormatter('en_US', NumberFormatter::DECIMAL);
      echo $formatter->format(1234567), PHP_EOL;

      $formatter = new MessageFormatter('de_DE', '{0,number,#,###.##} MB');
      echo $formatter->format([12345.6789]);
      ?>
    PHP
    assert_equal "1,234,567\n12.345,68 MB", shell_output("#{bin}/php test.php")
    assert_match "intl", shell_output("#{bin}/php -m")

    system "#{sbin}/php-fpm", "-t"
    system "#{bin}/phpdbg", "-V"
    system "#{bin}/php-cgi", "-m"
    # Prevent SNMP extension to be added
    refute_match(/^snmp$/, shell_output("#{bin}/php -m"),
      "SNMP extension doesn't work reliably with Homebrew on High Sierra")
    begin
      port = free_port
      port_fpm = free_port

      expected_output = /^Hello world!$/
      (testpath/"index.php").write <<~EOS
        <?php
        echo 'Hello world!' . PHP_EOL;
        var_dump(ldap_connect());
      EOS
      main_config = <<~EOS
        Listen #{port}
        ServerName localhost:#{port}
        DocumentRoot "#{testpath}"
        ErrorLog "#{testpath}/httpd-error.log"
        ServerRoot "#{Formula["httpd"].opt_prefix}"
        PidFile "#{testpath}/httpd.pid"
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

      (testpath/"fpm.conf").write <<~EOS
        [global]
        daemonize=no
        [www]
        listen = 127.0.0.1:#{port_fpm}
        pm = dynamic
        pm.max_children = 5
        pm.start_servers = 2
        pm.min_spare_servers = 1
        pm.max_spare_servers = 3
      EOS

      (testpath/"httpd-fpm.conf").write <<~EOS
        #{main_config}
        LoadModule mpm_event_module lib/httpd/modules/mod_mpm_event.so
        LoadModule proxy_module lib/httpd/modules/mod_proxy.so
        LoadModule proxy_fcgi_module lib/httpd/modules/mod_proxy_fcgi.so
        <FilesMatch \\.(php|phar)$>
          SetHandler "proxy:fcgi://127.0.0.1:#{port_fpm}"
        </FilesMatch>
      EOS

      pid = fork do
        exec Formula["httpd"].opt_bin/"httpd", "-X", "-f", "#{testpath}/httpd.conf"
      end
      sleep 5

      assert_match expected_output, shell_output("curl -s 127.0.0.1:#{port}")

      Process.kill("TERM", pid)
      Process.wait(pid)

      fpm_pid = fork do
        exec sbin/"php-fpm", "-y", "fpm.conf"
      end
      pid = fork do
        exec Formula["httpd"].opt_bin/"httpd", "-X", "-f", "#{testpath}/httpd-fpm.conf"
      end
      sleep 3

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
diff --git a/ext/curl/interface.c b/ext/curl/interface.c
index 134de48d6fe..90f486dfe77 100644
--- a/ext/curl/interface.c
+++ b/ext/curl/interface.c
@@ -1453,11 +1453,11 @@ static int curl_fnmatch(void *ctx, const char *pattern, const char *string)
 /* }}} */
 
 /* {{{ curl_progress */
-static size_t curl_progress(void *clientp, double dltotal, double dlnow, double ultotal, double ulnow)
+static int curl_progress(void *clientp, double dltotal, double dlnow, double ultotal, double ulnow)
 {
 	php_curl *ch = (php_curl *)clientp;
 	php_curl_progress *t = ch->handlers->progress;
-	size_t	rval = 0;
+	int rval = 0;
 
 #if PHP_CURL_DEBUG
 	fprintf(stderr, "curl_progress() called\n");
@@ -1817,8 +1817,8 @@ static void _php_curl_set_default_options(php_curl *ch)
 {
 	char *cainfo;
 
-	curl_easy_setopt(ch->cp, CURLOPT_NOPROGRESS,        1);
-	curl_easy_setopt(ch->cp, CURLOPT_VERBOSE,           0);
+	curl_easy_setopt(ch->cp, CURLOPT_NOPROGRESS,        1L);
+	curl_easy_setopt(ch->cp, CURLOPT_VERBOSE,           0L);
 	curl_easy_setopt(ch->cp, CURLOPT_ERRORBUFFER,       ch->err.str);
 	curl_easy_setopt(ch->cp, CURLOPT_WRITEFUNCTION,     curl_write);
 	curl_easy_setopt(ch->cp, CURLOPT_FILE,              (void *) ch);
@@ -1829,8 +1829,8 @@ static void _php_curl_set_default_options(php_curl *ch)
 #ifndef ZTS
 	curl_easy_setopt(ch->cp, CURLOPT_DNS_USE_GLOBAL_CACHE, 1);
 #endif
-	curl_easy_setopt(ch->cp, CURLOPT_DNS_CACHE_TIMEOUT, 120);
-	curl_easy_setopt(ch->cp, CURLOPT_MAXREDIRS, 20); /* prevent infinite redirects */
+	curl_easy_setopt(ch->cp, CURLOPT_DNS_CACHE_TIMEOUT, 120L);
+	curl_easy_setopt(ch->cp, CURLOPT_MAXREDIRS, 20L); /* prevent infinite redirects */
 
 	cainfo = INI_STR("openssl.cafile");
 	if (!(cainfo && cainfo[0] != '\0')) {
@@ -1841,7 +1841,7 @@ static void _php_curl_set_default_options(php_curl *ch)
 	}
 
 #ifdef ZTS
-	curl_easy_setopt(ch->cp, CURLOPT_NOSIGNAL, 1);
+	curl_easy_setopt(ch->cp, CURLOPT_NOSIGNAL, 1L);
 #endif
 }
 /* }}} */
@@ -2216,7 +2216,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue, bool i
 			lval = zval_get_long(zvalue);
 			if (lval == 1) {
 				php_error_docref(NULL, E_NOTICE, "CURLOPT_SSL_VERIFYHOST no longer accepts the value 1, value 2 will be used instead");
-				error = curl_easy_setopt(ch->cp, option, 2);
+				error = curl_easy_setopt(ch->cp, option, 2L);
 				break;
 			}
 		case CURLOPT_AUTOREFERER:
@@ -2377,7 +2377,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue, bool i
 				return 1;
 			}
 # endif
-			error = curl_easy_setopt(ch->cp, option, lval);
+			error = curl_easy_setopt(ch->cp, option, (long) lval);
 			break;
 		case CURLOPT_SAFE_UPLOAD:
 			if (!zend_is_true(zvalue)) {
@@ -2711,7 +2711,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue, bool i
 
 		case CURLOPT_FOLLOWLOCATION:
 			lval = zend_is_true(zvalue);
-			error = curl_easy_setopt(ch->cp, option, lval);
+			error = curl_easy_setopt(ch->cp, option, (long) lval);
 			break;
 
 		case CURLOPT_HEADERFUNCTION:
@@ -2729,7 +2729,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue, bool i
 					/* no need to build the mime structure for empty hashtables;
 					   also works around https://github.com/curl/curl/issues/6455 */
 					curl_easy_setopt(ch->cp, CURLOPT_POSTFIELDS, "");
-					error = curl_easy_setopt(ch->cp, CURLOPT_POSTFIELDSIZE, 0);
+					error = curl_easy_setopt(ch->cp, CURLOPT_POSTFIELDSIZE, 0L);
 				} else {
 					return build_mime_structure_from_hash(ch, zvalue);
 				}
@@ -2794,7 +2794,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue, bool i
 
 		case CURLOPT_POSTREDIR:
 			lval = zval_get_long(zvalue);
-			error = curl_easy_setopt(ch->cp, CURLOPT_POSTREDIR, lval & CURL_REDIR_POST_ALL);
+			error = curl_easy_setopt(ch->cp, CURLOPT_POSTREDIR, (long) (lval & CURL_REDIR_POST_ALL));
 			break;
 
 		/* the following options deal with files, therefore the open_basedir check
@@ -2829,11 +2829,11 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue, bool i
 			if (zend_is_true(zvalue)) {
 				curl_easy_setopt(ch->cp, CURLOPT_DEBUGFUNCTION, curl_debug);
 				curl_easy_setopt(ch->cp, CURLOPT_DEBUGDATA, (void *)ch);
-				curl_easy_setopt(ch->cp, CURLOPT_VERBOSE, 1);
+				curl_easy_setopt(ch->cp, CURLOPT_VERBOSE, 1L);
 			} else {
 				curl_easy_setopt(ch->cp, CURLOPT_DEBUGFUNCTION, NULL);
 				curl_easy_setopt(ch->cp, CURLOPT_DEBUGDATA, NULL);
-				curl_easy_setopt(ch->cp, CURLOPT_VERBOSE, 0);
+				curl_easy_setopt(ch->cp, CURLOPT_VERBOSE, 0L);
 			}
 			break;
