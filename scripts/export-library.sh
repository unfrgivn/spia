#!/usr/bin/env bash
# Exports a Spia library (the Mac app's by default) so its recordings can become fixtures: every
# check's transcript, with the result the app saved next to it as <entry>.result.json, and a
# list of the cars and checks it holds. Nothing in the library changes.
#
# Usage: scripts/export-library.sh [source] [destination]
#   source:      the folder holding Library.store and Transcripts (default: the Mac app's
#                sandbox container, ~/Library/Containers/com.unfrgivn.spia/Data/Library/Application Support/Spia)
#   destination: a directory to create (default: $TMPDIR/spia-library/<timestamp>)
#
# Promote a check into Tests/Fixtures with its two files, named for the car and the check:
#   cp <destination>/Transcripts/<vehicle>/<entry>.txt         Tests/Fixtures/<car>-app-<check>.txt
#   cp <destination>/Transcripts/<vehicle>/<entry>.result.json Tests/Fixtures/<car>-app-<check>.result.json
#
# The queries read SwiftData's generated tables (ZVEHICLE, ZTIMELINEENTRY, ...), so a model change
# in SpiaStore can break them. Since schema v2 a reading belongs to its vehicle and may have no
# problem, so the listing joins on the vehicle, not the session.
set -euo pipefail
default_source="$HOME/Library/Containers/com.unfrgivn.spia/Data/Library/Application Support/Spia"
source=${1:-$default_source}
tmp=${TMPDIR:-/tmp}
tmp=${tmp%/}
dest=${2:-"$tmp/spia-library/$(date +%Y%m%d-%H%M%S)"}
if [[ ! -f "$source/Library.store" ]]; then
    echo "No library at $source (no Library.store). Is the app installed and has it run?" >&2
    exit 1
fi
if [[ -e $dest ]]; then
    echo "$dest already exists; give a new directory." >&2
    exit 1
fi
mkdir -p "$dest"
# The store's write-ahead log holds the newest checks, so all three files travel together.
for item in Library.store Library.store-wal Library.store-shm Transcripts; do
    if [[ -e "$source/$item" ]]; then cp -R "$source/$item" "$dest/$item"; fi
done

store="$dest/Library.store"
# A saved result is the JSON after Core Data's one-byte marker: 01 when it's stored inline.
sqlite3 "$store" "select ZTRANSCRIPTPATH from ZTIMELINEENTRY
    where ZRESULTDATA is not null and ZTRANSCRIPTPATH is not null;" |
    while IFS= read -r path; do
        out="$dest/${path%.txt}.result.json"
        quoted=${path//\'/\'\'}
        mkdir -p "$(dirname "$out")"
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
echo "Checks (oldest first; a problem's title when the check was taken for one):"
sqlite3 -separator '  ' "$store" "select '  ' || datetime(e.ZDATE + 978307200, 'unixepoch',
    'localtime'), v.ZNAME, e.ZTITLE || ':', replace(coalesce(e.ZBODY, ''), char(10), ' '),
    coalesce(e.ZTRANSCRIPTPATH, '(no recording)'),
    coalesce((select s.ZTITLE from ZDIAGNOSTICSESSION s where s.Z_PK = e.ZSESSION), '')
    from ZTIMELINEENTRY e join ZVEHICLE v on e.ZVEHICLE = v.Z_PK
    where v.ZISDEMO = 0 and e.ZKINDRAW in ('result', 'failure') order by e.ZDATE;"
echo
echo "Exported to $dest"
