class PhpAT81 < Formula
  desc "General-purpose scripting language"
  homepage "https://www.php.net/"
  url "https://github.com/php/php-src/archive/master.tar.gz?v=php-8.1.0"
  license "PHP-3.01"

  bottle do
    root_url "https://dl.bintray.com/shivammathur/php"
  end

  keg_only :versioned_formula

  depends_on "bison" => :build
  depends_on "httpd" => [:build, :test]
  depends_on "pkg-config" => :build
  depends_on "re2c" => :build
  depends_on "apr"
  depends_on "apr-util"
  depends_on "argon2"
  depends_on "aspell"
  depends_on "autoconf"
  depends_on "curl-openssl"
  depends_on "freetds"
  depends_on "gd"
  depends_on "gettext"
  depends_on "glib"
  depends_on "gmp"
  depends_on "icu4c"
  depends_on "krb5"
  depends_on "libffi"
  depends_on "libpq"
  depends_on "libsodium"
  depends_on "libzip"
  depends_on "oniguruma"
  depends_on "openldap"
  depends_on "openssl@1.1"
  depends_on "pcre2"
  depends_on "sqlite"
  depends_on "tidy-html5"
  depends_on "unixodbc"

  uses_from_macos "xz" => :build
  uses_from_macos "bzip2"
  uses_from_macos "libedit"
  uses_from_macos "libxml2"
  uses_from_macos "libxslt"
  uses_from_macos "zlib"

  # PHP build system incorrectly links system libraries
  # see https://github.com/php/php-src/pull/3472
  patch :DATA

  def install
    # Ensure that libxml2 will be detected correctly in older MacOS
    ENV["SDKROOT"] = MacOS.sdk_path if MacOS.version == :el_capitan || MacOS.version == :sierra

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
              "LIBEXECDIR='" + "#{lib}/httpd/modules".gsub("@", "\\@") + "'"
    end

    # Update error message in apache sapi to better explain the requirements
    # of using Apache http in combination with php if the non-compatible MPM
    # has been selected. Homebrew has chosen not to support being able to
    # compile a thread safe version of PHP and therefore it is not
    # possible to recompile as suggested in the original message
    inreplace "sapi/apache2handler/sapi_apache2.c",
              "You need to recompile PHP.",
              "Homebrew PHP does not support a thread-safe php binary. "\
              "To use the PHP apache sapi please change "\
              "your httpd config to use the prefork MPM"

    inreplace "sapi/fpm/php-fpm.conf.in", ";daemonize = yes", "daemonize = no"

    config_path = etc/"php/#{php_version}"
    # Prevent system pear config from inhibiting pear install
    (config_path/"pear.conf").delete if (config_path/"pear.conf").exist?

    # Prevent homebrew from harcoding path to sed shim in phpize script
    ENV["lt_cv_path_SED"] = "sed"

    # system pkg-config missing
    ENV["SASL_CFLAGS"] = "-I#{MacOS.sdk_path_if_needed}/usr/include/sasl"
    ENV["SASL_LIBS"] = "-lsasl2"

    # Each extension that is built on Mojave needs a direct reference to the
    # sdk path or it won't find the headers
    headers_path = "=#{MacOS.sdk_path_if_needed}/usr"

    args = %W[
      --prefix=#{prefix}
      --localstatedir=#{var}
      --sysconfdir=#{config_path}
      --with-config-file-path=#{config_path}
      --with-config-file-scan-dir=#{config_path}/conf.d
      --with-pear=#{pkgshare}/pear
      --with-os-sdkpath=#{MacOS.sdk_path_if_needed}
      --enable-bcmath
      --enable-calendar
      --enable-dba
      --enable-dtrace
      --enable-exif
      --enable-ftp
      --enable-fpm
      --enable-gd
      --enable-intl
      --enable-mbregex
      --enable-mbstring
      --enable-mysqlnd
      --enable-opcache
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
      --with-fpm-user=_www
      --with-fpm-group=_www
      --with-gettext=#{Formula["gettext"].opt_prefix}
      --with-gmp=#{Formula["gmp"].opt_prefix}
      --with-iconv#{headers_path}
      --with-kerberos
      --with-layout=GNU
      --with-ldap=#{Formula["openldap"].opt_prefix}
      --with-ldap-sasl
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

    system "./configure", *args
    system "make"
    system "make", "install"

    # Allow pecl to install outside of Cellar
    extension_dir = Utils.safe_popen_read("#{bin}/php-config --extension-dir").chomp
    orig_ext_dir = File.basename(extension_dir)
    inreplace bin/"php-config", lib/"php", prefix/"pecl"
    inreplace "php.ini-development", %r{; ?extension_dir = "\./"},
      "extension_dir = \"#{HOMEBREW_PREFIX}/lib/php/pecl/#{orig_ext_dir}\""

    # Use OpenSSL cert bundle
    openssl = Formula["openssl@1.1"]
    inreplace "php.ini-development", /; ?openssl\.cafile=/,
      "openssl.cafile = \"#{openssl.pkgetc}/cert.pem\""
    inreplace "php.ini-development", /; ?openssl\.capath=/,
      "openssl.capath = \"#{openssl.pkgetc}/certs\""

    config_files = {
      "php.ini-development"   => "php.ini",
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
    ln_s pecl_path, prefix/"pecl" unless (prefix/"pecl").exist?
    extension_dir = Utils.safe_popen_read("#{bin}/php-config --extension-dir").chomp
    php_basename = File.basename(extension_dir)
    php_ext_dir = opt_prefix/"lib/php"/php_basename

    # fix pear config to install outside cellar
    pear_path = HOMEBREW_PREFIX/"share/pear@#{php_version}"
    cp_r pkgshare/"pear/.", pear_path
    {
      "php_ini"  => etc/"php/#{php_version}/php.ini",
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

    # Configure JIT
    jit_ini = etc/"php/#{php_version}/conf.d/jit.ini"
    jit_ini.write <<~EOS
      opcache.enable=1
      opcache.jit_buffer_size=256M
      opcache.jit=1235
    EOS

    %w[
      opcache
    ].each do |e|
      ext_config_path = etc/"php/#{php_version}/conf.d/ext-#{e}.ini"
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
          #{etc}/php/#{php_version}/
    EOS
  end

  def php_version
    version.to_s.split(".")[0..1].join(".")
  end

  plist_options manual: "php-fpm"

  def plist
    <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
        <dict>
          <key>KeepAlive</key>
          <true/>
          <key>Label</key>
          <string>#{plist_name}</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{opt_sbin}/php-fpm</string>
            <string>--nodaemonize</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>WorkingDirectory</key>
          <string>#{var}</string>
          <key>StandardErrorPath</key>
          <string>#{var}/log/php-fpm.log</string>
        </dict>
      </plist>
    EOS
  end

  test do
    assert_match /^Zend OPcache$/, shell_output("#{bin}/php -i"),
      "Zend OPCache extension not loaded"
    # Test related to libxml2 and
    # https://github.com/Homebrew/homebrew-core/issues/28398
    assert_includes MachO::Tools.dylibs("#{bin}/php"),
      "#{Formula["libpq"].opt_lib}/libpq.5.dylib"
    system "#{sbin}/php-fpm", "-t"
    system "#{bin}/phpdbg", "-V"
    system "#{bin}/php-cgi", "-m"
    # Prevent SNMP extension to be added
    assert_no_match /^snmp$/, shell_output("#{bin}/php -m"),
      "SNMP extension doesn't work reliably with Homebrew on High Sierra"
    begin
      require "socket"

      server = TCPServer.new(0)
      port = server.addr[1]
      server_fpm = TCPServer.new(0)
      port_fpm = server_fpm.addr[1]
      server.close
      server_fpm.close

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
      sleep 3

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
