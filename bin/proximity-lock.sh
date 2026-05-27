#!/bin/bash
# proximity-lock.sh — lock the macOS screen when trusted Bluetooth devices
#                     leave range AND the user has been idle for a moment.
#
# Reliability story: instead of running our own classic-BT inquiry (which does
# not see modern iPhones/Watches reliably), we read macOS's already-maintained
# BLE state via `system_profiler SPBluetoothDataType -json`. The macOS Bluetooth
# daemon keeps a live RSSI for paired Apple devices because Continuity needs it;
# we just consume that snapshot.
set -u

# --- Config ---
TRUSTED_MACS=(
    "aa:aa:aa:aa:aa:aa"   # e.g. iPhone
    "bb:bb:bb:bb:bb:bb"   # e.g. Apple Watch
)

# "all_absent" = lock only when NONE of the trusted devices are detected
# "any_absent" = lock as soon as ANY trusted device is missing
PRESENCE_POLICY="all_absent"

POLL_INTERVAL=3           # seconds between snapshots (system_profiler is fast)
MISS_THRESHOLD=2          # consecutive failing snapshots before considering "away"
IDLE_THRESHOLD=5          # require >= this many seconds of HID idle before locking
MIN_RSSI=-75              # RSSI weaker than this is treated as absent
                          # (-75 ≈ same room only; raise toward -85 if too aggressive)
RESPECT_MEDIA_ASSERTION=1 # 1 = skip lock while something prevents display sleep

LOG="$HOME/Library/Logs/proximity-lock.log"
STATUS_DIR="$HOME/Library/Application Support/proximity-lock"
STATUS_FILE="$STATUS_DIR/status.env"
# Plugin-driven runtime overrides (KEY=VALUE per line). Re-read every cycle
# so menu-bar changes take effect without restarting the daemon.
OVERRIDES_FILE="$STATUS_DIR/plugin.env"
# --------------

PMSET="/usr/bin/pmset"
OSASCRIPT="/usr/bin/osascript"
IOREG="/usr/sbin/ioreg"
PRESENCE_HELPER="${PRESENCE_HELPER:-$HOME/bin/proximity-presence.py}"

mkdir -p "$STATUS_DIR" "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $1" >> "$LOG"; }

for bin in "$OSASCRIPT" "$IOREG" "$PMSET"; do
    [ -x "$bin" ] || { log "FATAL: $bin not found or not executable"; exit 1; }
done
[ -x "$PRESENCE_HELPER" ] || { log "FATAL: $PRESENCE_HELPER not found or not executable"; exit 1; }

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

# Read a value from the plugin overrides file. Returns the default if unset
# or file missing. Whitelisted in apply_overrides to avoid drive-by edits.
override_get() {
    local key="$1" default="$2"
    if [ -f "$OVERRIDES_FILE" ]; then
        local v
        v=$(grep -E "^${key}=" "$OVERRIDES_FILE" | tail -1 | cut -d= -f2-)
        [ -n "$v" ] && { printf '%s' "$v"; return; }
    fi
    printf '%s' "$default"
}

# Pull live overrides from plugin.env on every cycle, with whitelisting and
# basic validation. Anything not whitelisted is ignored.
apply_overrides() {
    local v
    v=$(override_get PRESENCE_POLICY "")
    case "$v" in
        all_absent|any_absent) PRESENCE_POLICY="$v" ;;
        "") : ;;
        *) log "ignoring invalid PRESENCE_POLICY override: $v" ;;
    esac
}

# Wraps the python helper. One TSV line per device with a live RSSI:
#   "<mac>\t<rssi>\t<name>"
snapshot() {
    "$PRESENCE_HELPER" "${TRUSTED_MACS[@]}" 2>/dev/null
}

# Per-cycle scan state, parallel to TRUSTED_MACS.
TRUSTED_NAMES=()
DEVICE_PRESENT=()
DEVICE_RSSI=()
DEVICE_LAST_SEEN=()
for _ in "${TRUSTED_MACS[@]}"; do
    TRUSTED_NAMES+=("unknown")
    DEVICE_PRESENT+=(0)
    DEVICE_RSSI+=("")
    DEVICE_LAST_SEEN+=(0)
done

normalize_mac() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '-' ':'
}

scan_and_update_state() {
    local snap addr rssi name i mac matched
    snap="$(snapshot)"

    for i in "${!TRUSTED_MACS[@]}"; do
        mac="$(normalize_mac "${TRUSTED_MACS[i]}")"
        matched=0
        while IFS=$'\t' read -r addr rssi name; do
            [ -z "$addr" ] && continue
            if [ "$addr" = "$mac" ]; then
                # Strip control chars and chars that would break KEY="value" parsing.
                name="$(printf '%s' "$name" | LC_ALL=C tr -d $'\r\n"=')"
                [ -n "$name" ] && TRUSTED_NAMES[i]="$name"
                if [ "$rssi" -ge "$MIN_RSSI" ] 2>/dev/null; then
                    DEVICE_PRESENT[i]=1
                    DEVICE_RSSI[i]="$rssi"
                    DEVICE_LAST_SEEN[i]=$(date +%s)
                else
                    DEVICE_PRESENT[i]=0
                    DEVICE_RSSI[i]="$rssi"
                fi
                matched=1
                break
            fi
        done <<< "$snap"
        if [ "$matched" -eq 0 ]; then
            DEVICE_PRESENT[i]=0
            DEVICE_RSSI[i]=""
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
        echo "MIN_RSSI=$MIN_RSSI"
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

log "proximity-lock started (policy=$PRESENCE_POLICY, devices=${#TRUSTED_MACS[@]}, poll=${POLL_INTERVAL}s, min_rssi=${MIN_RSSI}, idle_gate=${IDLE_THRESHOLD}s)"

while true; do
    apply_overrides
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
