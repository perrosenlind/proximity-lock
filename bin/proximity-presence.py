#!/usr/bin/env python3
"""Emit live BT presence for given MACs by reading macOS's BT daemon state.

Usage: proximity-presence.py <mac1> [<mac2> ...]

Output: one tab-separated line per device that currently has a live RSSI:
    <mac>\t<rssi>\t<name>

MACs not found (or paired but without current RSSI) are simply not emitted.
This is the most reliable presence signal available without a code-signed
CoreBluetooth helper: macOS already runs continuous BLE scanning for paired
Apple devices to power Continuity, and exposes their live RSSI here.
"""
import json
import subprocess
import sys


def normalize(mac: str) -> str:
    return mac.strip().lower().replace("-", ":")


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: proximity-presence.py <mac> [<mac> ...]", file=sys.stderr)
        return 2

    wanted = {normalize(m) for m in sys.argv[1:] if m.strip()}

    try:
        out = subprocess.run(
            ["/usr/sbin/system_profiler", "SPBluetoothDataType", "-json"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"system_profiler failed: {e}", file=sys.stderr)
        return 1

    try:
        data = json.loads(out.stdout or "{}")
    except json.JSONDecodeError as e:
        print(f"json decode failed: {e}", file=sys.stderr)
        return 1

    for entry in data.get("SPBluetoothDataType", []):
        for bucket in ("device_connected", "device_not_connected"):
            for dev in entry.get(bucket, []):
                for name, info in dev.items():
                    addr = info.get("device_address", "").lower()
                    rssi = info.get("device_rssi")
                    if addr in wanted and rssi is not None:
                        print(f"{addr}\t{rssi}\t{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
