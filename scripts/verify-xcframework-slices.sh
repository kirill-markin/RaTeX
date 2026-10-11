#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <xcframework-path> <required-platform> [required-platform ...]" >&2
  exit 2
fi

XCFRAMEWORK_PATH="$1"
shift
REQUIRED_PLATFORMS=("$@")
INFO_PLIST="$XCFRAMEWORK_PATH/Info.plist"

if [ ! -d "$XCFRAMEWORK_PATH" ]; then
  echo "::error::XCFramework not found: $XCFRAMEWORK_PATH" >&2
  exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
  echo "::error::Missing Info.plist: $INFO_PLIST" >&2
  exit 1
fi

python3 - "$INFO_PLIST" "${REQUIRED_PLATFORMS[@]}" <<'PY'
import plistlib
import sys
from pathlib import Path

info_plist = Path(sys.argv[1])
required = sys.argv[2:]

with info_plist.open("rb") as f:
    data = plistlib.load(f)

libs = data.get("AvailableLibraries", [])
def platform_group(lib):
    platform = lib.get("SupportedPlatform")
    if platform == "ios" and lib.get("SupportedPlatformVariant") == "maccatalyst":
        return "maccatalyst"
    return platform

present = sorted({platform_group(lib) for lib in libs if platform_group(lib)})
missing = [platform for platform in required if platform not in present]

print(f"Present platforms: {', '.join(present) if present else '(none)'}")
print(f"Required platforms: {', '.join(required)}")

if missing:
    print(f"::error::Missing XCFramework platform slices: {', '.join(missing)}")
    sys.exit(1)

def matches(platform: str, variant: str | None = None):
    for lib in libs:
        if lib.get("SupportedPlatform") != platform:
            continue
        if variant is None:
            if "SupportedPlatformVariant" not in lib:
                yield lib
        else:
            if lib.get("SupportedPlatformVariant") == variant:
                yield lib

def arch_union(entries):
    result = set()
    for item in entries:
        result.update(item.get("SupportedArchitectures", []))
    return result

if "ios" in required:
    ios_device = list(matches("ios", None))
    ios_sim = list(matches("ios", "simulator"))
    if not ios_device:
        print("::error::Missing iOS device slice (SupportedPlatform=ios, no variant).")
        sys.exit(1)
    if not ios_sim:
        print("::error::Missing iOS simulator slice (SupportedPlatform=ios, SupportedPlatformVariant=simulator).")
        sys.exit(1)

    ios_device_arch = arch_union(ios_device)
    ios_sim_arch = arch_union(ios_sim)
    if "arm64" not in ios_device_arch:
        print(f"::error::iOS device slice missing arm64. Found: {sorted(ios_device_arch)}")
        sys.exit(1)
    for arch in ("arm64", "x86_64"):
        if arch not in ios_sim_arch:
            print(f"::error::iOS simulator slice missing {arch}. Found: {sorted(ios_sim_arch)}")
            sys.exit(1)

    print(f"iOS device architectures: {sorted(ios_device_arch)}")
    print(f"iOS simulator architectures: {sorted(ios_sim_arch)}")

if "macos" in required:
    mac_entries = list(matches("macos", None))
    if not mac_entries:
        print("::error::Missing macOS slice (SupportedPlatform=macos).")
        sys.exit(1)
    mac_arch = arch_union(mac_entries)
    for arch in ("arm64", "x86_64"):
        if arch not in mac_arch:
            print(f"::error::macOS slice missing {arch}. Found: {sorted(mac_arch)}")
            sys.exit(1)
    print(f"macOS architectures: {sorted(mac_arch)}")

if "maccatalyst" in required:
    catalyst_entries = list(matches("ios", "maccatalyst"))
    catalyst_arch = arch_union(catalyst_entries)
    for arch in ("arm64", "x86_64"):
        if arch not in catalyst_arch:
            print(f"::error::Mac Catalyst slice missing {arch}. Found: {sorted(catalyst_arch)}")
            sys.exit(1)
    print(f"Mac Catalyst architectures: {sorted(catalyst_arch)}")

print("XCFramework platform slice check passed.")
PY
