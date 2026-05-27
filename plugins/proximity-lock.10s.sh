#!/bin/bash
# SwiftBar plugin: proximity-lock status (modernized, with icon styles)
#
# <bitbar.title>Proximity Lock</bitbar.title>
# <bitbar.version>1.2</bitbar.version>
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
PLUGIN_CONFIG="$HOME/Library/Application Support/proximity-lock/plugin.env"
LOG="$HOME/Library/Logs/proximity-lock.log"
SCRIPT_USER="$HOME/bin/proximity-lock.sh"

PLIST_USER=""
for candidate in "$HOME"/Library/LaunchAgents/*proximitylock*.plist; do
    [ -f "$candidate" ] && { PLIST_USER="$candidate"; break; }
done

# ---------------------------------------------------------------- config I/O
read_setting() {
    local key="$1" default="$2"
    if [ -f "$PLUGIN_CONFIG" ]; then
        local v
        v=$(grep -E "^${key}=" "$PLUGIN_CONFIG" | tail -1 | cut -d= -f2-)
        [ -n "$v" ] && { printf '%s' "$v"; return; }
    fi
    printf '%s' "$default"
}

write_setting() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$PLUGIN_CONFIG")"
    if [ -f "$PLUGIN_CONFIG" ] && grep -q "^${key}=" "$PLUGIN_CONFIG"; then
        /usr/bin/sed -i '' "s|^${key}=.*|${key}=${val}|" "$PLUGIN_CONFIG"
    else
        echo "${key}=${val}" >> "$PLUGIN_CONFIG"
    fi
}

# CLI dispatch: clicking a settings menu item re-invokes this script with
# `--set KEY VALUE`, which we handle here and exit before rendering.
if [ "${1:-}" = "--set" ] && [ -n "${2:-}" ] && [ -n "${3:-}" ]; then
    write_setting "$2" "$3"
    exit 0
fi

# ---------------------------------------------------------------- icon styles
# Each style maps a state to "<sfimage>|<sfcolor>".
# States: present_all, present_partial, absent_all, stale, locked.
icon_for() {
    local style="$1" state="$2"
    case "$style/$state" in
        radio/present_all)     echo "dot.radiowaves.left.and.right|systemGreen" ;;
        radio/present_partial) echo "dot.radiowaves.left.and.right|systemOrange" ;;
        radio/absent_all)      echo "dot.radiowaves.left.and.right|systemRed" ;;
        radio/stale)           echo "hourglass|systemGray" ;;
        radio/locked)          echo "lock.fill|systemRed" ;;

        lock/present_all)      echo "lock.open.fill|systemGreen" ;;
        lock/present_partial)  echo "lock.open.fill|systemOrange" ;;
        lock/absent_all)       echo "lock.fill|systemRed" ;;
        lock/stale)            echo "lock.slash.fill|systemGray" ;;
        lock/locked)           echo "lock.fill|systemRed" ;;

        person/present_all)     echo "person.fill|systemGreen" ;;
        person/present_partial) echo "person.fill|systemOrange" ;;
        person/absent_all)      echo "person.slash.fill|systemRed" ;;
        person/stale)           echo "person.fill.questionmark|systemGray" ;;
        person/locked)          echo "person.fill.xmark|systemRed" ;;

        shield/present_all)     echo "lock.shield.fill|systemGreen" ;;
        shield/present_partial) echo "lock.shield.fill|systemOrange" ;;
        shield/absent_all)      echo "xmark.shield.fill|systemRed" ;;
        shield/stale)           echo "questionmark.diamond.fill|systemGray" ;;
        shield/locked)          echo "lock.shield.fill|systemRed" ;;

        eye/present_all)     echo "eye.fill|systemGreen" ;;
        eye/present_partial) echo "eye.fill|systemOrange" ;;
        eye/absent_all)      echo "eye.slash.fill|systemRed" ;;
        eye/stale)           echo "eye.trianglebadge.exclamationmark.fill|systemGray" ;;
        eye/locked)          echo "eye.slash.fill|systemRed" ;;

        dot/present_all)     echo "circle.fill|systemGreen" ;;
        dot/present_partial) echo "circle.fill|systemOrange" ;;
        dot/absent_all)      echo "circle.fill|systemRed" ;;
        dot/stale)           echo "circle.dotted|systemGray" ;;
        dot/locked)          echo "lock.fill|systemRed" ;;

        # Fallback to radio if style unknown.
        *) icon_for radio "$state" ;;
    esac
}

# Ordered list of available styles, with display names.
ICON_STYLES=(
    "radio:Radio waves"
    "lock:Lock"
    "person:Person"
    "shield:Shield"
    "eye:Eye"
    "dot:Dot"
)

ICON_STYLE=$(read_setting ICON_STYLE radio)
BAR_DISPLAY=$(read_setting BAR_DISPLAY show)

# ---------------------------------------------------------------- render
now=$(date +%s)
MONO="font=Menlo size=11"
DIM="size=11 color=#8e8e93"
HEADER="size=10 color=#8e8e93"

emit_missing() {
    local pair sym color
    pair=$(icon_for "$ICON_STYLE" stale)
    sym=${pair%%|*}; color=${pair##*|}
    if [ "$BAR_DISPLAY" = "hide" ]; then
        echo "· | size=11 color=#8e8e93"
    else
        echo "proximity | sfimage=$sym sfcolor=$color"
    fi
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
    echo "---"
    emit_bar_visibility_menu "$BAR_DISPLAY"
    emit_icon_style_menu
}

emit_icon_style_menu() {
    echo "---"
    echo "Icon style | sfimage=paintbrush $HEADER"
    local entry id label pair sym color
    for entry in "${ICON_STYLES[@]}"; do
        id=${entry%%:*}; label=${entry##*:}
        pair=$(icon_for "$id" present_all)
        sym=${pair%%|*}; color=${pair##*|}
        if [ "$id" = "$ICON_STYLE" ]; then
            echo "--✓ $label | sfimage=$sym sfcolor=$color bash=$0 param1=--set param2=ICON_STYLE param3=$id terminal=false refresh=true"
        else
            echo "--   $label | sfimage=$sym sfcolor=$color bash=$0 param1=--set param2=ICON_STYLE param3=$id terminal=false refresh=true"
        fi
    done
}

emit_bar_visibility_menu() {
    local current="$1"
    echo "Menu bar | sfimage=menubar.dock.rectangle $HEADER"
    if [ "$current" = "show" ]; then
        echo "--✓ Show icon | sfimage=eye.fill sfcolor=systemBlue bash=$0 param1=--set param2=BAR_DISPLAY param3=show terminal=false refresh=true"
        echo "--   Hide (tiny dot remains, clickable) | sfimage=eye.slash bash=$0 param1=--set param2=BAR_DISPLAY param3=hide terminal=false refresh=true"
    else
        echo "--   Show icon | sfimage=eye.fill bash=$0 param1=--set param2=BAR_DISPLAY param3=show terminal=false refresh=true"
        echo "--✓ Hide (tiny dot remains, clickable) | sfimage=eye.slash sfcolor=systemBlue bash=$0 param1=--set param2=BAR_DISPLAY param3=hide terminal=false refresh=true"
    fi
}

emit_policy_menu() {
    local current="$1"
    echo "Lock policy | sfimage=slider.horizontal.3 $HEADER"
    if [ "$current" = "all_absent" ]; then
        echo "--✓ Lock only when ALL trusted devices leave | sfimage=person.2.fill sfcolor=systemBlue bash=$0 param1=--set param2=PRESENCE_POLICY param3=all_absent terminal=false refresh=true"
    else
        echo "--   Lock only when ALL trusted devices leave | sfimage=person.2.fill bash=$0 param1=--set param2=PRESENCE_POLICY param3=all_absent terminal=false refresh=true"
    fi
    if [ "$current" = "any_absent" ]; then
        echo "--✓ Lock as soon as ANY trusted device leaves | sfimage=person.fill.xmark sfcolor=systemBlue bash=$0 param1=--set param2=PRESENCE_POLICY param3=any_absent terminal=false refresh=true"
    else
        echo "--   Lock as soon as ANY trusted device leaves | sfimage=person.fill.xmark bash=$0 param1=--set param2=PRESENCE_POLICY param3=any_absent terminal=false refresh=true"
    fi
    echo "--Changes apply within ${POLL_INTERVAL:-10}s | $DIM"
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

# Resolve state name for icon lookup.
if [ "$stale" = "1" ]; then
    bar_state="stale"
elif [ "${LOCKED:-0}" = "1" ]; then
    bar_state="locked"
elif [ "$present" -eq "$DEVICE_COUNT" ]; then
    bar_state="present_all"
elif [ "$present" -gt 0 ]; then
    bar_state="present_partial"
else
    bar_state="absent_all"
fi

bar_pair=$(icon_for "$ICON_STYLE" "$bar_state")
bar_icon=${bar_pair%%|*}
bar_color=${bar_pair##*|}

if [ "$BAR_DISPLAY" = "hide" ]; then
    # Tiny dim dot — keeps the dropdown reachable so the user can re-enable.
    echo "· | size=11 color=#8e8e93"
else
    echo "${present}/${DEVICE_COUNT} | sfimage=$bar_icon sfcolor=$bar_color"
fi
echo "---"

# Daemon state line (uses its own state-specific icons, independent of style).
if [ "${LOCKED:-0}" = "1" ]; then
    state_icon="lock.fill"; state_text="Locked — waiting for device return"; state_color="systemRed"
elif [ "${MISSES:-0}" -ge "${MISS_THRESHOLD:-3}" ]; then
    state_icon="exclamationmark.circle.fill"; state_text="Armed — locking when idle reaches ${IDLE_THRESHOLD}s"; state_color="systemOrange"
elif [ "${MISSES:-0}" -gt 0 ]; then
    state_icon="hourglass"; state_text="Missed ${MISSES}/${MISS_THRESHOLD} scans"; state_color="systemYellow"
else
    state_icon="checkmark.circle.fill"; state_text="Watching"; state_color="systemGreen"
fi

echo "$state_text | sfimage=$state_icon sfcolor=$state_color"
echo "Policy: $POLICY  ·  Idle: ${IDLE_SECONDS}s  ·  Poll: ${POLL_INTERVAL}s | $DIM"
if [ "$stale" = "1" ]; then
    echo "Status stale: ${age}s old | size=11 color=systemOrange"
else
    echo "Updated ${age}s ago  ·  $TIMESTAMP_HUMAN | $DIM"
fi

echo "---"
echo "DEVICES | $HEADER"

device_icon() {
    local name_lower
    name_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$name_lower" in
        *iphone*)              echo "iphone" ;;
        *ipad*)                echo "ipad" ;;
        *watch*)               echo "applewatch" ;;
        *airpods*max*)         echo "airpods.max" ;;
        *airpods*pro*)         echo "airpods.pro" ;;
        *airpods*)             echo "airpods" ;;
        *macbook*)             echo "laptopcomputer" ;;
        *mac*mini*)            echo "macmini" ;;
        *imac*)                echo "desktopcomputer" ;;
        *keyboard*)            echo "keyboard" ;;
        *mouse*|*mx*)          echo "computermouse" ;;
        *headphone*|*headset*) echo "headphones" ;;
        *)                     echo "dot.circle" ;;
    esac
}

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
    icon=$(device_icon "$name")

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
# Reflect the user's pending selection immediately, even if the daemon hasn't
# rolled to its next cycle yet.
POLICY_EFFECTIVE=$(read_setting PRESENCE_POLICY "$POLICY")
emit_policy_menu "$POLICY_EFFECTIVE"
emit_bar_visibility_menu "$BAR_DISPLAY"
emit_icon_style_menu

echo "---"
if [ -n "$PLIST_USER" ]; then
    echo "Restart daemon | sfimage=arrow.clockwise.circle bash=/bin/bash param1=-c param2=\"launchctl unload '$PLIST_USER' 2>/dev/null; launchctl load -w '$PLIST_USER'\" terminal=false refresh=true"
fi
echo "Refresh | sfimage=arrow.clockwise refresh=true"
