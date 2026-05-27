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

```bash
git clone https://github.com/perrosenlind/proximity-lock.git
cd proximity-lock
./install.sh
```

The installer will:

1. Check macOS, `/usr/bin/python3`, and Homebrew.
2. Show you a numbered list of paired Bluetooth devices (devices currently
   in range are listed first — those are your candidates) and ask which to
   trust as "you".
3. Copy `proximity-lock.sh` and `proximity-presence.py` to `~/bin/`, with
   your picks baked into the `TRUSTED_MACS` config.
4. Install and load the LaunchAgent so the daemon runs at login.
5. Install [SwiftBar](https://github.com/swiftbar/SwiftBar) via Homebrew if
   it's missing, drop the menu bar plugin into `~/SwiftBar/Plugins`, and
   launch it.

Re-running is safe — it'll detect any existing install (including under a
different LaunchAgent label) and prompt before replacing it.

After install, set **System Settings → Lock Screen → Require password →
Immediately** so the lock screen actually requires authentication.

To remove everything:

```bash
./uninstall.sh
```

(SwiftBar itself is left in place — run `brew uninstall --cask swiftbar` if
you also want it gone.)

### Manual install

If you'd rather not run the installer:

```bash
mkdir -p ~/bin
cp bin/proximity-lock.sh bin/proximity-presence.py ~/bin/
chmod +x ~/bin/proximity-lock.sh ~/bin/proximity-presence.py
# Edit ~/bin/proximity-lock.sh and fill in TRUSTED_MACS with your addresses
# (find them with: system_profiler SPBluetoothDataType | grep -E 'Address:|RSSI:')

cp LaunchAgents/com.example.proximitylock.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.example.proximitylock.plist
```

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

A [SwiftBar](https://github.com/swiftbar/SwiftBar) /
[xbar](https://xbarapp.com/) plugin lives in `plugins/proximity-lock.10s.sh`.
The installer drops it in `~/SwiftBar/Plugins/` automatically. It reads the
status file written by the daemon and renders:

- A menu bar icon — SF Symbol `dot.radiowaves.left.and.right` with adaptive
  color (green / orange / red) and `present/total` count.
- Per-device rows with device-type SF Symbol (iphone, applewatch, airpods…),
  signal-strength label (Excellent → Very weak), RSSI in dBm, and copy-MAC
  submenu.
- Daemon state — Watching / Missed scans / Armed / Locked, each with its own
  state icon.
- Quick actions — open or tail the log, edit config, restart the LaunchAgent.

The `.10s.sh` filename suffix tells SwiftBar to refresh every 10 seconds.
xbar uses the same plugin format if you prefer it over SwiftBar.

If the daemon isn't running, the plugin shows a "daemon not running" state
with a one-click action to load the LaunchAgent.

### Hiding the menu bar icon

The icon-style submenu lets you change the symbol, but to remove the menu
bar item entirely use the CLI:

```bash
# Hide — no menu bar item, no click target.
~/SwiftBar/Plugins/proximity-lock.10s.sh --hide

# Bring it back.
~/SwiftBar/Plugins/proximity-lock.10s.sh --show
```

The daemon keeps running either way — only the icon goes away. The
visibility setting is persisted in
`~/Library/Application Support/proximity-lock/plugin.env`, so the choice
survives reboots and SwiftBar restarts.

Run the plugin with `--help` for the full CLI reference.

## License

MIT
