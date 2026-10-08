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
compose.yaml          service definition
backup-loop.sh        entrypoint: scheduling, markers, keepalive, verification
verify-backups.sh     integrity verifier (also usable manually)
.env.example          compose-level settings (copy to .env)
app.env.example       application settings (copy to <COMPOSE_PROJECT_NAME>-app.env)
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
cp .env.example .env
cp app.env.example github-backup-app.env   # name: ${COMPOSE_PROJECT_NAME}-app.env
```

Edit `.env` (compose-level settings):

- `COMPOSE_PROJECT_NAME` - selects the application file `${COMPOSE_PROJECT_NAME}-app.env`
- `BACKUP_HOST_PATH` - absolute NAS path for backup data
- optional `BACKUP_IMAGE_TAG`

Edit `<COMPOSE_PROJECT_NAME>-app.env` (application settings):

- the GitHub user or organization (`GH_ACCOUNT`)
- whether the target is an organization (`GH_ORGANIZATION=true`)
- optional timezone and scheduling intervals

Create the token secret:

```bash
mkdir -p secrets
printf '%s\n' 'YOUR_GITHUB_TOKEN' > secrets/github_token
chmod 600 secrets/github_token
```

Use a read-only fine-grained Personal Access Token where possible. Typical permissions are read access to Contents, Metadata, Issues, Pull Requests and Discussions.

Start the service:

```bash
docker compose config
docker compose pull
docker compose up -d
```

Follow logs:

```bash
docker compose logs -f github-backup
```

## Configuration reference

Application settings are environment variables in `<COMPOSE_PROJECT_NAME>-app.env` (loaded via `env_file`, values are literal - no `${VAR}` interpolation). `BACKUP_HOST_PATH` and `BACKUP_IMAGE_TAG` stay in `.env`. Times are in seconds.

| Variable | Default | Meaning |
|---|---|---|
| `GH_ACCOUNT` | required | GitHub user or organization |
| `GH_ORGANIZATION` | `false` | `true` when the account is an organization |
| `BACKUP_HOST_PATH` (`.env`) | required | Host path mounted as `/data` |
| `BACKUP_IMAGE_TAG` (`.env`) | `latest` | Image tag; pin a release for reproducibility |
| `INCLUDE_PRIVATE` / `INCLUDE_FORKS` | `true` | Include private repositories / forks |
| `GH_EXTRA_ARGS` | empty | Extra flags passed to `github-backup` |
| `BACKUP_INTERVAL` | `21600` (6 h) | Pause between runs |
| `FULL_INTERVAL` | `604800` (7 d) | Age after which a non-incremental run is done |
| `KEEPALIVE_URL`, `KEEPALIVE_TIMEOUT` | empty, `10` | Success ping after a backup |
| `VERIFY_INTERVAL` | `604800` (7 d) | Time between verifications; `0` = every backup |
| `VERIFY_LFS` | `true` | Re-hash all LFS objects during verification |
| `VERIFY_KEEPALIVE_URL`, `VERIFY_KEEPALIVE_TIMEOUT` | empty, `10` | Success ping after verification |

Interval values are validated at start-up; a non-numeric value stops the container with an error.

The container handles `docker stop` gracefully: the running `github-backup` is terminated and the loop exits immediately.

## Optional success keepalive

An optional HTTP GET notification can be sent after a backup finishes successfully.

Configure it in the app env file:

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

## Default schedule

```text
Incremental backup: every 6 hours
Full metadata refresh: every 7 days
```

The first run is full.

The wrapper records:

```text
status/last-full
status/last-success
status/last-failure
status/last-verify-success
status/last-verify-failure
```

These files can be monitored externally.

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

1. every Git mirror with `git fsck --full`;
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
