class BisonAT27 < Formula
  desc "Parser generator"
  homepage "https://www.gnu.org/software/bison/"
  url "https://ftp.gnu.org/gnu/bison/bison-2.7.1.tar.gz"
  mirror "https://ftpmirror.gnu.org/bison/bison-2.7.1.tar.gz"
  sha256 "08e2296b024bab8ea36f3bb3b91d071165b22afda39a17ffc8ff53ade2883431"
  license "GPL-3.0-or-later"
  revision 1

  bottle do
    root_url "https://ghcr.io/v2/shivammathur/php"
    sha256 arm64_sequoia: "5bc5e08daecaee2f6d0a094dd1812e44a61bd81d0ff6c920ce67a0ee9fba5420"
    sha256 arm64_sonoma:  "7d078c31dd6daabae2ac36c3af29c7f5a1718c1f059d90e916ea2b38fda57817"
    sha256 arm64_ventura: "057c698f13e4e26ff80796b0f296ef104c35f66cb40db22fad346efc96569286"
    sha256 ventura:       "d5559bda41c602d9c6f6cec440f3077a5757930a1333124657b59f3853b369df"
    sha256 x86_64_linux:  "0ec010e69a853cec8145244ea97ed02ee26f3ea0ddd95bfd288737ce3fb99568"
  end

  keg_only :versioned_formula

  deprecate! date: "2023-12-14", because: :versioned_formula

  uses_from_macos "m4"

  patch :DATA

  patch :p0 do
    on_high_sierra :or_newer do
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
