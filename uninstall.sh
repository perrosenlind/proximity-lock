#!/bin/bash
# uninstall.sh — remove proximity-lock from this Mac.
#
# Removes daemon files, LaunchAgent, log, status snapshot, and the SwiftBar
# plugin symlink. Does NOT uninstall SwiftBar itself (use `brew uninstall
# --cask swiftbar` if you also want that gone).
set -u

if [ -t 1 ]; then
    BOLD=$(tput bold); DIM=$(tput dim); RESET=$(tput sgr0)
    GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""
fi
ok()    { printf '%s✓%s %s\n' "$GREEN"  "$RESET" "$1"; }
warn()  { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
step()  { printf '\n%s%s%s\n' "$BOLD"   "$1"     "$RESET"; }
hint()  { printf '%s  %s%s\n' "$DIM"    "$1"     "$RESET"; }

DAEMON="$HOME/bin/proximity-lock.sh"
HELPER="$HOME/bin/proximity-presence.py"
LOG="$HOME/Library/Logs/proximity-lock.log"
STATUS_DIR="$HOME/Library/Application Support/proximity-lock"
PLUGIN="$HOME/SwiftBar/Plugins/proximity-lock.5s.sh"

# Unload and remove every proximity-lock LaunchAgent regardless of label.
step "Stopping daemon"
FOUND_ANY=0
for p in "$HOME"/Library/LaunchAgents/*proximitylock*.plist; do
    [ -f "$p" ] || continue
    FOUND_ANY=1
    label=$(basename "$p" .plist)
    if launchctl list 2>/dev/null | grep -q "$label"; then
        launchctl unload "$p" 2>/dev/null || true
        ok "unloaded $label"
    fi
    rm -f "$p"
    ok "removed $p"
done
[ "$FOUND_ANY" -eq 0 ] && hint "no LaunchAgent plists found"

step "Removing files"
for f in "$DAEMON" "$HELPER" "$LOG" "$PLUGIN"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
        rm -f "$f"
        ok "removed $f"
    fi
done

if [ -d "$STATUS_DIR" ]; then
    rm -rf "$STATUS_DIR"
    ok "removed $STATUS_DIR"
fi

step "Done"
hint "SwiftBar is still installed (brew uninstall --cask swiftbar to remove)."
hint "Your Lock Screen settings were not changed."
