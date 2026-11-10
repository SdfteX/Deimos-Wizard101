#!/bin/bash
# Builds Deimos.app so Deimos can be started from the Dock or Applications with no Terminal window.
# Run once from the Deimos folder (the one that contains clickMe.command, tools/ and repos/):
#     bash make_app.sh            (uses icon.png in this folder if present)
#     bash make_app.sh /path/to/picture.png
# Re-run it if you ever move the Deimos folder.
set -e

HOME_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_SRC="${1:-$HOME_DIR/icon.png}"

if [ ! -d "$HOME_DIR/repos/Deimos-Wizard101" ] || [ ! -d "$HOME_DIR/tools" ]; then
    echo "Run this from the Deimos folder (needs tools/ and repos/Deimos-Wizard101)."
    exit 1
fi

# macOS blocks apps from running scripts in Documents, Desktop, Downloads and iCloud Drive.
# If we are in one of those, copy the whole folder to ~/Deimos-mac and continue from there.
case "$HOME_DIR" in
    "$HOME/Documents"*|"$HOME/Desktop"*|"$HOME/Downloads"*|"$HOME/Library/Mobile Documents"*)
        TARGET="$HOME/Deimos-mac"
        if [ -e "$TARGET" ]; then
            echo "$TARGET already exists, so nothing was copied."
            echo "Delete or rename it, then run this again. Or run: bash \"$TARGET/make_app.sh\" to rebuild the app from it."
            exit 1
        fi
        echo "This folder is in a location macOS protects, so the app would be blocked from running Deimos."
        echo "Copying it to $TARGET ..."
        mkdir -p "$TARGET"
        if ! cp -R "$HOME_DIR/." "$TARGET/"; then
            rm -rf "$TARGET"
            echo "Copy failed, nothing was changed. Try moving the folder to $TARGET yourself, then run make_app.sh from there."
            exit 1
        fi
        rm -rf "$TARGET/.git"
        echo "Copied. The original folder is left untouched, you can delete it once the app works."
        exec bash "$TARGET/make_app.sh" "$@"
        ;;
esac

# downloaded files carry a quarantine flag and may lose their executable bit, fix both
xattr -dr com.apple.quarantine "$HOME_DIR" 2>/dev/null || true
find "$HOME_DIR/tools" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

DEST_DIR="/Applications"
[ -w "$DEST_DIR" ] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
APP="$DEST_DIR/Deimos.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
printf '%s' "$HOME_DIR" > "$APP/Contents/Resources/deimos_home"

# icon (optional)
ICON_XML=""
if [ -f "$ICON_SRC" ]; then
    SET="$(mktemp -d)/Deimos.iconset"
    mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICON_SRC" --out "$SET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$ICON_SRC" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$APP/Contents/Resources/Deimos.icns"
    ICON_XML='<key>CFBundleIconFile</key><string>Deimos</string>'
else
    echo "No icon found at $ICON_SRC, the app will have the default icon."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Deimos</string>
    <key>CFBundleDisplayName</key><string>Deimos</string>
    <key>CFBundleIdentifier</key><string>local.deimos.launcher</string>
    <key>CFBundleExecutable</key><string>Deimos</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    $ICON_XML
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/Deimos" <<'LAUNCH'
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HERE="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$(cat "$HERE/../Resources/deimos_home")"
LOG="$HOME/Library/Logs/Deimos.log"

alert() {
    osascript -e "display dialog \"$1\" buttons {\"OK\"} default button 1 with icon caution" >/dev/null 2>&1
}

if [ ! -d "$HOME_DIR/repos/Deimos-Wizard101" ]; then
    alert "Deimos folder not found at $HOME_DIR. Run make_app.sh again from the new location."
    exit 1
fi
cd "$HOME_DIR" || exit 1

KI_WINE="/Applications/Wizard101.app/Contents/SharedSupport/wizard101/bin/wine"
CX_WINE=""
for p in "/Applications/CrossOver.app" "$HOME/Applications/CrossOver.app"; do
    [ -x "$p/Contents/SharedSupport/CrossOver/bin/wine" ] && CX_WINE="$p/Contents/SharedSupport/CrossOver/bin/wine" && break
done

# pick where the game lives, once, and remember it in tools/wine.conf
if [ ! -f tools/wine.conf ]; then
    labels=(); bins=(); bottles=()
    if [ -x "$KI_WINE" ]; then
        labels+=("Wizard101 Mac app"); bins+=("$KI_WINE"); bottles+=("wizard101")
    fi
    if [ -n "$CX_WINE" ]; then
        while IFS= read -r b; do
            labels+=("CrossOver bottle: $b"); bins+=("$CX_WINE"); bottles+=("$b")
        done < <(ls -1 "$HOME/Library/Application Support/CrossOver/Bottles" 2>/dev/null)
    fi

    if [ ${#labels[@]} -eq 0 ]; then
        alert "Couldn't find Wizard101 or CrossOver. Install one of them first."
        exit 1
    fi

    choice=0
    if [ ${#labels[@]} -gt 1 ]; then
        list=""
        for l in "${labels[@]}"; do list+="\"$l\", "; done
        sel="$(osascript -e "choose from list {${list%, }} with prompt \"Where is Wizard101 installed?\" without multiple selections allowed" 2>/dev/null)"
        if [ -z "$sel" ] || [ "$sel" = "false" ]; then exit 0; fi
        choice=-1
        for i in "${!labels[@]}"; do [ "${labels[$i]}" = "$sel" ] && choice=$i; done
        [ "$choice" -lt 0 ] && exit 1
    fi
    printf 'WINE_BIN=%q\nWINE_BOTTLE=%q\n' "${bins[$choice]}" "${bottles[$choice]}" > tools/wine.conf
fi

# stage the patched libs on the first run
if [ ! -d tools/deimos-libs ]; then
    osascript -e 'display notification "First run setup, this can take a minute" with title "Deimos"' >/dev/null 2>&1
    if ! bash tools/shim/stage_deimos_libs.sh >> "$LOG" 2>&1; then
        alert "Setup failed. Details are in ~/Library/Logs/Deimos.log"
        exit 1
    fi
fi

cd repos/Deimos-Wizard101 || exit 1
osascript -e 'display notification "Start Wizard101 and log in" with title "Deimos"' >/dev/null 2>&1
# Run in the foreground so the app stays alive as long as Deimos does.
# When launched from the Dock, macOS can kill background children once the launcher exits.
exec ../../tools/run_wine.sh Deimos.py >> "$LOG" 2>&1
LAUNCH

chmod +x "$APP/Contents/MacOS/Deimos"
touch "$APP"

echo "Created $APP"
echo "Drag it from Applications to the Dock. Logs go to ~/Library/Logs/Deimos.log"
