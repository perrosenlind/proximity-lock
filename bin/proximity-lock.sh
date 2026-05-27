#!/bin/bash
# proximity-lock.sh — lock the macOS screen when trusted Bluetooth devices
#                     leave range AND the user has been idle for a moment.
#
# Requires: brew install blueutil
#
# Writes a status snapshot to:
#   ~/Library/Application Support/proximity-lock/status.env
# which the optional SwiftBar/xbar plugin (plugins/proximity-lock.10s.sh)
# reads to render menu bar status and per-device stats.
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
STATUS_DIR="$HOME/Library/Application Support/proximity-lock"
STATUS_FILE="$STATUS_DIR/status.env"
# --------------

BLUEUTIL="$(command -v blueutil)"
PMSET="/usr/bin/pmset"
OSASCRIPT="/usr/bin/osascript"
IOREG="/usr/sbin/ioreg"

mkdir -p "$STATUS_DIR" "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG"; }

if [ -z "$BLUEUTIL" ]; then
    log "FATAL: blueutil not found in PATH — install with: brew install blueutil"
    exit 1
fi

lock_screen() {
    "$OSASCRIPT" -e 'tell application "System Events" to keystroke "q" using {control down, command down}'
}

hid_idle_seconds() {
    "$IOREG" -c IOHIDSystem 2>/dev/null \
        | awk '/HIDIdleTime/ { print int($NF/1000000000); exit }'
}

media_assertion_active() {
    [ "$RESPECT_MEDIA_ASSERTION" -eq 1 ] || return 1
    "$PMSET" -g assertions | grep -Eq '^[[:space:]]+PreventUserIdleDisplaySleep[[:space:]]+1'
}

# Look up a device's friendly name from `blueutil --paired`.
device_name() {
    local mac="$1" name
    name="$("$BLUEUTIL" --paired 2>/dev/null \
            | grep -i "address: $mac" \
            | sed -n 's/.*name: "\([^"]*\)".*/\1/p' \
            | head -1)"
    printf '%s' "$name" | tr -d '\r\n' | tr '"=`$\\' '_____'
}

# Pre-compute device names (rarely change).
TRUSTED_NAMES=()
for mac in "${TRUSTED_MACS[@]}"; do
    n="$(device_name "$mac")"
    TRUSTED_NAMES+=("${n:-unknown}")
done

# Per-cycle scan state, parallel to TRUSTED_MACS.
DEVICE_PRESENT=()
DEVICE_RSSI=()
DEVICE_LAST_SEEN=()
for _ in "${TRUSTED_MACS[@]}"; do
    DEVICE_PRESENT+=(0)
    DEVICE_RSSI+=("")
    DEVICE_LAST_SEEN+=(0)
done

scan_and_update_state() {
    local scan i mac rssi line
    scan="$("$BLUEUTIL" --inquiry "$INQUIRY_DURATION" 2>/dev/null \
            | tr '[:upper:]' '[:lower:]')"

    for i in "${!TRUSTED_MACS[@]}"; do
        mac="$(printf '%s' "${TRUSTED_MACS[$i]}" | tr '[:upper:]' '[:lower:]')"
        line="$(printf '%s\n' "$scan" | grep -F "$mac" | head -1)"
        if [ -n "$line" ]; then
            DEVICE_PRESENT[$i]=1
            DEVICE_LAST_SEEN[$i]=$(date +%s)
            rssi="$(printf '%s' "$line" | grep -oE 'rssi: *-?[0-9]+' | head -1 | awk '{print $NF}')"
            DEVICE_RSSI[$i]="${rssi:-}"
        else
            DEVICE_PRESENT[$i]=0
        fi
    done
}

absent_by_policy() {
    local present=0 i
    for i in "${!TRUSTED_MACS[@]}"; do
        [ "${DEVICE_PRESENT[$i]}" -eq 1 ] && present=$((present + 1))
    done
    case "$PRESENCE_POLICY" in
        all_absent) [ "$present" -eq 0 ] ;;
        any_absent) [ "$present" -lt "${#TRUSTED_MACS[@]}" ] ;;
        *) log "FATAL: unknown PRESENCE_POLICY=$PRESENCE_POLICY"; exit 2 ;;
    esac
}

write_status() {
    local idle="$1" locked_state="$2" misses_now="$3" tmp i
    tmp="$(mktemp "${STATUS_FILE}.XXXXXX")"
    {
        echo "# proximity-lock status — regenerated each cycle"
        echo "TIMESTAMP=$(date +%s)"
        echo "TIMESTAMP_HUMAN=\"$(date '+%Y-%m-%d %H:%M:%S')\""
        echo "POLICY=$PRESENCE_POLICY"
        echo "POLL_INTERVAL=$POLL_INTERVAL"
        echo "MISS_THRESHOLD=$MISS_THRESHOLD"
        echo "IDLE_THRESHOLD=$IDLE_THRESHOLD"
        echo "MISSES=$misses_now"
        echo "IDLE_SECONDS=$idle"
        echo "LOCKED=$locked_state"
        echo "DEVICE_COUNT=${#TRUSTED_MACS[@]}"
        for i in "${!TRUSTED_MACS[@]}"; do
            echo "DEVICE_${i}_MAC=${TRUSTED_MACS[$i]}"
            echo "DEVICE_${i}_NAME=\"${TRUSTED_NAMES[$i]}\""
            echo "DEVICE_${i}_PRESENT=${DEVICE_PRESENT[$i]}"
            echo "DEVICE_${i}_RSSI=${DEVICE_RSSI[$i]}"
            echo "DEVICE_${i}_LAST_SEEN=${DEVICE_LAST_SEEN[$i]}"
        done
    } > "$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

misses=0
locked=0

log "proximity-lock started (policy=$PRESENCE_POLICY, devices=${#TRUSTED_MACS[@]}, poll=${POLL_INTERVAL}s, idle_gate=${IDLE_THRESHOLD}s)"

while true; do
    scan_and_update_state
    idle="$(hid_idle_seconds)"; idle="${idle:-0}"

    if absent_by_policy; then
        misses=$((misses + 1))

        if [ "$misses" -ge "$MISS_THRESHOLD" ] && [ "$locked" -eq 0 ]; then
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

    write_status "$idle" "$locked" "$misses"
    sleep "$POLL_INTERVAL"
done
