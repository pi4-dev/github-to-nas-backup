# Restore and Verification Test

A backup job reporting success is not proof that recovery works.

The preferred test reconstructs a repository from the local NAS copy without contacting GitHub.

## 1. Select one repository mirror

Set a variable that points directly at one backed-up Git mirror:

```bash
REPOSITORY_BACKUP=/path/to/backup/repositories/<repository-name>/repository
```

Confirm that it is a bare repository:

```bash
git --git-dir="$REPOSITORY_BACKUP" rev-parse --is-bare-repository
```

Expected result:

```text
true
```

## 2. Verify Git integrity

```bash
git --git-dir="$REPOSITORY_BACKUP" fsck --full
git --git-dir="$REPOSITORY_BACKUP" show-ref
git --git-dir="$REPOSITORY_BACKUP" branch -a
git --git-dir="$REPOSITORY_BACKUP" log --all --oneline --decorate --graph -20
```

Errors such as missing blobs, trees or commits indicate a damaged backup.

Messages about dangling or unreachable objects are not automatically evidence of corruption.

## 3. Create an independent local restore

```bash
RESTORE_DIR=/tmp/github-restore-test

rm -rf "$RESTORE_DIR"

git clone --no-hardlinks   "$REPOSITORY_BACKUP"   "$RESTORE_DIR"
```

`--no-hardlinks` matters for a local disaster-recovery test because it forces Git to create an independent object copy instead of reusing source objects through hard links.

Verify the restored working tree:

```bash
git -C "$RESTORE_DIR" status
git -C "$RESTORE_DIR" branch -a
git -C "$RESTORE_DIR" log --oneline -10
git -C "$RESTORE_DIR" fsck --full
```

## 4. Handle "detected dubious ownership"

Modern Git can reject a repository owned by a different operating-system user:

```text
fatal: detected dubious ownership in repository
```

This is an ownership safety feature. It does not mean that the repository is corrupt.

Trust only the repository being tested:

```bash
git config --global --add safe.directory "$REPOSITORY_BACKUP"
```

Review configured trusted paths:

```bash
git config --global --get-all safe.directory
```

Then repeat the restore test.

Avoid globally disabling the protection with:

```bash
git config --global --add safe.directory '*'
```

Also avoid recursively changing ownership of the live backup merely to make a restore test pass.

## 5. Offline restore test

The strongest practical test disables networking completely:

```bash
docker run --rm \
  --network none \
  -v "$REPOSITORY_BACKUP:/source:ro" \
  --entrypoint sh \
  ghcr.io/josegonzalez/python-github-backup:latest \
  -c '
    set -e
    git config --global --add safe.directory /source
    git clone --no-hardlinks /source /tmp/restore
    git -C /tmp/restore fsck --full
    git -C /tmp/restore log --all --oneline -10
    echo "OFFLINE RESTORE TEST: PASS"
  '
```

This proves that normal Git data can be reconstructed solely from the local copy.

## 6. Git LFS verification

Normal `git fsck` validates Git objects but not all Git LFS payloads.

Check whether LFS is used:

```bash
git --git-dir="$REPOSITORY_BACKUP" lfs ls-files --all
```

If LFS objects are present:

```bash
git --git-dir="$REPOSITORY_BACKUP" lfs fsck
```

Inspect the local LFS store if needed:

```bash
find "$REPOSITORY_BACKUP/lfs/objects" -type f | head
```

## 7. Verify exported metadata

GitHub-side metadata is stored separately from the Git mirror.

Select exported JSON files and confirm that they can be parsed:

```bash
jq . /path/to/exported/metadata.json
```

Issues, Pull Requests, Discussions and related metadata should primarily be treated as an archival record because GitHub APIs cannot recreate every original property exactly.

## 8. Test a historical snapshot

Periodically repeat the same procedure from an older filesystem snapshot rather than from the current live backup.

Recommended workflow:

1. expose or clone an older snapshot to a temporary location;
2. point `REPOSITORY_BACKUP` to a mirror inside that recovery point;
3. run `git fsck --full`;
4. perform the independent local clone;
5. verify LFS when applicable;
6. inspect at least one metadata export.

## Suggested verification schedule

| Test | Frequency |
|---|---|
| Check last successful backup | daily / monitoring |
| Review backup failures | daily / monitoring |
| `git fsck --full` for all mirrors | weekly |
| Offline clone of a rotating repository | weekly |
| LFS verification | weekly or after major changes |
| Restore from a historical snapshot | monthly |
| Broader disaster-recovery exercise | quarterly |

## Acceptance criteria

A repository backup is verified when:

- the mirror opens locally;
- `git fsck --full` reports no corruption;
- expected refs are present;
- an independent clone can be created;
- the clone succeeds without network access;
- LFS payloads are available when required;
- metadata exports are readable;
- at least one historical snapshot has been used successfully for recovery testing.
