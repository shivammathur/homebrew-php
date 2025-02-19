class AutoconfAT269 < Formula
  desc "Automatic configure script builder"
  homepage "https://www.gnu.org/software/autoconf/"
  url "https://ftp.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz"
  mirror "https://ftpmirror.gnu.org/autoconf/autoconf-2.69.tar.gz"
  sha256 "954bd69b391edc12d6a4a51a2dd1476543da5c6bbf05a95b59dc0dd6fd4c2969"
  license all_of: [
    "GPL-3.0-or-later",
    "GPL-3.0-or-later" => { with: "Autoconf-exception-3.0" },
  ]

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "96301e5356fdc3b29a198b42020b3eba440e646ba621d7e067937465b5f2769e"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "96301e5356fdc3b29a198b42020b3eba440e646ba621d7e067937465b5f2769e"
    sha256 cellar: :any_skip_relocation, arm64_ventura: "96301e5356fdc3b29a198b42020b3eba440e646ba621d7e067937465b5f2769e"
    sha256 cellar: :any_skip_relocation, ventura:       "9a959c1c602064858b64d1d173a0bb98c1b044fc6d973d3ce77852a5c554f0b9"
    sha256 cellar: :any_skip_relocation, x86_64_linux:  "1f8008ef7b62aa1069c98033fed971c441efc5aa33cdc827ba2299ffd7df01a2"
  end

  keg_only :versioned_formula

  deprecate! date: "2023-12-14", because: :versioned_formula

  depends_on "m4"
  uses_from_macos "perl"

  def install
    if OS.mac?
      ENV["PERL"] = "/usr/bin/perl"

      # force autoreconf to look for and use our glibtoolize
      inreplace "bin/autoreconf.in", "libtoolize", "glibtoolize"
      # also touch the man page so that it isn't rebuilt
      inreplace "man/autoreconf.1", "libtoolize", "glibtoolize"
    end

    system "./configure", "--prefix=#{prefix}", "--with-lispdir=#{elisp}"
    system "make", "install"

    rm(info/"standards.info")
  end

  test do
    cp prefix/"share/autoconf/autotest/autotest.m4", "autotest.m4"
    system bin/"autoconf", "autotest.m4"

    (testpath/"configure.ac").write <<~EOS
      AC_INIT([hello], [1.0])
      AC_CONFIG_SRCDIR([hello.c])
      AC_PROG_CC
      AC_OUTPUT
    EOS
    (testpath/"hello.c").write "int foo(void) { return 42; }"

    system bin/"autoconf"
    system "./configure"
    assert_path_exists testpath/"config.status"
    assert_match(/\nCC=.*#{ENV.cc}/, (testpath/"config.log").read)
  end
end
