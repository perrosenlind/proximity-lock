#!/bin/bash
# SwiftBar plugin: proximity-lock status (modernized)
#
# <bitbar.title>Proximity Lock</bitbar.title>
# <bitbar.version>1.1</bitbar.version>
# <bitbar.author>proximity-lock</bitbar.author>
# <bitbar.author.github>perrosenlind</bitbar.author.github>
# <bitbar.desc>Shows tracked Bluetooth devices and proximity-lock daemon state.</bitbar.desc>
# <bitbar.dependencies>bash, proximity-lock daemon</bitbar.dependencies>
#
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
set -u

STATUS="$HOME/Library/Application Support/proximity-lock/status.env"
LOG="$HOME/Library/Logs/proximity-lock.log"
SCRIPT_USER="$HOME/bin/proximity-lock.sh"

# Find any installed LaunchAgent for the daemon, regardless of label.
PLIST_USER=""
for candidate in "$HOME"/Library/LaunchAgents/*proximitylock*.plist; do
    [ -f "$candidate" ] && { PLIST_USER="$candidate"; break; }
done

now=$(date +%s)
# Use the system font; only fall back to mono for MAC addresses and RSSI.
MONO="font=Menlo size=11"
DIM="size=11 color=#8e8e93"
HEADER="size=10 color=#8e8e93"

emit_missing() {
    echo "proximity | sfimage=exclamationmark.triangle sfcolor=systemOrange"
    echo "---"
    echo "Daemon not running"
    echo "Status file missing | $DIM"
    echo "$STATUS | $MONO color=#8e8e93"
    echo "---"
    if [ -n "$PLIST_USER" ]; then
        echo "Start daemon | sfimage=play.fill bash=/bin/launchctl param1=load param2=-w param3=$PLIST_USER terminal=false refresh=true"
    else
        echo "No LaunchAgent plist found | $DIM"
    fi
    echo "Run in foreground | sfimage=terminal bash=$SCRIPT_USER terminal=true"
    echo "Edit config… | sfimage=square.and.pencil bash=/usr/bin/open param1=-t param2=$SCRIPT_USER terminal=false"
}

if [ ! -f "$STATUS" ]; then
    emit_missing
    exit 0
fi

get() {
    local key="$1"
    grep -E "^${key}=" "$STATUS" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'
}

TIMESTAMP=$(get TIMESTAMP)
TIMESTAMP_HUMAN=$(get TIMESTAMP_HUMAN)
POLICY=$(get POLICY)
POLL_INTERVAL=$(get POLL_INTERVAL)
MISS_THRESHOLD=$(get MISS_THRESHOLD)
IDLE_THRESHOLD=$(get IDLE_THRESHOLD)
MISSES=$(get MISSES)
IDLE_SECONDS=$(get IDLE_SECONDS)
LOCKED=$(get LOCKED)
DEVICE_COUNT=$(get DEVICE_COUNT)

age=$(( now - ${TIMESTAMP:-0} ))
stale_threshold=$(( ${POLL_INTERVAL:-30} * 3 ))
stale=0
[ "$age" -gt "$stale_threshold" ] && stale=1

present=0
for i in $(seq 0 $((DEVICE_COUNT - 1))); do
    p=$(get "DEVICE_${i}_PRESENT")
    [ "${p:-0}" = "1" ] && present=$((present + 1))
done

# ---- Menu bar icon (SF Symbol, adaptive colors) ----
if [ "$stale" = "1" ]; then
    bar_icon="hourglass"
    bar_color="systemGray"
elif [ "${LOCKED:-0}" = "1" ]; then
    bar_icon="lock.fill"
    bar_color="systemRed"
elif [ "$present" -eq "$DEVICE_COUNT" ]; then
    bar_icon="dot.radiowaves.left.and.right"
    bar_color="systemGreen"
elif [ "$present" -gt 0 ]; then
    bar_icon="dot.radiowaves.left.and.right"
    bar_color="systemOrange"
else
    bar_icon="dot.radiowaves.left.and.right"
    bar_color="systemRed"
fi

echo "${present}/${DEVICE_COUNT} | sfimage=$bar_icon sfcolor=$bar_color"
echo "---"

# ---- Status header ----
if [ "${LOCKED:-0}" = "1" ]; then
    state_icon="lock.fill"
    state_text="Locked — waiting for device return"
    state_color="systemRed"
elif [ "${MISSES:-0}" -ge "${MISS_THRESHOLD:-3}" ]; then
    state_icon="exclamationmark.circle.fill"
    state_text="Armed — locking when idle reaches ${IDLE_THRESHOLD}s"
    state_color="systemOrange"
elif [ "${MISSES:-0}" -gt 0 ]; then
    state_icon="hourglass"
    state_text="Missed ${MISSES}/${MISS_THRESHOLD} scans"
    state_color="systemYellow"
else
    state_icon="checkmark.circle.fill"
    state_text="Watching"
    state_color="systemGreen"
fi

echo "$state_text | sfimage=$state_icon sfcolor=$state_color"

# ---- Secondary metadata, dim ----
echo "Policy: $POLICY  ·  Idle: ${IDLE_SECONDS}s  ·  Poll: ${POLL_INTERVAL}s | $DIM"
if [ "$stale" = "1" ]; then
    echo "Status stale: ${age}s old | size=11 color=systemOrange"
else
    echo "Updated ${age}s ago  ·  $TIMESTAMP_HUMAN | $DIM"
fi

echo "---"
echo "DEVICES | $HEADER"

# Pick an SF Symbol based on the device name.
device_icon() {
    local name_lower
    name_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$name_lower" in
        *iphone*)     echo "iphone" ;;
        *ipad*)       echo "ipad" ;;
        *watch*)      echo "applewatch" ;;
        *airpods*max*) echo "airpods.max" ;;
        *airpods*pro*) echo "airpods.pro" ;;
        *airpods*)    echo "airpods" ;;
        *macbook*)    echo "laptopcomputer" ;;
        *mac*mini*)   echo "macmini" ;;
        *imac*)       echo "desktopcomputer" ;;
        *keyboard*)   echo "keyboard" ;;
        *mouse*|*mx*) echo "computermouse" ;;
        *headphone*|*headset*) echo "headphones" ;;
        *)            echo "dot.circle" ;;
    esac
}

# RSSI buckets, expressed both as SF Symbol and human label.
rssi_label() {
    local r="$1"
    [ -z "$r" ] && { echo "no signal"; return; }
    if   [ "$r" -ge -55 ]; then echo "Excellent"
    elif [ "$r" -ge -65 ]; then echo "Good"
    elif [ "$r" -ge -75 ]; then echo "Fair"
    elif [ "$r" -ge -85 ]; then echo "Weak"
    else                        echo "Very weak"
    fi
}

human_age() {
    local secs="$1"
    if [ -z "$secs" ] || [ "$secs" -eq 0 ]; then echo "never"; return; fi
    local a=$(( now - secs ))
    if   [ "$a" -lt 60 ];    then echo "${a}s ago"
    elif [ "$a" -lt 3600 ];  then echo "$(( a / 60 ))m ago"
    elif [ "$a" -lt 86400 ]; then echo "$(( a / 3600 ))h ago"
    else                          echo "$(( a / 86400 ))d ago"
    fi
}

for i in $(seq 0 $((DEVICE_COUNT - 1))); do
    mac=$(get "DEVICE_${i}_MAC")
    name=$(get "DEVICE_${i}_NAME")
    p=$(get "DEVICE_${i}_PRESENT")
    rssi=$(get "DEVICE_${i}_RSSI")
    seen=$(get "DEVICE_${i}_LAST_SEEN")
    icon="$(device_icon "$name")"

    if [ "${p:-0}" = "1" ]; then
        echo "${name:-unknown} | sfimage=$icon sfcolor=systemGreen"
        echo "--$(rssi_label "$rssi")  ·  ${rssi} dBm | sfimage=antenna.radiowaves.left.and.right sfcolor=systemGreen size=12"
    else
        echo "${name:-unknown} | sfimage=$icon sfcolor=systemGray"
        if [ -n "$rssi" ]; then
            echo "--Out of range  ·  last RSSI ${rssi} dBm | sfimage=antenna.radiowaves.left.and.right.slash sfcolor=systemGray size=12"
        else
            echo "--Out of range  ·  last seen $(human_age "$seen") | sfimage=antenna.radiowaves.left.and.right.slash sfcolor=systemGray size=12"
        fi
    fi
    echo "--$mac | $MONO color=#8e8e93"
    echo "--Copy MAC address | sfimage=doc.on.doc bash=/bin/bash param1=-c param2=\"printf %s '$mac' | /usr/bin/pbcopy\" terminal=false"
done

echo "---"
echo "LOGS & CONFIG | $HEADER"
echo "Open log | sfimage=doc.text bash=/usr/bin/open param1=-t param2=$LOG terminal=false"
echo "Tail log in Terminal | sfimage=terminal bash=/usr/bin/tail param1=-f param2=$LOG terminal=true"
echo "Edit config… | sfimage=square.and.pencil bash=/usr/bin/open param1=-t param2=$SCRIPT_USER terminal=false"

echo "---"
if [ -n "$PLIST_USER" ]; then
    echo "Restart daemon | sfimage=arrow.clockwise.circle bash=/bin/bash param1=-c param2=\"launchctl unload '$PLIST_USER' 2>/dev/null; launchctl load -w '$PLIST_USER'\" terminal=false refresh=true"
fi
echo "Refresh | sfimage=arrow.clockwise refresh=true"
