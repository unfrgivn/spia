#!/usr/bin/env bash
# Copies Spia's library off a paired iPhone and hands it to export-library.sh, so a car onboarded
# on the phone can be read on the Mac: every check's transcript with the result the app saved
# next to it as <entry>.result.json, a ready-made pair for Tests/Fixtures, lands in
# <destination>.export.
#
# Usage: scripts/pull-phone-library.sh [destination]
#   destination: a directory to create (default: $TMPDIR/spia-phone/<timestamp>)
# Environment: SPIA_DEVICE, a device name or identifier (default: the first paired iPhone).
#
# Only builds installed from Xcode allow this; TestFlight and App Store builds don't. Keep the
# phone unlocked and on the Mac's network, or plugged in. Nothing on the phone changes.
#
set -euo pipefail

bundle=com.unfrgivn.spia
library="Library/Application Support/Spia"
tmp=${TMPDIR:-/tmp}
tmp=${tmp%/}
dest=${1:-"$tmp/spia-phone/$(date +%Y%m%d-%H%M%S)"}
if [[ -e $dest ]]; then
    echo "$dest already exists; give a new directory." >&2
    exit 1
fi

device=${SPIA_DEVICE:-}
if [[ -z $device ]]; then
    list=$(mktemp)
    trap 'rm -f "$list"' EXIT
    xcrun devicectl list devices --json-output "$list" >/dev/null
    count=$(plutil -extract result.devices raw -o - "$list")
    for ((i = 0; i < count; i++)); do
        type=$(plutil -extract "result.devices.$i.hardwareProperties.deviceType" raw -o - "$list")
        pairing=$(plutil -extract "result.devices.$i.connectionProperties.pairingState" raw -o - "$list")
        if [[ $type == iPhone && $pairing == paired ]]; then
            device=$(plutil -extract "result.devices.$i.identifier" raw -o - "$list")
            echo "Phone: $(plutil -extract "result.devices.$i.deviceProperties.name" raw -o - "$list")"
            break
        fi
    done
    if [[ -z $device ]]; then
        echo "No paired iPhone. Pair it in Xcode (Window > Devices and Simulators) first." >&2
        exit 1
    fi
fi

# A phone that's asleep often misses the first connection, so each item gets three tries.
pull() {
    local item=$1 attempt
    for attempt in 1 2 3; do
        rm -rf "${dest:?}/$item"
        if xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
            --domain-identifier "$bundle" --source "$library/$item" --destination "$dest/$item" \
            --timeout 60 --quiet >/dev/null 2>&1; then
            return 0
        fi
        echo "$item: the phone didn't answer (try $attempt of 3). Is it unlocked and on this network?" >&2
        sleep 3
    done
    return 1
}

mkdir -p "$dest"
# The store's write-ahead log holds the newest checks, so all three files travel together.
for item in Library.store Library.store-wal Library.store-shm Transcripts; do
    pull "$item"
done

# From here the phone's copy is an ordinary library: the export script writes each saved result
# next to its transcript and lists the cars and checks.
exec "$(dirname "$0")/export-library.sh" "$dest" "$dest.export"
