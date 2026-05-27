#!/bin/bash
# install.sh — set up proximity-lock on a fresh macOS install
#
# What it does:
#   1. Preflight: confirms macOS, python3, brew. Bails clean if anything's missing.
#   2. Reads paired Bluetooth devices from system_profiler and shows them in a
#      numbered list so you can pick which ones to treat as "you".
#   3. Copies bin/proximity-lock.sh and bin/proximity-presence.py to ~/bin,
#      replacing the TRUSTED_MACS array with your picks.
#   4. Installs and loads the LaunchAgent (auto-runs at every reboot).
#   5. Installs SwiftBar if missing (brew --cask), drops the plugin into
#      ~/SwiftBar/Plugins, adds SwiftBar to macOS Login Items so the menu
#      bar UI also auto-starts after reboot, and launches it.
#   6. Prints a final checklist (lock-screen setting, log location).
#
# Safe to re-run. If an existing install is detected, you'll be asked first.
set -eu

# ---------------------------------------------------------------- styling
if [ -t 1 ]; then
    BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
    RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
else
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""
fi
ok()    { printf '%s✓%s %s\n'   "$GREEN"  "$RESET" "$1"; }
warn()  { printf '%s!%s %s\n'   "$YELLOW" "$RESET" "$1"; }
fail()  { printf '%s✗%s %s\n'   "$RED"    "$RESET" "$1" >&2; }
step()  { printf '\n%s%s%s\n'   "$BOLD"   "$1"     "$RESET"; }
hint()  { printf '%s  %s%s\n'   "$DIM"    "$1"     "$RESET"; }

# ---------------------------------------------------------------- paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC_DAEMON="$SCRIPT_DIR/bin/proximity-lock.sh"
SRC_HELPER="$SCRIPT_DIR/bin/proximity-presence.py"
SRC_PLIST="$SCRIPT_DIR/LaunchAgents/com.example.proximitylock.plist"
SRC_PLUGIN="$SCRIPT_DIR/plugins/proximity-lock.5s.sh"

DEST_BIN="$HOME/bin"
DEST_DAEMON="$DEST_BIN/proximity-lock.sh"
DEST_HELPER="$DEST_BIN/proximity-presence.py"
DEST_PLIST="$HOME/Library/LaunchAgents/com.example.proximitylock.plist"
DEST_PLUGIN_DIR="$HOME/SwiftBar/Plugins"
DEST_PLUGIN="$DEST_PLUGIN_DIR/proximity-lock.5s.sh"

# ---------------------------------------------------------------- preflight
step "Preflight checks"

if [ "$(uname -s)" != "Darwin" ]; then
    fail "macOS required (uname says $(uname -s))"; exit 1
fi
ok "macOS"

if [ ! -x /usr/bin/python3 ]; then
    fail "/usr/bin/python3 not found"
    hint "Install Xcode Command Line Tools first:  xcode-select --install"
    exit 1
fi
ok "python3 at /usr/bin/python3"

HAVE_BREW=0
if command -v brew >/dev/null 2>&1; then
    HAVE_BREW=1
    ok "Homebrew available ($(brew --prefix))"
else
    warn "Homebrew not found — SwiftBar auto-install will be skipped"
    hint "Get it from https://brew.sh if you want the menu bar UI"
fi

for src in "$SRC_DAEMON" "$SRC_HELPER" "$SRC_PLIST" "$SRC_PLUGIN"; do
    if [ ! -f "$src" ]; then
        fail "missing source file: $src"; exit 1
    fi
done
ok "Repo source files present"

# ---------------------------------------------------------------- existing install detection
EXISTING_PLISTS=()
for p in "$HOME"/Library/LaunchAgents/*proximitylock*.plist; do
    [ -f "$p" ] && EXISTING_PLISTS+=("$p")
done

if [ -f "$DEST_DAEMON" ] || [ "${#EXISTING_PLISTS[@]}" -gt 0 ]; then
    step "Existing install detected"
    [ -f "$DEST_DAEMON" ] && hint "$DEST_DAEMON"
    for p in "${EXISTING_PLISTS[@]}"; do hint "$p"; done
    printf 'Reinstall (will replace daemon and unload old LaunchAgents)? [y/N] '
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ok "Proceeding with reinstall" ;;
        *) warn "Aborted by user"; exit 0 ;;
    esac
    # Unload and remove every old LaunchAgent variant so we don't end up
    # with two daemons racing each other.
    for p in "${EXISTING_PLISTS[@]}"; do
        label=$(basename "$p" .plist)
        if launchctl list 2>/dev/null | grep -q "$label"; then
            launchctl unload "$p" 2>/dev/null || true
            ok "unloaded $label"
        fi
        if [ "$p" != "$DEST_PLIST" ]; then
            rm -f "$p"
            ok "removed old plist $p"
        fi
    done
fi

# ---------------------------------------------------------------- discovery
step "Discovering paired Bluetooth devices"
hint "Devices with a current RSSI are actively in range right now."

# Capture devices JSON to a temp file so the python heredoc below can read
# the JSON via argv (pipe + heredoc together is ambiguous in bash).
DEVICES_JSON=$(mktemp)
TMP_DAEMON=$(mktemp)
cleanup() { rm -f "$DEVICES_JSON" "$TMP_DAEMON"; }
trap cleanup EXIT

/usr/sbin/system_profiler SPBluetoothDataType -json > "$DEVICES_JSON" 2>/dev/null

CANDIDATES=()
while IFS= read -r line; do
    CANDIDATES+=("$line")
done < <(/usr/bin/python3 - "$DEVICES_JSON" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    text = f.read()
data = json.loads(text) if text.strip() else {}
rows = []
for entry in data.get("SPBluetoothDataType", []):
    for bucket in ("device_connected", "device_not_connected"):
        for dev in entry.get(bucket, []):
            for name, info in dev.items():
                addr = info.get("device_address", "")
                rssi = info.get("device_rssi", "")
                if not addr:
                    continue
                rows.append((addr.lower(), name, str(rssi)))
# Devices with a current RSSI go first (more likely to be "on you").
rows.sort(key=lambda r: (not r[2], r[1].lower()))
for addr, name, rssi in rows:
    print(f"{addr}|{name}|{rssi}")
PY
)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
    fail "No paired Bluetooth devices found"
    hint "Pair your iPhone / Watch / AirPods to this Mac first, then re-run."
    exit 1
fi

printf '\n  %s#  %-17s  %-7s  %s\n' "$BOLD" "ADDRESS" "RSSI" "NAME$RESET"
i=0
for row in "${CANDIDATES[@]}"; do
    i=$((i + 1))
    addr=$(printf '%s' "$row" | cut -d'|' -f1)
    name=$(printf '%s' "$row" | cut -d'|' -f2)
    rssi=$(printf '%s' "$row" | cut -d'|' -f3)
    rssi_display=${rssi:-—}
    printf '  %2d  %-17s  %-7s  %s\n' "$i" "$addr" "$rssi_display" "$name"
done

printf '\nPick which devices to treat as "you" (space- or comma-separated numbers): '
read -r picks
picks=$(printf '%s' "$picks" | tr ',' ' ')

PICKED_MACS=()
for n in $picks; do
    [[ "$n" =~ ^[0-9]+$ ]] || { fail "Not a number: $n"; exit 1; }
    if [ "$n" -lt 1 ] || [ "$n" -gt "${#CANDIDATES[@]}" ]; then
        fail "Out of range: $n"; exit 1
    fi
    row=${CANDIDATES[$((n - 1))]}
    PICKED_MACS+=("$(printf '%s' "$row" | cut -d'|' -f1)")
done

if [ "${#PICKED_MACS[@]}" -eq 0 ]; then
    fail "No devices picked"; exit 1
fi
ok "Trusting ${#PICKED_MACS[@]} device(s):"
for mac in "${PICKED_MACS[@]}"; do hint "$mac"; done

# ---------------------------------------------------------------- install files
step "Installing daemon files"
mkdir -p "$DEST_BIN"
install -m 0755 "$SRC_HELPER" "$DEST_HELPER"
ok "wrote $DEST_HELPER"

# Build the new TRUSTED_MACS block, then replace the placeholder block.
NEW_BLOCK="TRUSTED_MACS=("
for mac in "${PICKED_MACS[@]}"; do
    NEW_BLOCK+=$'\n'"    \"$mac\""
done
NEW_BLOCK+=$'\n'")"

/usr/bin/python3 - "$SRC_DAEMON" "$TMP_DAEMON" "$NEW_BLOCK" <<'PY'
import re, sys
src, dst, new_block = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f: text = f.read()
# Replace the first TRUSTED_MACS=(...) block. The regex is multi-line, non-greedy.
pattern = re.compile(r'TRUSTED_MACS=\(.*?\)', re.DOTALL)
new_text, n = pattern.subn(new_block, text, count=1)
if n != 1:
    sys.exit("could not find TRUSTED_MACS=(...) block in source script")
with open(dst, 'w') as f: f.write(new_text)
PY

install -m 0755 "$TMP_DAEMON" "$DEST_DAEMON"
ok "wrote $DEST_DAEMON (with your MACs)"

# ---------------------------------------------------------------- LaunchAgent
step "Installing LaunchAgent"
mkdir -p "$(dirname "$DEST_PLIST")"
launchctl unload "$DEST_PLIST" 2>/dev/null || true
install -m 0644 "$SRC_PLIST" "$DEST_PLIST"
launchctl load -w "$DEST_PLIST"
sleep 1
if launchctl list | grep -q com.example.proximitylock; then
    ok "LaunchAgent loaded — daemon is running"
else
    warn "LaunchAgent did not show in launchctl list (check $DEST_PLIST)"
fi

# ---------------------------------------------------------------- SwiftBar
step "Setting up SwiftBar (menu bar UI)"

SWIFTBAR_APP="/Applications/SwiftBar.app"
if [ ! -d "$SWIFTBAR_APP" ]; then
    if [ "$HAVE_BREW" -eq 1 ]; then
        hint "Installing SwiftBar via Homebrew…"
        brew install --cask swiftbar
    else
        warn "Skipping SwiftBar — install Homebrew first, then re-run."
    fi
fi

if [ -d "$SWIFTBAR_APP" ]; then
    mkdir -p "$DEST_PLUGIN_DIR"
    ln -sf "$SRC_PLUGIN" "$DEST_PLUGIN"
    defaults write com.ameba.SwiftBar PluginDirectory -string "$DEST_PLUGIN_DIR"
    ok "Plugin symlinked: $DEST_PLUGIN"

    # Add SwiftBar to macOS Login Items so the menu bar UI comes back after
    # reboots. The osascript first checks for an existing entry to avoid
    # duplicates.
    if /usr/bin/osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -qi SwiftBar; then
        ok "SwiftBar already in Login Items"
    elif /usr/bin/osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:true}' >/dev/null 2>&1; then
        ok "Added SwiftBar to Login Items (auto-starts after reboot)"
    else
        warn "Could not add SwiftBar to Login Items — add it manually in System Settings → General → Login Items"
    fi

    if ! pgrep -fq /Applications/SwiftBar.app/Contents/MacOS/SwiftBar; then
        open -a SwiftBar
        ok "Launched SwiftBar"
        hint "If SwiftBar prompts to grant access to the plugin folder, accept it."
    else
        ok "SwiftBar already running — it will pick up the new plugin within 5s"
    fi
fi

# ---------------------------------------------------------------- final notes
step "Done"
ok "Daemon log:   ~/Library/Logs/proximity-lock.log"
ok "Status file:  ~/Library/Application Support/proximity-lock/status.env"
ok "Config:       $DEST_DAEMON"
printf '\n%sOne more thing — set the lock-screen password timing:%s\n' "$BOLD" "$RESET"
hint "System Settings → Lock Screen → Require password → Immediately"
printf '\nWalk away to test. The log will tell you when each gate fires.\n'
