#!/bin/sh
# Regression checks for GH_TOKEN_TYPE: strict validation and safe CLI selection.
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
[ "$(tail -n 1 backup-loop.sh)" = main ] || { echo "Unexpected backup-loop.sh entrypoint" >&2; exit 1; }
sed '$d' backup-loop.sh > "$tmp/functions.sh"
GH_ACCOUNT=ci
# shellcheck disable=SC1091
. "$tmp/functions.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# A misspelling must fail before permissions checks or backup activity.
for value in '' Fine CLASSIC yes 1; do
    if output="$(env GH_ACCOUNT=ci "GH_TOKEN_TYPE=$value" sh ./backup-loop.sh 2>&1)"; then
        fail "invalid token type accepted: $value"
    fi
    expected="ERROR: GH_TOKEN_TYPE must be 'fine' or 'classic', got '$value'"
    printf '%s\n' "$output" | grep -Fq "$expected" || fail "unexpected diagnostic: $output"
done

# Intercept the actual command argv without invoking GitHub or reading a token.
TOKEN_FILE="$tmp/test-token"
run_interruptible() {
    case "$GH_TOKEN_TYPE:$EXPECTED_FLAG" in
        fine:--token-fine | classic:--token) ;;
        *) fail "token mode/flag expectation mismatch" ;;
    esac
    [ "$1" = github-backup ] || fail "unexpected executable: $1"
    shift
    [ "$1" = "$GH_ACCOUNT" ] || fail "wrong account: $1"
    shift
    [ "$1" = "$EXPECTED_FLAG" ] || fail "wrong token flag: $1"
    shift
    [ "$1" = "file://$TOKEN_FILE" ] || fail "token secret not passed as file URI"
    shift
    for arg do
        case "$arg" in
            --token | --token-fine) fail "unexpected duplicate authentication flag: $arg" ;;
        esac
    done
}

GH_TOKEN_TYPE=fine
EXPECTED_FLAG=--token-fine
run_github_backup full
run_github_backup incremental
GH_TOKEN_TYPE=classic
EXPECTED_FLAG=--token
run_github_backup full
run_github_backup incremental

echo "PASS: fine/classic token selection and startup validation"
