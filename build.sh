#!/bin/sh
# Builds SoftClick.app into build/.
#
#   ./build.sh            build for this Mac and run the self-test
#   ./build.sh --install  build, then copy the app to ~/Applications
#   ./build.sh --release  universal (Apple silicon + Intel) build plus build/SoftClick.zip
#
# Set VERSION=1.2.3 to override the version written into Info.plist.
set -eu
cd "$(dirname "$0")"

NAME=SoftClick
MODE="${1:-}"
case "$MODE" in
    ""|--install|--release) ;;
    *) echo "Usage: $0 [--install | --release]" >&2; exit 2 ;;
esac

ARCHS=""
if [ "$MODE" = "--release" ]; then
    ARCHS="-arch arm64 -arch x86_64"
    rm -f build/$NAME    # never reuse a single-architecture binary
fi
make app ARCHS="$ARCHS"

APP="build/$NAME.app"
if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
    codesign --force --sign - --timestamp=none --identifier io.github.vivogf.SoftClick "$APP"
fi
if ! SELFTEST="$("$APP/Contents/MacOS/$NAME" --selftest)"; then
    echo "$SELFTEST"
    echo "self-test failed" >&2
    exit 1
fi
echo "built $APP"

case "$MODE" in
    --install)
        if pgrep -x "$NAME" >/dev/null; then
            echo "Quit Soft Click from its menu first, so it can restore the stock click." >&2
            exit 1
        fi
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/$NAME.app"
        cp -R "$APP" "$HOME/Applications/"
        echo "installed $HOME/Applications/$NAME.app"
        ;;
    --release)
        rm -f "build/$NAME.zip"
        ditto -c -k --keepParent "$APP" "build/$NAME.zip"
        shasum -a 256 "build/$NAME.zip"
        ;;
esac
