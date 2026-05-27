#!/bin/bash
# SwiftBar / xbar plugin for proximity-lock
#
# <bitbar.title>Proximity Lock</bitbar.title>
# <bitbar.version>1.0</bitbar.version>
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

# Find an installed LaunchAgent plist for the daemon (any reverse-domain prefix).
# Empty string if not installed yet.
PLIST_USER=""
for candidate in "$HOME"/Library/LaunchAgents/*proximitylock*.plist; do
    if [ -f "$candidate" ]; then
        PLIST_USER="$candidate"
        break
    fi
done

now=$(date +%s)
FONT="font=Menlo size=12"

emit_missing() {
    echo "⚠︎ proximity"
    echo "---"
    echo "proximity-lock daemon is not running"
    echo "Status file missing:"
    echo "$STATUS | $FONT color=#888888"
    echo "---"
    if [ -n "$PLIST_USER" ]; then
        echo "Start daemon (launchctl load) | bash=/bin/launchctl param1=load param2=-w param3=$PLIST_USER terminal=false refresh=true"
    else
        echo "No LaunchAgent plist found in ~/Library/LaunchAgents/ | $FONT color=#888888"
    fi
    echo "Run in foreground (terminal) | bash=$SCRIPT_USER terminal=true"
    echo "Edit config… | bash=/usr/bin/open param1=-t param2=$SCRIPT_USER terminal=false"
}

if [ ! -f "$STATUS" ]; then
    emit_missing
    exit 0
fi

# Safe key reader: grep + cut, no sourcing.
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

# Stale check: status > 3x poll interval old means daemon likely stuck/dead.
age=$(( now - ${TIMESTAMP:-0} ))
stale_threshold=$(( ${POLL_INTERVAL:-30} * 3 ))
stale=0
[ "$age" -gt "$stale_threshold" ] && stale=1

# Count present devices.
present=0
for i in $(seq 0 $((DEVICE_COUNT - 1))); do
    p=$(get "DEVICE_${i}_PRESENT")
    [ "${p:-0}" = "1" ] && present=$((present + 1))
done

# Pick menu bar icon based on presence (and stale state overrides).
if [ "$stale" = "1" ]; then
    bar="⌛ ${present}/${DEVICE_COUNT}"
elif [ "$present" -eq "$DEVICE_COUNT" ]; then
    bar="🟢 ${present}/${DEVICE_COUNT}"
elif [ "$present" -gt 0 ]; then
    bar="🟡 ${present}/${DEVICE_COUNT}"
else
    bar="🔴 ${present}/${DEVICE_COUNT}"
fi

echo "$bar"
echo "---"

# Header line summarizing daemon state.
state_line="state: "
if [ "${LOCKED:-0}" = "1" ]; then
    state_line+="locked (waiting for device return)"
elif [ "${MISSES:-0}" -ge "${MISS_THRESHOLD:-2}" ]; then
    state_line+="armed — would lock if idle reaches ${IDLE_THRESHOLD}s"
elif [ "${MISSES:-0}" -gt 0 ]; then
    state_line+="missed ${MISSES}/${MISS_THRESHOLD} scans"
else
    state_line+="watching"
fi
echo "$state_line | $FONT"

echo "policy: $POLICY · idle: ${IDLE_SECONDS}s · poll: ${POLL_INTERVAL}s | $FONT color=#888888"
if [ "$stale" = "1" ]; then
    echo "⚠︎ status stale: ${age}s old (last update $TIMESTAMP_HUMAN) | $FONT color=#cc6600"
else
    echo "updated ${age}s ago ($TIMESTAMP_HUMAN) | $FONT color=#888888"
fi

echo "---"
echo "Devices | $FONT color=#888888"

# RSSI → human-friendly bars.
rssi_bars() {
    local r="$1"
    [ -z "$r" ] && { echo "—"; return; }
    if   [ "$r" -ge -55 ]; then echo "▰▰▰▰▰"
    elif [ "$r" -ge -65 ]; then echo "▰▰▰▰▱"
    elif [ "$r" -ge -75 ]; then echo "▰▰▰▱▱"
    elif [ "$r" -ge -85 ]; then echo "▰▰▱▱▱"
    else echo "▰▱▱▱▱"; fi
}

human_age() {
    local secs="$1"
    [ -z "$secs" ] || [ "$secs" -eq 0 ] && { echo "never"; return; }
    local a=$(( now - secs ))
    if   [ "$a" -lt 60 ];    then echo "${a}s ago"
    elif [ "$a" -lt 3600 ];  then echo "$(( a / 60 ))m ago"
    elif [ "$a" -lt 86400 ]; then echo "$(( a / 3600 ))h ago"
    else echo "$(( a / 86400 ))d ago"; fi
}

for i in $(seq 0 $((DEVICE_COUNT - 1))); do
    mac=$(get "DEVICE_${i}_MAC")
    name=$(get "DEVICE_${i}_NAME")
    p=$(get "DEVICE_${i}_PRESENT")
    rssi=$(get "DEVICE_${i}_RSSI")
    seen=$(get "DEVICE_${i}_LAST_SEEN")

    if [ "${p:-0}" = "1" ]; then
        dot="●"; color="#2ea043"
        meta="$(rssi_bars "$rssi")  ${rssi:-?} dBm"
    else
        dot="○"; color="#888888"
        meta="last seen $(human_age "$seen")"
    fi

    label="${dot} ${name:-unknown}"
    echo "${label} | $FONT color=${color}"
    echo "--${meta} | $FONT color=#888888"
    echo "--${mac} | $FONT color=#888888"
    echo "--Copy MAC | bash=/bin/bash param1=-c param2=\"printf %s '$mac' | /usr/bin/pbcopy\" terminal=false"
done

echo "---"
echo "Open log | bash=/usr/bin/open param1=-t param2=$LOG terminal=false"
echo "Tail log (terminal) | bash=/usr/bin/tail param1=-f param2=$LOG terminal=true"
echo "Edit config… | bash=/usr/bin/open param1=-t param2=$SCRIPT_USER terminal=false"
echo "---"
if [ -n "$PLIST_USER" ]; then
    echo "Restart daemon | bash=/bin/bash param1=-c param2=\"launchctl unload '$PLIST_USER' 2>/dev/null; launchctl load -w '$PLIST_USER'\" terminal=false refresh=true"
fi
echo "Refresh | refresh=true"
