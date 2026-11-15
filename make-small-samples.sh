#!/bin/bash
#
# Makes sample crash reports, provisioning profiles, Internet locations and
# Java properties for trying Diptych's previews by hand.
#
#   ./make-small-samples.sh [folder]   (default: ../test_folder/24-small)
#
# Everything is made up; every name is an example. It writes only into the
# folder given, and only the files named below, replacing them when they are
# there already. Needs openssl and plutil.
#
#   Sample-crash.ips          a Swift overflow, with the app's own frames
#   Sample-abort.ips          an Objective-C exception, its backtrace
#   Old-text.ips              a report in the old text form
#   Development.mobileprovision   signed with a made-up certificate, so
#                             not by Apple: the page says so
#   Example.webloc            an ordinary web address with tracking parameters
#   Looks-familiar.webloc     a user name that looks like a site, a punycode
#                             site name, a program at the end
#   Server.inetloc            an FTP location
#   Example.url               a Windows shortcut to a web page
#   Invoice.url               a Windows shortcut to a program on a file
#                             server, its icon fetched from there too
#   Messages.properties       comments, continued lines, escapes, a key set
#                             twice, blanks at the end of a value
#   Messages_hu.properties    a resource bundle in UTF-8

set -euo pipefail
cd "$(dirname "$0")"
TARGET="${1:-../test_folder/24-small}"

for tool in openssl plutil; do
    command -v "$tool" >/dev/null || { echo "needs $tool on the PATH" >&2; exit 1; }
done
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

crash() { # $1 name, $2 exception, $3 signal, $4 top frame, $5 extra body fields
cat <<EOF
{"app_name":"Sample","timestamp":"2026-11-10 09:15:00.00 +0100","app_version":"1.2","slice_uuid":"00000000-0000-0000-0000-000000000001","build_version":"34","platform":1,"bundleID":"com.example.sample","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 27.2 (26B123)","incident_id":"00000000-0000-0000-0000-000000000002","name":"Sample"}
{
  "procName" : "Sample", "procPath" : "/Applications/Sample.app/Contents/MacOS/Sample", "pid" : 4242,
  "parentProc" : "launchd", "parentPid" : 1, "cpuType" : "ARM-64", "modelCode" : "Mac14,2", "uptime" : 93784,
  "captureTime" : "2026-11-10 09:15:00.0000 +0100", "procLaunch" : "2026-11-10 09:14:12.0000 +0100",
  "osVersion" : {"train" : "macOS 27.2", "build" : "26B123", "releaseType" : "User"},
  "bundleInfo" : {"CFBundleShortVersionString" : "1.2", "CFBundleVersion" : "34", "CFBundleIdentifier" : "com.example.sample"},
  "codeSigningTeamID" : "ABCDE12345",
  "exception" : {"type" : "$2", "signal" : "$3", "codes" : "0x0000000000000001, 0x0000000100004010"},
  "termination" : {"flags" : 0, "code" : 5, "namespace" : "SIGNAL", "indicator" : "Trace/BPT trap: 5", "byProc" : "exc handler"},
  $5
  "faultingThread" : 1,
  "usedImages" : [
    {"source" : "P", "arch" : "arm64", "base" : 4294967296, "size" : 65536, "uuid" : "00000000-0000-0000-0000-000000000003",
     "path" : "/Applications/Sample.app/Contents/MacOS/Sample", "name" : "Sample", "CFBundleIdentifier" : "com.example.sample", "CFBundleShortVersionString" : "1.2"},
    {"source" : "P", "arch" : "arm64e", "base" : 6442450944, "size" : 1048576, "path" : "/usr/lib/swift/libswiftCore.dylib", "name" : "libswiftCore.dylib"},
    {"source" : "P", "arch" : "arm64e", "base" : 6450839552, "size" : 262144, "path" : "/usr/lib/system/libsystem_kernel.dylib", "name" : "libsystem_kernel.dylib"}
  ],
  "threads" : [
    {"id" : 100, "queue" : "com.apple.main-thread", "frames" : [{"imageIndex" : 2, "imageOffset" : 3080, "symbol" : "mach_msg2_trap", "symbolLocation" : 8}]},
    {"id" : 101, "triggered" : true, "queue" : "com.example.sample.loader", "frames" : [
      {"imageIndex" : 1, "imageOffset" : 4096, "symbol" : "$4", "symbolLocation" : 0},
      {"imageIndex" : 0, "imageOffset" : 16400, "symbol" : "Loader.total(of:)", "symbolLocation" : 64, "sourceFile" : "Loader.swift", "sourceLine" : 17},
      {"imageIndex" : 0, "imageOffset" : 16200, "symbol" : "closure #1 in Loader.start()", "symbolLocation" : 32, "sourceFile" : "Loader.swift", "sourceLine" : 9},
      {"imageIndex" : 2, "imageOffset" : 9000, "symbol" : "_pthread_start", "symbolLocation" : 136}]},
    {"id" : 102, "name" : "com.apple.NSEventThread", "frames" : [{"imageIndex" : 2, "imageOffset" : 3080, "symbol" : "mach_msg2_trap", "symbolLocation" : 8}]}
  ]
}
EOF
}

echo "Sample-crash.ips"
crash Sample EXC_BREAKPOINT SIGTRAP "Swift runtime failure: arithmetic overflow" "" > "$TARGET/Sample-crash.ips"
echo "Sample-abort.ips"
crash Sample EXC_CRASH SIGABRT "__pthread_kill" '"asi" : {"libsystem_c.dylib" : ["abort() called"]},
  "lastExceptionBacktrace" : [{"imageIndex" : 1, "imageOffset" : 100, "symbol" : "objc_exception_throw"},
    {"imageIndex" : 0, "imageOffset" : 16100, "symbol" : "-[SampleController load:]", "sourceFile" : "SampleController.m", "sourceLine" : 42}],' \
    > "$TARGET/Sample-abort.ips"

echo "Old-text.ips"
cat > "$TARGET/Old-text.ips" <<'EOF'
{"app_name":"Old Sample","timestamp":"2020-01-02 03:04:05.00 +0100","app_version":"0.9","bug_type":"109","os_version":"Mac OS X 10.15.7 (19H2)","bundleID":"com.example.old","name":"Old Sample"}
Process:               Old Sample [123]
Identifier:            com.example.old
Version:               0.9
Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
Exception Codes:       KERN_INVALID_ADDRESS at 0x0000000000000010

Thread 0 Crashed:: Dispatch queue: com.apple.main-thread
0   com.example.old               0x0000000100001234 -[OldController update] + 52
1   com.apple.AppKit              0x00007fff2ff00000 -[NSApplication run] + 600
EOF

echo "Development.mobileprovision"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=Apple Development: Sample Person (ABCDE12345)/OU=ABCDE12345" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
CERT=$(openssl x509 -in "$WORK/cert.pem" -outform DER | base64)
cat > "$WORK/profile.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AppIDName</key><string>Sample</string>
	<key>ApplicationIdentifierPrefix</key><array><string>ABCDE12345</string></array>
	<key>CreationDate</key><date>2026-11-01T10:00:00Z</date>
	<key>Platform</key><array><string>iOS</string></array>
	<key>IsXcodeManaged</key><true/>
	<key>DeveloperCertificates</key><array><data>$CERT</data></array>
	<key>Entitlements</key>
	<dict>
		<key>application-identifier</key><string>ABCDE12345.com.example.sample</string>
		<key>com.apple.developer.team-identifier</key><string>ABCDE12345</string>
		<key>get-task-allow</key><true/>
		<key>keychain-access-groups</key><array><string>ABCDE12345.*</string></array>
		<key>aps-environment</key><string>development</string>
	</dict>
	<key>ExpirationDate</key><date>2027-11-01T10:00:00Z</date>
	<key>Name</key><string>Sample Development Profile</string>
	<key>ProvisionedDevices</key><array>
		<string>00008110-000000000000001E</string>
		<string>00008110-000000000000002E</string>
		<string>00008120-000000000000003E</string>
	</array>
	<key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
	<key>TeamName</key><string>Example Team</string>
	<key>TimeToLive</key><integer>365</integer>
	<key>UUID</key><string>00000000-0000-0000-0000-00000000000A</string>
	<key>Version</key><integer>1</integer>
</dict>
</plist>
EOF
openssl smime -sign -binary -nodetach -outform DER -in "$WORK/profile.plist" -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" \
    > "$TARGET/Development.mobileprovision"

location() { # $1 file, $2 address
    printf '{"URL":"%s"}' "$2" | plutil -convert xml1 -o "$1" -
}
echo "Example.webloc"
location "$TARGET/Example.webloc" "https://www.example.com/products/sample?utm_source=newsletter&utm_medium=email&id=42#reviews"
echo "Looks-familiar.webloc"
location "$TARGET/Looks-familiar.webloc" "http://www.example.com@xn--bcher-kva.example/downloads/setup.exe"
echo "Server.inetloc"
location "$TARGET/Server.inetloc" "ftp://ftp.example.org/pub/"

echo "Example.url"
printf '[InternetShortcut]\r\nURL=https://www.example.org/\r\nIconIndex=0\r\n' > "$TARGET/Example.url"
echo "Invoice.url"
printf '[{000214A0-0000-0000-C000-000000000046}]\r\nProp3=19,11\r\n[InternetShortcut]\r\nIDList=\r\nURL=file://fileserver.example/share/Invoice.pdf.exe\r\nIconFile=\\\\fileserver.example\\icons\\pdf.ico\r\nIconIndex=0\r\nModified=00A0E4A2C0D6DA0100\r\n' \
    > "$TARGET/Invoice.url"

echo "Messages.properties"
cat > "$TARGET/Messages.properties" <<'EOF'
# Sample messages
! An exclamation mark starts a comment too.

app.title = Sample
app.greeting = Hello, \
               world!
path.temp : C:\\temp\\sample
key\ with\ spaces   a value after blanks
unicode.escaped=\u00e1rv\u00edzt\u0171r\u0151 t\u00fck\u00f6rf\u00far\u00f3g\u00e9p
multi.line=first line\nsecond line
trailing.blanks=two blanks follow
empty.value=

# Set again: only this one counts.
app.title = Sample, Second Edition
broken.escape=\u12
EOF

echo "Messages_hu.properties"
cat > "$TARGET/Messages_hu.properties" <<'EOF'
# Magyar szövegek, UTF-8
app.title = Minta
app.greeting = Szia, világ!
EOF

echo "Written to $TARGET"
