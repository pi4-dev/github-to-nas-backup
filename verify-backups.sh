#!/bin/sh
# Integrity verification of a backup produced by backup-loop.sh.
#
# Checks, in order:
#   1. git fsck --full for every mirror in $BACKUP_ROOT/repositories/*/repository
#   2. every exported *.json file parses (and at least one exists)
#   3. every Git LFS object matches the SHA-256 in its file name
#      (skipped when VERIFY_LFS=false; hashing large stores takes a while)
#
# Exit status is non-zero if anything is missing or corrupt.

set -eu

BACKUP_ROOT="${BACKUP_ROOT:?Set BACKUP_ROOT to the backup data directory}"
VERIFY_LFS="${VERIFY_LFS:-true}"

found=0
failures=0

echo "Starting repository integrity verification."

for repo in "$BACKUP_ROOT"/repositories/*/repository; do
    [ -d "$repo" ] || continue
    found=1

    echo
    echo "=== Git fsck: $repo ==="

    # safe.directory is set per repository because the backup is owned by a
    # different user than the one running the check; avoids a global '*'.
    if git -c safe.directory="$repo" --git-dir="$repo" fsck --full; then
        echo "PASS"
    else
        echo "FAIL" >&2
        failures=$((failures + 1))
    fi
done

echo

if [ "$found" -eq 0 ]; then
    echo "No repository mirrors found under: $BACKUP_ROOT/repositories" >&2
    exit 1
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures repository mirror(s) failed git fsck." >&2
    exit 1
fi

echo "All Git mirrors passed git fsck --full."
echo
echo "Validating JSON metadata and Git LFS object hashes."

python - "$BACKUP_ROOT" "$VERIFY_LFS" <<'PY'
import hashlib
import json
import os
import re
import sys

backup_root, verify_lfs = sys.argv[1], sys.argv[2] == "true"
json_checked = 0
lfs_checked = 0
errors = []

# Layout written by git-lfs: <repo>/lfs/objects/<oid[0:2]>/<oid[2:4]>/<oid>
LFS_DIR = re.compile(r"/lfs/objects/[0-9a-f]{2}/[0-9a-f]{2}$")
OID = re.compile(r"[0-9a-f]{64}")


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


for directory, _, filenames in os.walk(backup_root):
    is_lfs = verify_lfs and LFS_DIR.search(directory.replace(os.sep, "/"))

    for filename in filenames:
        path = os.path.join(directory, filename)

        if filename.endswith(".json"):
            json_checked += 1
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    json.load(handle)
            except Exception as exc:
                errors.append(f"Invalid JSON: {path}: {exc}")

        if is_lfs and OID.fullmatch(filename):
            lfs_checked += 1
            try:
                actual = sha256_of(path)
            except Exception as exc:
                errors.append(f"Cannot read LFS object: {path}: {exc}")
                continue

            if actual != filename:
                errors.append(
                    f"LFS SHA-256 mismatch: {path}: "
                    f"expected {filename}, got {actual}"
                )

print(f"JSON files checked: {json_checked}")
print(f"LFS objects checked: {lfs_checked}" if verify_lfs else "LFS check skipped")

# A backup without any exported metadata is incomplete, not "valid".
if json_checked == 0:
    errors.append(f"No JSON metadata files found under: {backup_root}")

if errors:
    for error in errors:
        print(error, file=sys.stderr)
    raise SystemExit(1)
PY

echo
echo "Backup verification completed successfully."
