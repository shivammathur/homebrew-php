class PhpAT74Debug < Formula
  desc "General-purpose scripting language"
  homepage "https://www.php.net/"
  url "https://github.com/shivammathur/php-src-backports/archive/e5b417c927f43ba9c4b237a672de1ec60d6f77ca.tar.gz"
  version "7.4.33"
  sha256 "7f9b8e85407c223c3a45e11c1bb4fbebf66ef7c9008277eb1ddba2b5d1037384"
  license "PHP-3.01"
  revision 14

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    sha256 arm64_tahoe:   "f693026cb2d06a4cb1a41a617e266e2df5d9958ab2e083bc7b3f0890380e13b7"
    sha256 arm64_sequoia: "ccd25d51f525a0259eabd72eed94b7313c95759a1ed00bb813d939a82e311032"
    sha256 arm64_sonoma:  "5f5a59b713bbb3c35f47559b670233a225651b370b33777b7ac45d9dc8bfc979"
    sha256 sonoma:        "8a95925648e93c21ce8ab34a98168e92082cea22a1b32390d3e72e0223f1ba0f"
    sha256 arm64_linux:   "24b38d4dd6e1c630c6706ba240bf82298853d009b4015a22f10368e7dd2317ed"
    sha256 x86_64_linux:  "508561ff34b4bca326378e2426d4ada46e714f8211a5f9bf7ba79b5214025e51"
  end

  keg_only :versioned_formula

  # This PHP version is not supported upstream as of 2022-11-28.
  # Although, this was built with back-ported security patches,
  # we recommended to use a currently supported PHP version.
  # For more details, refer to https://www.php.net/eol.php
  deprecate! date: "2022-11-28", because: :deprecated_upstream

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
  depends_on "icu4c@78"
  depends_on "krb5"
  depends_on "libffi"
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

  # PHP build system incorrectly links system libraries
  # see https://github.com/php/php-src/issues/10680
  patch :DATA

  def install
    # Work around for building with Xcode 15.3
    if DevelopmentTools.clang_build_version >= 1500
      ENV.append "CFLAGS", "-Wno-incompatible-function-pointer-types"
      ENV.append "LDFLAGS", "-lresolv"
    end

    ENV.append "CFLAGS", "-Wno-incompatible-pointer-types" if OS.mac? && ENV.compiler.to_s.start_with?("gcc")

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
      --with-xmlrpc
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
    extension_dir = Utils.safe_popen_read(bin/"php-config", "--extension-dir").chomp
    orig_ext_dir = File.basename(extension_dir)
    inreplace bin/"php-config", lib/"php", prefix/"pecl"

    openssl = Formula["openssl@3"]
    %w[development production].each do |mode|
      inreplace "php.ini-#{mode}" do |s|
        # Allow pecl to install outside of Cellar
        s.gsub! %r{; ?extension_dir = "\./"}, "extension_dir = \"#{HOMEBREW_PREFIX}/lib/php/pecl/#{orig_ext_dir}\""

        # Use OpenSSL cert bundle
        s.gsub!(/; ?openssl\.cafile=/, "openssl.cafile = \"#{openssl.pkgetc}/cert.pem\"")
        s.gsub!(/; ?openssl\.capath=/, "openssl.capath = \"#{openssl.pkgetc}/certs\"")
      end
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
    extension_dir = Utils.safe_popen_read(bin/"php-config", "--extension-dir").chomp
    php_basename = File.basename(extension_dir)
    php_ext_dir = opt_prefix/"lib/php"/php_basename
    (pecl_path/php_basename).mkpath

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
        ext_config_path.write <<~INI
          [#{e}]
          #{extension_type}="#{php_ext_dir}/#{e}.so"
        INI
      end
    end
  end

  def caveats
    <<~EOS
      To enable PHP in Apache add the following to httpd.conf and restart Apache:
          LoadModule php7_module #{opt_lib}/httpd/modules/libphp7.so

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
        ServerRoot "#{Formula["httpd"].opt_prefix}"
        PidFile "#{testpath}/httpd.pid"
        LoadModule authz_core_module lib/httpd/modules/mod_authz_core.so
        LoadModule unixd_module lib/httpd/modules/mod_unixd.so
        LoadModule dir_module lib/httpd/modules/mod_dir.so
        DirectoryIndex index.php
      EOS

      php_module = if head?
        "LoadModule php_module #{lib}/httpd/modules/libphp.so"
      else
        "LoadModule php7_module #{lib}/httpd/modules/libphp7.so"
      end

      (testpath/"httpd.conf").write <<~EOS
        #{main_config}
        LoadModule mpm_prefork_module lib/httpd/modules/mod_mpm_prefork.so
        #{php_module}
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

      pid = spawn Formula["httpd"].opt_bin/"httpd", "-X", "-f", "#{testpath}/httpd.conf"
      sleep 10
      assert_match expected_output, shell_output("curl -s 127.0.0.1:#{port}")

      Process.kill("TERM", pid)
      Process.wait(pid)

      fpm_pid = spawn sbin/"php-fpm", "-y", "fpm.conf"
      pid = spawn Formula["httpd"].opt_bin/"httpd", "-X", "-f", "#{testpath}/httpd-fpm.conf"
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
diff --git a/ext/curl/interface.c b/ext/curl/interface.c
index 630cf86ce27..27b42ee15cb 100644
--- a/ext/curl/interface.c
+++ b/ext/curl/interface.c
@@ -1579,11 +1579,11 @@ static int curl_fnmatch(void *ctx, const char *pattern, const char *string)
 
 /* {{{ curl_progress
  */
-static size_t curl_progress(void *clientp, double dltotal, double dlnow, double ultotal, double ulnow)
+static int curl_progress(void *clientp, double dltotal, double dlnow, double ultotal, double ulnow)
 {
 	php_curl *ch = (php_curl *)clientp;
 	php_curl_progress *t = ch->handlers->progress;
-	size_t	rval = 0;
+	int rval = 0;
 
 #if PHP_CURL_DEBUG
 	fprintf(stderr, "curl_progress() called\n");
@@ -1960,8 +1960,8 @@ static void _php_curl_set_default_options(php_curl *ch)
 {
 	char *cainfo;
 
-	curl_easy_setopt(ch->cp, CURLOPT_NOPROGRESS,        1);
-	curl_easy_setopt(ch->cp, CURLOPT_VERBOSE,           0);
+	curl_easy_setopt(ch->cp, CURLOPT_NOPROGRESS,        1L);
+	curl_easy_setopt(ch->cp, CURLOPT_VERBOSE,           0L);
 	curl_easy_setopt(ch->cp, CURLOPT_ERRORBUFFER,       ch->err.str);
 	curl_easy_setopt(ch->cp, CURLOPT_WRITEFUNCTION,     curl_write);
 	curl_easy_setopt(ch->cp, CURLOPT_FILE,              (void *) ch);
@@ -1972,8 +1972,8 @@ static void _php_curl_set_default_options(php_curl *ch)
 #if !defined(ZTS)
 	curl_easy_setopt(ch->cp, CURLOPT_DNS_USE_GLOBAL_CACHE, 1);
 #endif
-	curl_easy_setopt(ch->cp, CURLOPT_DNS_CACHE_TIMEOUT, 120);
-	curl_easy_setopt(ch->cp, CURLOPT_MAXREDIRS, 20); /* prevent infinite redirects */
+	curl_easy_setopt(ch->cp, CURLOPT_DNS_CACHE_TIMEOUT, 120L);
+	curl_easy_setopt(ch->cp, CURLOPT_MAXREDIRS, 20L); /* prevent infinite redirects */
 
 	cainfo = INI_STR("openssl.cafile");
 	if (!(cainfo && cainfo[0] != '\0')) {
@@ -1984,7 +1984,7 @@ static void _php_curl_set_default_options(php_curl *ch)
 	}
 
 #if defined(ZTS)
-	curl_easy_setopt(ch->cp, CURLOPT_NOSIGNAL, 1);
+	curl_easy_setopt(ch->cp, CURLOPT_NOSIGNAL, 1L);
 #endif
 }
 /* }}} */
@@ -2388,7 +2388,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue) /* {{{
 				php_error_docref(NULL, E_NOTICE, "CURLOPT_SSL_VERIFYHOST with value 1 is deprecated and will be removed as of libcurl 7.28.1. It is recommended to use value 2 instead");
 #else
 				php_error_docref(NULL, E_NOTICE, "CURLOPT_SSL_VERIFYHOST no longer accepts the value 1, value 2 will be used instead");
-				error = curl_easy_setopt(ch->cp, option, 2);
+				error = curl_easy_setopt(ch->cp, option, 2L);
 				break;
 #endif
 			}
@@ -2587,7 +2587,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue) /* {{{
 				return 1;
 			}
 # endif
-			error = curl_easy_setopt(ch->cp, option, lval);
+			error = curl_easy_setopt(ch->cp, option, (long) lval);
 			break;
 		case CURLOPT_SAFE_UPLOAD:
 			if (!zend_is_true(zvalue)) {
@@ -2957,7 +2957,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue) /* {{{
 				return FAILURE;
 			}
 #endif
-			error = curl_easy_setopt(ch->cp, option, lval);
+			error = curl_easy_setopt(ch->cp, option, (long) lval);
 			break;
 
 		case CURLOPT_HEADERFUNCTION:
@@ -2975,7 +2975,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue) /* {{{
 					/* no need to build the mime structure for empty hashtables;
 					   also works around https://github.com/curl/curl/issues/6455 */
 					curl_easy_setopt(ch->cp, CURLOPT_POSTFIELDS, "");
-					error = curl_easy_setopt(ch->cp, CURLOPT_POSTFIELDSIZE, 0);
+					error = curl_easy_setopt(ch->cp, CURLOPT_POSTFIELDSIZE, 0L);
 				} else {
 					return build_mime_structure_from_hash(ch, zvalue);
 				}
@@ -3054,7 +3054,7 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue) /* {{{
 #if LIBCURL_VERSION_NUM >= 0x071301 /* Available since 7.19.1 */
 		case CURLOPT_POSTREDIR:
 			lval = zval_get_long(zvalue);
-			error = curl_easy_setopt(ch->cp, CURLOPT_POSTREDIR, lval & CURL_REDIR_POST_ALL);
+			error = curl_easy_setopt(ch->cp, CURLOPT_POSTREDIR, (long) (lval & CURL_REDIR_POST_ALL));
 			break;
 #endif
 
@@ -3096,11 +3096,11 @@ static int _php_curl_setopt(php_curl *ch, zend_long option, zval *zvalue) /* {{{
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
