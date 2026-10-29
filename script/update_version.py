#!/usr/bin/env python3
"""Increment patch (default), minor or major; patch/minor carry at 1000."""
import argparse
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]

def next_version(current, level="patch"):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?", current)
    if not match:
        raise ValueError("Expected a semantic version")
    values = list(map(int, match.groups()))
    position = {"major": 0, "minor": 1, "patch": 2}[level]
    values[position] += 1
    values[position + 1:] = [0] * (2 - position)
    for index in (2, 1):
        carry, values[index] = divmod(values[index], 1000)
        values[index - 1] += carry
    return ".".join(map(str, values))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("level", choices=["patch", "minor", "major"], nargs="?", default="patch")
    args = parser.parse_args()
    path = ROOT / "Resources/Info.plist"
    info = plistlib.loads(path.read_bytes())
    version = next_version(info["CFBundleShortVersionString"], args.level)
    info.update(CFBundleShortVersionString=version, LinvellReleaseVersion=version,
                CFBundleVersion=str(int(info["CFBundleVersion"]) + 1))
    path.write_bytes(plistlib.dumps(info, sort_keys=False))
    print(version)

if __name__ == "__main__":
    main()
