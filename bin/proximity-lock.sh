#!/bin/bash
# proximity-lock.sh — lock the macOS screen when trusted Bluetooth devices
#                     leave range AND the user has been idle for a moment.
#
# Requires: brew install blueutil
set -u

# --- Config ---
# Fill in the BT addresses of your trusted devices (lowercase, hyphen-separated,
# as printed by `blueutil --paired`). Add or remove entries freely.
TRUSTED_MACS=(
    "aa-aa-aa-aa-aa-aa"   # e.g. iPhone
    "bb-bb-bb-bb-bb-bb"   # e.g. Apple Watch
)

# "all_absent" = lock only when NONE of the trusted devices are detected
#                (recommended: avoids locking when you put one on a charger)
# "any_absent" = lock as soon as ANY trusted device is missing
PRESENCE_POLICY="all_absent"

POLL_INTERVAL=30          # seconds between scan cycles (inquiry itself takes a few s)
INQUIRY_DURATION=4        # active-scan length in seconds (blueutil --inquiry N)
MISS_THRESHOLD=2          # consecutive failing scans before locking
IDLE_THRESHOLD=30         # require >= this many seconds of HID idle before locking
RESPECT_MEDIA_ASSERTION=1 # 1 = skip lock while something prevents display sleep

LOG="$HOME/Library/Logs/proximity-lock.log"
# --------------

BLUEUTIL="$(command -v blueutil)"
PMSET="/usr/bin/pmset"
OSASCRIPT="/usr/bin/osascript"
IOREG="/usr/sbin/ioreg"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG"; }

if [ -z "$BLUEUTIL" ]; then
    log "FATAL: blueutil not found in PATH — install with: brew install blueutil"
    exit 1
fi

lock_screen() {
    "$OSASCRIPT" -e 'tell application "System Events" to keystroke "q" using {control down, command down}'
}

# Seconds since last keyboard/mouse/trackpad activity.
hid_idle_seconds() {
    "$IOREG" -c IOHIDSystem 2>/dev/null \
        | awk '/HIDIdleTime/ { print int($NF/1000000000); exit }'
}

media_assertion_active() {
    [ "$RESPECT_MEDIA_ASSERTION" -eq 1 ] || return 1
    "$PMSET" -g assertions | grep -Eq '^[[:space:]]+PreventUserIdleDisplaySleep[[:space:]]+1'
}

# Returns 0 (true) if, by policy, the user should be considered "away".
trusted_absent() {
    local scan present_count=0 mac
    scan="$("$BLUEUTIL" --inquiry "$INQUIRY_DURATION" 2>/dev/null \
            | tr '[:upper:]' '[:lower:]')"

    for mac in "${TRUSTED_MACS[@]}"; do
        mac="$(printf '%s' "$mac" | tr '[:upper:]' '[:lower:]')"
        if printf '%s' "$scan" | grep -q "$mac"; then
            present_count=$((present_count + 1))
        fi
    done

    case "$PRESENCE_POLICY" in
        all_absent)
            [ "$present_count" -eq 0 ]
            ;;
        any_absent)
            [ "$present_count" -lt "${#TRUSTED_MACS[@]}" ]
            ;;
        *)
            log "FATAL: unknown PRESENCE_POLICY=$PRESENCE_POLICY"
            exit 2
            ;;
    esac
}

misses=0
locked=0

log "proximity-lock started (policy=$PRESENCE_POLICY, devices=${#TRUSTED_MACS[@]}, poll=${POLL_INTERVAL}s, idle_gate=${IDLE_THRESHOLD}s)"

while true; do
    if trusted_absent; then
        misses=$((misses + 1))

        if [ "$misses" -ge "$MISS_THRESHOLD" ] && [ "$locked" -eq 0 ]; then
            idle="$(hid_idle_seconds)"
            idle="${idle:-0}"

            if media_assertion_active; then
                log "trusted devices absent ($misses) but media assertion active — skipping"
            elif [ "$idle" -lt "$IDLE_THRESHOLD" ]; then
                log "trusted devices absent ($misses) but user active (idle=${idle}s < ${IDLE_THRESHOLD}s) — skipping"
            else
                log "trusted devices absent ($misses), idle=${idle}s — locking"
                lock_screen
                locked=1
            fi
        fi
    else
        if [ "$misses" -ne 0 ] || [ "$locked" -ne 0 ]; then
            log "trusted device(s) back in range — resetting"
        fi
        misses=0
        locked=0
    fi

    sleep "$POLL_INTERVAL"
done
