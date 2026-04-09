# mailcow-s3-backup

Wrapper around the official Mailcow backup script that uploads the generated backup set to an S3-compatible object store through `rclone`.

## What It Does

This project supports two backup modes:

- Full backup: runs Mailcow's official `backup_and_restore.sh` and uploads the generated `mailcow-<timestamp>` directory.
- Granular domain backup: exports a custom package for one domain, including mailbox metadata, maildirs, sieve filters, and SOGo user data for the users in that domain.

## Requirements

- `bash`
- `docker`
- `rclone`
- A working Mailcow installation with `helper-scripts/backup_and_restore.sh`

## Quick Start

1. Copy `.env.example` to `.env`.
2. Adjust the `rclone` and Mailcow paths.
3. Run the script:

```bash
# Full backup
./scripts/mailcow_s3_backup.sh

# Full backup list
./scripts/mailcow_s3_backup.sh --list

# Full restore
./scripts/mailcow_s3_backup.sh --restore mailcow-2026-04-07-12-00-00

# Granular domain backup
./scripts/mailcow_s3_backup.sh --backup --domain example.com

# Granular backup list for a domain
./scripts/mailcow_s3_backup.sh --list --domain example.com

# Granular mailbox restore from the latest backup of a domain
./scripts/mailcow_s3_backup.sh --restore --domain example.com --user alice
```

The script automatically loads `.env` from the project root when present.

## Main Variables

- `MAILCOW_BACKUP_SCRIPT`: Absolute path to Mailcow's `backup_and_restore.sh`
- `MAILCOW_BACKUP_LOCATION`: Local staging directory used by the Mailcow script
- `RCLONE_REMOTE`: Name of the configured `rclone` remote
- `RCLONE_BUCKET`: Bucket name to use inside the configured `rclone` remote
- `RCLONE_DESTINATION_PATH`: Optional path inside the remote
- `RCLONE_CONFIG_FILE`: Optional explicit path to `rclone.conf`
- `RCLONE_FLAGS`: Optional extra flags passed to `rclone copy`
- `DELETE_LOCAL_AFTER_UPLOAD`: Remove the local backup after a successful upload. Default: `true`
- `LOCAL_RETENTION_DAYS`: Optional local retention for older `mailcow-*` directories

## Notes

- The script uploads the full generated backup directory so all Mailcow backup artifacts stay grouped under one timestamp.
- Granular domain backups are stored separately under `granular/` in the same configured S3 path.
- Mailcow creates the backup locally first in `MAILCOW_BACKUP_LOCATION`, then the script uploads it to S3.
- Uploads and downloads through `rclone` run with `--progress`, so you can monitor transfer progress directly in the terminal.
- By default, the local backup is deleted after a successful upload to avoid consuming disk space. Set `DELETE_LOCAL_AFTER_UPLOAD=false` in `.env` if you want to keep local copies.
- When `DELETE_LOCAL_AFTER_UPLOAD=true`, a later `--restore` will download the selected backup from S3 again before starting the Mailcow restore flow.
- Credentials and provider-specific settings are handled by the configured `rclone` remote; the destination bucket is selected via `RCLONE_BUCKET`.

## List Backups

Use `--list` to show the available full `mailcow-*` backup directories in the configured bucket path.

```bash
./scripts/mailcow_s3_backup.sh --list
```

To list granular backups for a specific domain:

```bash
./scripts/mailcow_s3_backup.sh --list --domain example.com
```

## Restore

Use the same script with `--restore <mailcow-backup-directory>`. It will download the selected full backup from the configured bucket to `MAILCOW_BACKUP_LOCATION` and then call Mailcow's official restore flow.

Example:

```bash
# List available backups in the bucket
./scripts/mailcow_s3_backup.sh --list

# Download and restore one backup
./scripts/mailcow_s3_backup.sh --restore mailcow-2026-04-07-12-00-00
```

Important:

- Run restore from the actual Mailcow installation directory and use the original `helper-scripts/backup_and_restore.sh`.
- The target Mailcow instance should already be installed, initialized, and running before restore.
- The final `backup_and_restore.sh restore` step remains interactive, because that is Mailcow's native restore behavior.
- If the local directory `${MAILCOW_BACKUP_LOCATION}/<backup-name>` already exists, the script reuses it and skips the download step.
- If `RCLONE_DESTINATION_PATH` is empty, omit that path segment from the `rclone` commands above.
- For large restores, ensure `MAILCOW_BACKUP_LOCATION` has enough free disk space for the full extracted backup.

For the official Mailcow restore behavior and prerequisites, see:
- https://docs.mailcow.email/backup_restore/b_n_r-backup/
- https://docs.mailcow.email/de/backup_restore/b_n_r-restore/

## Granular Domain Backup

Use `--backup --domain <domain>` to create a domain-scoped backup package. This custom backup mode includes:

- SQL metadata needed for the domain and its mailboxes
- Maildir contents for the mailboxes in the domain
- User sieve files
- SOGo user exports for the mailboxes in the domain

Example:

```bash
./scripts/mailcow_s3_backup.sh --backup --domain example.com
```

Important:

- This mode is separate from Mailcow's native full backup and restore flow.
- The current granular restore path restores a single mailbox from a domain backup.
- The script reads `mailcow.conf` from the Mailcow installation to access the Mailcow database and Docker volumes.

## Granular Mailbox Restore

Use `--restore --domain <domain> --user <mailbox|localpart>` to restore a single mailbox from the latest granular backup available for that domain. If you need a specific backup version, pass `--backup-name`.

Examples:

```bash
# Restore from the latest granular backup for the domain
./scripts/mailcow_s3_backup.sh --restore --domain example.com --user alice

# Restore from a specific granular backup directory
./scripts/mailcow_s3_backup.sh \
  --restore \
  --domain example.com \
  --user alice@example.com \
  --backup-name mailcow-domain-example-com-2026-04-07-16-00-00
```

Important:

- If `--user` is given as only the local part, the script automatically expands it to `<user>@<domain>`.
- The restore imports mailbox metadata, restores the maildir, restores the user sieve files, restores SOGo data when present, and then runs `doveadm force-resync` and `doveadm quota recalc`.
- If the latest granular backup is not present locally, the script downloads it from S3 first.
- Granular restore currently targets one mailbox at a time, not a full domain restore in a single command.

## Example Rclone Setup

```bash
rclone config create mailcow-backups s3 \
  provider Minio \
  env_auth false \
  access_key_id YOUR_KEY \
  secret_access_key YOUR_SECRET \
  endpoint https://s3.example.com
```

Then set `RCLONE_REMOTE=mailcow-backups` and `RCLONE_BUCKET=<your-bucket-name>` in `.env`.
