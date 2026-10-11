# Snapshot Strategy

The live backup follows the current state of GitHub. That is useful for fast recovery, but it is not an immutable historical archive.

If a branch is deleted, a tag is removed, history is rewritten or a repository is damaged upstream, a later synchronization can reproduce that state locally.

Filesystem snapshots preserve older generations of the backup.

## Protection layers

```text
GitHub
  |
  v
Live NAS backup
  |
  v
Filesystem snapshots
  |
  v
Independent / off-site copy
```

Each layer protects against a different failure mode.

### Live backup

Protects primarily against:

- repository deletion;
- loss of access to GitHub;
- service-side problems;
- the need for fast local recovery.

### Snapshots

Protect primarily against:

- deleted branches or tags;
- force-push and history rewrite;
- destructive changes already propagated into the live mirror;
- accidental local deletion;
- a bad backup run;
- delayed discovery of corruption.

### Independent copy

Protects against:

- NAS hardware loss;
- storage-pool failure;
- theft;
- fire or flood;
- site-wide failure.

Snapshots stored on the same NAS are not an off-site backup.

## Recommended retention

A balanced GFS-style policy is:

| Snapshot class | Frequency | Retention | Approximate count |
|---|---:|---:|---:|
| Short-term | every 6 hours | 48 hours | 8 |
| Daily | once per day | 14 days | 14 |
| Weekly | once per week | 8 weeks | 8 |
| Monthly | once per month | 12 months | 12 |

This gives dense recovery points near the present and progressively sparser history further back.

## Why 6-hour snapshots for 48 hours?

Most destructive mistakes are noticed quickly:

- accidental branch deletion;
- incorrect force-push;
- bad backup update;
- mistaken repository removal.

Six-hour generations provide good short-term rollback granularity.

## Why 14 daily snapshots?

Not every problem is discovered immediately.

A missing branch, release asset or metadata object may only be noticed several days later.

Two weeks of daily restore points cover this common detection window.

## Why 8 weekly snapshots?

Weekly restore points provide roughly two months of medium-term history.

They are useful when an old branch, release or metadata object is discovered missing weeks after the original event.

## Why 12 monthly snapshots?

Monthly restore points provide useful long-term history without retaining every short-term generation indefinitely.

## Snapshot timing and safe-run checks

Prefer snapshots taken after a successful backup run. Even an atomic filesystem snapshot may contain an **inconsistent in-progress backup** (partially updated Git pack files, refs, LFS data or metadata).

The default scheduler waits `BACKUP_INTERVAL` **after** backup and optional verification finish. Its wall-clock start times drift; a NAS snapshot at fixed times is not guaranteed to follow a complete backup. Set `ALIGN_SCHEDULE=true` for UTC epoch-aligned slots, e.g. `BACKUP_INTERVAL=21600` gives **00/06/12/18 UTC**. Missed slots are skipped if a run is still executing. Local snapshot hours change with daylight saving time.

An illustrative fixed snapshot schedule is **05/11/17/23 UTC**, but only if the preceding backup finishes within five hours. **Never rely on a fixed delay alone.** Before creating a snapshot, the NAS job should confirm:

1. `status/running` does **not** exist (covers backup, verification and notifications).
2. `status/last-success` exists and its mtime is **at least** that of `status/last-start` (the latest started GitHub backup completed successfully).
3. `status/last-failure` is absent; optionally require a fresh `last-verify-success` when a verified snapshot is needed.

`status/last-start` and `status/running` are created together at the start of each cycle. `running` is removed on normal completion, handled failures and SIGTERM/SIGINT. A power loss or SIGKILL can leave an **orphaned running marker**. Treat it as a reason to defer snapshots and investigate `last-start`, logs and process status. After restart an orphan is logged and retained until the next backup starts.

These filesystem marker checks are **advisory rather than an atomic lock**: a backup can begin between a NAS-side check and the snapshot operation. When strict consistency is required, serialize snapshots and backup starts using a shared lock, or trigger the snapshot via a completion hook with mutual exclusion. Monitor snapshot freshness and alert if checks prevent snapshots for too long.

## Recovery objectives

With `BACKUP_INTERVAL=21600`, aligned starts offer a nominal 6-hour cadence **only if runs finish within one slot**. Without alignment, the interval is measured from the end of each run. With overruns, failures or skipped slots, the actual RPO can exceed six hours; monitor the age of `last-success`.

The local Git mirror usually gives a short RTO for restoring an individual repository.

Restoring a complete GitHub account, including metadata, takes longer and cannot reproduce every GitHub-side attribute exactly.

## Storage behaviour

Copy-on-write snapshots initially consume little extra space because unchanged blocks are shared.

Space usage grows when live data changes.

Git workloads deserve attention because:

- fetches add pack files;
- repacks can rewrite large pack files;
- Git LFS objects can be large;
- release assets and attachments can be large;
- deleting live data does not free blocks still referenced by snapshots.

Monitor real allocated space and free capacity, not only the apparent size of the live backup tree.

## Git garbage collection

A Git repack can rewrite a large amount of data.

With snapshots retained, old pack files may remain referenced while new pack files are written to the live backup.

Therefore:

- avoid unnecessary aggressive `git gc`;
- check free space before bulk maintenance;
- understand that snapshots can retain pre-repack packs;
- expire snapshots according to policy.

## Recovery workflow

When a destructive change is discovered:

1. pause scheduled backup activity if further synchronization could remove useful history;
2. determine approximately when the unwanted change occurred;
3. select the newest snapshot from before the incident;
4. expose or copy the snapshot to a temporary recovery location;
5. run Git integrity checks;
6. create an independent local clone;
7. recover only the required refs or repository when possible;
8. resume scheduled backup only after the desired state is restored.

Do not overwrite the live backup before validating the selected recovery point.

## Verification

Snapshots should be tested, not merely counted.

Recommended baseline:

| Verification | Frequency |
|---|---|
| Git integrity check | weekly |
| Local/offline restore of a rotating repository | weekly |
| Restore from an older snapshot | monthly |
| Broader disaster-recovery exercise | quarterly |

## Extra manual snapshots

Create an additional recovery point before:

- upgrading backup software;
- changing token permissions;
- changing backup flags;
- reorganizing backup storage;
- bulk Git maintenance;
- migrating the storage pool;
- changing retention policy;
- large cleanup operations.

## Policy summary

```text
Backup:
  incremental        every 6 hours after completion by default; UTC slots when aligned
  full metadata      every 7 days

Snapshots:
  short-term         every 6 hours, keep 48 hours
  daily              keep 14 days
  weekly             keep 8 weeks
  monthly            keep 12 months

Verification:
  git fsck           weekly
  local restore      weekly
  snapshot restore   monthly
  broader DR test    quarterly

Off-site:
  maintain an independent copy when the data is important
```

> The live mirror protects against losing the remote source. Snapshots protect against losing yesterday. An independent copy protects against losing the NAS.
