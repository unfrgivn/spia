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

expect_failure "Missing expected argument '--tx" --rx 4C4
expect_failure "Missing expected argument '--rx" --tx 744
expect_failure "11-bit hexadecimal CAN ID" --tx 800 --rx 4C4
expect_failure "one byte of hexadecimal" --tx 744 --rx 4C4 --status-mask 100
expect_failure "positive" --tx 744 --rx 4C4 --timeout 0
expect_failure "timeout" --tx 744 --rx 4C4 --timeout nan
expect_failure "timeout" --tx 744 --rx 4C4 --timeout infinity
expect_failure "at most 120" --tx 744 --rx 4C4 --timeout 121

printf '%s\n' "CLI validation checks passed"
