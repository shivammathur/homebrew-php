class PhpDebug < Formula
  desc "General-purpose scripting language"
  homepage "https://www.php.net/"
  # Should only be updated if the new version is announced on the homepage, https://www.php.net/
  url "https://www.php.net/distributions/php-8.5.8.tar.xz"
  mirror "https://fossies.org/linux/www/php-8.5.8.tar.xz"
  sha256 "58910198d19e873048fe87cdfe16bc790025417ede3d1651bfa1c4b533d573f2"
  license all_of: [
    "PHP-3.01",

    # Extra licenses not documented in README.REDIST.BINS
    "Zend-2.0", # Zend/LICENSE
    "BSL-1.0",  # Zend/asm/LICENSE
    "MIT",      # ext/date/lib/LICENSE.rst

    # Extra licenses documented in README.REDIST.BINS ignoring unbundled pcre2lib (3) and gd (13)
    # ref: https://github.com/php/php-src/blob/PHP-8.5/README.REDIST.BINS
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

  livecheck do
    url "https://www.php.net/downloads?source=Y"
    regex(/href=.*?php[._-]v?(\d+(?:\.\d+)+)\.t/i)
  end

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    sha256 arm64_tahoe:   "62c1259fa97abfc48db120860e909e9cd9299f0667703e0777be0dda6c5ec709"
    sha256 arm64_sequoia: "bf196033639a6dff598259d0bba7a67763cad7f347cce8ee1a11e9163e62dfad"
    sha256 arm64_sonoma:  "affaf74970aaaf88d79f1540d7ccd1b270aeb802fee73cb8f27903ea75a5b9be"
    sha256 sonoma:        "261a5858d4bdcb4e9f2ae7e58beb49b4a509c2d013f4792482bb4b878817a5c7"
    sha256 arm64_linux:   "e9c2dda866b32f81e177655da02b9d8d786465c68c50c2c8628b13ffd73770f5"
    sha256 x86_64_linux:  "c1da367490f13a7acb419bc8709efcdcbf6cb0ac48df25edd977f93736914c2a"
  end

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

  deny_network_access! [:build, :postinstall]

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

      # NOTE: `versioned_formula?` conditionals are to make sure correct changes
      # are applied if copied from `php`. Remove dead code when creating `php@x.y`
      if versioned_formula?
        # apxs will interpolate the @ in the versioned prefix: https://bz.apache.org/bugzilla/show_bug.cgi?id=61944
        s.gsub! "LIBEXECDIR='$APXS_LIBEXECDIR'",
                "LIBEXECDIR='" + "#{lib}/httpd/modules".gsub("\\", "\\\\").gsub("@", "\\@") + "'"
      end
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

    # Identify build provider in php -v output and phpinfo()
    ENV["PHP_BUILD_PROVIDER"] = "Shivam Mathur"

    # Runtime optimizations
    ENV.O3
    use_pgo = !OS.mac? || Hardware::CPU.arm?
    use_lto = OS.mac? && Hardware::CPU.arm?
    pgo_prefix = "pgo-debug"

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
      --enable-debug
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
      --with-password-argon2=#{formula_opt_prefix("argon2")}
      --with-pdo-dblib=#{formula_opt_prefix("freetds")}
      --with-pdo-mysql=mysqlnd
      --with-pdo-odbc=unixODBC,#{formula_opt_prefix("unixodbc")}
      --with-pdo-pgsql=#{formula_opt_prefix("libpq")}
      --with-pdo-sqlite
      --with-pgsql=#{formula_opt_prefix("libpq")}
      --with-pic
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

    if use_pgo
      pgo_script = buildpath/"pgo_script.php"
      pgo_script.write (Pathname(__dir__).parent/"Scripts/pgo_script.php").read

      base_flags = %w[CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS LDFLAGS].to_h { |key| [key, ENV[key]] }
      profile_dir = buildpath/"pgo-data"
      pgo_generate_flag = if OS.mac?
        "-fprofile-instr-generate"
      else
        profile_dir.mkpath
        "-fprofile-generate=#{profile_dir}"
      end
      %w[CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS].each do |key|
        ENV.append key, pgo_generate_flag
      end
      ENV.append "LDFLAGS", pgo_generate_flag

      system "./configure", *args
      system "make"

      php = buildpath/"sapi/cli/php"
      if OS.mac?
        profile_pattern = buildpath/"#{pgo_prefix}-%p-%m.profraw"
        ENV["LLVM_PROFILE_FILE"] = profile_pattern.to_s
      end
      begin
        system php, "-n", "-d", "opcache.enable_cli=1", "Zend/bench.php", "--repeat", "3"
        system php, "-n", "Zend/bench.php", "--repeat", "3"
        3.times do
          system php, "-n", "-d", "opcache.enable_cli=1", pgo_script
          system php, "-n", pgo_script
        end
      ensure
        ENV.delete("LLVM_PROFILE_FILE")
      end

      if OS.mac?
        profiles = Dir[buildpath/"#{pgo_prefix}-*.profraw"]
        odie "PGO training did not generate any profile data" if profiles.empty?

        profdata_tool = Utils.safe_popen_read("/usr/bin/xcrun", "--find", "llvm-profdata").chomp
        profdata = buildpath/"#{pgo_prefix}.profdata"
        system profdata_tool, "merge", "-o", profdata, *profiles
        pgo_use_flag = "-fprofile-instr-use=#{profdata}"
      else
        profiles = Dir[profile_dir/"**/*.gcda"]
        odie "PGO training did not generate any profile data" if profiles.empty?

        pgo_use_flag = "-fprofile-use=#{profile_dir}"
      end

      system "make", "distclean"
      base_flags.each do |key, value|
        if value.nil?
          ENV.delete(key)
        else
          ENV[key] = value
        end
      end

      %w[CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS].each do |key|
        ENV.append key, pgo_use_flag
        if OS.mac?
          ENV.append key, "-Wno-profile-instr-out-of-date"
          ENV.append key, "-Wno-profile-instr-unprofiled"
        else
          ENV.append key, "-fprofile-correction"
          # GCC 13's tracer pass crashes on session.c under -fprofile-use (https://github.com/php/php-src/issues/18807)
          ENV.append key, "-fno-tracer"
        end
      end
      ENV.append "LDFLAGS", pgo_use_flag
      if use_lto
        %w[CFLAGS CXXFLAGS OBJCFLAGS OBJCXXFLAGS].each do |key|
          ENV.append key, "-flto=thin"
        end
        ENV.append "LDFLAGS", "-flto=thin"
        ENV.append "LDFLAGS", "-Wl,-export_dynamic"
      end
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
    (pecl_path/php_basename).mkpath

    # fix pear config to install outside cellar
    pear_path = HOMEBREW_PREFIX/"share/pear"
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
    version.to_s.split(".")[0..1].join(".") + "-debug"
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
