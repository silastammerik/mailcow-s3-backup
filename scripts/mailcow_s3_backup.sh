#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

load_env_file() {
  local env_file="${1:-}"

  [[ -f "${env_file}" ]] || return 0

  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  set +a
}

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required binary: $1"
}

trim_trailing_slash() {
  local value="${1:-}"
  printf '%s' "${value%/}"
}

join_remote_path() {
  local left="${1:-}"
  local right="${2:-}"

  left="${left#/}"
  left="${left%/}"
  right="${right#/}"

  if [[ -z "${left}" ]]; then
    printf '%s' "${right}"
  else
    printf '%s/%s' "${left}" "${right}"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/mailcow_s3_backup.sh [--backup]
  ./scripts/mailcow_s3_backup.sh --list
  ./scripts/mailcow_s3_backup.sh --restore <mailcow-backup-directory>
  ./scripts/mailcow_s3_backup.sh --help

Examples:
  ./scripts/mailcow_s3_backup.sh
  ./scripts/mailcow_s3_backup.sh --backup
  ./scripts/mailcow_s3_backup.sh --list
  ./scripts/mailcow_s3_backup.sh --restore mailcow-2026-04-07-12-00-00
EOF
}

build_rclone_copy_args() {
  local source="${1:?source is required}"
  local destination="${2:?destination is required}"

  RCLONE_ARGS=(copy "${source}" "${destination}" --create-empty-src-dirs)

  if [[ -n "${RCLONE_CONFIG_FILE:-}" ]]; then
    RCLONE_ARGS+=(--config "${RCLONE_CONFIG_FILE}")
  fi

  if [[ -n "${RCLONE_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_flags=( ${RCLONE_FLAGS} )
    RCLONE_ARGS+=("${extra_flags[@]}")
  fi
}

build_remote_target() {
  local suffix="${1:-}"
  local remote_base_path
  local remote_path

  remote_base_path="$(join_remote_path "${RCLONE_BUCKET}" "${RCLONE_DESTINATION_PATH}")"
  remote_path="$(join_remote_path "${remote_base_path}" "${suffix}")"
  printf '%s:%s' "${RCLONE_REMOTE}" "${remote_path}"
}

delete_old_local_backups() {
  local retention_days="${1:-}"

  [[ -z "${retention_days}" ]] && return 0
  [[ "${retention_days}" =~ ^[0-9]+$ ]] || fail "LOCAL_RETENTION_DAYS must be a non-negative integer"
  [[ "${retention_days}" -gt 0 ]] || return 0

  log "Deleting local backup directories older than ${retention_days} days"
  find "${MAILCOW_BACKUP_LOCATION}" -mindepth 1 -maxdepth 1 -type d -name 'mailcow-*' -mtime +"${retention_days}" -print -exec rm -rf {} +
}

run_backup() {
  local before_latest
  local after_latest
  local backup_dir
  local backup_name
  local remote_target

  before_latest="$(
    find "${MAILCOW_BACKUP_LOCATION}" -mindepth 1 -maxdepth 1 -type d -name 'mailcow-*' -print 2>/dev/null \
      | sort \
      | tail -n 1
  )"

  log "Starting Mailcow backup using ${MAILCOW_BACKUP_SCRIPT}"
  MAILCOW_BACKUP_LOCATION="${MAILCOW_BACKUP_LOCATION}" THREADS="${THREADS}" \
    "${MAILCOW_BACKUP_SCRIPT}" backup "${MAILCOW_BACKUP_TARGET}"

  after_latest="$(
    find "${MAILCOW_BACKUP_LOCATION}" -mindepth 1 -maxdepth 1 -type d -name 'mailcow-*' -print 2>/dev/null \
      | sort \
      | tail -n 1
  )"

  [[ -n "${after_latest}" ]] || fail "No Mailcow backup directory was created"
  [[ "${after_latest}" != "${before_latest}" || ! -e "${before_latest}" ]] || fail "Backup completed but no new backup directory was detected"

  backup_dir="${after_latest}"
  backup_name="$(basename "${backup_dir}")"
  remote_target="$(build_remote_target "${backup_name}")"

  build_rclone_copy_args "${backup_dir}" "${remote_target}"

  log "Uploading ${backup_name} to ${remote_target}"
  rclone "${RCLONE_ARGS[@]}"

  if [[ "${DELETE_LOCAL_AFTER_UPLOAD}" == "true" ]]; then
    log "Upload succeeded, deleting local backup directory ${backup_dir}"
    rm -rf "${backup_dir}"
  fi

  delete_old_local_backups "${LOCAL_RETENTION_DAYS}"

  log "Backup completed successfully"
}

run_restore() {
  local restore_name="${1:-}"
  local remote_target
  local local_restore_dir

  [[ -n "${restore_name}" ]] || fail "Restore mode requires a backup directory name, e.g. --restore mailcow-2026-04-07-12-00-00"
  [[ "${restore_name}" != */* ]] || fail "Restore name must be a single backup directory name, not a path"

  remote_target="$(build_remote_target "${restore_name}")"
  local_restore_dir="${MAILCOW_BACKUP_LOCATION}/${restore_name}"

  if [[ -d "${local_restore_dir}" ]]; then
    log "Using existing local restore directory ${local_restore_dir}"
  else
    if [[ -e "${local_restore_dir}" ]]; then
      fail "Local restore path exists but is not a directory: ${local_restore_dir}"
    fi

    log "Downloading ${restore_name} from ${remote_target} to ${local_restore_dir}"
    build_rclone_copy_args "${remote_target}" "${local_restore_dir}"
    rclone "${RCLONE_ARGS[@]}"

    [[ -d "${local_restore_dir}" ]] || fail "Restore download did not create ${local_restore_dir}"
  fi

  log "Starting Mailcow restore using ${MAILCOW_BACKUP_SCRIPT}"
  MAILCOW_BACKUP_LOCATION="${MAILCOW_BACKUP_LOCATION}" THREADS="${THREADS}" \
    "${MAILCOW_BACKUP_SCRIPT}" restore
}

run_list() {
  local remote_target

  remote_target="$(build_remote_target "")"

  log "Listing backups in ${remote_target}"
  rclone lsd "${remote_target}"
}

load_env_file "${PROJECT_ROOT}/.env"
if [[ "${PWD}" != "${PROJECT_ROOT}" ]]; then
  load_env_file "${PWD}/.env"
fi

OPERATION="backup"
RESTORE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      OPERATION="backup"
      shift
      ;;
    --restore)
      OPERATION="restore"
      shift
      [[ $# -gt 0 ]] || fail "--restore requires a backup directory name"
      RESTORE_NAME="$1"
      shift
      ;;
    --list)
      OPERATION="list"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

MAILCOW_BACKUP_SCRIPT="${MAILCOW_BACKUP_SCRIPT:-/opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh}"
MAILCOW_BACKUP_LOCATION="${MAILCOW_BACKUP_LOCATION:-/var/backups/mailcow}"
MAILCOW_BACKUP_TARGET="${MAILCOW_BACKUP_TARGET:-all}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_BUCKET="${RCLONE_BUCKET:-}"
RCLONE_DESTINATION_PATH="${RCLONE_DESTINATION_PATH:-}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-}"
RCLONE_FLAGS="${RCLONE_FLAGS:-}"
DELETE_LOCAL_AFTER_UPLOAD="${DELETE_LOCAL_AFTER_UPLOAD:-false}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-}"
THREADS="${THREADS:-1}"

require_bin bash
require_bin rclone

[[ -x "${MAILCOW_BACKUP_SCRIPT}" ]] || fail "MAILCOW_BACKUP_SCRIPT is not executable: ${MAILCOW_BACKUP_SCRIPT}"
[[ -n "${RCLONE_REMOTE}" ]] || fail "RCLONE_REMOTE is required"
[[ -n "${RCLONE_BUCKET}" ]] || fail "RCLONE_BUCKET is required"
[[ "${MAILCOW_BACKUP_LOCATION}" = /* ]] || fail "MAILCOW_BACKUP_LOCATION must be an absolute path"
[[ "${MAILCOW_BACKUP_TARGET}" =~ ^(crypt|vmail|redis|rspamd|postfix|mysql|all)$ ]] || fail "MAILCOW_BACKUP_TARGET has an invalid value"
[[ "${THREADS}" =~ ^[1-9][0-9]*$ ]] || fail "THREADS must be a positive integer"

mkdir -p "${MAILCOW_BACKUP_LOCATION}"
MAILCOW_BACKUP_LOCATION="$(trim_trailing_slash "${MAILCOW_BACKUP_LOCATION}")"

case "${OPERATION}" in
  backup)
    run_backup
    ;;
  list)
    run_list
    ;;
  restore)
    run_restore "${RESTORE_NAME}"
    ;;
  *)
    fail "Unsupported operation: ${OPERATION}"
    ;;
esac
