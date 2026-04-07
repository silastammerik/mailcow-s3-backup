#!/usr/bin/env bash

set -Eeuo pipefail

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

build_rclone_args() {
  RCLONE_ARGS=(copy "${backup_dir}" "${remote_target}" --create-empty-src-dirs)

  if [[ -n "${RCLONE_CONFIG_FILE:-}" ]]; then
    RCLONE_ARGS+=(--config "${RCLONE_CONFIG_FILE}")
  fi

  if [[ -n "${RCLONE_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_flags=( ${RCLONE_FLAGS} )
    RCLONE_ARGS+=("${extra_flags[@]}")
  fi
}

delete_old_local_backups() {
  local retention_days="${1:-}"

  [[ -z "${retention_days}" ]] && return 0
  [[ "${retention_days}" =~ ^[0-9]+$ ]] || fail "LOCAL_RETENTION_DAYS must be a non-negative integer"
  [[ "${retention_days}" -gt 0 ]] || return 0

  log "Deleting local backup directories older than ${retention_days} days"
  find "${MAILCOW_BACKUP_LOCATION}" -mindepth 1 -maxdepth 1 -type d -name 'mailcow-*' -mtime +"${retention_days}" -print -exec rm -rf {} +
}

MAILCOW_BACKUP_SCRIPT="${MAILCOW_BACKUP_SCRIPT:-/opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh}"
MAILCOW_BACKUP_LOCATION="${MAILCOW_BACKUP_LOCATION:-/var/backups/mailcow}"
MAILCOW_BACKUP_TARGET="${MAILCOW_BACKUP_TARGET:-all}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
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
[[ "${MAILCOW_BACKUP_LOCATION}" = /* ]] || fail "MAILCOW_BACKUP_LOCATION must be an absolute path"
[[ "${MAILCOW_BACKUP_TARGET}" =~ ^(crypt|vmail|redis|rspamd|postfix|mysql|all)$ ]] || fail "MAILCOW_BACKUP_TARGET has an invalid value"
[[ "${THREADS}" =~ ^[1-9][0-9]*$ ]] || fail "THREADS must be a positive integer"

mkdir -p "${MAILCOW_BACKUP_LOCATION}"
MAILCOW_BACKUP_LOCATION="$(trim_trailing_slash "${MAILCOW_BACKUP_LOCATION}")"

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
remote_path="$(join_remote_path "${RCLONE_DESTINATION_PATH}" "${backup_name}")"
remote_target="${RCLONE_REMOTE}:${remote_path}"

build_rclone_args

log "Uploading ${backup_name} to ${remote_target}"
rclone "${RCLONE_ARGS[@]}"

if [[ "${DELETE_LOCAL_AFTER_UPLOAD}" == "true" ]]; then
  log "Upload succeeded, deleting local backup directory ${backup_dir}"
  rm -rf "${backup_dir}"
fi

delete_old_local_backups "${LOCAL_RETENTION_DAYS}"

log "Backup completed successfully"
