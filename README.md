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
- [`blueutil`](https://github.com/toy/blueutil): `brew install blueutil`

## Install

1. Find your trusted devices' Bluetooth addresses:

   ```bash
   blueutil --paired
   ```

   Copy the `address:` field (format `aa-aa-aa-aa-aa-aa`) for each device
   you want to treat as "you".

2. Drop the script into `~/bin` and make it executable:

   ```bash
   mkdir -p ~/bin
   cp bin/proximity-lock.sh ~/bin/
   chmod +x ~/bin/proximity-lock.sh
   ```

3. Edit `~/bin/proximity-lock.sh` and replace the `TRUSTED_MACS` entries
   with your own addresses.

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
| `TRUSTED_MACS` | `(aa-aa-…  bb-bb-…)` | List of BT addresses considered "you". |
| `PRESENCE_POLICY` | `all_absent` | `all_absent` locks only when no trusted device is detected. `any_absent` locks if any one is missing. |
| `POLL_INTERVAL` | `30` | Seconds between scans. |
| `INQUIRY_DURATION` | `4` | Active-scan length in seconds passed to `blueutil --inquiry`. |
| `MISS_THRESHOLD` | `2` | Consecutive failed scans before considering you "away". |
| `IDLE_THRESHOLD` | `30` | Lock only if there's been at least this many seconds of no keyboard/trackpad input. |
| `RESPECT_MEDIA_ASSERTION` | `1` | If `1`, skip locking while another app holds a `PreventUserIdleDisplaySleep` assertion. |

Grace period before a lock attempt = `POLL_INTERVAL × MISS_THRESHOLD`. With
defaults that's about a minute of absence + 30 s of inactivity before the
screen locks.

## How it works

- Polls Bluetooth via `blueutil --inquiry`. This is an *active scan* that works
  even for devices (like iPhones) that don't keep a persistent connection to
  the Mac.
- When all (or any) trusted devices are missing, checks
  `ioreg -c IOHIDSystem` for `HIDIdleTime` and only proceeds if the user has
  truly stepped away.
- Locks via the documented user-facing shortcut (Cmd+Ctrl+Q) using
  `osascript`. No private framework calls.
- Logs every interesting event to `~/Library/Logs/proximity-lock.log`.
- After each scan cycle, writes a status snapshot to
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
rm ~/bin/proximity-lock.sh
rm ~/Library/Logs/proximity-lock.log
rm -rf "$HOME/Library/Application Support/proximity-lock"
# If you installed the menu bar plugin:
rm -f ~/.swiftbar/proximity-lock.10s.sh
```

## License

MIT
