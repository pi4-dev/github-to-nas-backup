#!/bin/sh
# Periodic GitHub backup loop (entrypoint of the github-backup container).
#
# Every BACKUP_INTERVAL seconds it runs python-github-backup (a "full" run when
# FULL_INTERVAL has elapsed since the last one, "incremental" otherwise) and,
# after a successful backup, optionally pings KEEPALIVE_URL and runs
# verify-backups.sh when VERIFY_INTERVAL has elapsed.
#
# State is kept as marker files in $STATUS_DIR; their mtime is the timestamp.
# See README.md for the full list of environment variables.

set -eu

GH_ACCOUNT="${GH_ACCOUNT:?GH_ACCOUNT must be set}"
GH_ORGANIZATION="${GH_ORGANIZATION:-false}"
INCLUDE_PRIVATE="${INCLUDE_PRIVATE:-true}"
INCLUDE_FORKS="${INCLUDE_FORKS:-true}"
# Extra github-backup flags, intentionally word-split (e.g. "--prefer-ssh").
GH_EXTRA_ARGS="${GH_EXTRA_ARGS:-}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-21600}"
FULL_INTERVAL="${FULL_INTERVAL:-604800}"
KEEPALIVE_URL="${KEEPALIVE_URL:-}"
KEEPALIVE_TIMEOUT="${KEEPALIVE_TIMEOUT:-10}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-604800}"
VERIFY_KEEPALIVE_URL="${VERIFY_KEEPALIVE_URL:-}"
VERIFY_KEEPALIVE_TIMEOUT="${VERIFY_KEEPALIVE_TIMEOUT:-10}"

BACKUP_DIR="/data"
STATUS_DIR="${BACKUP_DIR}/status"
TOKEN_FILE="/run/secrets/github_token"
VERIFIER_SCRIPT="/verify-backups.sh"

LAST_FULL="${STATUS_DIR}/last-full"
LAST_SUCCESS="${STATUS_DIR}/last-success"
LAST_FAILURE="${STATUS_DIR}/last-failure"
LAST_VERIFY_SUCCESS="${STATUS_DIR}/last-verify-success"
LAST_VERIFY_FAILURE="${STATUS_DIR}/last-verify-failure"

# PID of the currently running child (github-backup or sleep), if any.
child_pid=""

log() {
    echo "[$(date -Iseconds)] $*"
}

warn() {
    echo "[$(date -Iseconds)] $*" >&2
}

require_int() {
    case "$2" in
        '' | *[!0-9]*)
            warn "ERROR: $1 must be a non-negative integer (seconds), got '$2'"
            exit 1
            ;;
    esac
}

# Forward termination to the running child and exit promptly. As PID 1 the
# shell would otherwise ignore SIGTERM and docker would wait for SIGKILL.
on_signal() {
    if [ -n "$child_pid" ]; then
        kill "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
    log "received termination signal, exiting"
    exit 0
}

# Run a command in the background and wait for it, so that signals are handled
# immediately instead of after the command finishes. Returns its exit status.
run_interruptible() {
    "$@" &
    child_pid=$!
    status=0
    wait "$child_pid" || status=$?
    child_pid=""
    return "$status"
}

# Age in seconds of a marker file; prints nothing and fails if it is missing.
file_age() {
    [ -f "$1" ] || return 1
    mtime="$(stat -c %Y "$1" 2>/dev/null || echo 0)"
    echo $(($(date +%s) - mtime))
}

# True when the marker is missing or at least $2 seconds old.
is_due() {
    age="$(file_age "$1")" || return 0
    [ "$age" -ge "$2" ]
}

send_keepalive() {
    ka_url="$1"
    ka_timeout="$2"
    ka_label="$3"

    [ -n "$ka_url" ] || return 0

    log "sending $ka_label keepalive notification"

    # The URL is passed as an argument and never logged (it may hold a secret).
    # The image ships Python, so no extra curl/wget dependency is needed.
    if python -c '
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=float(sys.argv[2])) as response:
    status = getattr(response, "status", 200)

raise SystemExit(0 if 200 <= status < 400 else 1)
' "$ka_url" "$ka_timeout"
    then
        log "$ka_label keepalive notification succeeded"
    else
        warn "WARNING: $ka_label keepalive notification failed"
    fi
}

# A failed verification never invalidates the backup itself; it only leaves the
# failure marker, skips the verification keepalive and is retried after the
# next successful backup.
run_verification_if_due() {
    is_due "$LAST_VERIFY_SUCCESS" "$VERIFY_INTERVAL" || return 0

    log "starting backup verification"

    if run_interruptible env BACKUP_ROOT="$BACKUP_DIR" sh "$VERIFIER_SCRIPT"; then
        touch "$LAST_VERIFY_SUCCESS"
        rm -f "$LAST_VERIFY_FAILURE"
        log "backup verification completed successfully"
        send_keepalive "$VERIFY_KEEPALIVE_URL" "$VERIFY_KEEPALIVE_TIMEOUT" "verification"
    else
        touch "$LAST_VERIFY_FAILURE"
        warn "ERROR: backup verification failed"
        warn "verification keepalive will not be sent"
    fi
}

# Runs github-backup. $1 is "full" or "incremental".
run_github_backup() {
    mode="$1"

    # Flags that are always on: everything that makes the archive complete
    # (mirror + LFS + wikis + all issue/PR/discussion/release metadata).
    # NOTE: timeline/details/reviews cost many API calls per item and are the
    # main consumer of the GitHub rate limit on large accounts.
    set -- "$GH_ACCOUNT" \
        --token-fine "file://$TOKEN_FILE" \
        --output-directory "$BACKUP_DIR" \
        --repositories --bare --lfs --wikis \
        --issues --issue-comments --issue-events --issue-timeline \
        --pulls --pull-comments --pull-reviews --pull-commits --pull-details \
        --labels --milestones --discussions \
        --releases --assets --attachments \
        --retries 5

    [ "$GH_ORGANIZATION" = "true" ] && set -- "$@" --organization
    [ "$INCLUDE_PRIVATE" = "true" ] && set -- "$@" --private
    [ "$INCLUDE_FORKS" = "true" ] && set -- "$@" --fork
    [ "$mode" = "incremental" ] && set -- "$@" --incremental

    # shellcheck disable=SC2086  # GH_EXTRA_ARGS is meant to be word-split
    [ -n "$GH_EXTRA_ARGS" ] && set -- "$@" $GH_EXTRA_ARGS

    run_interruptible github-backup "$@"
}

run_backup() {
    mode="$1"

    log "starting $mode backup for $GH_ACCOUNT"

    if ! run_github_backup "$mode"; then
        touch "$LAST_FAILURE"
        warn "backup failed"
        return 1
    fi

    touch "$LAST_SUCCESS"
    rm -f "$LAST_FAILURE"
    [ "$mode" = "full" ] && touch "$LAST_FULL"

    log "backup completed successfully"
    send_keepalive "$KEEPALIVE_URL" "$KEEPALIVE_TIMEOUT" "backup"
    run_verification_if_due
}

main() {
    require_int BACKUP_INTERVAL "$BACKUP_INTERVAL"
    require_int FULL_INTERVAL "$FULL_INTERVAL"
    require_int VERIFY_INTERVAL "$VERIFY_INTERVAL"
    require_int KEEPALIVE_TIMEOUT "$KEEPALIVE_TIMEOUT"
    require_int VERIFY_KEEPALIVE_TIMEOUT "$VERIFY_KEEPALIVE_TIMEOUT"

    mkdir -p "$STATUS_DIR"
    trap on_signal TERM INT

    while true; do
        if is_due "$LAST_FULL" "$FULL_INTERVAL"; then
            run_backup full || true
        else
            run_backup incremental || true
        fi

        log "next run in $BACKUP_INTERVAL seconds"
        run_interruptible sleep "$BACKUP_INTERVAL"
    done
}

main
