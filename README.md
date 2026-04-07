# mailcow-s3-backup

Wrapper around the official Mailcow backup script that uploads the generated backup set to an S3-compatible object store through `rclone`.

## What It Does

This project does not replace Mailcow's backup logic. It runs the official `backup_and_restore.sh` script and then uploads the generated `mailcow-<timestamp>` directory through a configured `rclone` remote into an explicitly configured bucket.

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
# Backup
./scripts/mailcow_s3_backup.sh

# List available backups
./scripts/mailcow_s3_backup.sh --list

# Restore a specific backup
./scripts/mailcow_s3_backup.sh --restore mailcow-2026-04-07-12-00-00
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
- `DELETE_LOCAL_AFTER_UPLOAD`: Remove the local backup after a successful upload when set to `true`
- `LOCAL_RETENTION_DAYS`: Optional local retention for older `mailcow-*` directories

## Notes

- The script uploads the full generated backup directory so all Mailcow backup artifacts stay grouped under one timestamp.
- Credentials and provider-specific settings are handled by the configured `rclone` remote; the destination bucket is selected via `RCLONE_BUCKET`.

## List Backups

Use `--list` to show the available `mailcow-*` backup directories in the configured bucket path.

```bash
./scripts/mailcow_s3_backup.sh --list
```

## Restore

Use the same script with `--restore <mailcow-backup-directory>`. It will download the selected backup from the configured bucket to `MAILCOW_BACKUP_LOCATION` and then call Mailcow's official restore flow.

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
- If the local directory `${MAILCOW_BACKUP_LOCATION}/<backup-name>` already exists, the script aborts instead of overwriting it.
- If `RCLONE_DESTINATION_PATH` is empty, omit that path segment from the `rclone` commands above.
- For large restores, ensure `MAILCOW_BACKUP_LOCATION` has enough free disk space for the full extracted backup.

For the official Mailcow restore behavior and prerequisites, see:
- https://docs.mailcow.email/backup_restore/b_n_r-backup/
- https://docs.mailcow.email/de/backup_restore/b_n_r-restore/

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
