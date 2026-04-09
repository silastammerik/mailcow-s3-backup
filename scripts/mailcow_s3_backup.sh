#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MAILCOW_CONF_LOADED=false
MAILCOW_PROJECT_DIR=""
CMPS_PRJ=""
MYSQL_CONTAINER_ID=""
DOVECOT_CONTAINER_ID=""
SOGO_CONTAINER_ID=""
VMAIL_VOLUME_MOUNTPOINT=""
SOGO_CONFIG_DIR=""
SQL_IMAGE=""
SOURCE_DBROOT=""
SOURCE_DBNAME=""
FULL_RESTORE_STAGE_ROOT=""
FULL_RESTORE_TEMP_DB_DIR=""
FULL_RESTORE_TEMP_DB_CONTAINER=""
DEBUG="${DEBUG:-false}"

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

cleanup_temp_resources() {
  if [[ -n "${FULL_RESTORE_TEMP_DB_CONTAINER}" ]]; then
    docker rm -f "${FULL_RESTORE_TEMP_DB_CONTAINER}" >/dev/null 2>&1 || true
    FULL_RESTORE_TEMP_DB_CONTAINER=""
  fi

  if [[ -n "${FULL_RESTORE_STAGE_ROOT}" && -d "${FULL_RESTORE_STAGE_ROOT}" ]]; then
    rm -rf "${FULL_RESTORE_STAGE_ROOT}" >/dev/null 2>&1 || true
    FULL_RESTORE_STAGE_ROOT=""
  fi
}

trap cleanup_temp_resources EXIT

require_bin() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required binary: $1"
}

run_quiet_command() {
  local description="${1:?description is required}"
  shift
  local log_file

  log "${description}"

  if [[ "${DEBUG}" == "true" ]]; then
    "$@"
    return 0
  fi

  log_file="$(mktemp)"

  if "$@" >"${log_file}" 2>&1; then
    rm -f "${log_file}"
    return 0
  fi

  cat "${log_file}" >&2
  rm -f "${log_file}"
  fail "${description} failed"
}

run_filtered_command() {
  local description="${1:?description is required}"
  local filter_pattern="${2:?filter_pattern is required}"
  shift 2
  local log_file

  log "${description}"

  if [[ "${DEBUG}" == "true" ]]; then
    "$@"
    return 0
  fi

  log_file="$(mktemp)"

  if "$@" >"${log_file}" 2>&1; then
    grep -Ev "${filter_pattern}" "${log_file}" || true
    rm -f "${log_file}"
    return 0
  fi

  cat "${log_file}" >&2
  rm -f "${log_file}"
  fail "${description} failed"
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
  elif [[ -z "${right}" ]]; then
    printf '%s' "${left}"
  else
    printf '%s/%s' "${left}" "${right}"
  fi
}

sanitize_name() {
  local value="${1:-}"

  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]')"
  value="$(printf '%s' "${value}" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${value}"
}

sql_escape() {
  local value="${1:-}"

  value="${value//\'/\'\'}"
  printf '%s' "${value}"
}

normalize_mailbox_user() {
  local domain="${1:-}"
  local user="${2:-}"
  local user_domain

  [[ -n "${domain}" ]] || fail "Domain is required"
  [[ -n "${user}" ]] || fail "User is required"

  if [[ "${user}" == *"@"* ]]; then
    user_domain="${user##*@}"
    [[ "${user_domain}" == "${domain}" ]] || fail "User ${user} does not belong to domain ${domain}"
    printf '%s' "${user}"
    return 0
  fi

  printf '%s@%s' "${user}" "${domain}"
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/mailcow_s3_backup.sh [--backup]
  ./scripts/mailcow_s3_backup.sh --backup --domain <domain>
  ./scripts/mailcow_s3_backup.sh --list
  ./scripts/mailcow_s3_backup.sh --list --domain <domain>
  ./scripts/mailcow_s3_backup.sh --restore <mailcow-backup-directory>
  ./scripts/mailcow_s3_backup.sh --restore-domain-from-full <mailcow-backup-directory> --domain <domain> [--user <mailbox|localpart>]
  ./scripts/mailcow_s3_backup.sh --restore --domain <domain> --user <mailbox|localpart> [--backup-name <granular-backup-directory>]
  ./scripts/mailcow_s3_backup.sh --debug ...
  ./scripts/mailcow_s3_backup.sh --help

Examples:
  ./scripts/mailcow_s3_backup.sh
  ./scripts/mailcow_s3_backup.sh --backup --domain example.com
  ./scripts/mailcow_s3_backup.sh --list
  ./scripts/mailcow_s3_backup.sh --list --domain example.com
  ./scripts/mailcow_s3_backup.sh --restore mailcow-2026-04-07-12-00-00
  ./scripts/mailcow_s3_backup.sh --restore-domain-from-full mailcow-2026-04-07-12-00-00 --domain example.com
  ./scripts/mailcow_s3_backup.sh --restore --domain example.com --user alice
  ./scripts/mailcow_s3_backup.sh --debug --restore-domain-from-full mailcow-2026-04-07-12-00-00 --domain example.com --user alice
EOF
}

build_rclone_copy_args() {
  local source="${1:?source is required}"
  local destination="${2:?destination is required}"

  RCLONE_ARGS=(copy "${source}" "${destination}" --create-empty-src-dirs --progress)

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

list_remote_backup_dirs() {
  local remote_target="${1:?remote_target is required}"

  rclone lsf -R "${remote_target}" 2>/dev/null \
    | awk -F/ 'NF > 1 { print $1 }' \
    | sed '/^$/d' \
    | sort -u
}

delete_old_local_backups() {
  local retention_days="${1:-}"

  [[ -z "${retention_days}" ]] && return 0
  [[ "${retention_days}" =~ ^[0-9]+$ ]] || fail "LOCAL_RETENTION_DAYS must be a non-negative integer"
  [[ "${retention_days}" -gt 0 ]] || return 0

  log "Deleting local backup directories older than ${retention_days} days"
  find "${MAILCOW_BACKUP_LOCATION}" -mindepth 1 -maxdepth 1 -type d -name 'mailcow-*' -mtime +"${retention_days}" -print -exec rm -rf {} +
}

resolve_mailcow_project_dir() {
  local helper_dir

  helper_dir="$(cd "$(dirname "${MAILCOW_BACKUP_SCRIPT}")" && pwd)"
  printf '%s' "$(cd "${helper_dir}/.." && pwd)"
}

load_mailcow_conf() {
  local conf_file

  [[ "${MAILCOW_CONF_LOADED}" == "true" ]] && return 0

  MAILCOW_PROJECT_DIR="$(resolve_mailcow_project_dir)"
  conf_file="${MAILCOW_PROJECT_DIR}/mailcow.conf"

  [[ -f "${conf_file}" ]] || fail "mailcow.conf not found: ${conf_file}"

  # shellcheck disable=SC1090
  source "${conf_file}"

  [[ -n "${COMPOSE_PROJECT_NAME:-}" ]] || fail "COMPOSE_PROJECT_NAME is missing in ${conf_file}"
  [[ -n "${DBROOT:-}" ]] || fail "DBROOT is missing in ${conf_file}"
  [[ -n "${DBNAME:-}" ]] || fail "DBNAME is missing in ${conf_file}"

  CMPS_PRJ="$(printf '%s' "${COMPOSE_PROJECT_NAME}" | tr -cd '0-9A-Za-z-_')"
  SOGO_CONFIG_DIR="${MAILCOW_PROJECT_DIR}/data/conf/sogo"

  MAILCOW_CONF_LOADED=true
}

get_container_id() {
  local pattern="${1:?pattern is required}"
  local container_id

  container_id="$(docker ps -qf "name=${pattern}" | head -n 1)"
  [[ -n "${container_id}" ]] || fail "Could not find running container matching ${pattern}"

  printf '%s' "${container_id}"
}

load_mailcow_runtime() {
  load_mailcow_conf

  [[ -n "${MYSQL_CONTAINER_ID}" ]] || MYSQL_CONTAINER_ID="$(get_container_id "mysql-mailcow")"
  [[ -n "${DOVECOT_CONTAINER_ID}" ]] || DOVECOT_CONTAINER_ID="$(get_container_id "dovecot-mailcow")"
  [[ -n "${SOGO_CONTAINER_ID}" ]] || SOGO_CONTAINER_ID="$(get_container_id "sogo-mailcow")"
  [[ -n "${VMAIL_VOLUME_MOUNTPOINT}" ]] || VMAIL_VOLUME_MOUNTPOINT="$(docker volume inspect "${CMPS_PRJ}_vmail-vol-1" --format '{{ .Mountpoint }}')"

  [[ -d "${VMAIL_VOLUME_MOUNTPOINT}" ]] || fail "Could not access vmail volume mountpoint"
  [[ -d "${SOGO_CONFIG_DIR}" ]] || fail "SOGo config directory not found: ${SOGO_CONFIG_DIR}"
}

get_sql_image() {
  load_mailcow_conf

  if [[ -z "${SQL_IMAGE}" ]]; then
    SQL_IMAGE="$(grep -iEo '(mysql|mariadb)\:.+' "${MAILCOW_PROJECT_DIR}/docker-compose.yml" | head -n 1)"
  fi

  [[ -n "${SQL_IMAGE}" ]] || fail "Could not determine SQL image from docker-compose.yml"
  printf '%s' "${SQL_IMAGE}"
}

mysql_query() {
  local sql="${1:?sql is required}"

  docker exec "${MYSQL_CONTAINER_ID}" mariadb -N -uroot "-p${DBROOT}" "${DBNAME}" -e "${sql}"
}

mysql_import_file() {
  local sql_file="${1:?sql_file is required}"

  [[ -f "${sql_file}" ]] || return 0
  docker exec -i "${MYSQL_CONTAINER_ID}" mariadb -uroot "-p${DBROOT}" "${DBNAME}" < "${sql_file}"
}

delete_rows_if_table_exists() {
  local table="${1:?table is required}"
  local where_clause="${2:?where_clause is required}"

  table_exists "${table}" || return 0
  mysql_query "DELETE FROM \`${table}\` WHERE ${where_clause};" >/dev/null
}

table_exists() {
  local table="${1:?table is required}"
  local escaped_table

  escaped_table="$(sql_escape "${table}")"
  [[ -n "$(mysql_query "SHOW TABLES LIKE '${escaped_table}';")" ]]
}

source_mysql_query() {
  local sql="${1:?sql is required}"

  docker exec "${FULL_RESTORE_TEMP_DB_CONTAINER}" mariadb -N -uroot "-p${SOURCE_DBROOT}" "${SOURCE_DBNAME}" -e "${sql}"
}

source_table_exists() {
  local table="${1:?table is required}"
  local escaped_table

  escaped_table="$(sql_escape "${table}")"
  [[ -n "$(source_mysql_query "SHOW TABLES LIKE '${escaped_table}';")" ]]
}

append_source_table_dump() {
  local table="${1:?table is required}"
  local where_clause="${2:?where_clause is required}"
  local output_file="${3:?output_file is required}"
  local count

  source_table_exists "${table}" || return 0

  count="$(source_mysql_query "SELECT COUNT(*) FROM \`${table}\` WHERE ${where_clause};" | tr -d '[:space:]')"
  [[ "${count:-0}" =~ ^[0-9]+$ ]] || fail "Could not count source rows in table ${table}"
  [[ "${count}" -gt 0 ]] || return 0

  docker exec "${FULL_RESTORE_TEMP_DB_CONTAINER}" mariadb-dump \
    -uroot "-p${SOURCE_DBROOT}" "${SOURCE_DBNAME}" \
    --no-create-info \
    --skip-triggers \
    --complete-insert \
    --replace \
    --skip-comments \
    "${table}" \
    "--where=${where_clause}" >> "${output_file}"

  printf '\n' >> "${output_file}"
}

get_archive_info() {
  local backup_name="${1:?backup_name is required}"
  local location="${2:?location is required}"

  if [[ -f "${location}/${backup_name}.tar.zst" ]]; then
    printf '%s|%s\n' "${location}/${backup_name}.tar.zst" "zstd -d -T${THREADS}"
  elif [[ -f "${location}/${backup_name}.tar.gz" ]]; then
    printf '%s|%s\n' "${location}/${backup_name}.tar.gz" "pigz -d -p ${THREADS}"
  else
    printf '\n'
  fi
}

ensure_full_backup_available() {
  local backup_name="${1:?backup_name is required}"
  local remote_target
  local local_restore_dir

  [[ "${backup_name}" != */* ]] || fail "Backup name must be a single directory name, not a path"

  remote_target="$(build_remote_target "${backup_name}")"
  local_restore_dir="${MAILCOW_BACKUP_LOCATION}/${backup_name}"

  if [[ -d "${local_restore_dir}" ]]; then
    printf '%s' "${local_restore_dir}"
    return 0
  fi

  if [[ -e "${local_restore_dir}" ]]; then
    fail "Local restore path exists but is not a directory: ${local_restore_dir}"
  fi

  log "Downloading ${backup_name} from ${remote_target} to ${local_restore_dir}"
  build_rclone_copy_args "${remote_target}" "${local_restore_dir}"
  rclone "${RCLONE_ARGS[@]}"

  [[ -d "${local_restore_dir}" ]] || fail "Restore download did not create ${local_restore_dir}"
  printf '%s' "${local_restore_dir}"
}

extract_archive_to_dir() {
  local archive_file="${1:?archive_file is required}"
  local decompress_prog="${2:?decompress_prog is required}"
  local destination_dir="${3:?destination_dir is required}"
  local log_file

  mkdir -p "${destination_dir}"

  if [[ "${DEBUG}" == "true" ]]; then
    tar -C "${destination_dir}" --use-compress-program="${decompress_prog}" -xf "${archive_file}"
    return 0
  fi

  log_file="$(mktemp)"

  if tar -C "${destination_dir}" --use-compress-program="${decompress_prog}" -xf "${archive_file}" >"${log_file}" 2>&1; then
    awk '
      /decompression does not support multi-threading/ { next }
      /Removing leading `\/'\'' from member names/ { next }
      { print }
    ' "${log_file}"
    rm -f "${log_file}"
    return 0
  fi

  cat "${log_file}" >&2
  rm -f "${log_file}"
  fail "Failed to extract archive ${archive_file}"
}

load_backup_mailcow_conf() {
  local backup_dir="${1:?backup_dir is required}"
  local backup_conf="${backup_dir}/mailcow.conf"

  [[ -f "${backup_conf}" ]] || fail "mailcow.conf not found in full backup: ${backup_conf}"

  SOURCE_DBROOT="$(source "${backup_conf}" >/dev/null 2>&1; printf '%s' "${DBROOT:-}")"
  SOURCE_DBNAME="$(source "${backup_conf}" >/dev/null 2>&1; printf '%s' "${DBNAME:-mailcow}")"

  [[ -n "${SOURCE_DBROOT}" ]] || fail "DBROOT not found in backup mailcow.conf"
  [[ -n "${SOURCE_DBNAME}" ]] || fail "DBNAME not found in backup mailcow.conf"
}

wait_for_source_db() {
  local tries=0

  until docker exec "${FULL_RESTORE_TEMP_DB_CONTAINER}" mariadb -N -uroot "-p${SOURCE_DBROOT}" "${SOURCE_DBNAME}" -e "SELECT 1;" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [[ "${tries}" -lt 60 ]] || fail "Temporary MariaDB from full backup did not become ready"
    sleep 1
  done
}

prepare_full_backup_stage() {
  local backup_name="${1:?backup_name is required}"
  local local_backup_dir
  local archive_info
  local archive_file
  local decompress_prog
  local sql_image

  cleanup_temp_resources
  load_mailcow_runtime

  local_backup_dir="$(ensure_full_backup_available "${backup_name}")"
  load_backup_mailcow_conf "${local_backup_dir}"

  FULL_RESTORE_STAGE_ROOT="$(mktemp -d "${MAILCOW_BACKUP_LOCATION}/restore-from-full-${backup_name}.XXXXXX")"

  archive_info="$(get_archive_info "backup_vmail" "${local_backup_dir}")"
  [[ -n "${archive_info}" ]] || fail "No backup_vmail archive found in ${local_backup_dir}"
  archive_file="${archive_info%%|*}"
  decompress_prog="${archive_info#*|}"
  log "Extracting vmail data from ${backup_name}"
  extract_archive_to_dir "${archive_file}" "${decompress_prog}" "${FULL_RESTORE_STAGE_ROOT}/extracted"
  [[ -d "${FULL_RESTORE_STAGE_ROOT}/extracted/vmail" ]] || fail "Extracted full backup is missing vmail data"

  archive_info="$(get_archive_info "backup_mariadb" "${local_backup_dir}")"
  [[ -n "${archive_info}" ]] || fail "No backup_mariadb archive found in ${local_backup_dir}"
  archive_file="${archive_info%%|*}"
  decompress_prog="${archive_info#*|}"
  log "Extracting MariaDB data from ${backup_name}"
  extract_archive_to_dir "${archive_file}" "${decompress_prog}" "${FULL_RESTORE_STAGE_ROOT}/extracted"
  [[ -d "${FULL_RESTORE_STAGE_ROOT}/extracted/backup_mariadb" ]] || fail "Extracted full backup is missing mariadb data"

  FULL_RESTORE_TEMP_DB_DIR="${FULL_RESTORE_STAGE_ROOT}/mysql-datadir"
  mkdir -p "${FULL_RESTORE_TEMP_DB_DIR}"

  sql_image="$(get_sql_image)"

  run_quiet_command "Preparing temporary MariaDB datadir from full backup" \
    docker run --rm --entrypoint= \
      -v "${FULL_RESTORE_STAGE_ROOT}/extracted/backup_mariadb:/backup_mariadb:ro" \
      -v "${FULL_RESTORE_TEMP_DB_DIR}:/var/lib/mysql:rw" \
      "${sql_image}" \
      /bin/sh -c "mariabackup --copy-back --target-dir=/backup_mariadb --datadir=/var/lib/mysql && chown -R 999:999 /var/lib/mysql"

  FULL_RESTORE_TEMP_DB_CONTAINER="mailcow-full-restore-${RANDOM}-$$"
  log "Starting temporary MariaDB from staged full backup"
  docker run -d --rm \
    --name "${FULL_RESTORE_TEMP_DB_CONTAINER}" \
    -v "${FULL_RESTORE_TEMP_DB_DIR}:/var/lib/mysql:rw" \
    "${sql_image}" >/dev/null

  wait_for_source_db
}

append_table_dump() {
  local table="${1:?table is required}"
  local where_clause="${2:?where_clause is required}"
  local output_file="${3:?output_file is required}"
  local count

  table_exists "${table}" || return 0

  count="$(mysql_query "SELECT COUNT(*) FROM \`${table}\` WHERE ${where_clause};" | tr -d '[:space:]')"
  [[ "${count:-0}" =~ ^[0-9]+$ ]] || fail "Could not count rows in table ${table}"
  [[ "${count}" -gt 0 ]] || return 0

  docker exec "${MYSQL_CONTAINER_ID}" mariadb-dump \
    -uroot "-p${DBROOT}" "${DBNAME}" \
    --no-create-info \
    --skip-triggers \
    --complete-insert \
    --replace \
    --skip-comments \
    "${table}" \
    "--where=${where_clause}" >> "${output_file}"

  printf '\n' >> "${output_file}"
}

copy_path_if_exists() {
  local source_path="${1:?source_path is required}"
  local destination_dir="${2:?destination_dir is required}"

  [[ -e "${source_path}" ]] || return 0

  mkdir -p "${destination_dir}"
  cp -a "${source_path}" "${destination_dir}/"
}

backup_sogo_user() {
  local mailbox_user="${1:?mailbox_user is required}"
  local output_dir="${2:?output_dir is required}"
  local sogo_export_file

  sogo_export_file="${SOGO_CONFIG_DIR}/${mailbox_user}"
  rm -f "${sogo_export_file}"

  if docker exec -u sogo "${SOGO_CONTAINER_ID}" sogo-tool backup /etc/sogo "${mailbox_user}" >/dev/null 2>&1; then
    if [[ -f "${sogo_export_file}" ]]; then
      mkdir -p "${output_dir}"
      cp -a "${sogo_export_file}" "${output_dir}/"
      rm -f "${sogo_export_file}"
    fi
  else
    log "Skipping SOGo export for ${mailbox_user}"
    rm -f "${sogo_export_file}"
  fi
}

write_granular_manifest() {
  local manifest_file="${1:?manifest_file is required}"
  local backup_name="${2:?backup_name is required}"
  local domain="${3:?domain is required}"
  shift 3
  local users=( "$@" )

  {
    printf 'backup_type=domain\n'
    printf 'backup_name=%s\n' "${backup_name}"
    printf 'domain=%s\n' "${domain}"
    printf 'created_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'users=%s\n' "$(IFS=,; printf '%s' "${users[*]}")"
  } > "${manifest_file}"
}

granular_backup_prefix() {
  local domain="${1:?domain is required}"
  printf 'mailcow-domain-%s-' "$(sanitize_name "${domain}")"
}

find_latest_local_granular_backup() {
  local domain="${1:?domain is required}"
  local granular_root="${MAILCOW_BACKUP_LOCATION}/granular"
  local prefix

  prefix="$(granular_backup_prefix "${domain}")"
  [[ -d "${granular_root}" ]] || return 0

  find "${granular_root}" -mindepth 1 -maxdepth 1 -type d -name "${prefix}*" -print 2>/dev/null | sort | tail -n 1
}

find_latest_remote_granular_backup_name() {
  local domain="${1:?domain is required}"
  local prefix
  local remote_target

  prefix="$(granular_backup_prefix "${domain}")"
  remote_target="$(build_remote_target "granular")"

  list_remote_backup_dirs "${remote_target}" | grep "^${prefix}" | sort | tail -n 1 || true
}

download_granular_backup_if_needed() {
  local backup_name="${1:?backup_name is required}"
  local local_backup_dir="${MAILCOW_BACKUP_LOCATION}/granular/${backup_name}"
  local remote_backup_dir

  if [[ -d "${local_backup_dir}" ]]; then
    printf '%s' "${local_backup_dir}"
    return 0
  fi

  mkdir -p "${MAILCOW_BACKUP_LOCATION}/granular"
  remote_backup_dir="$(build_remote_target "granular/${backup_name}")"

  log "Downloading granular backup ${backup_name} from ${remote_backup_dir}"
  build_rclone_copy_args "${remote_backup_dir}" "${local_backup_dir}"
  rclone "${RCLONE_ARGS[@]}"

  [[ -d "${local_backup_dir}" ]] || fail "Granular backup download did not create ${local_backup_dir}"
  printf '%s' "${local_backup_dir}"
}

cleanup_user_metadata() {
  local mailbox_user="${1:?mailbox_user is required}"
  local escaped_user

  escaped_user="$(sql_escape "${mailbox_user}")"

  delete_rows_if_table_exists "alias" "\`address\` = '${escaped_user}' OR FIND_IN_SET('${escaped_user}', REPLACE(\`goto\`, ' ', '')) > 0"
  delete_rows_if_table_exists "pushover" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "quarantine" "\`rcpt\` = '${escaped_user}'"
  delete_rows_if_table_exists "quota2" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "quota2replica" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "mailbox" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "sender_acl" "\`logged_in_as\` = '${escaped_user}' OR \`send_as\` = '${escaped_user}'"
  delete_rows_if_table_exists "user_acl" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "spamalias" "\`goto\` = '${escaped_user}' OR \`address\` = '${escaped_user}'"
  delete_rows_if_table_exists "imapsync" "\`user2\` = '${escaped_user}'"
  delete_rows_if_table_exists "filterconf" "\`object\` = '${escaped_user}'"
  delete_rows_if_table_exists "bcc_maps" "\`local_dest\` = '${escaped_user}' OR \`bcc_dest\` = '${escaped_user}'"
  delete_rows_if_table_exists "oauth_access_tokens" "\`user_id\` = '${escaped_user}'"
  delete_rows_if_table_exists "oauth_refresh_tokens" "\`user_id\` = '${escaped_user}'"
  delete_rows_if_table_exists "oauth_authorization_codes" "\`user_id\` = '${escaped_user}'"
  delete_rows_if_table_exists "tfa" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "fido2" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "app_passwd" "\`mailbox\` = '${escaped_user}'"
  delete_rows_if_table_exists "sieve_filters" "\`username\` = '${escaped_user}'"
  delete_rows_if_table_exists "sogo_user_profile" "\`c_uid\` = '${escaped_user}'"
  delete_rows_if_table_exists "sogo_cache_folder" "\`c_uid\` = '${escaped_user}'"
  delete_rows_if_table_exists "sogo_acl" "\`c_uid\` = '${escaped_user}' OR \`c_object\` LIKE '%/${escaped_user}/%'"
  delete_rows_if_table_exists "sogo_store" "\`c_folder_id\` IN (SELECT \`c_folder_id\` FROM \`sogo_folder_info\` WHERE \`c_path2\` = '${escaped_user}')"
  delete_rows_if_table_exists "sogo_quick_contact" "\`c_folder_id\` IN (SELECT \`c_folder_id\` FROM \`sogo_folder_info\` WHERE \`c_path2\` = '${escaped_user}')"
  delete_rows_if_table_exists "sogo_quick_appointment" "\`c_folder_id\` IN (SELECT \`c_folder_id\` FROM \`sogo_folder_info\` WHERE \`c_path2\` = '${escaped_user}')"
  delete_rows_if_table_exists "sogo_folder_info" "\`c_path2\` = '${escaped_user}'"
}

restore_user_maildir_from_root() {
  local source_root="${1:?source_root is required}"
  local domain="${2:?domain is required}"
  local mailbox_user="${3:?mailbox_user is required}"
  local local_part
  local source_maildir
  local target_maildir

  local_part="${mailbox_user%@*}"
  source_maildir="${source_root}/${domain}/${local_part}"
  target_maildir="${VMAIL_VOLUME_MOUNTPOINT}/${domain}/${local_part}"

  [[ -d "${source_maildir}" ]] || return 0

  rm -rf "${target_maildir}"
  mkdir -p "$(dirname "${target_maildir}")"
  cp -a "${source_maildir}" "${target_maildir}"

  docker exec "${DOVECOT_CONTAINER_ID}" chown -R vmail:vmail "/var/vmail/${domain}/${local_part}" >/dev/null
}

restore_user_maildir() {
  local backup_dir="${1:?backup_dir is required}"
  local domain="${2:?domain is required}"
  local mailbox_user="${3:?mailbox_user is required}"

  restore_user_maildir_from_root "${backup_dir}/maildir" "${domain}" "${mailbox_user}"
}

restore_user_sieve_from_root() {
  local source_root="${1:?source_root is required}"
  local mailbox_user="${2:?mailbox_user is required}"
  local sieve_dir="${VMAIL_VOLUME_MOUNTPOINT}/sieve"
  local source_path

  mkdir -p "${sieve_dir}"

  for source_path in \
    "${source_root}/${mailbox_user}.sieve" \
    "${source_root}/${mailbox_user}.svbin"
  do
    [[ -e "${source_path}" ]] || continue
    cp -a "${source_path}" "${sieve_dir}/"
  done

  docker exec "${DOVECOT_CONTAINER_ID}" sh -lc "chown -R vmail:vmail /var/vmail/sieve >/dev/null 2>&1 || true"
}

restore_user_sieve() {
  local backup_dir="${1:?backup_dir is required}"
  local mailbox_user="${2:?mailbox_user is required}"

  restore_user_sieve_from_root "${backup_dir}/sieve" "${mailbox_user}"
}

restore_user_sogo() {
  local backup_dir="${1:?backup_dir is required}"
  local mailbox_user="${2:?mailbox_user is required}"
  local source_file="${backup_dir}/sogo/${mailbox_user}"
  local target_file="${SOGO_CONFIG_DIR}/${mailbox_user}"

  [[ -f "${source_file}" ]] || return 0

  cp -a "${source_file}" "${target_file}"
  docker exec -u sogo "${SOGO_CONTAINER_ID}" sogo-tool restore -F ALL /etc/sogo "${mailbox_user}" >/dev/null
  rm -f "${target_file}"
}

resync_mailbox() {
  local mailbox_user="${1:?mailbox_user is required}"

  run_filtered_command \
    "Reindexing mailbox ${mailbox_user}" \
    'UIDVALIDITY changed' \
    docker exec "${DOVECOT_CONTAINER_ID}" doveadm force-resync -u "${mailbox_user}" '*'

  run_quiet_command \
    "Recalculating quota for ${mailbox_user}" \
    docker exec "${DOVECOT_CONTAINER_ID}" doveadm quota recalc -u "${mailbox_user}"
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

run_domain_backup() {
  local domain="${1:?domain is required}"
  local escaped_domain
  local backup_name
  local backup_dir
  local metadata_dir
  local users_sql_dir
  local domain_sql_file
  local remote_target
  local mailbox_user
  local escaped_user
  local local_part
  local maildir_source
  local user_sql_file
  local -a domain_users=()

  load_mailcow_runtime

  escaped_domain="$(sql_escape "${domain}")"
  mapfile -t domain_users < <(mysql_query "SELECT \`username\` FROM \`mailbox\` WHERE \`domain\` = '${escaped_domain}' ORDER BY \`username\`;")

  [[ "${#domain_users[@]}" -gt 0 ]] || fail "No mailboxes found for domain ${domain}"

  backup_name="mailcow-domain-$(sanitize_name "${domain}")-$(date '+%Y-%m-%d-%H-%M-%S')"
  backup_dir="${MAILCOW_BACKUP_LOCATION}/granular/${backup_name}"
  metadata_dir="${backup_dir}/metadata"
  users_sql_dir="${metadata_dir}/users"
  domain_sql_file="${metadata_dir}/domain.sql"

  mkdir -p "${users_sql_dir}" "${backup_dir}/maildir/${domain}" "${backup_dir}/sieve" "${backup_dir}/sogo"
  : > "${domain_sql_file}"

  append_table_dump "domain" "\`domain\` = '${escaped_domain}'" "${domain_sql_file}"
  append_table_dump "domain_admins" "\`domain\` = '${escaped_domain}'" "${domain_sql_file}"
  append_table_dump "alias_domain" "\`target_domain\` = '${escaped_domain}' OR \`alias_domain\` = '${escaped_domain}'" "${domain_sql_file}"
  append_table_dump "filterconf" "\`object\` = '${escaped_domain}'" "${domain_sql_file}"
  append_table_dump "bcc_maps" "\`local_dest\` = '${escaped_domain}' OR \`bcc_dest\` = '${escaped_domain}'" "${domain_sql_file}"
  append_table_dump "mta_sts" "\`domain\` = '${escaped_domain}'" "${domain_sql_file}"

  for mailbox_user in "${domain_users[@]}"; do
    escaped_user="$(sql_escape "${mailbox_user}")"
    local_part="${mailbox_user%@*}"
    maildir_source="${VMAIL_VOLUME_MOUNTPOINT}/${domain}/${local_part}"
    user_sql_file="${users_sql_dir}/${mailbox_user}.sql"

    : > "${user_sql_file}"

    append_table_dump "mailbox" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "alias" "\`address\` = '${escaped_user}' OR FIND_IN_SET('${escaped_user}', REPLACE(\`goto\`, ' ', '')) > 0" "${user_sql_file}"
    append_table_dump "sender_acl" "\`logged_in_as\` = '${escaped_user}' OR \`send_as\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "quota2" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "quota2replica" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "pushover" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "filterconf" "\`object\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "bcc_maps" "\`local_dest\` = '${escaped_user}' OR \`bcc_dest\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "spamalias" "\`goto\` = '${escaped_user}' OR \`address\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "sieve_filters" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "user_acl" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "app_passwd" "\`mailbox\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "imapsync" "\`user2\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "oauth_access_tokens" "\`user_id\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "oauth_refresh_tokens" "\`user_id\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "oauth_authorization_codes" "\`user_id\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "tfa" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_table_dump "fido2" "\`username\` = '${escaped_user}'" "${user_sql_file}"

    copy_path_if_exists "${maildir_source}" "${backup_dir}/maildir/${domain}"
    copy_path_if_exists "${VMAIL_VOLUME_MOUNTPOINT}/sieve/${mailbox_user}.sieve" "${backup_dir}/sieve"
    copy_path_if_exists "${VMAIL_VOLUME_MOUNTPOINT}/sieve/${mailbox_user}.svbin" "${backup_dir}/sieve"
    backup_sogo_user "${mailbox_user}" "${backup_dir}/sogo"
  done

  write_granular_manifest "${backup_dir}/manifest.env" "${backup_name}" "${domain}" "${domain_users[@]}"

  remote_target="$(build_remote_target "granular/${backup_name}")"
  build_rclone_copy_args "${backup_dir}" "${remote_target}"

  log "Uploading granular backup ${backup_name} to ${remote_target}"
  rclone "${RCLONE_ARGS[@]}"

  if [[ "${DELETE_LOCAL_AFTER_UPLOAD}" == "true" ]]; then
    log "Upload succeeded, deleting local granular backup directory ${backup_dir}"
    rm -rf "${backup_dir}"
  fi

  log "Granular domain backup completed successfully"
}

build_domain_package_from_full_backup() {
  local domain="${1:?domain is required}"
  local package_dir="${2:?package_dir is required}"
  local specific_mailbox_user="${3:-}"
  local escaped_domain
  local metadata_dir
  local users_sql_dir
  local domain_sql_file
  local mailbox_user
  local escaped_user
  local local_part
  local maildir_source
  local -a source_users=()

  escaped_domain="$(sql_escape "${domain}")"
  metadata_dir="${package_dir}/metadata"
  users_sql_dir="${metadata_dir}/users"
  domain_sql_file="${metadata_dir}/domain.sql"

  mkdir -p "${users_sql_dir}" "${package_dir}/maildir/${domain}" "${package_dir}/sieve"
  : > "${domain_sql_file}"

  append_source_table_dump "domain" "\`domain\` = '${escaped_domain}'" "${domain_sql_file}"
  append_source_table_dump "domain_admins" "\`domain\` = '${escaped_domain}'" "${domain_sql_file}"
  append_source_table_dump "alias_domain" "\`target_domain\` = '${escaped_domain}' OR \`alias_domain\` = '${escaped_domain}'" "${domain_sql_file}"
  append_source_table_dump "alias" "\`domain\` = '${escaped_domain}'" "${domain_sql_file}"
  append_source_table_dump "filterconf" "\`object\` = '${escaped_domain}'" "${domain_sql_file}"
  append_source_table_dump "bcc_maps" "\`local_dest\` = '${escaped_domain}' OR \`bcc_dest\` = '${escaped_domain}'" "${domain_sql_file}"
  append_source_table_dump "mta_sts" "\`domain\` = '${escaped_domain}'" "${domain_sql_file}"

  if [[ -n "${specific_mailbox_user}" ]]; then
    source_users=( "${specific_mailbox_user}" )
  else
    mapfile -t source_users < <(source_mysql_query "SELECT \`username\` FROM \`mailbox\` WHERE \`domain\` = '${escaped_domain}' ORDER BY \`username\`;")
  fi

  [[ "${#source_users[@]}" -gt 0 ]] || fail "No mailboxes found for domain ${domain} in full backup"

  for mailbox_user in "${source_users[@]}"; do
    escaped_user="$(sql_escape "${mailbox_user}")"
    local_part="${mailbox_user%@*}"
    maildir_source="${FULL_RESTORE_STAGE_ROOT}/extracted/vmail/${domain}/${local_part}"
    user_sql_file="${users_sql_dir}/${mailbox_user}.sql"

    : > "${user_sql_file}"

    append_source_table_dump "mailbox" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "alias" "\`address\` = '${escaped_user}' OR FIND_IN_SET('${escaped_user}', REPLACE(\`goto\`, ' ', '')) > 0" "${user_sql_file}"
    append_source_table_dump "sender_acl" "\`logged_in_as\` = '${escaped_user}' OR \`send_as\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "quota2" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "quota2replica" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "pushover" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "filterconf" "\`object\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "bcc_maps" "\`local_dest\` = '${escaped_user}' OR \`bcc_dest\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "spamalias" "\`goto\` = '${escaped_user}' OR \`address\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "sieve_filters" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "user_acl" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "app_passwd" "\`mailbox\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "imapsync" "\`user2\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "oauth_access_tokens" "\`user_id\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "oauth_refresh_tokens" "\`user_id\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "oauth_authorization_codes" "\`user_id\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "tfa" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "fido2" "\`username\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "sogo_user_profile" "\`c_uid\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "sogo_cache_folder" "\`c_uid\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "sogo_acl" "\`c_uid\` = '${escaped_user}' OR \`c_object\` LIKE '%/${escaped_user}/%'" "${user_sql_file}"
    append_source_table_dump "sogo_folder_info" "\`c_path2\` = '${escaped_user}'" "${user_sql_file}"
    append_source_table_dump "sogo_store" "\`c_folder_id\` IN (SELECT \`c_folder_id\` FROM \`sogo_folder_info\` WHERE \`c_path2\` = '${escaped_user}')" "${user_sql_file}"
    append_source_table_dump "sogo_quick_contact" "\`c_folder_id\` IN (SELECT \`c_folder_id\` FROM \`sogo_folder_info\` WHERE \`c_path2\` = '${escaped_user}')" "${user_sql_file}"
    append_source_table_dump "sogo_quick_appointment" "\`c_folder_id\` IN (SELECT \`c_folder_id\` FROM \`sogo_folder_info\` WHERE \`c_path2\` = '${escaped_user}')" "${user_sql_file}"

    copy_path_if_exists "${maildir_source}" "${package_dir}/maildir/${domain}"
    copy_path_if_exists "${FULL_RESTORE_STAGE_ROOT}/extracted/vmail/sieve/${mailbox_user}.sieve" "${package_dir}/sieve"
    copy_path_if_exists "${FULL_RESTORE_STAGE_ROOT}/extracted/vmail/sieve/${mailbox_user}.svbin" "${package_dir}/sieve"
  done

  write_granular_manifest "${package_dir}/manifest.env" "$(basename "${package_dir}")" "${domain}" "${source_users[@]}"
}

run_restore_domain_from_full() {
  local backup_name="${1:?backup_name is required}"
  local domain="${2:?domain is required}"
  local user_input="${3:-}"
  local mailbox_user=""
  local package_dir
  local domain_sql_file
  local user_sql_file
  local restore_user
  local -a restore_users=()

  load_mailcow_runtime
  prepare_full_backup_stage "${backup_name}"

  if [[ -n "${user_input}" ]]; then
    mailbox_user="$(normalize_mailbox_user "${domain}" "${user_input}")"
  fi

  package_dir="${FULL_RESTORE_STAGE_ROOT}/domain-package"
  build_domain_package_from_full_backup "${domain}" "${package_dir}" "${mailbox_user}"
  domain_sql_file="${package_dir}/metadata/domain.sql"

  if [[ -n "${mailbox_user}" ]]; then
    restore_users=( "${mailbox_user}" )
  else
    mapfile -t restore_users < <(find "${package_dir}/metadata/users" -mindepth 1 -maxdepth 1 -type f -name '*.sql' -exec basename {} .sql \; | sort)
  fi

  [[ "${#restore_users[@]}" -gt 0 ]] || fail "No users found to restore from full backup for domain ${domain}"

  log "Restoring ${#restore_users[@]} mailbox(es) for domain ${domain} from full backup ${backup_name}"

  mysql_import_file "${domain_sql_file}"

  for restore_user in "${restore_users[@]}"; do
    user_sql_file="${package_dir}/metadata/users/${restore_user}.sql"
    [[ -f "${user_sql_file}" ]] || fail "Missing user SQL for ${restore_user} in staged full backup package"

    cleanup_user_metadata "${restore_user}"
    mysql_import_file "${user_sql_file}"
    restore_user_maildir_from_root "${package_dir}/maildir" "${domain}" "${restore_user}"
    restore_user_sieve_from_root "${package_dir}/sieve" "${restore_user}"
    resync_mailbox "${restore_user}"
  done

  log "Restore from full backup completed successfully for domain ${domain}"
}

run_full_restore() {
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

run_granular_restore() {
  local domain="${1:?domain is required}"
  local user_input="${2:?user_input is required}"
  local explicit_backup_name="${3:-}"
  local mailbox_user
  local backup_name
  local local_backup_dir
  local local_domain_sql
  local local_user_sql

  load_mailcow_runtime

  mailbox_user="$(normalize_mailbox_user "${domain}" "${user_input}")"

  if [[ -n "${explicit_backup_name}" ]]; then
    backup_name="${explicit_backup_name}"
  else
    local_backup_dir="$(find_latest_local_granular_backup "${domain}")"
    if [[ -n "${local_backup_dir}" ]]; then
      backup_name="$(basename "${local_backup_dir}")"
    else
      backup_name="$(find_latest_remote_granular_backup_name "${domain}")"
    fi
  fi

  [[ -n "${backup_name}" ]] || fail "No granular backup found for domain ${domain}"

  local_backup_dir="$(download_granular_backup_if_needed "${backup_name}")"
  local_domain_sql="${local_backup_dir}/metadata/domain.sql"
  local_user_sql="${local_backup_dir}/metadata/users/${mailbox_user}.sql"

  [[ -f "${local_user_sql}" ]] || fail "Mailbox ${mailbox_user} is not present in granular backup ${backup_name}"

  log "Restoring mailbox ${mailbox_user} from granular backup ${backup_name}"

  cleanup_user_metadata "${mailbox_user}"
  mysql_import_file "${local_domain_sql}"
  mysql_import_file "${local_user_sql}"
  restore_user_maildir "${local_backup_dir}" "${domain}" "${mailbox_user}"
  restore_user_sieve "${local_backup_dir}" "${mailbox_user}"
  restore_user_sogo "${local_backup_dir}" "${mailbox_user}"
  resync_mailbox "${mailbox_user}"

  log "Granular mailbox restore completed successfully for ${mailbox_user}"
}

run_full_list() {
  local remote_target
  local entries

  remote_target="$(build_remote_target "")"
  entries="$(list_remote_backup_dirs "${remote_target}" | grep '^mailcow-' | grep -v '^mailcow-domain-' || true)"

  [[ -n "${entries}" ]] || fail "No full backups found in ${remote_target}"

  log "Listing full backups in ${remote_target}"
  printf '%s\n' "${entries}"
}

run_granular_list() {
  local domain="${1:?domain is required}"
  local remote_target
  local prefix
  local entries

  remote_target="$(build_remote_target "granular")"
  prefix="$(granular_backup_prefix "${domain}")"
  entries="$(list_remote_backup_dirs "${remote_target}" | grep "^${prefix}" || true)"

  [[ -n "${entries}" ]] || fail "No granular backups found for domain ${domain}"

  log "Listing granular backups for ${domain} in ${remote_target}"
  printf '%s\n' "${entries}"
}

run_list() {
  if [[ -n "${DOMAIN_NAME}" ]]; then
    run_granular_list "${DOMAIN_NAME}"
  else
    run_full_list
  fi
}

load_env_file "${PROJECT_ROOT}/.env"
if [[ "${PWD}" != "${PROJECT_ROOT}" ]]; then
  load_env_file "${PWD}/.env"
fi

OPERATION="backup"
FULL_RESTORE_NAME=""
DOMAIN_NAME=""
USER_NAME=""
GRANULAR_BACKUP_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup)
      OPERATION="backup"
      shift
      ;;
    --restore-domain-from-full)
      OPERATION="restore_from_full"
      shift
      [[ $# -gt 0 && "$1" != --* ]] || fail "--restore-domain-from-full requires a full backup directory name"
      FULL_RESTORE_NAME="$1"
      shift
      ;;
    --restore)
      OPERATION="restore"
      shift
      if [[ $# -gt 0 && "$1" != --* ]]; then
        FULL_RESTORE_NAME="$1"
        shift
      fi
      ;;
    --list)
      OPERATION="list"
      shift
      ;;
    --domain)
      shift
      [[ $# -gt 0 ]] || fail "--domain requires a value"
      DOMAIN_NAME="$1"
      shift
      ;;
    --user)
      shift
      [[ $# -gt 0 ]] || fail "--user requires a value"
      USER_NAME="$1"
      shift
      ;;
    --backup-name)
      shift
      [[ $# -gt 0 ]] || fail "--backup-name requires a value"
      GRANULAR_BACKUP_NAME="$1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --debug)
      DEBUG="true"
      shift
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
DELETE_LOCAL_AFTER_UPLOAD="${DELETE_LOCAL_AFTER_UPLOAD:-true}"
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-}"
THREADS="${THREADS:-1}"

require_bin bash
require_bin docker
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
    if [[ -n "${DOMAIN_NAME}" ]]; then
      [[ -z "${USER_NAME}" ]] || fail "--user is not supported together with --backup --domain"
      run_domain_backup "${DOMAIN_NAME}"
    else
      run_backup
    fi
    ;;
  list)
    [[ -z "${USER_NAME}" ]] || fail "--user is not supported with --list"
    run_list
    ;;
  restore)
    if [[ -n "${DOMAIN_NAME}" ]]; then
      [[ -n "${USER_NAME}" ]] || fail "Granular restore requires --domain and --user"
      [[ -z "${FULL_RESTORE_NAME}" ]] || fail "Do not pass a full backup directory together with --restore --domain"
      run_granular_restore "${DOMAIN_NAME}" "${USER_NAME}" "${GRANULAR_BACKUP_NAME}"
    else
      [[ -z "${USER_NAME}" ]] || fail "--user requires --domain"
      [[ -z "${GRANULAR_BACKUP_NAME}" ]] || fail "--backup-name requires --domain"
      run_full_restore "${FULL_RESTORE_NAME}"
    fi
    ;;
  restore_from_full)
    [[ -n "${DOMAIN_NAME}" ]] || fail "--restore-domain-from-full requires --domain"
    [[ -z "${GRANULAR_BACKUP_NAME}" ]] || fail "--backup-name is not supported with --restore-domain-from-full"
    run_restore_domain_from_full "${FULL_RESTORE_NAME}" "${DOMAIN_NAME}" "${USER_NAME}"
    ;;
  *)
    fail "Unsupported operation: ${OPERATION}"
    ;;
esac
