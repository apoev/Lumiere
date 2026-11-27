#!/bin/bash
# Печатает следующий номер версии: на единицу выше Info.plist и последнего тега vX.Y.Z.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"

python3 - "$ROOT" "$CURRENT" <<'PY'
import subprocess
import sys

root, current = sys.argv[1], sys.argv[2]


def parts(value):
    nums = []
    for piece in value.split("."):
        digits = ""
        for ch in piece:
            if ch.isdigit():
                digits += ch
            else:
                break
        nums.append(int(digits) if digits else 0)
    return nums or [0]


def newer(left, right):
    a, b = parts(left), parts(right)
    width = max(len(a), len(b))
    a += [0] * (width - len(a))
    b += [0] * (width - len(b))
    return a > b


best = current
tags = subprocess.check_output(["git", "-C", root, "tag", "-l", "v[0-9]*"], text=True)
for line in tags.splitlines():
    version = line.strip()
    if version[:1] in ("v", "V"):
        version = version[1:]
    if version and newer(version, best):
        best = version

nums = parts(best)
while len(nums) < 3:
    nums.append(0)
nums[-1] += 1
print(".".join(str(number) for number in nums))
PY
