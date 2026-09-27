#!/bin/sh
set -eu

SPiA="${1:-.build/debug/spia}"
PORT=/definitely/not-a-port

expect_failure() {
    expected=$1
    shift
    set +e
    output=$($SPiA uds dtcs --port "$PORT" "$@" 2>&1)
    status=$?
    set -e
    test "$status" -ne 0
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
}

expect_scan_failure() {
    expected=$1
    shift
    set +e
    output=$($SPiA scan --port "$PORT" "$@" 2>&1)
    status=$?
    set -e
    test "$status" -ne 0
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
}

expect_info_failure() {
    expected=$1
    shift
    set +e
    output=$($SPiA info --port "$PORT" "$@" 2>&1)
    status=$?
    set -e
    test "$status" -ne 0
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
}

expect_capture_failure() {
    expected=$1
    shift
    set +e
    output=$($SPiA capture --port "$PORT" "$@" 2>&1)
    status=$?
    set -e
    test "$status" -ne 0
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
}

expect_discover_failure() {
    expected=$1
    shift
    set +e
    output=$($SPiA discover --port "$PORT" "$@" 2>&1)
    status=$?
    set -e
    test "$status" -ne 0
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
}

expect_live_failure() {
    expected=$1
    shift
    set +e
    output=$($SPiA live --port "$PORT" "$@" 2>&1)
    status=$?
    set -e
    test "$status" -ne 0
    printf '%s\n' "$output" | grep -F "$expected" >/dev/null
}

expect_failure "Missing expected argument '--tx" --rx 4C4
expect_failure "Missing expected argument '--rx" --tx 744
expect_failure "11-bit hexadecimal CAN ID" --tx 800 --rx 4C4
expect_failure "one byte of hexadecimal" --tx 744 --rx 4C4 --status-mask 100
expect_failure "positive" --tx 744 --rx 4C4 --timeout 0
expect_failure "timeout" --tx 744 --rx 4C4 --timeout nan
expect_failure "timeout" --tx 744 --rx 4C4 --timeout infinity
expect_failure "at most 120" --tx 744 --rx 4C4 --timeout 121

"$SPiA" scan --help >/dev/null
"$SPiA" info --help >/dev/null
"$SPiA" live --help >/dev/null
expect_scan_failure "CAN 11-bit 500k" --protocol 3
expect_info_failure "CAN 11-bit 500k" --protocol 8
expect_live_failure "positive" --duration 0
expect_live_failure "finite" --duration nan
expect_live_failure "between 0.1 and 60" --interval 0
expect_live_failure "one byte of hexadecimal" --pid GG
expect_live_failure "support bitmap" --pid 00
expect_capture_failure "finite, positive" --duration 0
expect_capture_failure "ATMA or STMA" --command AT
expect_capture_failure "requires CAN protocol" --protocol 3
expect_capture_failure "could not open" --uart-baud 0
expect_capture_failure "zero or positive" --uart-baud=-1
expect_capture_failure "29-bit" --id 1FFFFFFFF
expect_capture_failure "53 or 54" --stp 52
expect_capture_failure "only 125000" --stp 53 --stp-baud 500000
expect_capture_failure "requires --stp" --stp-baud 125000
expect_capture_failure "different files" --out /tmp/spia-same --record /tmp/spia-same
expect_discover_failure "restricted to 3E00" --request 1001 --skip-standard --skip-extended
expect_discover_failure "multiple of 4" --wait 5 --skip-standard --skip-extended
expect_discover_failure "experimental" --range 700-7F7 --skip-extended
expect_discover_failure "exact aligned" --response-window 601-7FF --experimental --skip-extended
expect_discover_failure "at or above 480" --response-window 400-7FF --experimental --skip-extended
expect_discover_failure "no sweep enabled" --skip-standard --skip-extended
expect_discover_failure "could not open" --range 700-7FF --response-window 600-7FF --experimental --skip-extended

printf '%s\n' "CLI validation checks passed"
