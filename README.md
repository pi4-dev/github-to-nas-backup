# GitHub to NAS Backup

Generic Docker-based backup of a GitHub user or organization to local NAS storage.

The project uses `josegonzalez/python-github-backup` and is designed to preserve both Git data and GitHub-side metadata.

## What is backed up

The default configuration includes:

- public repositories
- private repositories visible to the token
- forks
- full Git mirrors
- all refs
- Git LFS objects
- wikis
- Issues, comments, events and timelines
- Pull Requests, reviews, comments and commits
- labels and milestones
- Discussions
- Releases and release assets
- attachments where GitHub permits access

The upstream `--bare` option creates a real Git mirror using `git clone --mirror`.

### Token type and private repository attachments

`GH_TOKEN_TYPE=fine` (default) uses upstream `--token-fine`; `GH_TOKEN_TYPE=classic` uses upstream `--token`. Both options load the credential from the **same Docker secret** (`secrets/github_token`) via `file:///run/secrets/github_token`. The token value is not stored in the environment file or passed as a literal command-line argument. Replace the contents of the secret with a token of the matching type when switching.

**Known upstream/GitHub limitation:** fine-grained personal access tokens cannot directly download user-uploaded attachments from **private repositories**. Upstream implements a GitHub Markdown API workaround for images, but **non-image attachments such as PDFs and text files return HTTP 404**. These may be missing from a backup even when other repository content is available. For comprehensive attachment coverage of private repositories, upstream recommends a **classic personal access token**. This choice is not a guarantee that every remote attachment will remain available; inspect attachment manifests and errors. Details: [upstream attachment documentation](https://github.com/josegonzalez/python-github-backup#about-attachments).

Classic PATs generally require the broad `repo` scope to access private repositories and therefore carry greater risk than fine-grained PATs. Use the least privilege available for your requirements, restrict and rotate credentials, and authorize organization SSO where applicable. **Changing `GH_TOKEN_TYPE` does not convert the existing token**; configure a real token of the selected type in `secrets/github_token`.

## Protection model

```text
GitHub
   |
   | pull backup
   v
Local NAS backup
   |
   +-- Git mirrors
   +-- Git LFS
   +-- GitHub metadata
   |
   v
Filesystem snapshots
   |
   v
Optional off-site backup
```

The live backup protects against losing GitHub data. Snapshots preserve older states after deletions or history rewrites propagate into the mirror. An independent copy protects against loss of the NAS itself.

## Files

```text
docker-compose.yaml                service definition
backup-loop.sh                     entrypoint: scheduling, markers, keepalive, verification
verify-backups.sh                  integrity verifier (also usable manually)
github-to-nas-backup.env.example   unified settings (copy to github-to-nas-backup.env)
secrets/              github_token goes here (git-ignored)
.github/workflows/    ShellCheck + compose validation
docs/
  RESTORE-TEST.md
  SNAPSHOT-STRATEGY.md
```

Runtime state markers are written to `<BACKUP_HOST_PATH>/status/` on the NAS.

## Quick start

Copy the templates:

```bash
cp github-to-nas-backup.env.example github-to-nas-backup.env
```

Edit `github-to-nas-backup.env`:

- `BACKUP_HOST_PATH` - absolute NAS path for backup data
- `BACKUP_IMAGE_TAG` - optional upstream image tag
- `GH_ACCOUNT` - GitHub user or organization
- `GH_TOKEN_TYPE` - `fine` (default) or `classic`; match the secret's token
- `GH_ORGANIZATION=true` when backing up an organization
- optional scheduling, verification, selection and keepalive settings

`docker-compose.yaml` includes `github-to-nas-backup.env` as a service-level `env_file`. **That does not provide variables for Compose interpolation** (including the backup volume's host path and image tag). Always pass the same file with `docker compose --env-file ./github-to-nas-backup.env ...`. The old `.env` and `*-app.env` configuration files are no longer used. Git ignores the real configuration file, but tracks the `.example`.

Create the token secret:

```bash
mkdir -p secrets
printf '%s\n' 'YOUR_GITHUB_TOKEN' > secrets/github_token
sudo chown 1000:1000 secrets/github_token
sudo chmod 400 secrets/github_token
```

Use a fine-grained Personal Access Token with read permissions where possible. Typical permissions are read access to Contents, Metadata, Issues, Pull Requests and Discussions. If private-repository **document attachments** must be included, see the classic-token limitation and permissions discussion above.

### NAS filesystem permissions (UID/GID)

The upstream `josegonzalez/python-github-backup` image runs as `appuser` with **UID 1000 and GID 1000**. This Compose setup uses that account (no `user:` override). Both the GitHub token and `/data` must therefore be accessible to **1000:1000**, regardless of the NAS login user's UID/GID (for example, Synology users may start at UID 1026).

With ordinary Docker Compose (non-Swarm), a secret declared with `file:` is mounted from the host, retaining its host filesystem permissions. **`chmod 600` alone is insufficient** when the token file belongs to another UID. The Quick start uses `chown 1000:1000` plus `chmod 400` so only UID 1000 can read the token; no write permission inside the container is needed.

Create a **dedicated backup directory** matching `BACKUP_HOST_PATH` in `github-to-nas-backup.env` and make it writable by UID 1000:

```bash
sudo mkdir -p /absolute/path/to/backup/storage
sudo chown -R 1000:1000 /absolute/path/to/backup/storage
sudo chmod u+rwx /absolute/path/to/backup/storage
```

Replace the example path with the **exact** value of `BACKUP_HOST_PATH`. The recursive `chown` is intended only for a dedicated backup tree (including pre-existing `status/` and repository data), **not** a shared NAS directory. Parent directories must also allow traversal. On a NAS using ACLs, NFS/SMB mounts, or Docker user-namespace remapping, adjust the effective host UID/GID or grant equivalent permissions through the NAS ACLs instead of assuming `chown` will work.

Check access with the actual container user **before** starting scheduled backups:

```bash
docker compose --env-file ./github-to-nas-backup.env run --rm --entrypoint /bin/sh github-to-nas-backup -ec '
  id
  test -r /run/secrets/github_token || { echo "GitHub token is unreadable" >&2; exit 1; }
  test -w /data || { echo "Backup directory is not writable" >&2; exit 1; }
  mkdir -p /data/status
  test -w /data/status || { echo "Status directory is not writable" >&2; exit 1; }
  echo "Permissions OK"
'
```

The entrypoint also checks these permissions at startup and exits with an actionable error instead of repeatedly attempting backups with an unreadable token or unwritable storage. Do not add a configurable `user:` override without validating the upstream image's home directory and its runtime write paths for the chosen UID.

Start the service:

```bash
docker compose --env-file ./github-to-nas-backup.env config
docker compose --env-file ./github-to-nas-backup.env pull
docker compose --env-file ./github-to-nas-backup.env up -d
```

Follow logs:

```bash
docker compose --env-file ./github-to-nas-backup.env logs -f github-to-nas-backup
```

When upgrading from the previous Compose service name `github-backup`, remove the old orphaned service so it does not run concurrently against the same backup storage:

```bash
docker compose --env-file ./github-to-nas-backup.env up -d --remove-orphans
```

## Container log rotation

The service pins Docker's `json-file` logging driver and rotates container stdout/stderr logs with `max-size: "10m"` and `max-file: "5"` (approximately 50 MB of log files per container, excluding filesystem overhead). This prevents GitHub repository-by-repository progress output from growing without bound, regardless of the Docker daemon's default logging configuration. It does not rotate the actual backup data stored in `BACKUP_HOST_PATH`.

After updating the Compose file on the NAS, recreate the container to apply its new logging configuration (this briefly stops the running backup):

```bash
docker compose --env-file ./github-to-nas-backup.env up -d --force-recreate
docker inspect github-to-nas-backup --format '{{json .HostConfig.LogConfig}}'
```

The inspect output should show `json-file`, `max-size=10m` and `max-file=5`. Existing unbounded historical log files are not retroactively rotated; recreation replaces the old container and its logs.

## Container healthcheck

Docker Compose reports `healthy` when `status/last-success` exists and its modification time is less than **three times `BACKUP_INTERVAL`** old (default: 18 hours). Future-dated timestamps are rejected. This is a **backup freshness** signal, not a guarantee of archive integrity: a running backup or failed verification can coexist with `healthy` as long as the previous success is fresh. For detailed monitoring, continue to track the `running`, `last-failure` and `last-verify-success` markers and the success keepalive.

The built-in check runs every **15 minutes**, has a **10-second timeout**, and uses a **24-hour start period** to allow an initial full backup to finish (including the wait for the first UTC slot if `ALIGN_SCHEDULE=true`). During this grace period failures do not immediately mark the container unhealthy. A first full backup lasting longer than 24 hours may still cause an `unhealthy` status; adapt the start period on large installations if needed.

The threshold is based on elapsed seconds, so drift in unaligned mode, repeated retries, or missed aligned slots can make a still-running process `unhealthy` when no successful backup has completed recently. This is intentional: monitor **successful backup age**, not only process liveness. Docker’s `restart: unless-stopped` does not automatically restart an unhealthy but running container.

Inspect the health status after recreating the service:

```bash
docker compose --env-file ./github-to-nas-backup.env up -d --force-recreate
docker inspect github-to-nas-backup --format '{{json .State.Health}}'
```

## Configuration reference

All settings live in `github-to-nas-backup.env`, loaded through service `env_file` and also passed with `--env-file` for Compose interpolation. Keep the GitHub token in `secrets/github_token`, not in the environment file. Times are in seconds.

| Variable | Default | Meaning |
|---|---|---|
| `GH_ACCOUNT` | required | GitHub user or organization |
| `GH_TOKEN_TYPE` | `fine` | `fine` → `--token-fine`; `classic` → `--token` (required for private repository non-image attachments) |
| `GH_ORGANIZATION` | `false` | `true` when the account is an organization |
| `BACKUP_HOST_PATH` | required | Host path mounted as `/data` |
| `BACKUP_IMAGE_TAG` | `latest` | Image tag; pin a release for reproducibility |
| `INCLUDE_PRIVATE` / `INCLUDE_FORKS` | `true` | Include private repositories / forks |
| `GH_EXTRA_ARGS` | empty | Extra flags passed to `github-backup` |
| `BACKUP_INTERVAL` | `21600` (6 h) | Seconds between aligned slots, or sleep duration after a successful run in default mode |
| `RETRY_INTERVAL` | `1800` (30 min) | Delay after a failed GitHub backup before the next attempt; must be greater than zero |
| `ALIGN_SCHEDULE` | `false` | `true` to align starts to UTC epoch boundaries; requires `BACKUP_INTERVAL > 0` |
| `FULL_INTERVAL` | `604800` (7 d) | Age after which a non-incremental run is done |
| `KEEPALIVE_URL`, `KEEPALIVE_TIMEOUT` | empty, `10` | Success ping after a backup |
| `VERIFY_INTERVAL` | `604800` (7 d) | Time between verifications; `0` = every backup |
| `VERIFY_LFS` | `true` | Re-hash all LFS objects during verification |
| `VERIFY_KEEPALIVE_URL`, `VERIFY_KEEPALIVE_TIMEOUT` | empty, `10` | Success ping after verification |

Interval values are validated at startup; a non-numeric value stops the container with an error. The boolean options `GH_ORGANIZATION`, `INCLUDE_PRIVATE`, `INCLUDE_FORKS`, `VERIFY_LFS` and `ALIGN_SCHEDULE` also require **exactly** lowercase `true` or `false`. Other spellings (`True`, `yes`, `1`) and explicitly empty values stop the container **before backup execution**, rather than silently excluding private repositories, forks, organization mode or LFS verification. Unset boolean options retain the defaults shown in the table. `GH_TOKEN_TYPE` likewise accepts only the exact values `fine` or `classic`; invalid or explicitly empty values fail during startup.

The container handles `docker stop` gracefully: the running `github-backup` is terminated and the loop exits immediately.

## Optional success keepalive

An optional HTTP GET notification can be sent after a backup finishes successfully.

Configure it in `github-to-nas-backup.env`:

```dotenv
KEEPALIVE_URL=https://example.invalid/your-monitoring-endpoint
KEEPALIVE_TIMEOUT=10
```

Leave `KEEPALIVE_URL` empty to disable the feature.

The URL is called only after:

1. `github-backup` exits successfully;
2. the local success marker is updated;
3. any previous failure marker is removed;
4. the full-backup marker is updated when applicable.

If the backup fails, the keepalive URL is **not called**.

If the backup succeeds but the keepalive endpoint itself fails or times out, the backup remains successful and the notification failure is logged as a warning. The URL itself is not written to the log.

This makes the option suitable for success-ping services such as self-hosted monitoring endpoints or health-check systems.

## Backup schedule and activity markers

By default (`ALIGN_SCHEDULE=false`), the first backup starts immediately. **After a successful backup**, the next run begins `BACKUP_INTERVAL` seconds after the cycle finishes, including optional verification and notifications. With a 6-hour interval and a 40-minute run, starts are roughly 6 h 40 min apart; wall-clock start times drift.

If `github-backup` fails (nonzero exit), the next attempt is scheduled **`RETRY_INTERVAL` seconds after the failed run ends**. The default is 1800 seconds (30 minutes); consecutive failures each retry after that delay. `RETRY_INTERVAL` must be a positive integer. The retry runs the same full/incremental mode selection based on the existing `last-full` timestamp, so a failed full backup is retried as full. The `last-failure` marker persists until GitHub backup succeeds, and failure never sends `KEEPALIVE_URL`.

A verification failure is tracked separately by `last-verify-failure` and **does not trigger a GitHub backup retry** when the backup itself succeeded; verification runs again after the next successful scheduled backup.

For fixed UTC-aligned start slots, configure:

```dotenv
BACKUP_INTERVAL=21600
ALIGN_SCHEDULE=true
```

This schedules normal starts at **00:00 / 06:00 / 12:00 / 18:00 UTC** (epoch multiples of 21600 s). The first run waits until the **next** slot, even if the container starts exactly on a boundary. Long-running backups **never overlap**: missed slots are skipped. On failure, the `RETRY_INTERVAL` countdown **overrides alignment**, allowing a retry between regular slots. After a successful retry, scheduling resumes at the next future aligned slot (without an immediate extra run). Timezone and DST do not change the UTC slots; local times in Europe/Warsaw shift between CET and CEST. When aligned, `BACKUP_INTERVAL` must be greater than zero; `ALIGN_SCHEDULE` accepts exactly `true` or `false`.

The first executed run is full; further non-incremental refreshes are due when `FULL_INTERVAL` elapses (default 7 days).

The wrapper uses these status files under `BACKUP_HOST_PATH/status/`:

```text
status/running                exists while backup and post-backup verification run
status/last-start             touched at start of every run
status/last-full              last successful full run
status/last-success           last successful GitHub backup
status/last-failure           last failed GitHub backup (cleared on success)
status/last-verify-success    last successful integrity verification
status/last-verify-failure    last failed verification
```

`status/running` is removed after a successful or failed backup cycle and on normal SIGTERM/SIGINT shutdown. An abrupt crash, SIGKILL or power loss can leave it behind; compare its mtime with `last-start`, recent logs and container status. On restart an existing marker is reported and preserved until a new run begins, rather than being silently treated as a live backup.

**Snapshot automation should check more than a clock:** `running` must be absent, a fresh `last-success` must exist for the latest `last-start`, and ideally there should be no `last-failure`. In aligned mode, 05:00 / 11:00 / 17:00 / 23:00 **UTC** are illustrative snapshot slots *only if* backups finish within five hours. A status check and snapshot are not atomic, so a race remains if a backup starts between them; for strict exclusion use a coordinated lock or an explicit snapshot hook after completion. See [docs/SNAPSHOT-STRATEGY.md](docs/SNAPSHOT-STRATEGY.md).

## Automated verification

Verification is automatically executed after a successful backup when `VERIFY_INTERVAL` has elapsed.

Default:

```dotenv
VERIFY_INTERVAL=604800
```

This means a full verification runs once every 7 days. Set:

```dotenv
VERIFY_INTERVAL=0
```

to verify after every successful backup.

The verifier checks:

1. every repository and wiki Git mirror with `git fsck --full --no-dangling` (ignoring harmless dangling-object messages);
2. every exported `.json` metadata file by parsing it;
3. every stored Git LFS object by recalculating its SHA-256 hash and comparing it with the LFS object ID.

If any repository, JSON document or LFS object fails verification, the verification run fails.

A failed verification does **not** turn a successfully completed backup job into a failed backup. Instead:

- `status/last-verify-failure` is updated;
- `status/last-verify-success` is not updated;
- the verification keepalive is not sent;
- verification is retried after the next successful backup.

Verification only runs after a successful backup. If backups keep failing, verification does not run either, so monitor `status/last-success` (or the backup keepalive) as well.

Verification fails if no mirrors or no JSON metadata are found, so an empty or partial backup is never reported as valid. Set `VERIFY_LFS=false` to skip LFS hashing on very large stores (the weekly run reads every LFS object).

### Verification keepalive

Verification has its own independent success URL:

```dotenv
VERIFY_KEEPALIVE_URL=https://example.invalid/verification-monitor
VERIFY_KEEPALIVE_TIMEOUT=10
```

Leave `VERIFY_KEEPALIVE_URL` empty to disable it.

The verification URL is called **only if all verification checks pass**.

This is intentionally independent from `KEEPALIVE_URL`:

```text
KEEPALIVE_URL
    = backup command completed successfully

VERIFY_KEEPALIVE_URL
    = stored backup passed integrity verification
```

Therefore an external monitoring system can distinguish between:

- "a new backup was created successfully", and
- "the stored backup has also been independently verified".

The verification keepalive URL itself is not printed to the logs.

### Manual verification

Verification can also be started manually:

```bash
BACKUP_ROOT=/path/to/backup/storage sh ./verify-backups.sh
```

A stronger reconstruction test is documented in [docs/RESTORE-TEST.md](docs/RESTORE-TEST.md).

## Snapshots

Recommended baseline:

| Class | Frequency | Retention |
|---|---:|---:|
| Short-term | every 6 hours | 48 hours |
| Daily | once per day | 14 days |
| Weekly | once per week | 8 weeks |
| Monthly | once per month | 12 months |

See [docs/SNAPSHOT-STRATEGY.md](docs/SNAPSHOT-STRATEGY.md).

## Important limitation

Git repositories can be restored directly.

GitHub metadata such as Issues, Pull Requests and Discussions is primarily an archive. GitHub APIs do not allow exact recreation of original numbers, authors, timestamps and every relationship.

## Disaster-recovery rule

A backup is not considered verified merely because the backup command succeeded.

It is verified when useful data can be reconstructed from the local copy without contacting GitHub.
