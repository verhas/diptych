#!/bin/bash
#
# Makes sample disk images for trying Diptych's disk image preview by hand.
#
#   ./make-disk-image-samples.sh [folder]   (default: ../test_folder/22-disk-images)
#
# The images hold a made-up app folder and a text file. Nothing is attached
# (mounted): hdiutil and diskutil build the images from a folder. It writes
# only into the folder given, and only the files named below, replacing them
# when they are there already. Needs hdiutil, diskutil and codesign.
#
#   Sample App.dmg            APFS, LZFSE-compressed (ULFO), an app and a link
#                             to Applications, signed ad hoc
#   Changed After Signing.dmg the same with one byte changed: its seal is broken
#   Classic HFS.dmg           Mac OS Extended, zlib-compressed (UDZO)
#   LZMA.dmg                  APFS, LZMA-compressed (ULMO)
#   Uncompressed.dmg          APFS, read-only, not compressed (UDRO)
#   Raw.dmg                   the bytes of a disk as they are
#   Sparse.sparseimage        a sparse image, HFS+
#   Sparse.sparsebundle       a sparse bundle (a folder of bands), APFS
#   Encrypted.dmg             AES-256; the password is "diptych-sample"
#   Disc.iso                  an ISO 9660 disc image

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/22-disk-images}"

for tool in hdiutil diskutil codesign; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCE="$WORK/Diptych Sample"
APP="$SOURCE/Diptych Sample.app/Contents"
mkdir -p "$APP/MacOS"
printf '#!/bin/sh\necho "Hello"\n' > "$APP/MacOS/Diptych Sample"
chmod 755 "$APP/MacOS/Diptych Sample"
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Diptych Sample</string>
    <key>CFBundleIdentifier</key><string>example.diptych.dmg</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF
echo "Drag the app onto Applications." > "$SOURCE/Read Me.txt"
ln -s /Applications "$SOURCE/Applications"

fresh() { rm -rf "$TARGET/$1"; }

# diskutil image create: the current tool, and APFS by default.
image() { # NAME FORMAT
    fresh "$1"
    diskutil image create from --format "$2" "$SOURCE" "$TARGET/$1" >/dev/null 2>&1
}

echo "Sample App.dmg"
image "Sample App.dmg" ULFO
codesign -s - "$TARGET/Sample App.dmg"

echo "Changed After Signing.dmg"
fresh "Changed After Signing.dmg"
cp "$TARGET/Sample App.dmg" "$TARGET/Changed After Signing.dmg"
# One byte inside the compressed data, well before the signature.
printf '\x00' | dd of="$TARGET/Changed After Signing.dmg" bs=1 seek=2000 conv=notrunc 2>/dev/null

echo "Classic HFS.dmg"
fresh "Classic HFS.dmg"
hdiutil create -quiet -srcfolder "$SOURCE" -volname "Classic HFS" -fs HFS+ -format UDZO "$TARGET/Classic HFS.dmg"

echo "LZMA.dmg"
image "LZMA.dmg" ULMO
echo "Uncompressed.dmg"
image "Uncompressed.dmg" UDRO
echo "Raw.dmg"
image "Raw.dmg" RAW

echo "Sparse.sparseimage"
fresh "Sparse.sparseimage"
hdiutil create -quiet -size 20m -type SPARSE -fs HFS+ -volname "Sparse" "$TARGET/Sparse.sparseimage"
echo "Sparse.sparsebundle"
fresh "Sparse.sparsebundle"
diskutil image create from "$SOURCE" "$TARGET/Sparse.sparsebundle" >/dev/null 2>&1

echo "Encrypted.dmg"
fresh "Encrypted.dmg"
printf 'diptych-sample' | diskutil image create from --encrypt --stdinpass "$SOURCE" "$TARGET/Encrypted.dmg" >/dev/null 2>&1

echo "Disc.iso"
fresh "Disc.iso"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name "DIPTYCH_DISC" -o "$TARGET/Disc.iso" "$SOURCE"

echo "Written to $TARGET"
