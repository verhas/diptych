#!/bin/bash
#
# Makes sample installer packages for trying Diptych's package preview by
# hand.
#
#   ./make-package-samples.sh [folder]   (default: ../test_folder/21-packages)
#
# Every package is made up here; identifiers are under example.diptych.
# Nothing is installed: the packages are only built. It writes only into the
# folder given, and only the files named below, replacing them when they are
# there already. Needs pkgbuild and productbuild.
#
#   Sample Tool.pkg       a component package: a command-line tool, a launch
#                         daemon, preinstall and postinstall scripts
#   Sample Product.pkg    a product package (Distribution): title, minimum
#                         macOS, processors, an installation check in
#                         JavaScript, two components, choices, a welcome text
#   Scripts Only.pkg      installs no files; all it does is run a script
#   Not a Package.pkg     text with a .pkg name

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/21-packages}"

for tool in pkgbuild productbuild python3; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# xar records who built each file by name: the samples say root instead,
# and the table's checksum is made again to match.
anonymous() {
    python3 - "$1" <<'PY'
import hashlib, re, struct, sys, zlib
path = sys.argv[1]
data = open(path, "rb").read()
header, = struct.unpack(">H", data[4:6])
packed, = struct.unpack(">Q", data[8:16])
toc = zlib.decompress(data[header:header + packed]).decode()
for tag, value in (("user", "root"), ("group", "wheel"), ("uid", "0"), ("gid", "0")):
    toc = re.sub(r"<%s>[^<]*</%s>" % (tag, tag), "<%s>%s</%s>" % (tag, value, tag), toc)
table = zlib.compress(toc.encode(), 9)
heap = bytearray(data[header + packed:])
found = re.search(r'<checksum style="(\w+)">\s*<offset>(\d+)</offset>\s*<size>(\d+)</size>', toc)
if found:
    digest = hashlib.new(found.group(1), table).digest()
    heap[int(found.group(2)):int(found.group(2)) + len(digest)] = digest
start = bytearray(data[:header])
start[8:24] = struct.pack(">QQ", len(table), len(toc.encode()))
open(path, "wb").write(bytes(start) + table + bytes(heap))
PY
}

# The tool: a script and a launch daemon that would start it.
ROOT="$WORK/tool-root"
mkdir -p "$ROOT/usr/local/bin" "$ROOT/Library/LaunchDaemons"
cat > "$ROOT/usr/local/bin/sample-tool" <<'EOF'
#!/bin/sh
echo "Hello from a Diptych sample tool"
EOF
chmod 755 "$ROOT/usr/local/bin/sample-tool"
cat > "$ROOT/Library/LaunchDaemons/example.diptych.tool.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>example.diptych.tool</string>
    <key>ProgramArguments</key><array><string>/usr/local/bin/sample-tool</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

SCRIPTS="$WORK/tool-scripts"
mkdir -p "$SCRIPTS"
cat > "$SCRIPTS/preinstall" <<'EOF'
#!/bin/sh
# Runs before the files are installed: stops an older copy of the daemon.
launchctl bootout system/example.diptych.tool 2>/dev/null || true
exit 0
EOF
cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/sh
# Runs after the files are installed: starts the daemon.
launchctl bootstrap system /Library/LaunchDaemons/example.diptych.tool.plist
"$(dirname "$0")/helper.sh" "$2"
exit 0
EOF
cat > "$SCRIPTS/helper.sh" <<'EOF'
#!/bin/sh
# Used by postinstall, not run by Installer itself.
echo "installed on $1"
EOF
chmod 755 "$SCRIPTS"/*

# Extended attributes would go in as "._" files beside each one.
xattr -cr "$WORK"
echo "Sample Tool.pkg"
pkgbuild --quiet --root "$ROOT" --scripts "$SCRIPTS" --identifier example.diptych.tool --version 1.2.0 \
    --install-location / "$TARGET/Sample Tool.pkg"
anonymous "$TARGET/Sample Tool.pkg"

# An application component for the product.
APP="$WORK/app-root/Diptych Sample Viewer.app/Contents"
mkdir -p "$APP/MacOS" "$APP/Resources"
printf '#!/bin/sh\necho "Hello"\n' > "$APP/MacOS/Diptych Sample Viewer"
chmod 755 "$APP/MacOS/Diptych Sample Viewer"
cat > "$APP/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Diptych Sample Viewer</string>
    <key>CFBundleIdentifier</key><string>example.diptych.viewer</string>
    <key>CFBundleShortVersionString</key><string>3.1</string>
    <key>CFBundleVersion</key><string>310</string>
    <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF
xattr -cr "$WORK"
pkgbuild --quiet --analyze --root "$WORK/app-root" "$WORK/components.plist"
pkgbuild --quiet --root "$WORK/app-root" --component-plist "$WORK/components.plist" \
    --identifier example.diptych.viewer --version 3.1 --install-location /Applications "$WORK/viewer.pkg"
cp "$TARGET/Sample Tool.pkg" "$WORK/tool.pkg"

mkdir -p "$WORK/resources/en.lproj"
echo "Welcome to the Diptych sample product. Nothing in it does anything." > "$WORK/resources/en.lproj/Welcome.txt"
cat > "$WORK/distribution.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Diptych Sample Product</title>
    <welcome file="Welcome.txt"/>
    <options customize="allow" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
    <installation-check script="enoughMemory()"/>
    <script><![CDATA[
function enoughMemory() {
    // Installer's JavaScript: it may look, not change.
    if (system.sysctl('hw.memsize') < 4 * 1024 * 1024 * 1024) {
        my.result.type = 'Fatal';
        my.result.message = 'This sample wants at least 4 GB of memory.';
        return false;
    }
    return true;
}
    ]]></script>
    <choices-outline>
        <line choice="viewer"/>
        <line choice="tool"/>
    </choices-outline>
    <choice id="viewer" title="Sample Viewer" description="The application.">
        <pkg-ref id="example.diptych.viewer"/>
    </choice>
    <choice id="tool" title="Command-line Tool" description="A tool and its daemon.">
        <pkg-ref id="example.diptych.tool"/>
    </choice>
    <pkg-ref id="example.diptych.viewer" version="3.1">viewer.pkg</pkg-ref>
    <pkg-ref id="example.diptych.tool" version="1.2.0" onConclusion="RequireRestart">tool.pkg</pkg-ref>
    <product id="example.diptych.product" version="3.1"/>
</installer-gui-script>
EOF
echo "Sample Product.pkg"
productbuild --quiet --distribution "$WORK/distribution.xml" --resources "$WORK/resources" \
    --package-path "$WORK" "$TARGET/Sample Product.pkg"
anonymous "$TARGET/Sample Product.pkg"

mkdir -p "$WORK/only-scripts"
cat > "$WORK/only-scripts/postinstall" <<'EOF'
#!/bin/sh
# All this package does: write a preference, as root.
defaults write /Library/Preferences/example.diptych.sample Configured -bool true
exit 0
EOF
chmod 755 "$WORK/only-scripts/postinstall"
xattr -cr "$WORK"
echo "Scripts Only.pkg"
pkgbuild --quiet --nopayload --scripts "$WORK/only-scripts" --identifier example.diptych.scripts --version 1.0 \
    "$TARGET/Scripts Only.pkg"
anonymous "$TARGET/Scripts Only.pkg"

echo "Not a Package.pkg"
echo "This is text, whatever its name says." > "$TARGET/Not a Package.pkg"

echo "Written to $TARGET"
