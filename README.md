# proximity-lock

Lock your macOS screen automatically when your trusted Bluetooth devices
(iPhone, Apple Watch, AirPods, etc.) leave range — and stay unlocked while
you're actively using the Mac.

Works around two common annoyances with naive proximity-lock scripts:

- **No false locks when you put a watch on the charger.** The default policy
  (`all_absent`) only locks when *every* trusted device is out of range, so
  having any one device nearby keeps the Mac open.
- **No locks while you're typing.** A HID idle-time gate skips locking
  whenever you've touched the keyboard or trackpad recently.
- **No locks during video calls or presentations.** An optional check for
  `PreventUserIdleDisplaySleep` assertions skips locking while another app is
  intentionally keeping the display awake.

## Requirements

- macOS (tested on Apple Silicon, current macOS)
- `python3` — included with Xcode Command Line Tools (`xcode-select --install`)
  or any system Python 3.

No `blueutil` or other Bluetooth library is needed at runtime. The script
relies on macOS's own Bluetooth daemon, which already does continuous BLE
scanning for paired Apple devices to power Continuity. We read its live RSSI
snapshot via `system_profiler SPBluetoothDataType -json`.

## Install

1. Find your trusted devices' Bluetooth addresses. Easiest:

   ```bash
   system_profiler SPBluetoothDataType | grep -E '^(  +)(\S.*:|Address:|RSSI:)' | head -40
   ```

   Look for entries that have an `RSSI` line — those are the devices macOS is
   actively tracking. Note their `Address:` values (format `AA:BB:CC:DD:EE:FF`).

2. Drop the daemon and the presence helper into `~/bin`:

   ```bash
   mkdir -p ~/bin
   cp bin/proximity-lock.sh bin/proximity-presence.py ~/bin/
   chmod +x ~/bin/proximity-lock.sh ~/bin/proximity-presence.py
   ```

3. Edit `~/bin/proximity-lock.sh` and replace the `TRUSTED_MACS` entries
   with your own addresses (colons or hyphens, lowercase, both accepted).

4. Test it in the foreground:

   ```bash
   ~/bin/proximity-lock.sh &
   tail -f ~/Library/Logs/proximity-lock.log
   # Walk away with your phone/watch. Confirm a lock event in the log.
   # kill %1 to stop.
   ```

5. Install the LaunchAgent so it runs at login and stays alive:

   ```bash
   cp LaunchAgents/com.example.proximitylock.plist ~/Library/LaunchAgents/
   launchctl load -w ~/Library/LaunchAgents/com.example.proximitylock.plist
   launchctl list | grep proximitylock
   ```

   Also set **System Settings → Lock Screen → Require password → Immediately**
   so the lock actually requires authentication.

## Configuration

Edit the `--- Config ---` block at the top of `proximity-lock.sh`:

| Variable | Default | What it does |
|----------|---------|--------------|
| `TRUSTED_MACS` | `(aa:aa:…  bb:bb:…)` | List of BT addresses considered "you". |
| `PRESENCE_POLICY` | `all_absent` | `all_absent` locks only when no trusted device is detected. `any_absent` locks if any one is missing. |
| `POLL_INTERVAL` | `10` | Seconds between presence snapshots (snapshots are cheap). |
| `MISS_THRESHOLD` | `3` | Consecutive failing snapshots before considering you "away". |
| `IDLE_THRESHOLD` | `30` | Lock only if there's been at least this many seconds of no keyboard/trackpad input. |
| `MIN_RSSI` | `-85` | RSSI weaker than this is treated as absent. `-85` ≈ next room; raise toward `-60` for "same desk only". |
| `RESPECT_MEDIA_ASSERTION` | `1` | If `1`, skip locking while another app holds a `PreventUserIdleDisplaySleep` assertion. |

Grace period before a lock attempt = `POLL_INTERVAL × MISS_THRESHOLD`. With
defaults that's about 30 s of absence + 30 s of inactivity before the screen
locks.

## How it works

- **Presence**: `bin/proximity-presence.py` runs `system_profiler
  SPBluetoothDataType -json` and reports current RSSI for the MACs you care
  about. macOS's Bluetooth daemon maintains this list in real time for Apple
  devices (iPhone, Apple Watch, AirPods), so we get reliable RSSI without
  doing our own BLE scanning or holding a connection.
- **Idle gate**: when all (or any) trusted devices are missing, the daemon
  checks `ioreg -c IOHIDSystem` for `HIDIdleTime` and only proceeds if the
  user has truly stepped away from the keyboard.
- **Media gate**: skips locking when another app holds a
  `PreventUserIdleDisplaySleep` assertion (calls, presentations, fullscreen
  video).
- **Lock**: invokes the documented user-facing shortcut (Cmd+Ctrl+Q) via
  `osascript`. No private framework calls.
- **Logging & status**: events go to `~/Library/Logs/proximity-lock.log`,
  and a per-cycle snapshot goes to
  `~/Library/Application Support/proximity-lock/status.env` (used by the
  optional menu bar plugin, below).

## Menu bar plugin (optional)

A [SwiftBar](https://github.com/swiftbar/SwiftBar) / [xbar](https://xbarapp.com/)
plugin lives in `plugins/proximity-lock.10s.sh`. It reads the status file
written by the daemon and renders:

- A menu bar icon — 🟢 / 🟡 / 🔴 with `present/total` count.
- Per-device rows showing presence, signal-strength bars, RSSI dBm, and
  last-seen time. Submenu lets you copy the MAC.
- Daemon state — current policy, idle seconds, miss count, locked-or-watching.
- Quick actions — open or tail the log, edit config, restart the LaunchAgent.

### Install (SwiftBar)

```bash
brew install --cask swiftbar
# Launch SwiftBar once, point its plugin folder somewhere (e.g. ~/.swiftbar),
# then drop the plugin in:
mkdir -p ~/.swiftbar
cp plugins/proximity-lock.10s.sh ~/.swiftbar/
chmod +x ~/.swiftbar/proximity-lock.10s.sh
```

The `.10s.sh` filename suffix tells SwiftBar to refresh every 10 seconds.
Adjust if you want a different cadence.

xbar uses the same plugin format — copy the file into its plugins folder
instead.

### What it shows when the daemon isn't running

If `~/Library/Application Support/proximity-lock/status.env` is missing, the
plugin shows a "daemon not running" state with a one-click action to load the
LaunchAgent.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.example.proximitylock.plist
rm ~/Library/LaunchAgents/com.example.proximitylock.plist
rm ~/bin/proximity-lock.sh ~/bin/proximity-presence.py
rm ~/Library/Logs/proximity-lock.log
rm -rf "$HOME/Library/Application Support/proximity-lock"
# If you installed the menu bar plugin:
rm -f ~/.swiftbar/proximity-lock.10s.sh
```

## License

MIT
