#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime.

Runner images change which devices and runtimes they ship, so CI asks instead
of naming a device. Reads `xcrun simctl list devices available -j` on stdin.
"""
import json
import sys

devices = json.load(sys.stdin)["devices"]
best = None
for runtime, entries in devices.items():
    # com.apple.CoreSimulator.SimRuntime.iOS-26-2
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(p) for p in runtime.split(".iOS-")[1].split("-"))
    for d in entries:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            # A one-screen iPhone first: the tests check logic, and the
            # foldable's simulator is new enough to be its own variable.
            # It is still taken when nothing else is there.
            rank = (0 if "Duo" in d["name"] else 1, version)
            if best is None or rank > best[0]:
                best = (rank, d["udid"], d["name"])

if best is None:
    sys.exit("no available iPhone simulator")
print(f"{best[2]} (iOS {'.'.join(map(str, best[0][1]))})", file=sys.stderr)
print(best[1])
