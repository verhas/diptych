#!/bin/bash
#
# Makes sample application bundles for trying Diptych's bundle preview by
# hand.
#
#   ./make-bundle-samples.sh [folder]   (default: ../test_folder/20-bundles)
#
# Every app is a made-up hello world compiled here and signed ad hoc; the
# identifiers are under example.diptych (example names are reserved). It
# writes only into the folder given, and only the bundles named below,
# replacing them when they are there already. Needs clang and codesign.
#
#   Diptych Sample.app      version, category, copyright, permissions it asks
#                           for, documents and links it opens, two languages;
#                           a framework, an app extension, a login item, a
#                           launch agent; hardened runtime, sandbox
#   Changed After Signing.app   the same with one resource edited and one
#                           deleted: its seal is broken
#   Unsigned.app            not signed at all
#   Downloaded.app          marked as downloaded with Safari, not opened yet
#   Menu Bar Sample.app     no Dock icon (LSUIElement)
#   Intel Only.app          x86_64 only

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/20-bundles}"

for tool in clang codesign; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.c" <<'EOF'
#include <stdio.h>
int main(void) { printf("Hello from a Diptych sample\n"); return 0; }
EOF
cat > "$WORK/kit.c" <<'EOF'
int sample_kit_answer(void) { return 42; }
EOF
cat > "$WORK/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.device.camera</key><true/>
    <key>com.apple.security.files.user-selected.read-write</key><true/>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
EOF

# info NAME IDENTIFIER VERSION EXTRA-KEYS > Info.plist
info() {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$1</string>
    <key>CFBundleName</key><string>$1</string>
    <key>CFBundleIdentifier</key><string>$2</string>
    <key>CFBundleShortVersionString</key><string>$3</string>
    <key>CFBundleVersion</key><string>${3}.17</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
$4
</dict>
</plist>
EOF
}

# app PATH NAME IDENTIFIER EXTRA-KEYS [arch]
app() {
    local bundle="$1" name="$2" arch="${5:-arm64}"
    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    clang -Os -arch "$arch" -mmacosx-version-min=13.0 "$WORK/main.c" -o "$bundle/Contents/MacOS/$name"
    info "$name" "$3" "1.4.2" "    <key>CFBundlePackageType</key><string>APPL</string>
$4" > "$bundle/Contents/Info.plist"
}

MAIN_KEYS='    <key>CFBundleDisplayName</key><string>Diptych Sample</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>Public domain. Made for Diptych samples.</string>
    <key>NSCameraUsageDescription</key><string>The sample takes no pictures; this is only what it would say.</string>
    <key>NSDesktopFolderUsageDescription</key><string>To show what a request for the Desktop looks like.</string>
    <key>NSAppleEventsUsageDescription</key><string>To show what asking to control other apps looks like.</string>
    <key>CFBundleDocumentTypes</key><array><dict>
        <key>CFBundleTypeName</key><string>Diptych Sample Document</string>
        <key>CFBundleTypeExtensions</key><array><string>diptychsample</string></array>
        <key>CFBundleTypeRole</key><string>Editor</string></dict></array>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>Diptych sample links</string>
        <key>CFBundleURLSchemes</key><array><string>diptych-sample</string></array></dict></array>
    <key>DTXcode</key><string>1610</string>
    <key>DTSDKName</key><string>macosx15.1</string>'

echo "Diptych Sample.app"
A="$TARGET/Diptych Sample.app"
app "$A" "Diptych Sample" example.diptych.sample "$MAIN_KEYS"
mkdir -p "$A/Contents/Resources/en.lproj" "$A/Contents/Resources/hu.lproj"
echo '"greeting" = "Hello";' > "$A/Contents/Resources/en.lproj/Localizable.strings"
echo '"greeting" = "Szia";' > "$A/Contents/Resources/hu.lproj/Localizable.strings"
echo "A resource file: the seal records its hash." > "$A/Contents/Resources/readme.txt"
echo "Another resource, deleted from the changed copy." > "$A/Contents/Resources/notes.txt"

# A framework, in its Versions layout.
F="$A/Contents/Frameworks/SampleKit.framework"
mkdir -p "$F/Versions/A/Resources"
clang -Os -arch arm64 -dynamiclib "$WORK/kit.c" -o "$F/Versions/A/SampleKit" \
    -install_name @rpath/SampleKit.framework/Versions/A/SampleKit -mmacosx-version-min=13.0
info SampleKit example.diptych.samplekit 2.0 "    <key>CFBundlePackageType</key><string>FMWK</string>" \
    > "$F/Versions/A/Resources/Info.plist"
ln -s A "$F/Versions/Current"
ln -s Versions/Current/SampleKit "$F/SampleKit"
ln -s Versions/Current/Resources "$F/Resources"

# An app extension and a login item.
E="$A/Contents/PlugIns/Sample Widget.appex"
mkdir -p "$E/Contents/MacOS"
clang -Os -arch arm64 -mmacosx-version-min=13.0 "$WORK/main.c" -o "$E/Contents/MacOS/Sample Widget"
info "Sample Widget" example.diptych.sample.widget 1.4.2 "    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>" \
    > "$E/Contents/Info.plist"
app "$A/Contents/Library/LoginItems/Sample Helper.app" "Sample Helper" example.diptych.sample.helper \
    "    <key>LSUIElement</key><true/>"
mkdir -p "$A/Contents/Library/LaunchAgents"
cat > "$A/Contents/Library/LaunchAgents/example.diptych.sample.agent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>example.diptych.sample.agent</string>
    <key>BundleProgram</key><string>Contents/Library/LoginItems/Sample Helper.app/Contents/MacOS/Sample Helper</string>
    <key>Program</key><string>Contents/Library/LoginItems/Sample Helper.app/Contents/MacOS/Sample Helper</string>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

# Signed inside out, as Xcode does: the nested code first.
codesign -f -s - "$F/Versions/A" 2>/dev/null
codesign -f -s - -o runtime "$E" 2>/dev/null
codesign -f -s - -o runtime "$A/Contents/Library/LoginItems/Sample Helper.app" 2>/dev/null
codesign -f -s - -o runtime --entitlements "$WORK/entitlements.plist" "$A" 2>/dev/null

echo "Changed After Signing.app"
C="$TARGET/Changed After Signing.app"
rm -rf "$C"
cp -R "$A" "$C"
echo "Edited after signing." >> "$C/Contents/Resources/readme.txt"
rm "$C/Contents/Resources/notes.txt"

echo "Unsigned.app"
U="$TARGET/Unsigned.app"
app "$U" Unsigned example.diptych.unsigned ""
codesign --remove-signature "$U/Contents/MacOS/Unsigned"

echo "Downloaded.app"
D="$TARGET/Downloaded.app"
app "$D" Downloaded example.diptych.downloaded ""
codesign -f -s - "$D" 2>/dev/null
# What a browser leaves: flags, the time in hex, the agent; and the address.
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;" "$D"
xattr -wx com.apple.metadata:kMDItemWhereFroms \
    "$(printf '%s' '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><array><string>https://example.com/downloads/Downloaded.zip</string><string>https://example.com/</string></array></plist>' \
       | plutil -convert binary1 -o - - | xxd -p | tr -d '\n')" "$D"

echo "Menu Bar Sample.app"
app "$TARGET/Menu Bar Sample.app" "Menu Bar Sample" example.diptych.menubar "    <key>LSUIElement</key><true/>"
codesign -f -s - "$TARGET/Menu Bar Sample.app" 2>/dev/null

echo "Intel Only.app"
app "$TARGET/Intel Only.app" "Intel Only" example.diptych.intel "" x86_64
codesign -f -s - "$TARGET/Intel Only.app" 2>/dev/null

echo "Written to $TARGET"
