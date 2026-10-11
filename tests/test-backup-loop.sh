#!/bin/sh
# Standalone tests of scheduler arithmetic and run/termination markers.
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
[ "$(tail -n 1 backup-loop.sh)" = main ] || { echo "Unexpected backup-loop.sh entrypoint" >&2; exit 1; }
# Import functions without executing the infinite loop.
sed '$d' backup-loop.sh > "$tmp/functions.sh"
GH_ACCOUNT=ci
# shellcheck disable=SC1091
. "$tmp/functions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Validate boundary maths without waiting for a six-hour slot.
BACKUP_INTERVAL=21600
date() {
    if [ "$1" = "+%s" ]; then
        printf "%s\n" "$MOCK_NOW"
    else
        command date "$@"
    fi
}
for case in "0:21600" "1:21599" "21599:1" "21600:21600" "21601:21599" "86399:1"; do
    MOCK_NOW="${case%%:*}"
    expected="${case#*:}"
    [ "$(seconds_until_next_slot)" = "$expected" ] || fail "alignment at $MOCK_NOW"
done
unset MOCK_NOW

# A cleanly completed full run must mark its start and remove running.
STATUS_DIR="$tmp/status"
mkdir -p "$STATUS_DIR"
RUNNING="$STATUS_DIR/running"
LAST_START="$STATUS_DIR/last-start"
LAST_SUCCESS="$STATUS_DIR/last-success"
LAST_FAILURE="$STATUS_DIR/last-failure"
LAST_FULL="$STATUS_DIR/last-full"
run_github_backup() {
    [ -f "$RUNNING" ] && [ -f "$LAST_START" ] || fail "missing active markers"
    [ "$run_active" = true ] || fail "run flag missing"
    [ "${MOCK_BACKUP_RC:-0}" = 0 ]
}
send_keepalive() { :; }
run_verification_if_due() { [ -f "$RUNNING" ] || fail "running cleared before verification"; }
run_backup full || fail "successful run failed"
[ -f "$LAST_START" ] && [ -f "$LAST_SUCCESS" ] && [ -f "$LAST_FULL" ] || fail "missing successful markers"
[ ! -e "$RUNNING" ] && [ "$run_active" = false ] || fail "marker left after success"

# Failed runs must clear running and write last-failure.
MOCK_BACKUP_RC=1
if run_backup incremental; then fail "failing backup succeeded"; fi
[ -f "$LAST_FAILURE" ] || fail "failure marker missing"
[ ! -e "$RUNNING" ] && [ "$run_active" = false ] || fail "marker left after failure"

# SIGTERM handler must clear only our active marker.
(
    touch "$RUNNING"
    run_active=true
    child_pid=""
    on_signal
) || fail "signal handler failed"
[ ! -e "$RUNNING" ] || fail "marker left after signal"

# An orphan found while idle must not be silently cleared by shutdown.
touch "$RUNNING"
(
    run_active=false
    child_pid=""
    on_signal
) || fail "idle handler failed"
[ -e "$RUNNING" ] || fail "orphan was silently removed"

# Reject an aligned interval of zero at startup before permissions checks.
if output="$(env GH_ACCOUNT=ci ALIGN_SCHEDULE=true BACKUP_INTERVAL=0 sh ./backup-loop.sh 2>&1)"; then
    fail "aligned zero interval succeeded"
fi
printf "%s\n" "$output" | grep -Fq "requires BACKUP_INTERVAL > 0" || fail "unexpected validation error: $output"
echo "PASS: schedule and running-marker regression tests"
