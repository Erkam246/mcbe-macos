#!/bin/bash
# Installs a decrypted Minecraft IPA into PlayCover, applies the settings that
# work, and patches in the macfix dylib.
#
# usage: scripts/setup.sh <minecraft.ipa>   install, configure and patch
#        scripts/setup.sh --patch-only       re-patch an installed app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID=com.mojang.minecraftpe
PLAYCOVER=/Applications/PlayCover.app
CONTAINER="$HOME/Library/Containers/io.playcover.PlayCover"
APP_DIR="${APP_DIR:-$CONTAINER/Applications/$BUNDLE_ID.app}"
SETTINGS="${SETTINGS:-$CONTAINER/App Settings/$BUNDLE_ID.plist}"
BUILD="$ROOT/build"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

quit_game() {
    local pid
    pid=$(pgrep -x minecraftpe || true)
    [ -z "$pid" ] && return
    step "Quitting Minecraft"
    kill -TERM $pid
    for _ in $(seq 1 10); do kill -0 $pid 2>/dev/null || return 0; sleep 1; done
    kill -KILL $pid
}

check_host() {
    [ "$(uname -m)" = arm64 ] || die "needs an Apple Silicon Mac"
    xcrun --find clang >/dev/null 2>&1 || die "install Xcode Command Line Tools: xcode-select --install"
    [ -d "$PLAYCOVER" ] || die "PlayCover not found in /Applications (see README)"
    local build
    build=$(defaults read "$PLAYCOVER/Contents/Info" CFBundleVersion 2>/dev/null || echo 0)
    if [ "$build" -lt 1620 ]; then
        echo "warning: PlayCover build $build is older than the nightly this was tested with (1620)." >&2
        echo "         Older builds crash on launch; see README." >&2
    fi
}

install_ipa() {
    local ipa="$1" tmp
    [ -f "$ipa" ] || die "no such file: $ipa"
    tmp=$(mktemp -d)
    unzip -q -o "$ipa" 'Payload/*.app/minecraftpe' -d "$tmp"
    if otool -l "$tmp"/Payload/*.app/minecraftpe | grep -q 'cryptid 1'; then
        rm -rf "$tmp"
        die "this IPA is still FairPlay-encrypted; PlayCover needs a decrypted one"
    fi
    rm -rf "$tmp"

    quit_game
    local before=0
    [ -d "$APP_DIR" ] && before=$(stat -f %m "$APP_DIR")
    step "Installing into PlayCover"
    open -a PlayCover "$ipa"
    for _ in $(seq 1 180); do
        if [ -f "$APP_DIR/minecraftpe" ] && [ "$(stat -f %m "$APP_DIR")" -gt "$before" ] && [ -f "$SETTINGS" ]; then
            sleep 5  # let PlayCover finish signing
            break
        fi
        sleep 1
    done
    [ -f "$APP_DIR/minecraftpe" ] || die "PlayCover did not finish installing"

    # A keychain database left by an older PlayTools makes the game abort on launch.
    local chain="$CONTAINER/PlayChain"
    if ls "$chain/$BUNDLE_ID".* >/dev/null 2>&1; then
        local backup="$chain/backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$backup"
        mv "$chain/$BUNDLE_ID".* "$backup/"
        step "Moved old PlayChain database to $backup"
    fi
}

configure() {
    [ -f "$SETTINGS" ] || die "PlayCover settings not found; install the IPA first"
    step "Applying PlayCover settings"
    # Keymapping's fake mouse crashes the game; it has native mouse/keyboard support.
    plutil -replace keymapping -bool false "$SETTINGS"
    # Clicks stop registering unless the window height is exactly 1080.
    plutil -replace resolution -integer 2 "$SETTINGS"
    plutil -replace aspectRatio -integer 2 "$SETTINGS"
    plutil -replace windowWidth -integer 1728 "$SETTINGS"
    plutil -replace windowHeight -integer 1080 "$SETTINGS"
}

patch_app() {
    [ -f "$APP_DIR/minecraftpe" ] || die "Minecraft is not installed in PlayCover"
    quit_game

    step "Building libmacfix.dylib"
    mkdir -p "$BUILD"
    xcrun clang -target arm64-apple-ios15.0-macabi \
        -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
        -dynamiclib -fobjc-arc -framework Foundation \
        -install_name @executable_path/Frameworks/libmacfix.dylib \
        -o "$BUILD/libmacfix.dylib" "$ROOT/macfix/macfix.m"
    codesign -f -s - "$BUILD/libmacfix.dylib"

    step "Patching the app"
    local ent="$BUILD/entitlements.plist"
    codesign -d --entitlements - --xml "$APP_DIR" > "$ent" 2>/dev/null
    cp "$BUILD/libmacfix.dylib" "$APP_DIR/Frameworks/libmacfix.dylib"
    python3 "$ROOT/scripts/patch_app.py" "$APP_DIR/minecraftpe"
    # Marks the app as a game so fullscreen gets macOS Game Mode.
    plutil -replace LSApplicationCategoryType -string public.app-category.games "$APP_DIR/Info.plist"
    plutil -replace GCSupportsGameMode -bool true "$APP_DIR/Info.plist"
    codesign -f -s - --entitlements "$ent" "$APP_DIR"
    codesign -v "$APP_DIR"
}

main() {
    check_host
    case "${1:-}" in
        --patch-only) ;;
        ""|-h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) install_ipa "$1"; configure ;;
    esac
    patch_app
    step "Done. Launch Minecraft from PlayCover."
}

main "$@"
