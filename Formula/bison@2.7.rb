class BisonAT27 < Formula
  desc "Parser generator"
  homepage "https://www.gnu.org/software/bison/"
  url "https://ftpmirror.gnu.org/bison/bison-2.7.1.tar.gz"
  mirror "https://ftp.gnu.org/gnu/bison/bison-2.7.1.tar.gz"
  sha256 "08e2296b024bab8ea36f3bb3b91d071165b22afda39a17ffc8ff53ade2883431"
  license "GPL-3.0-or-later"
  revision 1

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    rebuild 1
    sha256 arm64_tahoe:   "600dba731d797c878249c7d5f1cf9c953f01bb3a60fc623f781a91345f87487c"
    sha256 arm64_sequoia: "0196e4f5dafa98d2a1375f8bf33b4c7f60624590186ceaca965d6fbb45594f4e"
    sha256 arm64_sonoma:  "2f1156966985c9dc1c641c781aab983949ecfc0e1dc5bb68efe26c4bb941e88b"
    sha256 sonoma:        "e7b19f2de9cba260d5059d395373b7ba6c88ea7fe999b623797b6e619ed7d9f1"
    sha256 arm64_linux:   "a8739940d5f98c22eee45316e4bd5c923ccf8280b3cece385aaf2f4379d6ba0d"
    sha256 x86_64_linux:  "14e5e8be74f6becdf03d8c7114f36db6dcb2cb966af79ab3a62b8253fcc3952b"
  end

  keg_only :versioned_formula

  deprecate! date: "2023-12-14", because: :versioned_formula

  uses_from_macos "m4"

  patch :DATA

  patch :p0 do
    on_macos do
      url "https://raw.githubusercontent.com/macports/macports-ports/b76d1e48dac/editors/nano/files/secure_snprintf.patch"
      sha256 "57f972940a10d448efbd3d5ba46e65979ae4eea93681a85e1d998060b356e0d2"
    end
  end

  def install
    system "./configure", "--disable-dependency-tracking",
                          "--prefix=#{prefix}"
    system "make", "install"
  end

  test do
    (testpath/"test.y").write <<~EOS
      %{ #include <iostream>
         using namespace std;
         extern void yyerror (char *s);
         extern int yylex ();
      %}
      %start prog
      %%
      prog:  //  empty
          |  prog expr '\\n' { cout << "pass"; exit(0); }
          ;
      expr: '(' ')'
          | '(' expr ')'
          |  expr expr
          ;
      %%
      char c;
      void yyerror (char *s) { cout << "fail"; exit(0); }
      int yylex () { cin.get(c); return c; }
      int main() { yyparse(); }
    EOS

    system bin/"bison", "test.y"
    system ENV.cxx, "test.tab.c", "-o", "test"
    assert_equal "pass", shell_output("echo \"((()(())))()\" | ./test")
    assert_equal "fail", shell_output("echo \"())\" | ./test")
  end
end

__END__
diff --git a/lib/fseterr.c b/lib/fseterr.c
index 0fca65f..2992daa 100644
--- a/lib/fseterr.c
+++ b/lib/fseterr.c
@@ -29,7 +29,7 @@ fseterr (FILE *fp)
   /* Most systems provide FILE as a struct and the necessary bitmask in
      <stdio.h>, because they need it for implementing getc() and putc() as
      fast macros.  */
-#if defined _IO_ftrylockfile || __GNU_LIBRARY__ == 1 /* GNU libc, BeOS, Haiku, Linux libc5 */
+#if defined _IO_EOF_SEEN || __GNU_LIBRARY__ == 1 /* GNU libc, BeOS, Haiku, Linux libc5 */
   fp->_flags |= _IO_ERR_SEEN;
 #elif defined __sferror || defined __DragonFly__ /* FreeBSD, NetBSD, OpenBSD, DragonFly, Mac OS X, Cygwin */
   fp_->_flags |= __SERR;
