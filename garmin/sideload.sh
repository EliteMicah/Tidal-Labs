#!/usr/bin/env bash
# Build for the watch that is plugged in right now and copy the PRG onto it.
#
# The product id has to match the connected watch exactly or the device ignores the PRG
# silently — no error, no icon, nothing. So this reads the watch's own part number out of
# GarminDevice.xml and looks the product up in the SDK device database rather than making
# you remember which of the 24 ids you own.
set -euo pipefail

APP=TIDALLBS   # 8.3-safe: the watch filesystem is FAT and short names are never a problem.
CIQ="$HOME/Library/Application Support/Garmin/ConnectIQ"
SDK=$(tr -d '\n' < "$CIQ/current-sdk.cfg")
cd "$(dirname "$0")"

# 1. Find the mounted watch.
VOL=""
for v in /Volumes/*; do
    [ -f "$v/GARMIN/GarminDevice.xml" ] && VOL="$v" && break
done
if [ -z "$VOL" ]; then
    # Nothing mounted. Separate "not plugged in" from "plugged in but never mounts", because
    # the two look identical in Finder and only the first one is fixed by replugging.
    # MTP-only models (Venu 3 and friends) enumerate as a vendor-specific Garmin interface,
    # 091e:0003 with no mass-storage interface at all, and macOS has no driver that turns
    # that into a volume. No amount of waiting produces one, so fail loudly instead.
    if system_profiler SPUSBDataType 2>/dev/null | grep -q "0x091e"; then
        cat >&2 <<MSG
A Garmin device is attached over USB but it is not mass storage, so there is no volume
to copy to.

On Venu 3 this is not fixable from the Mac. It enumerates as 091e:0003, one
vendor-specific interface, no mass-storage and no MTP interface, and it stays that way
across replugs and whether or not the watch is unlocked. Verified here: libmtp 1.1.23
finds no raw device, a PTP GetDeviceInfo after a bus reset times out, and the watch has
no USB Mode setting to flip. An MTP client will not help.

Use the store package instead. It reaches the watch over Bluetooth, no USB:

    "\$SDK/bin/monkeyc" -f monkey.jungle -o bin/TidalLabs.iq \\
        -y developer_key.der -e -r -w

Upload bin/TidalLabs.iq at https://apps.garmin.com/developer/dashboard as a private
app, then install it from Garmin Connect Mobile.

Watches that do mount as mass storage still work with this script, and on those the
by-hand path is bin/$APP.PRG into GARMIN/APPS/ plus an empty GARMIN/APPS/LOGS/$APP.TXT.
MSG
        exit 1
    fi
    echo "No Garmin device found on USB at all. Plug the watch in and re-run." >&2
    exit 1
fi

# 2. Watch tells us what it is. Part number, e.g. 006-B4536-00.
PART=$(sed -n 's/.*<PartNumber>\([^<]*\)<\/PartNumber>.*/\1/p' "$VOL/GARMIN/GarminDevice.xml" | head -1)
[ -n "$PART" ] || { echo "No <PartNumber> in $VOL/GARMIN/GarminDevice.xml" >&2; exit 1; }

# 3. Part number -> product id, straight out of the installed device database.
PRODUCT=$(python3 - "$CIQ/Devices" "$PART" <<'PY'
import json, os, sys
root, part = sys.argv[1], sys.argv[2]
for d in sorted(os.listdir(root)):
    f = os.path.join(root, d, "compiler.json")
    if os.path.exists(f):
        if part in [p.get("number") for p in json.load(open(f)).get("partNumbers", [])]:
            print(d)
            break
PY
)
if [ -z "$PRODUCT" ]; then
    echo "Part number $PART is not in $CIQ/Devices." >&2
    echo "Install that device in the SDK Manager, then re-run." >&2
    exit 1
fi
grep -q "id=\"$PRODUCT\"" manifest.xml || {
    echo "$PRODUCT ($PART) is not listed in manifest.xml. Add it there first." >&2; exit 1; }

echo "Watch: $PRODUCT  ($PART)  at $VOL"

# 4. Build signed, warnings on. No -t: that builds the test harness, not the app.
"$SDK/bin/monkeyc" -f monkey.jungle -o "bin/$APP.PRG" -y developer_key.der -d "$PRODUCT" -w

# 5. Copy in. The LOGS file is not auto-created and must match the PRG name, or
#    System.println() output goes nowhere.
mkdir -p "$VOL/GARMIN/APPS/LOGS"
cp "bin/$APP.PRG" "$VOL/GARMIN/APPS/$APP.PRG"
[ -f "$VOL/GARMIN/APPS/LOGS/$APP.TXT" ] || : > "$VOL/GARMIN/APPS/LOGS/$APP.TXT"

echo
echo "Copied. Now eject before unplugging:"
echo "    diskutil eject \"$VOL\""
echo
echo "After it reboots, the app is in Activities & Apps as \"Tidal Labs\"."
echo "Crash logs land in $VOL/GARMIN/APPS/LOGS/CIQ_LOG.YAML"
