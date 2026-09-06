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
    *)     die "unknown command '$1' (build | run | release | clean | path | stop)" ;;
esac
