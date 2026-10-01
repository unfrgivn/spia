#!/usr/bin/env bash
# Copies Spia's library off a paired iPhone and lists what it recorded, so a car onboarded on the
# phone can be read on the Mac. Every check keeps its transcript, and the result the app saved
# lands next to it as <entry>.result.json: together, a ready-made pair for Tests/Fixtures.
#
# Usage: scripts/pull-phone-library.sh [destination]
#   destination: a directory to create (default: $TMPDIR/spia-phone/<timestamp>)
# Environment: SPIA_DEVICE, a device name or identifier (default: the first paired iPhone).
#
# Only builds installed from Xcode allow this; TestFlight and App Store builds don't. Keep the
# phone unlocked and on the Mac's network, or plugged in. Nothing on the phone changes.
#
# The queries read SwiftData's generated tables (ZVEHICLE, ZTIMELINEENTRY, ...), so a model change
# in SpiaStore can break them.
set -euo pipefail

bundle=com.unfrgivn.spia
library="Library/Application Support/Spia"
dest=${1:-"${TMPDIR:-/tmp}/spia-phone/$(date +%Y%m%d-%H%M%S)"}
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

store="$dest/Library.store"
# A saved result is the JSON after Core Data's one-byte marker: 01 when it's stored inline.
sqlite3 "$store" "select ZTRANSCRIPTPATH from ZTIMELINEENTRY
    where ZRESULTDATA is not null and ZTRANSCRIPTPATH is not null;" |
    while IFS= read -r path; do
        out="$dest/${path%.txt}.result.json"
        quoted=${path//\'/\'\'}
        sqlite3 "$store" "select writefile('${out//\'/\'\'}.raw', ZRESULTDATA) from ZTIMELINEENTRY
            where ZTRANSCRIPTPATH = '$quoted';" >/dev/null
        if [[ $(head -c1 "$out.raw" | xxd -p) == 01 ]]; then
            tail -c +2 "$out.raw" >"$out"
        else
            echo "$path: its result is stored outside the database; skipped." >&2
        fi
        rm -f "$out.raw"
    done

echo
echo "Cars:"
sqlite3 -separator '  ' "$store" "select '  ' || v.ZNAME, coalesce(v.ZVIN, 'no VIN'),
    (select count(*) from ZMODULEPRESET m where m.ZVEHICLE = v.Z_PK) || ' saved modules'
    from ZVEHICLE v where v.ZISDEMO = 0 order by v.Z_PK;"
echo
echo "Checks (oldest first):"
sqlite3 -separator '  ' "$store" "select '  ' || datetime(e.ZDATE + 978307200, 'unixepoch',
    'localtime'), v.ZNAME, e.ZTITLE || ':', replace(coalesce(e.ZBODY, ''), char(10), ' '),
    coalesce(e.ZTRANSCRIPTPATH, '(no recording)')
    from ZTIMELINEENTRY e join ZDIAGNOSTICSESSION s on e.ZSESSION = s.Z_PK
    join ZVEHICLE v on s.ZVEHICLE = v.Z_PK
    where v.ZISDEMO = 0 and e.ZKINDRAW in ('result', 'failure') order by e.ZDATE;"
echo
echo "Copied to $dest"
