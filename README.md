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
3. Load the environment and run:

```bash
set -a
source .env
set +a

./scripts/mailcow_s3_backup.sh
```

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
- Restore from S3 is not implemented in this repository yet.

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
