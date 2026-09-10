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
#   ./build.sh version [x.y.z]   show, or set, the version
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
# without a werning even on a machine that has never seen it.
#
# Needs credentials stored once with:
#   xcrun notarytool store-credentials Diptych \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
# The version lives in the project file, twice -- once per build configuration --
# and there is no Info.plist to edit: GENERATE_INFOPLIST_FILE is on, so Xcode
# synthesises one from these settings at build time.
#
# Setting it by hand is the kind of thing that is easy to half-do. Change only
# the Release copy and a debug build reports a different version from the one
# you shipped; forget CURRENT_PROJECT_VERSION and Apple rejects the second
# upload of a version as a duplicate, because that number is what distinguishes
# two builds of the same release.
show_or_set_version() {
    local wanted="${1:-}"
    local current build_number
    # sed rather than awk fields: the lines are tab-indented, so which field
    # holds the value depends on how the separator treats leading whitespace --
    # and getting that wrong reads an empty string, which then silently sets the
    # build number to 1 instead of incrementing it.
    current=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PROJECT/project.pbxproj" | head -1)
    build_number=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' \
                   "$PROJECT/project.pbxproj" | head -1)
    [ -n "$current" ] || die "no MARKETING_VERSION in $PROJECT/project.pbxproj"
    case "$build_number" in
        ''|*[!0-9]*) die "CURRENT_PROJECT_VERSION is '$build_number', which is not a number" ;;
    esac

    if [ -z "$wanted" ]; then
        printf '%s (build %s)\n' "$current" "$build_number"
        return
    fi

    # Semantic versioning, since that is what the README promises and what the
    # DMG filename becomes.
    case "$wanted" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) die "version must look like 1.2.3, not '$wanted'" ;;
    esac

    local count
    count=$(grep -c "MARKETING_VERSION = " "$PROJECT/project.pbxproj" || true)
    [ "$count" -ge 2 ] || die "expected a MARKETING_VERSION per configuration, found $count"

    # Every occurrence, so the configurations cannot drift apart.
    sed -i '' "s/MARKETING_VERSION = .*;/MARKETING_VERSION = $wanted;/g" \
        "$PROJECT/project.pbxproj"
    sed -i '' "s/CURRENT_PROJECT_VERSION = .*;/CURRENT_PROJECT_VERSION = $(( build_number + 1 ));/g" \
        "$PROJECT/project.pbxproj"

    printf '%s==> %s (build %s) -- was %s (build %s)%s\n' \
        "$GREEN" "$wanted" "$(( build_number + 1 ))" "$current" "$build_number" "$OFF"
    printf '    %s\n' "The next ./build.sh dmg writes build/Diptych-$wanted.dmg"
}

notarize_dmg() {
    local dmg
    dmg=$(/bin/ls -t "$PWD/build"/Diptych-*.dmg 2>/dev/null | head -1)
    [ -n "$dmg" ] || die "no disk image in ./build -- run ./build.sh dmg first"

    [ -n "$(developer_id || true)" ] || die "notarizing needs a Developer ID certificate"

    # A stale image is the easy mistake: `dmg` and `notarize` are separate
    # commands, and the newest image in ./build may predate the certificate.
    local mount device
    mount=$(mktemp -d)
    # The device is detached by name, not by mount point: detaching by path
    # fails once the path is gone, and an image left attached makes the next
    # `hdiutil create` fail with nothing more helpful than "Resource busy".
    device=$(hdiutil attach -nobrowse -noverify "$dmg" -mountpoint "$mount" \
             | awk '/^\/dev\/disk/{print $1; exit}')
    local signed_ok=0 inside
    inside=$(codesign -dvv "$mount"/*.app 2>&1 || true)
    case "$inside" in *"Authority=Developer ID Application"*) signed_ok=1 ;; esac
    [ -n "$device" ] && hdiutil detach "$device" -force -quiet || true
    rmdir "$mount" 2>/dev/null || true
    [ "$signed_ok" = 1 ] || die "$(basename "$dmg") holds an app that is not Developer ID signed -- run ./build.sh dmg again"

    info "Submitting $(basename "$dmg") to Apple (this takes a few minutes)"
    local output status submission
    # notarytool exits 0 when the *submission* succeeded, whatever the verdict
    # was, so the verdict has to be read rather than assumed. Stapling a
    # rejected submission is what this used to do, and it failed confusingly
    # several minutes after the real error had already scrolled past.
    output=$(xcrun notarytool submit "$dmg" \
                --keychain-profile "${NOTARY_PROFILE:-Diptych}" --wait 2>&1) || true
    printf '%s\n' "$output" | sed 's/^/    /'

    submission=$(printf '%s\n' "$output" | awk '/^ *id: /{print $2; exit}')
    status=$(printf '%s\n' "$output" | awk '/^ *status: /{print $2; exit}')

    if [ "$status" != "Accepted" ]; then
        printf '%s==> Notarization was %s. Apple says:%s\n' "$YELLOW" "${status:-unknown}" "$OFF"
        [ -n "$submission" ] && xcrun notarytool log "$submission" \
            --keychain-profile "${NOTARY_PROFILE:-Diptych}" 2>&1 | sed 's/^/    /'
        die "notarization failed -- nothing was stapled"
    fi

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

        # Xcode injects com.apple.security.get-task-allow -- the "a debugger may
        # attach to me" entitlement -- into every build it signs, and Apple
        # refuses to notarize anything carrying it. Re-signing without
        # --entitlements keeps whatever is already embedded, so an explicit
        # empty set is the only way to be rid of it.
        local entitlements
        entitlements=$(mktemp -t diptych-entitlements)
        cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST

        # No --deep: it is deprecated for signing, and there is nothing nested
        # to sign anyway -- the bundle is one executable with no frameworks or
        # helpers. --options runtime and --timestamp are both required before
        # Apple will notarize.
        codesign --force --options runtime --timestamp \
                 --entitlements "$entitlements" \
                 --sign "$identity" "$app"
        rm -f "$entitlements"
        codesign --verify --deep --strict --verbose=1 "$app" 2>&1 | sed 's/^/    /'

        # Checked here rather than discovered by Apple twenty minutes later.
        # Each of these was an error in a rejected submission.
        #
        # Matched with `case` rather than piped into `grep -q`: grep exits at
        # the first match, codesign then dies of SIGPIPE, and `pipefail` reports
        # the whole pipeline as failed -- so the check rejected a perfectly good
        # signature. `set -euo pipefail` and `grep -q` do not mix.
        local description entitlements_now
        description=$(codesign -dvv "$app" 2>&1)
        case "$description" in
            *"Authority=Developer ID Application"*) ;;
            *) die "the app is not signed with a Developer ID certificate" ;;
        esac
        case "$description" in
            *"Timestamp="*) ;;
            *) die "the signature has no secure timestamp" ;;
        esac
        entitlements_now=$(codesign -d --entitlements - "$app" 2>/dev/null | tr -d '\0')
        case "$entitlements_now" in
            *get-task-allow*) die "the app still carries com.apple.security.get-task-allow" ;;
        esac
    fi

    info "Staging $app"
    cp -R "$app" "$staging/"

    mkdir -p "$PWD/build"
    rm -f "$dmg"

    info "Building $dmg"

    # Built explicitly rather than with `hdiutil create -srcfolder`, which does
    # its own create-attach-copy-detach-convert internally and fails as a whole
    # with nothing but "Resource busy" when any step of that is unhappy --
    # measured on this machine, where `create -size`, `attach` and `mount` all
    # worked and only `-srcfolder` did not. Doing the steps here means a failure
    # names which step failed, and it is what the DMG tools all do for the same
    # reason.
    local size_kb blank device attached mountpoint
    size_kb=$(du -sk "$staging" | awk '{print $1}')
    # Slack for the filesystem's own structures; an image sized to its contents
    # exactly has no room to write them.
    size_kb=$(( size_kb + 20480 ))

    blank="${dmg%.dmg}-rw.dmg"
    rm -f "$blank"
    hdiutil create -size "${size_kb}k" -volname "Diptych $version" \
                   -fs HFS+ -ov "$blank" >/dev/null \
        || die "could not create the empty image"

    attached=$(hdiutil attach -nobrowse -noverify -readwrite "$blank") \
        || die "could not attach the image"
    device=$(printf '%s\n' "$attached" | awk '/^\/dev\/disk/{print $1; exit}')
    mountpoint=$(printf '%s\n' "$attached" | sed -n 's|.*[[:space:]]\(/Volumes/.*\)$|\1|p' | head -1)
    [ -n "$mountpoint" ] || die "the image attached but did not mount"

    ditto "$app" "$mountpoint/$(basename "$app")" || {
        hdiutil detach "$device" -force -quiet || true
        die "could not copy the app into the image"
    }
    ln -s /Applications "$mountpoint/Applications"

    hdiutil detach "$device" -force -quiet || die "could not detach the image"
    hdiutil convert "$blank" -format UDZO -ov -o "$dmg" >/dev/null \
        || die "could not compress the image"
    rm -f "$blank"

    # Sign the image itself too, so Gatekeeper has something to check before the
    # app is ever copied out of it.
    if [ -n "$identity" ]; then
        info "Signing the image as $identity"
        codesign --sign "$identity" --timestamp "$dmg" || true
    else
        printf '%s==> No Developer ID found: the image is unsigned.%s\n' "$YELLOW" "$OFF"
        printf '    Users will see \"Apple could not verify Diptych is free of malware\"\n'
        printf '    and must allow it in System Settings > Privacy and Security.\n'
        printf '    Control-click > Open stopped working as a bypass in macOS 15.\n'
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
    version)  show_or_set_version "${2:-}" ;;
    *)     die "unknown command '$1' (build | run | release | test | clean | path | stop | dmg | notarize | version)" ;;
esac
