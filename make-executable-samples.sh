#!/bin/bash
#
# Makes sample executables, libraries and scripts for trying Diptych's
# "Unix executable" previews by hand.
#
#   ./make-executable-samples.sh [folder]   (default: ../test_folder/19-executables)
#
# Every program is a made-up hello world compiled here; the only file not
# made here is a copy of /bin/ls, to show an Apple signature. It writes only
# into the folder given, and only the files named below; nothing is deleted.
# Needs clang, lipo and codesign (Xcode's command line tools); the Linux and
# Windows samples need zig, and are skipped without it. The signed Windows
# programs are signed by a made-up CA with sign-pe-sample.py, which needs
# Python's cryptography package; without it they are skipped.
#
#   macos/    thin and universal programs, signed by the linker, ad hoc with
#             entitlements and the hardened runtime, unsigned, changed after
#             signing; a dynamic library and a program using it; an object
#             file, a bundle, an Intel-only program for an old macOS
#   linux/    ELF programs, dynamic and static, a shared library, an object
#   windows/  programs for x64, ARM64 and 32-bit x86, one with a version and
#             asking for administrator rights; a DLL with its import library,
#             a static library, an object file; signed, and changed after
#             signing; an MS-DOS program; batch files right and wrong
#   scripts/  #! lines that work, the mistakes that make them fail, and one
#             full of invisible characters for Text Edit

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/19-executables}"

for tool in clang lipo codesign; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done

mkdir -p "$TARGET"/{macos,linux,windows,scripts}
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/hello.c" <<'EOF'
#include <stdio.h>
int main(void) {
    printf("Hello from a Diptych sample\n");
    return 0;
}
EOF
cat > "$WORK/uses.c" <<'EOF'
#include <stdio.h>
int sample_answer(void);
int main(void) { printf("The answer is %d\n", sample_answer()); return 0; }
EOF
cat > "$WORK/lib.c" <<'EOF'
int sample_answer(void) { return 42; }
EOF
cat > "$WORK/plugin.c" <<'EOF'
int sample_plugin_entry(void) { return 1; }
EOF
cat > "$WORK/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.get-task-allow</key><true/>
</dict>
</plist>
EOF

M="$TARGET/macos"
echo "macOS samples"
clang -Os -arch arm64 -mmacosx-version-min=13.0 "$WORK/hello.c" -o "$M/hello-arm64"
clang -Os -arch x86_64 -mmacosx-version-min=10.13 "$WORK/hello.c" -o "$M/hello-intel-old-macos"
lipo -create "$M/hello-arm64" "$M/hello-intel-old-macos" -output "$M/hello-universal"

cp "$M/hello-arm64" "$M/hello-unsigned"
codesign --remove-signature "$M/hello-unsigned"

cp "$M/hello-arm64" "$M/hello-entitled"
codesign -f -s - -o runtime --identifier example.diptych.hello \
    --entitlements "$WORK/entitlements.plist" "$M/hello-entitled" 2>/dev/null

# Signed, then one letter of its text changed: the page hash no longer matches.
cp "$M/hello-entitled" "$M/hello-changed-after-signing"
perl -0777 -pi -e 's/Hello from a Diptych/Jello from a Diptych/' "$M/hello-changed-after-signing"

clang -Os -arch arm64 -dynamiclib "$WORK/lib.c" -o "$M/libsample.dylib" \
    -install_name @rpath/libsample.dylib -current_version 1.2.3 -compatibility_version 1.0
clang -Os -arch arm64 "$WORK/uses.c" -o "$M/uses-libsample" -L"$M" -lsample -Wl,-rpath,@executable_path
clang -Os -arch arm64 -c "$WORK/hello.c" -o "$M/hello.o"
clang -Os -arch arm64 -bundle "$WORK/plugin.c" -o "$M/plugin.bundle"
cp /bin/ls "$M/ls-signed-by-apple"

L="$TARGET/linux"
if command -v zig >/dev/null; then
    echo "Linux samples (zig; the first run builds its C libraries and takes a few minutes)"
    zig cc -target x86_64-linux-gnu.2.28 -Os "$WORK/hello.c" -o "$L/hello-x86_64"
    zig cc -target aarch64-linux-musl -Os -static -s "$WORK/hello.c" -o "$L/hello-arm64-static"
    zig cc -target x86_64-linux-gnu -Os -shared -fPIC "$WORK/lib.c" -o "$L/libsample.so.1" -Wl,-soname,libsample.so.1
    zig cc -target riscv64-linux-musl -Os -c "$WORK/hello.c" -o "$L/hello-riscv64.o"
else
    echo "zig not found: Linux samples skipped"
fi

W="$TARGET/windows"
# Without the C library -- kernel32 only, declared here -- the programs are
# a few kilobytes instead of sixty.
cat > "$WORK/win-hello.c" <<'EOF'
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned long which);
__declspec(dllimport) int __stdcall WriteFile(void *file, const void *buffer, unsigned long size,
                                              unsigned long *written, void *overlapped);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int code);

void start(void) {
    unsigned long written;
    WriteFile(GetStdHandle((unsigned long)-11), "Hello from a Diptych sample\r\n", 29, &written, 0);
    ExitProcess(0);
}
EOF
cat > "$WORK/dll.c" <<'EOF'
int __stdcall DllMain(void *instance, unsigned long reason, void *reserved) { return 1; }
__declspec(dllexport) int sample_answer(void) { return 42; }
__declspec(dllexport) int sample_twice(int x) { return 2 * x; }
EOF
cat > "$WORK/app.manifest" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3"><security><requestedPrivileges>
    <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
  </requestedPrivileges></security></trustInfo>
</assembly>
EOF
cat > "$WORK/version.rc" <<'EOF'
1 VERSIONINFO
FILEVERSION 1,2,3,4
PRODUCTVERSION 1,2,0,0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904b0"
    BEGIN
      VALUE "CompanyName", "Diptych Samples"
      VALUE "FileDescription", "A Diptych sample program"
      VALUE "FileVersion", "1.2.3.4"
      VALUE "ProductName", "Diptych Sample"
      VALUE "ProductVersion", "1.2"
      VALUE "OriginalFilename", "hello-admin.exe"
      VALUE "LegalCopyright", "Public domain"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
1 24 "app.manifest"
EOF
if command -v zig >/dev/null; then
    echo "Windows samples (zig; the first run builds its C libraries for each processor)"
    BARE=(-Os -nostdlib -Wl,--entry=start -lkernel32)
    zig cc -target x86_64-windows-gnu "${BARE[@]}" "$WORK/win-hello.c" -o "$W/hello-x64.exe"
    (cd "$WORK" && zig cc -target x86_64-windows-gnu "${BARE[@]}" win-hello.c version.rc -o "$W/hello-admin.exe")
    zig cc -target aarch64-windows-gnu "${BARE[@]}" "$WORK/win-hello.c" -o "$W/hello-arm64.exe"
    zig cc -target x86-windows-gnu "${BARE[@]}" -Wl,--subsystem,windows "$WORK/win-hello.c" -o "$W/hello-x86-windowed.exe"
    zig cc -target x86_64-windows-gnu -Os -nostdlib -shared -Wl,--entry=DllMain -lkernel32 "$WORK/dll.c" \
        -o "$W/sample.dll" -Wl,--out-implib,"$W/sample.lib"
    zig cc -target x86_64-windows-msvc -Os -c "$WORK/dll.c" -o "$W/sample.obj"
    rm -f "$W/sample-static.lib"
    zig ar rcs "$W/sample-static.lib" "$W/sample.obj"
    if python3 -c "import cryptography" 2>/dev/null; then
        python3 ./sign-pe-sample.py "$W/hello-x64.exe" "$W/hello-signed.exe"
        cp "$W/hello-signed.exe" "$W/hello-changed-after-signing.exe"
        perl -0777 -pi -e 's/Hello from a Diptych/Jello from a Diptych/' "$W/hello-changed-after-signing.exe"
    else
        echo "Python's cryptography package not found: signed Windows samples skipped"
    fi
else
    echo "zig not found: Windows programs skipped"
fi
# MS-DOS: a 32-byte header and a few instructions printing a line.
python3 - "$W/hello-dos.exe" <<'PYTHON'
import struct, sys
code = bytes([0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD, 0x21, 0xB8, 0x00, 0x4C, 0xCD, 0x21])
body = code + b"Hello from a Diptych sample$"
size = 32 + len(body)
header = struct.pack("<2sHHHHHHHHHHHH", b"MZ", size % 512, (size + 511) // 512, 0, 2, 0, 0xFFFF,
                     0x10, 0x100, 0, 0, 0, 0x1C) + b"\0" * 6
open(sys.argv[1], "wb").write(header + body)
PYTHON
printf '@echo off\r\nrem Saved with Windows line endings, as cmd.exe wants.\r\ngoto greet\r\n:greet\r\necho Hello from a Diptych sample\r\n' > "$W/right.bat"
printf '@echo off\ngoto greet\necho This line is skipped\n:greet\necho Labels in a file with LF line endings\n' > "$W/lf-line-endings.bat"
printf '\xEF\xBB\xBF@echo off\r\necho Saved with a byte-order mark\r\n' > "$W/byte-order-mark.cmd"
printf '@echo off\r\necho Caf\xC3\xA9 cr\xC3\xA8me br\xC3\xBBl\xC3\xA9e\r\n' > "$W/utf8-without-chcp.bat"

S="$TARGET/scripts"
echo "Script samples"
write() { # name, mode, then the text on standard input
    cat > "$S/$1"
    chmod "$2" "$S/$1"
}
write bash-script 755 <<'EOF'
#!/bin/bash
# Runs with /bin/bash.
echo "Hello from a Diptych sample"
EOF
write python-through-env 755 <<'EOF'
#!/usr/bin/env python3
"""Found through env, wherever python3 is on the PATH."""
print("Hello from a Diptych sample")
EOF
write env-split-arguments 755 <<'EOF'
#!/usr/bin/env -S deno run --allow-read
console.log("Hello from a Diptych sample");
EOF
write env-arguments-linux-would-not-split 755 <<'EOF'
#!/usr/bin/env python3 -u
print("macOS splits this line into words; Linux passes 'python3 -u' as one name")
EOF
write applescript 755 <<'EOF'
#!/usr/bin/osascript
display notification "Hello from a Diptych sample"
EOF
printf '#!/bin/bash\r\necho "Saved with Windows line endings"\r\n' > "$S/windows-line-endings"
chmod 755 "$S/windows-line-endings"
printf '\xEF\xBB\xBF#!/bin/bash\necho "Saved with a byte-order mark"\n' > "$S/byte-order-mark"
chmod 755 "$S/byte-order-mark"
# For Text Edit's invisible characters: a zero-width space, a right-to-left
# override that would reverse the rest of its line, an escape, a form feed.
printf '#!/bin/sh\n# Look\xE2\x80\x8Bclose: a zero-width space is in the word before this.\necho "abc\xE2\x80\xAEdef stays in order when shown"\nprintf "\x1B[1mbold\x1B[0m"\n\x0C\necho after a form feed\n' > "$S/invisible-characters"
chmod 755 "$S/invisible-characters"
write missing-interpreter 755 <<'EOF'
#!/usr/local/bin/no-such-shell
echo "The interpreter named above is not installed"
EOF
write relative-interpreter 755 <<'EOF'
#!bash
echo "The interpreter is not a full path"
EOF
write not-executable 644 <<'EOF'
#!/bin/sh
echo "Not marked executable"
EOF
write executable-text-no-hashbang 755 <<'EOF'
Plain text marked executable, without a #! line.
EOF

echo "Written to $TARGET"
