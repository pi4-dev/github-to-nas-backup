#!/bin/sh
# Periodic GitHub backup loop (entrypoint of the github-to-nas-backup container).
#
# By default a run starts immediately and the loop sleeps BACKUP_INTERVAL
# seconds after it finishes. With ALIGN_SCHEDULE=true, starts instead align to
# epoch-based interval boundaries, skipping slots missed by long backup runs.
# A "full" run is due when FULL_INTERVAL has elapsed; otherwise incremental.
# After backup,
# after a successful backup, optionally pings KEEPALIVE_URL and runs
# verify-backups.sh when VERIFY_INTERVAL has elapsed.
#
# State is kept as marker files in $STATUS_DIR; their mtime is the timestamp.
# See README.md for the full list of environment variables.

set -eu

GH_ACCOUNT="${GH_ACCOUNT:?GH_ACCOUNT must be set}"
GH_ORGANIZATION="${GH_ORGANIZATION-false}"
INCLUDE_PRIVATE="${INCLUDE_PRIVATE-true}"
INCLUDE_FORKS="${INCLUDE_FORKS-true}"
# Extra github-backup flags, intentionally word-split (e.g. "--prefer-ssh").
GH_EXTRA_ARGS="${GH_EXTRA_ARGS:-}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-21600}"
ALIGN_SCHEDULE="${ALIGN_SCHEDULE-false}"
FULL_INTERVAL="${FULL_INTERVAL:-604800}"
KEEPALIVE_URL="${KEEPALIVE_URL:-}"
KEEPALIVE_TIMEOUT="${KEEPALIVE_TIMEOUT:-10}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-604800}"
VERIFY_LFS="${VERIFY_LFS-true}"
export VERIFY_LFS
VERIFY_KEEPALIVE_URL="${VERIFY_KEEPALIVE_URL:-}"
VERIFY_KEEPALIVE_TIMEOUT="${VERIFY_KEEPALIVE_TIMEOUT:-10}"

BACKUP_DIR="/data"
STATUS_DIR="${BACKUP_DIR}/status"
TOKEN_FILE="/run/secrets/github_token"
VERIFIER_SCRIPT="/verify-backups.sh"

RUNNING="${STATUS_DIR}/running"
LAST_START="${STATUS_DIR}/last-start"
LAST_FULL="${STATUS_DIR}/last-full"
LAST_SUCCESS="${STATUS_DIR}/last-success"
LAST_FAILURE="${STATUS_DIR}/last-failure"
LAST_VERIFY_SUCCESS="${STATUS_DIR}/last-verify-success"
LAST_VERIFY_FAILURE="${STATUS_DIR}/last-verify-failure"

# PID of the currently running child (github-backup or sleep), if any.
child_pid=""
# Tracks a marker created by this process (not an orphan left by an older one).
run_active=false

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

# Reject typos before running a backup; non-true values must not silently
# disable private repositories, forks, organization mode or LFS verification.
require_bool() {
    case "$2" in
        true | false) ;;
        *)
            warn "ERROR: $1 must be 'true' or 'false', got '$2'"
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
    if [ "$run_active" = "true" ]; then
        rm -f "$RUNNING" || warn "ERROR: could not clear $RUNNING on termination"
        run_active=false
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

# Seconds to the NEXT epoch-aligned slot, strictly after the current second.
# Epoch arithmetic is timezone/DST-independent (e.g., every 21600 seconds
# produces 00/06/12/18 UTC). The current boundary waits a full interval.
seconds_until_next_slot() {
    now="$(date +%s)"
    echo "$((BACKUP_INTERVAL - now % BACKUP_INTERVAL))"
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

# Remove only our own running marker (never an orphan while idle).
finish_run() {
    rm -f "$RUNNING"
    run_active=false
}

run_backup() {
    mode="$1"

    # Mark the whole cycle, including post-backup verification, as active.
    touch "$LAST_START" "$RUNNING"
    run_active=true
    log "starting $mode backup for $GH_ACCOUNT"

    if ! run_github_backup "$mode"; then
        touch "$LAST_FAILURE"
        warn "backup failed"
        finish_run
        return 1
    fi

    touch "$LAST_SUCCESS"
    rm -f "$LAST_FAILURE"
    [ "$mode" = "full" ] && touch "$LAST_FULL"

    log "backup completed successfully"
    send_keepalive "$KEEPALIVE_URL" "$KEEPALIVE_TIMEOUT" "backup"
    run_verification_if_due
    finish_run
}

# Compose file-backed secrets keep their host permissions, and the upstream
# image runs as UID:GID 1000:1000. Fail fast if the host NAS paths do not allow
# the container user to read its token or write backup/status files.
check_host_permissions() {
    runtime_id="$(id -u):$(id -g)"

    if [ ! -f "$TOKEN_FILE" ] || [ ! -r "$TOKEN_FILE" ]; then
        warn "ERROR: GitHub token secret $TOKEN_FILE is not readable by UID:GID $runtime_id"
        warn "Fix host secret ownership and permissions (default: chown 1000:1000, chmod 400); see README.md"
        exit 1
    fi

    if [ ! -d "$BACKUP_DIR" ] || [ ! -w "$BACKUP_DIR" ]; then
        warn "ERROR: backup directory $BACKUP_DIR is not writable by UID:GID $runtime_id"
        warn "Fix BACKUP_HOST_PATH ownership or NAS ACLs; see README.md"
        exit 1
    fi

    if ! mkdir -p "$STATUS_DIR"; then
        warn "ERROR: cannot create status directory $STATUS_DIR as UID:GID $runtime_id"
        exit 1
    fi

    if [ ! -w "$STATUS_DIR" ]; then
        warn "ERROR: status directory $STATUS_DIR is not writable by UID:GID $runtime_id"
        warn "Fix ownership of existing status files/directories or NAS ACLs; see README.md"
        exit 1
    fi
}

main() {
    require_int BACKUP_INTERVAL "$BACKUP_INTERVAL"
    require_int FULL_INTERVAL "$FULL_INTERVAL"
    require_int VERIFY_INTERVAL "$VERIFY_INTERVAL"
    require_int KEEPALIVE_TIMEOUT "$KEEPALIVE_TIMEOUT"
    require_int VERIFY_KEEPALIVE_TIMEOUT "$VERIFY_KEEPALIVE_TIMEOUT"

    require_bool GH_ORGANIZATION "$GH_ORGANIZATION"
    require_bool INCLUDE_PRIVATE "$INCLUDE_PRIVATE"
    require_bool INCLUDE_FORKS "$INCLUDE_FORKS"
    require_bool VERIFY_LFS "$VERIFY_LFS"
    require_bool ALIGN_SCHEDULE "$ALIGN_SCHEDULE"
    if [ "$ALIGN_SCHEDULE" = "true" ] && [ "$BACKUP_INTERVAL" -eq 0 ]; then
        warn "ERROR: ALIGN_SCHEDULE=true requires BACKUP_INTERVAL > 0"
        exit 1
    fi

    check_host_permissions
    if [ -e "$RUNNING" ]; then
        warn "WARNING: found existing $RUNNING (last start: $LAST_START); possible orphan after abrupt shutdown"
        warn "WARNING: leaving the marker intact until the next backup starts; inspect before taking snapshots"
    fi
    trap on_signal TERM INT

    while true; do
        if [ "$ALIGN_SCHEDULE" = "true" ]; then
            until_slot="$(seconds_until_next_slot)"
            log "next aligned UTC/epoch slot in $until_slot seconds"
            run_interruptible sleep "$until_slot"
        fi

        if is_due "$LAST_FULL" "$FULL_INTERVAL"; then
            run_backup full || true
        else
            run_backup incremental || true
        fi

        if [ "$ALIGN_SCHEDULE" = "false" ]; then
            log "next run in $BACKUP_INTERVAL seconds after completion"
            run_interruptible sleep "$BACKUP_INTERVAL"
        fi
    done
}

main
