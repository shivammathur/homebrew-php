class PhpAT70 < Formula
  desc "General-purpose scripting language"
  homepage "https://secure.php.net/"
  url "https://github.com/shivammathur/php-src-backports/archive/da64b9b864bf43d9023d6d1d6d5b582800d72c9e.tar.gz"
  version "7.0.33"
  sha256 "c412fdeac66cb816f3f3fa5a7a6755daf3f37521d997fca771ecd40f61b22cc3"
  license "PHP-3.01"
  revision 18
  compatibility_version 1

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    sha256 arm64_tahoe:   "56da8b0c786306e411ccd788b8fe0c11c23fd92e9c91b9d31582db94f6a5db47"
    sha256 arm64_sequoia: "81b32df055ad936703f24e267d86a946321591e9c01566379d834740b9603dae"
    sha256 arm64_sonoma:  "e16f3f922deb296ea7da7a9ae0c20f8c0f0178069e7f13b60dd84857a706ab0d"
    sha256 arm64_linux:   "3c469796c97493713af298d4be0b6e02581fe0f95256cff4a2cfe2d5f799a247"
    sha256 x86_64_linux:  "2b35bea3c0a1c9db88c703fdddccd9c28dd5f12695aec9bb734ad8c78660b1a1"
  end

  keg_only :versioned_formula

  # This PHP version is not supported upstream as of 2019-01-10.
  # Although, this was built with back-ported security patches,
  # we recommended to use a currently supported PHP version.
  # For more details, refer to https://www.php.net/eol.php
  deprecate! date: "2019-01-10", because: :deprecated_upstream

  depends_on "bison" => :build
  depends_on "httpd" => [:build, :test]
  depends_on "pkgconf" => :build
  depends_on "re2c" => :build
  depends_on "apr"
  depends_on "apr-util"
  depends_on "aspell"
  depends_on "autoconf"
  depends_on "curl"
  depends_on "freetds"
  depends_on "freetype"
  depends_on "gd"
  depends_on "gmp"
  depends_on "icu4c@78"
  depends_on "jpeg"
  depends_on "krb5"
  depends_on "libpng"
  depends_on "libpq"
  depends_on "libtool"
  depends_on "libx11"
  depends_on "libxpm"
  depends_on "libzip"
  depends_on "openldap"
  depends_on "openssl@3"
  depends_on "pcre"
  depends_on "sqlite"
  depends_on "tidy-html5"
  depends_on "unixodbc"
  depends_on "webp"

  uses_from_macos "bzip2"
  uses_from_macos "libedit"
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
    # The runtime probe can misdetect glibc's POSIX readdir_r in build containers.
    ENV["ac_cv_what_readdir_r"] = "POSIX" if OS.linux?

    # Work around configure issues with Xcode 12
    # See https://bugs.php.net/bug.php?id=80171
    ENV.append "CFLAGS", "-Wno-implicit-function-declaration"

    # PHP 7.x still has old C sources that fail under C23.
    ENV.append "CFLAGS", "-std=gnu17"

    # Work around for building with Xcode 15.3
    if DevelopmentTools.clang_build_version >= 1500
      ENV.append "CFLAGS", "-Wno-incompatible-function-pointer-types"
      ENV.append "LDFLAGS", "-lresolv"
      inreplace "main/reentrancy.c", "readdir_r(dirp, entry)", "readdir_r(dirp, entry, result)"
    end

    # Workaround for https://bugs.php.net/80310
    ENV.append "CFLAGS", "-DU_DEFINE_FALSE_AND_TRUE=1"
    ENV.append "CXXFLAGS", "-DU_DEFINE_FALSE_AND_TRUE=1"

    # icu4c 61.1 compatibility
    ENV.append "CPPFLAGS", "-DU_USING_ICU_NAMESPACE=1"

    # Work around to support `icu4c` 75, which needs C++17.
    ENV.append "CXX", "-std=c++17"
    ENV.libcxx if ENV.compiler == :clang

    # buildconf required due to system library linking bug patch
    system "./buildconf", "--force"

    inreplace "configure" do |s|
      s.gsub! "APACHE_THREADED_MPM=`$APXS_HTTPD -V | grep 'threaded:.*yes'`",
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

    # API compatibility with tidy-html5 v5.0.0 - https://github.com/htacg/tidy-html5/issues/224
    inreplace "ext/tidy/tidy.c", "buffio.h", "tidybuffio.h"

    config_path = etc/"php/#{php_version}"
    # Prevent system pear config from inhibiting pear install
    (config_path/"pear.conf").delete if (config_path/"pear.conf").exist?

    # Prevent homebrew from hardcoding path to sed shim in phpize script
    ENV["lt_cv_path_SED"] = "sed"

    if OS.mac?
      # Each extension needs a direct reference to the sdk path or it won't find the headers
      headers_path = "=#{MacOS.sdk_for_formula(self).path}/usr"
      gettext_path = "=#{formula_opt_prefix("gettext")}"
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
      --enable-intl
      --enable-mbregex
      --enable-mbstring
      --enable-mysqlnd
      --enable-opcache-file
      --enable-pcntl
      --enable-phpdbg
      --enable-phpdbg-webhelper
      --enable-shmop
      --enable-soap
      --enable-sockets
      --enable-sysvmsg
      --enable-sysvsem
      --enable-sysvshm
      --enable-wddx
      --enable-zip
      --with-apxs2=#{formula_opt_bin("httpd")}/apxs
      --with-curl=#{formula_opt_prefix("curl")}
      --with-fpm-user=#{fpm_user}
      --with-fpm-group=#{fpm_group}
      --with-freetype-dir=#{formula_opt_prefix("freetype")}
      --with-gd=#{formula_opt_prefix("gd")}
      --with-gettext#{gettext_path}
      --with-gmp=#{formula_opt_prefix("gmp")}
      --with-iconv#{headers_path}
      --with-icu-dir=#{formula_opt_prefix("icu4c@78")}
      --with-jpeg-dir=#{formula_opt_prefix("jpeg")}
      --with-kerberos#{headers_path}
      --with-layout=GNU
      --with-ldap=#{formula_opt_prefix("openldap")}
      --with-ldap-sasl#{headers_path}
      --with-libzip
      --with-mhash#{headers_path}
      --with-mysql-sock=/tmp/mysql.sock
      --with-mysqli=mysqlnd
      --with-openssl=#{formula_opt_prefix("openssl@3")}
      --with-pdo-dblib=#{formula_opt_prefix("freetds")}
      --with-pdo-mysql=mysqlnd
      --with-pdo-odbc=unixODBC,#{formula_opt_prefix("unixodbc")}
      --with-pdo-pgsql=#{formula_opt_prefix("libpq")}
      --with-pdo-sqlite=#{formula_opt_prefix("sqlite")}
      --with-pgsql=#{formula_opt_prefix("libpq")}
      --with-pic
      --with-png-dir=#{formula_opt_prefix("libpng")}
      --with-pspell=#{formula_opt_prefix("aspell")}
      --with-sqlite3=#{formula_opt_prefix("sqlite")}
      --with-tidy=#{formula_opt_prefix("tidy-html5")}
      --with-unixODBC=#{formula_opt_prefix("unixodbc")}
      --with-webp-dir=#{formula_opt_prefix("webp")}
      --with-xmlrpc
      --with-xpm-dir=#{formula_opt_prefix("libxpm")}
    ]

    if OS.mac?
      args << "--enable-dtrace"
      args << "--with-bz2#{headers_path}"
      args << "--with-libedit#{headers_path}"
      args << "--with-libxml-dir#{headers_path}"
      args << "--with-ndbm#{headers_path}"
      args << "--with-xsl#{headers_path}"
      args << "--with-zlib#{headers_path}"
    else
      args << "--disable-dtrace"
      args << "--with-zlib=#{formula_opt_prefix("zlib-ng-compat")}"
      args << "--with-bzip2=#{formula_opt_prefix("bzip2")}"
      args << "--with-libedit=#{formula_opt_prefix("libedit")}"
      args << "--with-libxml-dir=#{formula_opt_prefix("libxml2")}"
      args << "--with-xsl=#{formula_opt_prefix("libxslt")}"
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
    configure_php
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
          #{etc}/php/#{php_version}/
    EOS
  end

  def php_version
    version.to_s.split(".")[0..1].join(".")
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
        LoadModule php7_module #{lib}/httpd/modules/libphp7.so
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
diff --git a/configure.in b/configure.in
index 7ba3bc05a5..279230fa80 100644
--- a/configure.in
+++ b/configure.in
@@ -60,7 +60,13 @@ AH_BOTTOM([
 #endif

 #if ZEND_BROKEN_SPRINTF
+#ifdef __cplusplus
+extern "C" {
+#endif
 int zend_sprintf(char *buffer, const char *format, ...);
+#ifdef __cplusplus
+}
+#endif
 #else
 # define zend_sprintf sprintf
 #endif
diff --git a/acinclude.m4 b/acinclude.m4
index 168c465f8d..6c087d152f 100644
--- a/acinclude.m4
+++ b/acinclude.m4
@@ -441,7 +441,11 @@ dnl
 dnl Adds a path to linkpath/runpath (LDFLAGS)
 dnl
 AC_DEFUN([PHP_ADD_LIBPATH],[
-  if test "$1" != "/usr/$PHP_LIBDIR" && test "$1" != "/usr/lib"; then
+  case "$1" in
+  "/usr/$PHP_LIBDIR"|"/usr/lib"[)] ;;
+  /Library/Developer/CommandLineTools/SDKs/*/usr/lib[)] ;;
+  /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/*/usr/lib[)] ;;
+  *[)]
     PHP_EXPAND_PATH($1, ai_p)
     ifelse([$2],,[
       _PHP_ADD_LIBPATH_GLOBAL([$ai_p])
@@ -452,8 +456,8 @@ AC_DEFUN([PHP_ADD_LIBPATH],[
       else
         _PHP_ADD_LIBPATH_GLOBAL([$ai_p])
       fi
-    ])
-  fi
+    ]) ;;
+  esac
 ])

 dnl
@@ -487,7 +491,11 @@ dnl add an include path.
 dnl if before is 1, add in the beginning of INCLUDES.
 dnl
 AC_DEFUN([PHP_ADD_INCLUDE],[
-  if test "$1" != "/usr/include"; then
+  case "$1" in
+  "/usr/include"[)] ;;
+  /Library/Developer/CommandLineTools/SDKs/*/usr/include[)] ;;
+  /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/*/usr/include[)] ;;
+  *[)]
     PHP_EXPAND_PATH($1, ai_p)
     PHP_RUN_ONCE(INCLUDEPATH, $ai_p, [
       if test "$2"; then
@@ -495,8 +503,8 @@ AC_DEFUN([PHP_ADD_INCLUDE],[
       else
         INCLUDES="$INCLUDES -I$ai_p"
       fi
-    ])
-  fi
+    ]) ;;
+  esac
 ])

 dnl internal, don't use
@@ -2411,7 +2419,8 @@ AC_DEFUN([PHP_SETUP_ICONV], [
     fi

     if test -f $ICONV_DIR/$PHP_LIBDIR/lib$iconv_lib_name.a ||
-       test -f $ICONV_DIR/$PHP_LIBDIR/lib$iconv_lib_name.$SHLIB_SUFFIX_NAME
+       test -f $ICONV_DIR/$PHP_LIBDIR/lib$iconv_lib_name.$SHLIB_SUFFIX_NAME ||
+       test -f $ICONV_DIR/$PHP_LIBDIR/lib$iconv_lib_name.tbd
     then
       PHP_CHECK_LIBRARY($iconv_lib_name, libiconv, [
         found_iconv=yes
