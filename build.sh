#!/bin/bash
#
# Build / run helper for Diptych.
#
#   ./build.sh           build (Debug)
#   ./build.sh run       build, then relaunch the app
#   ./build.sh release   build optimised (Release)
#   ./build.sh clean     delete build products
#   ./build.sh path      print the path of the built .app
#   ./build.sh stop      quit a running instance
#   ./build.sh test      run the unit tests
#   ./build.sh dmg       build Release and package it as a mountable .dmg
#   ./build.sh notarize  submit the .dmg to Apple and staple the ticket
#
# Everything Xcode does with Cmd-R, without opening Xcode.

set -euo pipefail

cd "$(dirname "$0")"

PROJECT="Diptych.xcodeproj"
SCHEME="Diptych"
CONFIG="${CONFIG:-Debug}"

# Pinning the destination avoids xcodebuild's "using the first of multiple
# matching destinations" warning, which it emits because a Mac can build both
# arm64 and x86_64.
DESTINATION="platform=macOS,arch=$(uname -m)"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# ANSI colours, but only when stdout is a terminal, so piping stays clean.
if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; OFF=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; OFF=""
fi

info() { printf '%s==>%s %s\n' "$BOLD" "$OFF" "$*"; }
die()  { printf '%s==> %s%s\n' "$RED" "$*" "$OFF" >&2; exit 1; }

# Ask xcodebuild where it puts the product rather than hardcoding a DerivedData
# path -- that path contains a hash of the project location and will differ on
# any other machine.
app_path() {
    local dir
    dir=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                     -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
          | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')
    [ -n "$dir" ] || die "could not determine BUILT_PRODUCTS_DIR"
    printf '%s/%s.app\n' "$dir" "$SCHEME"
}

build() {
    local log
    log=$(mktemp -t twopane-build)
    # Trap rather than a plain rm at the end, so an interrupted build still
    # cleans up after itself.
    trap 'rm -f "$log"' RETURN

    info "Building $SCHEME ($CONFIG)..."

    if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                  -destination "$DESTINATION" build >"$log" 2>&1; then
        # xcodebuild is extremely chatty. On success, surface only real
        # diagnostics -- lines that start with an absolute source path.
        local warnings
        warnings=$(grep -E '^/.*: warning:' "$log" | sort -u || true)
        if [ -n "$warnings" ]; then
            printf '%s%s%s\n' "$YELLOW" "$warnings" "$OFF"
        fi
        printf '%s==> Build succeeded%s\n' "$GREEN" "$OFF"
    else
        grep -E '^/.*: (error|warning):' "$log" || tail -40 "$log"
        die "Build failed"
    fi
}

stop_app() {
    if pgrep -x "$SCHEME" >/dev/null; then
        info "Quitting running $SCHEME..."
        osascript -e "tell application \"$SCHEME\" to quit" >/dev/null 2>&1 || true
        # Give it a moment to go away, then insist.
        for _ in $(seq 1 30); do
            pgrep -x "$SCHEME" >/dev/null || return 0
            /bin/sleep 0.1
        done
        pkill -x "$SCHEME" || true
    fi
}

# Unit tests. The test bundle is injected into the app, so the app launches and
# floods stderr with unrelated system logging; only the test lines are shown.
run_tests() {
    local log
    log=$(mktemp -t diptych-test)
    trap 'rm -f "$log"' RETURN

    info "Testing $SCHEME..."

    if xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
                  -destination "$DESTINATION" test >"$log" 2>&1; then
        grep -E "^Test Case .*(passed|failed)" "$log" \
            | sed -E "s/^Test Case '-\[[A-Za-z]+ (.*)\]'/    \1/" \
            | sed 's/ (.*seconds).*//' || true
        grep -E "^\s*Executed [0-9]+ test" "$log" | tail -1 | sed 's/^[[:space:]]*/    /'
        printf '%s==> Tests passed%s\n' "$GREEN" "$OFF"
    else
        grep -E "^Test Case .*failed|error:|XCTAssert" "$log" | head -40
        grep -E "^\s*Executed [0-9]+ test" "$log" | tail -1
        die "Tests failed"
    fi
}

# The first Developer ID Application certificate in the keychain, if any.
developer_id() {
    # `|| true`: grep exits non-zero when there is no such certificate, and
    # under `set -e` that would abort the whole build rather than simply
    # meaning "no Developer ID here".
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" \
        | head -1 \
        | sed 's/.*"\(.*\)"/\1/' || true
}

# Submit the image to Apple and staple the resulting ticket, so the app opens
# without a warning even on a machine that has never seen it.
#
# Needs credentials stored once with:
#   xcrun notarytool store-credentials Diptych \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
notarize_dmg() {
    local dmg
    dmg=$(/bin/ls -t "$PWD/build"/Diptych-*.dmg 2>/dev/null | head -1)
    [ -n "$dmg" ] || die "no disk image in ./build -- run ./build.sh dmg first"

    [ -n "$(developer_id || true)" ] || die "notarizing needs a Developer ID certificate"

    info "Submitting $(basename "$dmg") to Apple (this takes a few minutes)"
    xcrun notarytool submit "$dmg" --keychain-profile "${NOTARY_PROFILE:-Diptych}" --wait

    info "Stapling the ticket"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    printf '%s==> Notarized: %s%s\n' "$GREEN" "$dmg" "$OFF"
}

# Package the Release build as a disk image with an Applications shortcut, the
# arrangement users expect: mount, drag across, eject.
make_dmg() {
    CONFIG=Release
    build

    local app version staging dmg
    app=$(app_path)
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
              "$app/Contents/Info.plist")
    dmg="$PWD/build/Diptych-$version.dmg"

    staging=$(mktemp -d)
    trap 'rm -rf "$staging"' RETURN

    # Sign the app with a Developer ID when one exists. Without this the image
    # is just a container for an ad-hoc signed app, and Gatekeeper refuses it.
    local identity
    identity=$(developer_id || true)
    if [ -n "$identity" ]; then
        info "Signing the app as $identity"
        codesign --force --deep --options runtime --timestamp \
                 --sign "$identity" "$app"
        codesign --verify --deep --strict --verbose=1 "$app" 2>&1 | sed 's/^/    /'
    fi

    info "Staging $app"
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"

    mkdir -p "$PWD/build"
    rm -f "$dmg"

    info "Building $dmg"
    hdiutil create -volname "Diptych $version" \
                   -srcfolder "$staging" \
                   -fs HFS+ -format UDZO -ov -quiet "$dmg"

    # Sign the image itself too, so Gatekeeper has something to check before the
    # app is ever copied out of it.
    if [ -n "$identity" ]; then
        info "Signing the image as $identity"
        codesign --sign "$identity" --timestamp "$dmg" || true
    else
        printf '%s==> No Developer ID found: the image is unsigned.%s\n' "$YELLOW" "$OFF"
        printf '    Users will see \"Diptych cannot be opened because the developer\n'
        printf '    cannot be verified\" and must right-click > Open the first time.\n'
    fi

    printf '%s==> %s%s\n' "$GREEN" "$dmg" "$OFF"
    du -h "$dmg" | sed 's/^/    /'
}

case "${1:-build}" in
    build)   build ;;
    release) CONFIG=Release; build ;;
    run)
        build
        stop_app
        app=$(app_path)
        # Re-register with LaunchServices. Without this the Dock keeps showing
        # whatever icon it cached the first time it saw this bundle path, which
        # is a generic placeholder if the app was ever built without an icon.
        "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
        info "Launching $app"
        open "$app"
        ;;
    clean)
        info "Cleaning..."
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
                   -destination "$DESTINATION" clean >/dev/null
        printf '%s==> Clean%s\n' "$GREEN" "$OFF"
        ;;
    path)  app_path ;;
    stop)  stop_app ;;
    test)     run_tests ;;
    dmg)      make_dmg ;;
    notarize) notarize_dmg ;;
    *)     die "unknown command '$1' (build | run | release | test | clean | path | stop | dmg | notarize)" ;;
esac
