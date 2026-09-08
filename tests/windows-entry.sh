#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329 # Tests source and inspect checkout code.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-windows-entry.XXXXXX")

cleanup() {
  local pid
  trap - EXIT INT TERM HUP
  if declare -p run_case_pids >/dev/null 2>&1; then
    for pid in "${run_case_pids[@]}"; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "${run_case_pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
  release_boot_repair_lock 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=../lib/records.sh
source "${ROOT_DIR}/lib/records.sh"
# shellcheck source=../lib/software.sh
source "${ROOT_DIR}/lib/software.sh"
# shellcheck source=../lib/windows.sh
source "${ROOT_DIR}/lib/windows.sh"

# Test convenience: a lifecycle transaction without a preflight step.
run_lifecycle_transaction() {
  run_lifecycle_transaction_with_preflight "$1" "$2" "$3" : "${@:4}"
}

QUIET=true
CASE_DIR=""
CONFIG_FILE=""
ARTIFACT_FILE=""
TARGET_BOOT=0007
TARGET_LABEL='Windows Boot Manager'
TARGET_PARTUUID='11111111-2222-3333-4444-555555555555'
RESOLVE_CALLS=0
RESOLVE_FAIL_AT=0
RESOLVE_ALWAYS_FAIL=false
ARTIFACT_FAIL=false
PREFLIGHT_FAIL=false
CONFIG_SYNC_FAIL=false
REINSERT_BLOCK_AFTER_REPAIR=false
REPAIR_BODY_CALLS=0
PREFLIGHT_CONFIG_CHECKSUM=""
REPAIR_CONFIG_CHECKSUM=""
_repair_config_checksum=""
BOOTNEXT_TOOL_VALID=true
BOOTNEXT_TOOL_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
BOOTNEXT_COMMAND_RC=0
BOOTNEXT_COMMAND_EFFECT=true
BOOTNEXT_EFFECT_NUMBER=""
BOOTNEXT_COMMAND_CALLS=0
BOOTNEXT_FAILPOINT=""
BOOTNEXT_FAIL_ACTION=""
BOOTNEXT_CALL_LOG=""
WINDOWS_RECOVERY_FAILPOINT=""
WINDOWS_RECOVERY_FAIL_ACTION=""
UNLINK_COMMAND_RC=0
UNLINK_COMMAND_EFFECT=true
UNLINK_COMMAND_CALLS=0
UNLINK_CALL_LOG=""
BOOTNEXT_MOUNT_VALIDATIONS=0
BOOTNEXT_MOUNT_FAIL_AT=0
TEST_BOOT_ID='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
LIFECYCLE_FAILPOINT=""

state_dir_path() {
  printf '%s/state\n' "$CASE_DIR"
}

limine_lock_path() {
  printf '%s/boot-partition.lock\n' "$CASE_DIR"
}

snapshot_restore_lock_path() {
  printf '%s/limine-snapper-restore.lock\n' "$CASE_DIR"
}

pacman_database_lock_path() {
  printf '%s/pacman-db.lck\n' "$CASE_DIR"
}

windows_limine_config_path() {
  printf '%s\n' "$CONFIG_FILE"
}

control_owner_uid() {
  id -u
}

require_control_root() {
  :
}

boot_id_value() {
  printf '%s\n' "$TEST_BOOT_ID"
}

lifecycle_failpoint() {
  [[ "$LIFECYCLE_FAILPOINT" != "$1" ]]
}

durable_sync() {
  local path="$1"
  if [[ "$CONFIG_SYNC_FAIL" == true \
    && "$path" == "$(dirname "$CONFIG_FILE")" ]]; then
    CONFIG_SYNC_FAIL=false
    return 1
  fi
}

efivars_path() {
  printf '%s/efivars\n' "$CASE_DIR"
}

windows_validate_efivarfs_mount() {
  local directory
  BOOTNEXT_MOUNT_VALIDATIONS=$((BOOTNEXT_MOUNT_VALIDATIONS + 1))
  (( BOOTNEXT_MOUNT_FAIL_AT == 0 \
    || BOOTNEXT_MOUNT_VALIDATIONS != BOOTNEXT_MOUNT_FAIL_AT )) || return 1
  directory=$(efivars_path) || return 1
  [[ -d "$directory" && ! -L "$directory" ]]
}

validate_windows_efibootmgr_boundary() {
  [[ "$BOOTNEXT_TOOL_VALID" == true \
    && "$BOOTNEXT_TOOL_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
  _windows_efibootmgr_hash="$BOOTNEXT_TOOL_HASH"
  _windows_efibootmgr_package='efibootmgr 18-4'
}

hash_bound_windows_efibootmgr() {
  [[ "$BOOTNEXT_TOOL_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$BOOTNEXT_TOOL_HASH"
}

remove_windows_bootnext_variable() {
  local path="$1"
  [[ "$path" == "$(windows_bootnext_variable_path)" ]] || return 64
  UNLINK_COMMAND_CALLS=$((UNLINK_COMMAND_CALLS + 1))
  printf '%s\n' "$path" >> "$UNLINK_CALL_LOG"
  if [[ "$UNLINK_COMMAND_EFFECT" == true ]]; then
    rm -f "$path"
  fi
  return "$UNLINK_COMMAND_RC"
}

write_bootnext_variable() {
  local number="$1" attributes="${2:-7}" path value encoded
  [[ "$number" =~ ^[0-9A-F]{4}$ && "$attributes" =~ ^[0-9]+$ ]] || return 1
  path=$(windows_bootnext_variable_path) || return 1
  value=$((16#$number))
  printf -v encoded '\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x\\x%02x' \
    "$((attributes & 255))" "$(((attributes >> 8) & 255))" \
    "$(((attributes >> 16) & 255))" "$(((attributes >> 24) & 255))" \
    "$((value & 255))" "$(((value >> 8) & 255))"
  printf '%b' "$encoded" > "$path"
  chmod 600 "$path"
}

run_windows_efibootmgr() {
  local target
  [[ $# -eq 2 && "$1" == -n && "$2" =~ ^[0-9A-F]{4}$ ]] || return 64
  target="$2"
  BOOTNEXT_COMMAND_CALLS=$((BOOTNEXT_COMMAND_CALLS + 1))
  printf '%s\n' "$*" >> "$BOOTNEXT_CALL_LOG"
  if [[ "$BOOTNEXT_COMMAND_EFFECT" == true ]]; then
    write_bootnext_variable "${BOOTNEXT_EFFECT_NUMBER:-$target}" || return 1
  fi
  return "$BOOTNEXT_COMMAND_RC"
}

windows_bootnext_failpoint() {
  local point="$1"
  [[ "$BOOTNEXT_FAILPOINT" == "$point" ]] || return 0
  case "$BOOTNEXT_FAIL_ACTION" in
    change-prior) write_bootnext_variable 0009 ;;
    change-target) TARGET_BOOT=0008 ;;
    change-tool) BOOTNEXT_TOOL_HASH='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
    change-boot) TEST_BOOT_ID='11111111-2222-4333-8444-555555555555' ;;
    corrupt-attributes) write_bootnext_variable 0007 3 ;;
    signal-term) kill -TERM "$BASHPID" ;;
    fail) return 75 ;;
    *) return 1 ;;
  esac
}

windows_recovery_failpoint() {
  local point="$1" path
  [[ "$WINDOWS_RECOVERY_FAILPOINT" == "$point" ]] || return 0
  case "$WINDOWS_RECOVERY_FAIL_ACTION" in
    change-boot) TEST_BOOT_ID='11111111-2222-4333-8444-555555555555' ;;
    change-state) write_bootnext_variable 0008 ;;
    change-tool)
      BOOTNEXT_TOOL_HASH='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      ;;
    corrupt-attributes) write_bootnext_variable 0007 3 ;;
    replace-variable)
      path=$(windows_bootnext_variable_path) || return 1
      rm -f "$path"
      write_bootnext_variable 0007
      ;;
    fail) return 75 ;;
    *) return 1 ;;
  esac
}

resolve_windows_target() {
  RESOLVE_CALLS=$((RESOLVE_CALLS + 1))
  if [[ "$RESOLVE_ALWAYS_FAIL" == true ]] \
    || (( RESOLVE_FAIL_AT > 0 && RESOLVE_CALLS == RESOLVE_FAIL_AT )); then
    return 1
  fi
  _windows_boot_number="$TARGET_BOOT"
  _windows_label="$TARGET_LABEL"
  _windows_partuuid="$TARGET_PARTUUID"
  _windows_partition_number=1
  _windows_hd_start=2048
  _windows_hd_size=1048576
}

current_limine_config_checksum() {
  sha256_file "$CONFIG_FILE"
}

artifact_repair_refresh_config_checksum() {
  _repair_config_checksum=$(current_limine_config_checksum)
}

artifact_repair_preflight() {
  [[ "$PREFLIGHT_FAIL" == false ]] || return 1
  artifact_repair_refresh_config_checksum || return 1
  PREFLIGHT_CONFIG_CHECKSUM="$_repair_config_checksum"
}

repair_boot_artifacts() {
  local current_checksum
  REPAIR_BODY_CALLS=$((REPAIR_BODY_CALLS + 1))
  current_checksum=$(current_limine_config_checksum) || return 1
  REPAIR_CONFIG_CHECKSUM="$_repair_config_checksum"
  [[ "$REPAIR_CONFIG_CHECKSUM" == "$current_checksum" ]] || return 48
  transaction_phase_start "backup-artifacts" || return 1
  transaction_backup_file "$ARTIFACT_FILE" || return 1
  transaction_phase_complete "backup-artifacts" || return 1

  transaction_phase_start "mutate-artifacts" || return 1
  printf 'repaired:%s\n' "$REPAIR_CONFIG_CHECKSUM" > "$ARTIFACT_FILE"
  [[ "$ARTIFACT_FAIL" == false ]] || return 47
  transaction_phase_complete "mutate-artifacts" || return 1

  transaction_phase_start "prove-artifacts" || return 1
  /usr/bin/grep -Fxq "repaired:${REPAIR_CONFIG_CHECKSUM}" "$ARTIFACT_FILE" || return 1
  transaction_phase_complete "prove-artifacts" || return 1
  if [[ "$REINSERT_BLOCK_AFTER_REPAIR" == true ]]; then
    windows_rewrite_managed_block install "$_windows_state_label" || return 1
  fi
}

write_legacy_config() {
  cat > "$CONFIG_FILE" <<EOF
timeout: 5

# omasecboot:windows
/Windows
    comment: ${TARGET_LABEL}
    protocol: efi_boot_entry
    entry: ${TARGET_LABEL}

/Linux
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux.efi
EOF
}

setup_fixture() {
  local name="$1"
  release_boot_repair_lock
  CASE_DIR="${TEST_DIR}/${name}"
  CONFIG_FILE="${CASE_DIR}/boot/limine.conf"
  ARTIFACT_FILE="${CASE_DIR}/artifact"
  BOOTNEXT_CALL_LOG="${CASE_DIR}/bootnext-calls"
  UNLINK_CALL_LOG="${CASE_DIR}/unlink-calls"
  rm -rf "$CASE_DIR"
  mkdir -p "$(dirname "$CONFIG_FILE")" "${CASE_DIR}/efivars"
  chmod 755 "$CASE_DIR" "$(dirname "$CONFIG_FILE")" "${CASE_DIR}/efivars"
  printf 'original\n' > "$ARTIFACT_FILE"
  : > "$BOOTNEXT_CALL_LOG"
  : > "$UNLINK_CALL_LOG"
  TARGET_BOOT=0007
  TARGET_LABEL='Windows Boot Manager'
  TARGET_PARTUUID='11111111-2222-3333-4444-555555555555'
  RESOLVE_CALLS=0
  RESOLVE_FAIL_AT=0
  RESOLVE_ALWAYS_FAIL=false
  ARTIFACT_FAIL=false
  PREFLIGHT_FAIL=false
  CONFIG_SYNC_FAIL=false
  REINSERT_BLOCK_AFTER_REPAIR=false
  REPAIR_BODY_CALLS=0
  PREFLIGHT_CONFIG_CHECKSUM=""
  REPAIR_CONFIG_CHECKSUM=""
  _repair_config_checksum=""
  BOOTNEXT_TOOL_VALID=true
  BOOTNEXT_TOOL_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  BOOTNEXT_COMMAND_RC=0
  BOOTNEXT_COMMAND_EFFECT=true
  BOOTNEXT_EFFECT_NUMBER=""
  BOOTNEXT_COMMAND_CALLS=0
  BOOTNEXT_FAILPOINT=""
  BOOTNEXT_FAIL_ACTION=""
  WINDOWS_RECOVERY_FAILPOINT=""
  WINDOWS_RECOVERY_FAIL_ACTION=""
  UNLINK_COMMAND_RC=0
  UNLINK_COMMAND_EFFECT=true
  UNLINK_COMMAND_CALLS=0
  BOOTNEXT_MOUNT_VALIDATIONS=0
  BOOTNEXT_MOUNT_FAIL_AT=0
  TEST_BOOT_ID='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
  LIFECYCLE_FAILPOINT=""
  _windows_bootnext_record_json=""
  _windows_bootnext_record_path=""
  _windows_recovery_plan_json=""
  _windows_recovery_record_json=""
  _windows_recovery_record_path=""
  _windows_recovery_command_rc=null
  write_legacy_config
  adopt_lifecycle : "no" "no" "yes" "yes" \
    "absent" "absent" "absent" "absent" \
    || fail_test "${name}: active lifecycle fixture failed"
  : > "$(windows_target_state_path)"
  chmod 644 "$(windows_target_state_path)"
}

write_windows_target_fixture() {
  local state_file
  state_file=$(windows_target_state_path) || return 1
  jq -cn \
    --arg version "$OMASECBOOT_VERSION" \
    --arg boot_number "$TARGET_BOOT" \
    --arg label "$TARGET_LABEL" \
    --arg partuuid "$TARGET_PARTUUID" \
    --arg loader "$WINDOWS_LOADER_UEFI" '{
      schema_version: 1,
      writer_version: $version,
      enabled: true,
      boot_number: $boot_number,
      label: $label,
      partuuid: $partuuid,
      loader_path: $loader
    }' > "$state_file"
  chmod 644 "$state_file"
}

setup_bootnext_fixture() {
  local name="$1"
  setup_fixture "$name"
  write_windows_target_fixture || fail_test "${name}: target fixture could not be written"
}

assert_bootnext_recovery() {
  local expected_phase="$1" manifest reference
  read_lifecycle || fail_test "failed BootNext transaction damaged lifecycle state"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "uncertain BootNext transaction did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e --arg phase "$expected_phase" '
    .operation == "windows-bootnext" and
    .status == "failed" and
    .failure.phase == $phase and
    .rollback.status == "completed" and
    .rollback.failures == [] and
    .domain_records.bootnext != null
  ' "$manifest" >/dev/null || fail_test "BootNext failure manifest is incomplete"
  reference=$(jq -c '.domain_records.bootnext' "$manifest") \
    || fail_test "BootNext record reference is unreadable"
  validate_bootnext_record_reference "$_lifecycle_transaction_id" "$reference" \
    "$(read_control_document "$manifest")" \
    || fail_test "BootNext recovery evidence is invalid"
}

assert_recovery_rollback() {
  local expected_phase="$1" state_file manifest
  state_file=$(windows_target_state_path)
  read_lifecycle || fail_test "failed Windows transaction damaged lifecycle"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "failed Windows transaction did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e --arg phase "$expected_phase" '
    .status == "failed" and
    .failure.phase == $phase and
    .rollback.status == "completed" and
    .rollback.failures == []
  ' "$manifest" >/dev/null || fail_test "Windows rollback manifest is incomplete"
  [[ ! -s "$state_file" ]] || fail_test "Windows state was not rolled back to its legacy marker"
  /usr/bin/grep -Fxq original "$ARTIFACT_FILE" \
    || fail_test "artifact mutation was not rolled back"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "legacy block was not restored"
  [[ "$_windows_block_state" == legacy ]] \
    || fail_test "rollback did not restore the legacy managed block"
}

test_successful_setup() {
  local state_file config_once manifest
  setup_fixture success
  windows_classify_target_state || fail_test "legacy state marker was unsafe"
  [[ "$_windows_state_kind" == legacy-empty ]] \
    || fail_test "empty legacy state marker was not classified for migration"

  run_windows_handoff_setup || fail_test "Windows setup transaction failed"
  state_file=$(windows_target_state_path)
  read_windows_target_state || fail_test "written Windows target state is invalid"
  [[ "$_windows_state_boot_number" == 0007 \
    && "$_windows_state_label" == 'Windows Boot Manager' \
    && "$_windows_state_partuuid" == 11111111-2222-3333-4444-555555555555 \
    && "$_windows_state_loader_path" == "$WINDOWS_LOADER_UEFI" ]] \
    || fail_test "written Windows target identity is incomplete"
  [[ $(stat -Lc '%a' "$state_file") == 644 ]] \
    || fail_test "Windows target state mode is unsafe"
  jq -e '
    keys == ["boot_number", "enabled", "label", "loader_path", "partuuid", "schema_version", "writer_version"] and
    .schema_version == 1 and .enabled == true and .writer_version == "1.0.0"
  ' "$state_file" >/dev/null || fail_test "Windows target schema is not strict"

  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "bounded Windows block was not recognized"
  [[ "$_windows_block_state" == canonical ]] \
    || fail_test "legacy Windows block was not migrated"
  [[ $(/usr/bin/grep -Fxc "$WINDOWS_ENTRY_MARKER" "$CONFIG_FILE") -eq 1 \
    && $(/usr/bin/grep -Fxc "$WINDOWS_ENTRY_END_MARKER" "$CONFIG_FILE") -eq 1 ]] \
    || fail_test "bounded Windows markers are not unique"
  /usr/bin/grep -Fxq 'timeout: 5' "$CONFIG_FILE" \
    || fail_test "Windows block migration dropped global config"
  /usr/bin/grep -Fxq '/Linux' "$CONFIG_FILE" \
    || fail_test "Windows block migration dropped an unrelated entry"
  /usr/bin/grep -Eq '^repaired:[0-9a-f]{64}$' "$ARTIFACT_FILE" \
    || fail_test "artifact repair body did not run"
  [[ $REPAIR_BODY_CALLS -eq 1 ]] \
    || fail_test "Windows setup did not compose the artifact body exactly once"
  [[ -n "$PREFLIGHT_CONFIG_CHECKSUM" \
    && "$PREFLIGHT_CONFIG_CHECKSUM" != "$REPAIR_CONFIG_CHECKSUM" \
    && "$REPAIR_CONFIG_CHECKSUM" == "$(current_limine_config_checksum)" ]] \
    || fail_test "artifact repair did not use the post-write Limine config checksum"

  read_lifecycle || fail_test "successful Windows lifecycle is unreadable"
  manifest=$(lifecycle_manifest_path "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
  jq -e '.completed_phases == [
    "backup-windows",
    "resolve-windows",
    "persist-windows-target",
    "configure-windows-entry",
    "backup-artifacts",
    "mutate-artifacts",
    "prove-artifacts",
    "prove-windows"
  ] and .status == "completed"' "$manifest" >/dev/null \
    || fail_test "Windows and artifact phases were not committed in order"
  [[ $RESOLVE_CALLS -eq 4 ]] \
    || fail_test "Windows setup did not perform all four target proofs"

  config_once="${CASE_DIR}/limine.conf.once"
  cp -p "$CONFIG_FILE" "$config_once"
  RESOLVE_CALLS=0
  run_windows_handoff_setup || fail_test "idempotent Windows setup failed"
  cmp "$config_once" "$CONFIG_FILE" \
    || fail_test "idempotent Windows setup changed the canonical block"
}

test_label_round_trip() {
  setup_fixture label-round-trip
  TARGET_LABEL='Windows & Games'
  write_legacy_config
  run_windows_handoff_setup || fail_test "safe ampersand label setup failed"
  windows_managed_block_state 'Windows & Games' \
    || fail_test "safe ampersand label did not round-trip"
  [[ "$_windows_block_state" == canonical ]] \
    || fail_test "ampersand label block is not canonical"
  /usr/bin/grep -Fxq '    entry: Windows & Games' "$CONFIG_FILE" \
    || fail_test "ampersand label was transformed during config generation"
}

test_config_boundaries() {
  setup_fixture boundaries
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "exact legacy block was rejected"
  [[ "$_windows_block_state" == legacy ]] || fail_test "exact legacy block had the wrong state"

  cat > "$CONFIG_FILE" <<'EOF'
# omasecboot:windows
/Windows
    comment: Windows Boot Manager
    protocol: efi_boot_entry
    entry: Windows Boot Manager
    path: should-not-be-consumed
EOF
  if windows_managed_block_state 'Windows Boot Manager' >/dev/null 2>&1; then
    fail_test "legacy block with an indented continuation was accepted"
  fi

  printf '# omasecboot:windows\r\n/Windows\r\n    comment: Windows Boot Manager\r\n    protocol: efi_boot_entry\r\n    entry: Windows Boot Manager\r\n' \
    > "$CONFIG_FILE"
  if windows_managed_block_state 'Windows Boot Manager' >/dev/null 2>&1; then
    fail_test "CRLF legacy block was accepted as exact historical output"
  fi

  cat > "$CONFIG_FILE" <<'EOF'
# omasecboot:windows begin
/Windows
    comment: Windows Boot Manager
    protocol: efi_boot_entry
    entry: Windows Boot Manager
# omasecboot:windows end
# omasecboot:windows begin
/Windows
    comment: Windows Boot Manager
    protocol: efi_boot_entry
    entry: Windows Boot Manager
# omasecboot:windows end
EOF
  if windows_managed_block_state 'Windows Boot Manager' >/dev/null 2>&1; then
    fail_test "duplicate bounded Windows blocks were accepted"
  fi

  write_legacy_config
  printf '# omasecboot:windows unexpected\n' >> "$CONFIG_FILE"
  if windows_managed_block_state 'Windows Boot Manager' >/dev/null 2>&1; then
    fail_test "legacy block with a stray marker-like line was accepted"
  fi

  cat > "$CONFIG_FILE" <<'EOF'
# omasecboot:windows begin
/Windows
    comment: Windows Boot Manager
    protocol: efi_boot_entry
    entry: Windows Boot Manager
# omasecboot:windows end
# omasecboot:windows unexpected
EOF
  if windows_managed_block_state 'Windows Boot Manager' >/dev/null 2>&1; then
    fail_test "bounded block with a stray marker-like line was accepted"
  fi
}

test_state_schema_rejection() {
  local state_file valid
  setup_fixture state-schema
  run_windows_handoff_setup || fail_test "state schema fixture setup failed"
  state_file=$(windows_target_state_path)
  valid="${CASE_DIR}/valid-state.json"
  cp -p "$state_file" "$valid"

  jq '.unexpected = true' "$valid" > "$state_file"
  if read_windows_target_state >/dev/null 2>&1; then
    fail_test "Windows state with an unknown field was accepted"
  fi

  jq '.schema_version = 2' "$valid" > "$state_file"
  _windows_error=""
  if read_windows_target_state >/dev/null 2>&1; then
    fail_test "newer Windows state schema was accepted"
  fi
  [[ "$_windows_error" == 'Windows target state uses a newer schema' ]] \
    || fail_test "newer Windows state schema lacked its distinct diagnostic"

  jq '.schema_version = 1e100' "$valid" > "$state_file"
  _windows_error=""
  if read_windows_target_state > "${CASE_DIR}/large-schema.out" \
    2> "${CASE_DIR}/large-schema.err"; then
    fail_test "oversized Windows state schema was accepted"
  fi
  [[ ! -s "${CASE_DIR}/large-schema.err" \
    && "$_windows_error" == 'Windows target state uses a newer schema' ]] \
    || fail_test "oversized Windows state schema was not rejected cleanly"

  jq '.schema_version = 1.5' "$valid" > "$state_file"
  if read_windows_target_state > "${CASE_DIR}/float-schema.out" \
    2> "${CASE_DIR}/float-schema.err"; then
    fail_test "fractional Windows state schema was accepted"
  fi
  [[ ! -s "${CASE_DIR}/float-schema.err" ]] \
    || fail_test "fractional Windows state schema emitted an arithmetic error"

  jq '.enabled = false' "$valid" > "$state_file"
  if read_windows_target_state >/dev/null 2>&1; then
    fail_test "false enabled state was accepted as a second disabled representation"
  fi
}

test_artifact_failure_rollback() {
  setup_fixture artifact-failure
  ARTIFACT_FAIL=true
  if run_windows_handoff_setup >/dev/null 2>&1; then
    fail_test "artifact failure reported Windows setup success"
  fi
  assert_recovery_rollback mutate-artifacts
}

test_config_failure_rollback() {
  setup_fixture config-failure
  CONFIG_SYNC_FAIL=true
  if run_windows_handoff_setup >/dev/null 2>&1; then
    fail_test "config durability failure reported Windows setup success"
  fi
  CONFIG_SYNC_FAIL=false
  assert_recovery_rollback configure-windows-entry
}

test_final_proof_failure_rollback() {
  setup_fixture final-proof-failure
  RESOLVE_FAIL_AT=4
  if run_windows_handoff_setup >/dev/null 2>&1; then
    fail_test "final target proof failure reported Windows setup success"
  fi
  assert_recovery_rollback prove-windows
}

test_non_active_refusal() {
  local config_hash state_hash
  setup_fixture disabled
  rm -f "$(lifecycle_file_path)"
  rm -rf "$(transactions_dir_path)"
  run_lifecycle_transaction "disable-windows-test" "disabled" "unmanaged" : \
    || fail_test "disabled lifecycle fixture failed"
  config_hash=$(sha256_file "$CONFIG_FILE")
  state_hash=$(sha256_file "$(windows_target_state_path)")
  if run_windows_handoff_setup >/dev/null 2>&1; then
    fail_test "Windows setup ran outside active lifecycle state"
  fi
  [[ "$(sha256_file "$CONFIG_FILE")" == "$config_hash" \
    && "$(sha256_file "$(windows_target_state_path)")" == "$state_hash" ]] \
    || fail_test "blocked non-active setup changed Windows files"
}

test_setup_ownership_consistency() {
  local state_file config_hash
  setup_fixture ownership
  state_file=$(windows_target_state_path)
  rm -f "$state_file"
  cat > "$CONFIG_FILE" <<'EOF'
timeout: 5

/Linux
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux.efi
EOF
  run_windows_handoff_setup || fail_test "fresh state/config setup was rejected"
  read_windows_target_state || fail_test "fresh setup did not persist target identity"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "fresh setup did not write a bounded managed block"
  [[ "$_windows_block_state" == canonical ]] \
    || fail_test "fresh setup block is not canonical"

  rm -f "$state_file"
  config_hash=$(sha256_file "$CONFIG_FILE")
  if run_windows_handoff_setup >/dev/null 2>&1; then
    fail_test "setup inferred ownership from a managed block without durable state"
  fi
  [[ ! -e "$state_file" && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" ]] \
    || fail_test "ownership-mismatch refusal changed Windows state or config"

  : > "$state_file"
  chmod 644 "$state_file"
  if run_windows_handoff_setup >/dev/null 2>&1; then
    fail_test "empty legacy state claimed a new bounded block"
  fi
  [[ ! -s "$state_file" && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" ]] \
    || fail_test "legacy/canonical ownership refusal changed Windows files"
}

test_legacy_state_without_block_migration() {
  setup_fixture legacy-state-without-block
  cat > "$CONFIG_FILE" <<'EOF'
timeout: 5

/Linux
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux.efi
EOF
  run_windows_handoff_setup \
    || fail_test "legacy Windows opt-in without a managed block was not migrated"
  read_windows_target_state \
    || fail_test "legacy Windows opt-in migration did not persist target identity"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "legacy Windows opt-in migration did not install a managed block"
  [[ "$_windows_block_state" == canonical ]] \
    || fail_test "legacy Windows opt-in migration block is not canonical"
}

test_stale_suppression() {
  local state_file state_hash manifest
  setup_fixture suppression
  run_windows_handoff_setup || fail_test "suppression fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  TARGET_BOOT=0008
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  PREFLIGHT_CONFIG_CHECKSUM=""
  REPAIR_CONFIG_CHECKSUM=""
  suppress_stale_windows_entry || fail_test "stale Windows target was not suppressed"
  [[ $RESOLVE_CALLS -eq 2 ]] \
    || fail_test "stale suppression did not repeat target proof before writing"
  [[ "$(sha256_file "$state_file")" == "$state_hash" ]] \
    || fail_test "stale suppression changed durable opt-in identity"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "suppressed config could not be parsed"
  [[ "$_windows_block_state" == absent ]] \
    || fail_test "stale managed Windows block remained enabled"
  [[ -n "$PREFLIGHT_CONFIG_CHECKSUM" \
    && "$PREFLIGHT_CONFIG_CHECKSUM" != "$REPAIR_CONFIG_CHECKSUM" \
    && "$REPAIR_CONFIG_CHECKSUM" == "$(current_limine_config_checksum)" ]] \
    || fail_test "stale suppression repaired artifacts with a pre-write checksum"
  [[ $REPAIR_BODY_CALLS -eq 1 ]] \
    || fail_test "stale suppression did not repair artifacts exactly once"
  /usr/bin/grep -Eq '^repaired:[0-9a-f]{64}$' "$ARTIFACT_FILE" \
    || fail_test "stale suppression did not prove repaired artifacts"
  read_lifecycle || fail_test "successful suppression damaged lifecycle state"
  manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
  jq -e --arg state "$state_file" --arg config "$CONFIG_FILE" \
    --arg artifact "$ARTIFACT_FILE" '.completed_phases == [
    "backup-windows",
    "suppress-windows-entry",
    "backup-artifacts",
    "mutate-artifacts",
    "prove-artifacts",
    "prove-windows-suppression"
  ] and .status == "completed" and
  ([.backups[].target] | index($state) != null) and
  ([.backups[].target] | index($config) != null) and
  ([.backups[].target] | index($artifact) != null)' "$manifest" >/dev/null \
    || fail_test "suppression and artifact phases were not committed in order"
}

test_valid_target_suppression_refusal() {
  local state_file state_hash config_hash
  setup_fixture suppression-valid
  run_windows_handoff_setup || fail_test "valid suppression fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  config_hash=$(sha256_file "$CONFIG_FILE")
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  if suppress_stale_windows_entry >/dev/null 2>&1; then
    fail_test "valid Windows target was suppressed"
  fi
  [[ "$(sha256_file "$state_file")" == "$state_hash" \
    && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" ]] \
    || fail_test "valid-target suppression refusal changed Windows files"
  [[ $REPAIR_BODY_CALLS -eq 0 ]] \
    || fail_test "valid-target suppression refusal reached artifact repair"
  read_lifecycle || fail_test "valid-target suppression refusal damaged lifecycle"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "valid-target suppression refusal opened a transaction"
}

test_suppression_preflight_failure() {
  local state_file state_hash config_hash artifact_hash
  setup_fixture suppression-preflight
  run_windows_handoff_setup || fail_test "suppression preflight fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  config_hash=$(sha256_file "$CONFIG_FILE")
  artifact_hash=$(sha256_file "$ARTIFACT_FILE")
  TARGET_BOOT=0008
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  PREFLIGHT_FAIL=true
  if suppress_stale_windows_entry >/dev/null 2>&1; then
    fail_test "artifact preflight failure reported suppression success"
  fi
  [[ "$(sha256_file "$state_file")" == "$state_hash" \
    && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" \
    && "$(sha256_file "$ARTIFACT_FILE")" == "$artifact_hash" ]] \
    || fail_test "suppression preflight failure changed managed files"
  [[ $REPAIR_BODY_CALLS -eq 0 ]] \
    || fail_test "suppression preflight failure reached artifact repair"
  read_lifecycle || fail_test "suppression preflight failure damaged lifecycle"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "suppression preflight failure opened a transaction"
}

test_legacy_block_suppression() {
  local state_file state_hash
  setup_fixture suppression-legacy
  run_windows_handoff_setup || fail_test "legacy suppression fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  write_legacy_config
  TARGET_BOOT=0008
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  suppress_stale_windows_entry || fail_test "owned legacy block was not suppressed"
  [[ "$(sha256_file "$state_file")" == "$state_hash" ]] \
    || fail_test "legacy suppression changed durable identity"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "legacy suppression produced an invalid config"
  [[ "$_windows_block_state" == absent ]] \
    || fail_test "legacy suppression retained the managed block"
}

test_malformed_block_suppression_refusal() {
  local state_file state_hash config_hash
  setup_fixture suppression-malformed
  run_windows_handoff_setup || fail_test "malformed suppression fixture setup failed"
  state_file=$(windows_target_state_path)
  printf '# omasecboot:windows unexpected\n' >> "$CONFIG_FILE"
  state_hash=$(sha256_file "$state_file")
  config_hash=$(sha256_file "$CONFIG_FILE")
  TARGET_BOOT=0008
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  if suppress_stale_windows_entry >/dev/null 2>&1; then
    fail_test "malformed owned block was suppressed"
  fi
  [[ "$(sha256_file "$state_file")" == "$state_hash" \
    && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" ]] \
    || fail_test "malformed-block refusal changed Windows files"
  read_lifecycle || fail_test "malformed-block refusal damaged lifecycle"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "malformed-block refusal opened a transaction"
}

test_unprovable_target_suppression() {
  local state_file state_hash
  setup_fixture suppression-unprovable
  run_windows_handoff_setup || fail_test "unprovable suppression fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  RESOLVE_ALWAYS_FAIL=true
  suppress_stale_windows_entry \
    || fail_test "consistently unprovable Windows target was not suppressed"
  [[ $RESOLVE_CALLS -eq 2 ]] \
    || fail_test "unprovable target suppression did not repeat full proof"
  [[ "$(sha256_file "$state_file")" == "$state_hash" ]] \
    || fail_test "unprovable target suppression changed durable identity"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "unprovable target suppression produced an invalid config"
  [[ "$_windows_block_state" == absent ]] \
    || fail_test "unprovable target suppression retained the managed block"
  [[ $REPAIR_BODY_CALLS -eq 1 ]] \
    || fail_test "unprovable target suppression did not repair artifacts"
}

test_in_transaction_proof_failure_suppression() {
  local state_file state_hash
  setup_fixture suppression-revalidation
  run_windows_handoff_setup || fail_test "suppression revalidation fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")

  TARGET_BOOT=0008
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  RESOLVE_FAIL_AT=2
  suppress_stale_windows_entry \
    || fail_test "unsafe target with an in-transaction proof failure was not suppressed"
  [[ "$(sha256_file "$state_file")" == "$state_hash" ]] \
    || fail_test "in-transaction proof failure changed durable identity"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "in-transaction proof failure produced an invalid config"
  [[ "$_windows_block_state" == absent ]] \
    || fail_test "in-transaction proof failure retained the managed block"
  [[ $REPAIR_BODY_CALLS -eq 1 ]] \
    || fail_test "in-transaction proof failure did not repair artifacts"
}

test_valid_again_suppression_rollback() {
  local state_file state_hash config_hash artifact_hash manifest
  setup_fixture suppression-valid-again
  run_windows_handoff_setup || fail_test "valid-again suppression fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  config_hash=$(sha256_file "$CONFIG_FILE")
  artifact_hash=$(sha256_file "$ARTIFACT_FILE")
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  RESOLVE_FAIL_AT=1
  if suppress_stale_windows_entry >/dev/null 2>&1; then
    fail_test "target that became valid in-transaction was suppressed"
  fi
  [[ "$(sha256_file "$state_file")" == "$state_hash" \
    && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" \
    && "$(sha256_file "$ARTIFACT_FILE")" == "$artifact_hash" ]] \
    || fail_test "valid-again suppression failure changed managed files"
  [[ $REPAIR_BODY_CALLS -eq 0 ]] \
    || fail_test "valid-again suppression failure reached artifact repair"
  read_lifecycle || fail_test "valid-again suppression failure damaged lifecycle state"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "valid-again suppression failure did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .status == "failed" and
    .failure.phase == "suppress-windows-entry" and
    .rollback.status == "completed" and
    .rollback.failures == []
  ' "$manifest" >/dev/null \
    || fail_test "valid-again suppression rollback manifest is incomplete"
}

test_suppression_artifact_failure_rollback() {
  local state_file state_hash config_hash artifact_hash manifest
  setup_fixture suppression-artifact-failure
  run_windows_handoff_setup || fail_test "suppression rollback fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  config_hash=$(sha256_file "$CONFIG_FILE")
  artifact_hash=$(sha256_file "$ARTIFACT_FILE")
  TARGET_BOOT=0008
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  ARTIFACT_FAIL=true
  if suppress_stale_windows_entry >/dev/null 2>&1; then
    fail_test "artifact failure reported suppression success"
  fi
  ARTIFACT_FAIL=false
  [[ "$(sha256_file "$state_file")" == "$state_hash" \
    && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" \
    && "$(sha256_file "$ARTIFACT_FILE")" == "$artifact_hash" ]] \
    || fail_test "failed suppression did not restore config and artifacts"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "failed suppression restored an invalid config"
  [[ "$_windows_block_state" == canonical ]] \
    || fail_test "failed suppression did not restore the managed block"
  read_lifecycle || fail_test "failed suppression damaged lifecycle state"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "failed suppression did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .status == "failed" and
    .failure.phase == "mutate-artifacts" and
    .rollback.status == "completed" and
    .rollback.failures == []
  ' "$manifest" >/dev/null \
    || fail_test "suppression artifact rollback manifest is incomplete"
}

test_suppression_final_proof_rollback() {
  local state_file state_hash config_hash artifact_hash manifest
  setup_fixture suppression-final-proof
  run_windows_handoff_setup || fail_test "suppression final-proof fixture setup failed"
  state_file=$(windows_target_state_path)
  state_hash=$(sha256_file "$state_file")
  config_hash=$(sha256_file "$CONFIG_FILE")
  artifact_hash=$(sha256_file "$ARTIFACT_FILE")
  TARGET_BOOT=0008
  RESOLVE_CALLS=0
  REPAIR_BODY_CALLS=0
  REINSERT_BLOCK_AFTER_REPAIR=true
  if suppress_stale_windows_entry >/dev/null 2>&1; then
    fail_test "reappearing managed block passed final suppression proof"
  fi
  REINSERT_BLOCK_AFTER_REPAIR=false
  [[ "$(sha256_file "$state_file")" == "$state_hash" \
    && "$(sha256_file "$CONFIG_FILE")" == "$config_hash" \
    && "$(sha256_file "$ARTIFACT_FILE")" == "$artifact_hash" ]] \
    || fail_test "final suppression proof failure did not restore managed files"
  windows_managed_block_state 'Windows Boot Manager' \
    || fail_test "final suppression proof restored an invalid config"
  [[ "$_windows_block_state" == canonical ]] \
    || fail_test "final suppression proof did not restore the managed block"
  read_lifecycle || fail_test "final suppression proof damaged lifecycle state"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "final suppression proof failure did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .status == "failed" and
    .failure.phase == "prove-windows-suppression" and
    .rollback.status == "completed" and
    .rollback.failures == []
  ' "$manifest" >/dev/null \
    || fail_test "final suppression proof rollback manifest is incomplete"
}

test_bootnext_success_and_schema() {
  local lifecycle manifest transaction_id reference record state tampered
  setup_bootnext_fixture bootnext-success
  run_windows_bootnext || fail_test "BootNext transaction failed"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 1 \
    && $(<"$BOOTNEXT_CALL_LOG") == '-n 0007' ]] \
    || fail_test "BootNext transaction did not issue exactly one bounded write"
  state=$(read_windows_bootnext_state) || fail_test "BootNext readback became unreadable"
  jq -e '.present == true and .boot_number == "0007"' <<< "$state" >/dev/null \
    || fail_test "BootNext transaction did not retain the requested readback"

  read_lifecycle || fail_test "successful BootNext transaction damaged lifecycle"
  [[ "$_lifecycle_state" == active ]] || fail_test "BootNext transaction did not commit active state"
  transaction_id=$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")
  manifest=$(lifecycle_manifest_path "$transaction_id")
  jq -e '
    .operation == "windows-bootnext" and .status == "completed" and
    .completed_phases == ["record-bootnext","set-bootnext"] and
    .domain_records.bootnext != null and
    .domain_records.final_proof == null and .domain_records.firmware == null and
    .domain_records.managed_settings == null and .domain_records.producer == null and
    .domain_records.tracking_ownership == null and .domain_records.unconfigure == null and
    .domain_records.windows == null
  ' "$manifest" >/dev/null || fail_test "completed BootNext manifest is invalid"
  reference=$(jq -c '.domain_records.bootnext' "$manifest")
  validate_bootnext_record_reference "$transaction_id" "$reference" \
    "$(read_control_document "$manifest")" \
    || fail_test "completed BootNext record reference is invalid"
  record=$(jq -r '.path' <<< "$reference")
  [[ $(stat -Lc '%a' "$record") == 600 ]] \
    || fail_test "BootNext record mode is unsafe"
  jq -e \
    --arg hash "$BOOTNEXT_TOOL_HASH" \
    --arg package 'efibootmgr 18-4' '
    .operation == "windows-bootnext" and
    .prior == {boot_number:null,present:false} and
    .target == {
      boot_number:"0007",
      label:"Windows Boot Manager",
      loader_path:"\\EFI\\Microsoft\\Boot\\bootmgfw.efi",
      partuuid:"11111111-2222-3333-4444-555555555555"
    } and
    .efibootmgr.package == $package and .efibootmgr.executable_sha256 == $hash
  ' "$record" >/dev/null || fail_test "BootNext pre-write evidence is incomplete"

  tampered=$(jq '.unexpected = true' "$record")
  if validate_bootnext_record_json "$transaction_id" "$tampered" \
    "$(read_control_document "$manifest")"; then
    fail_test "BootNext record accepted an unknown field"
  fi
  tampered=$(jq '.target.label = "Windows ${unsafe}"' "$record")
  if validate_bootnext_record_json "$transaction_id" "$tampered" \
    "$(read_control_document "$manifest")"; then
    fail_test "BootNext record accepted an unsafe target label"
  fi
}

test_bootnext_prior_value() {
  local manifest record
  setup_bootnext_fixture bootnext-prior
  write_bootnext_variable 0042
  run_windows_bootnext || fail_test "BootNext replacement transaction failed"
  manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
  record=$(jq -r '.domain_records.bootnext.path' "$manifest")
  jq -e '.prior == {boot_number:"0042",present:true}' "$record" >/dev/null \
    || fail_test "BootNext transaction did not preserve the prior exact value"
}

test_bootnext_preflight_boundaries() {
  local lifecycle_hash variable
  setup_bootnext_fixture bootnext-attributes
  write_bootnext_variable 0009 3
  lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "unsupported BootNext attributes passed preflight"
  fi
  [[ $(sha256_file "$(lifecycle_file_path)") == "$lifecycle_hash" \
    && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "BootNext attribute uncertainty opened a transaction"

  setup_bootnext_fixture bootnext-tool
  BOOTNEXT_TOOL_VALID=false
  lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "unverified efibootmgr passed BootNext preflight"
  fi
  [[ $(sha256_file "$(lifecycle_file_path)") == "$lifecycle_hash" \
    && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "efibootmgr uncertainty opened a transaction"

  setup_bootnext_fixture bootnext-truncated
  variable=$(windows_bootnext_variable_path)
  printf '\x07\x00\x00\x00\x09' > "$variable"
  chmod 600 "$variable"
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "truncated BootNext payload passed preflight"
  fi
  read_lifecycle || fail_test "truncated BootNext preflight damaged lifecycle"
  [[ "$_lifecycle_state" == active && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "truncated BootNext payload opened a transaction"

  setup_bootnext_fixture bootnext-symlink
  variable=$(windows_bootnext_variable_path)
  ln -s "$(windows_target_state_path)" "$variable"
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "symlink BootNext variable passed preflight"
  fi
  read_lifecycle || fail_test "symlink BootNext preflight damaged lifecycle"
  [[ "$_lifecycle_state" == active && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "symlink BootNext variable opened a transaction"

  setup_bootnext_fixture bootnext-mount-race
  BOOTNEXT_MOUNT_FAIL_AT=2
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "efivarfs mount race passed BootNext preflight"
  fi
  read_lifecycle || fail_test "efivarfs mount race damaged lifecycle"
  [[ "$_lifecycle_state" == active && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "efivarfs mount race opened a transaction"
}

test_bootnext_prewrite_races() {
  setup_bootnext_fixture bootnext-prior-race
  BOOTNEXT_FAILPOINT=after-bootnext-record
  BOOTNEXT_FAIL_ACTION=change-prior
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "BootNext prior-value race reported success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "prior-value race reached efibootmgr"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-target-race
  BOOTNEXT_FAILPOINT=before-target-revalidation
  BOOTNEXT_FAIL_ACTION=change-target
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "Windows target race reported BootNext success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "target race reached efibootmgr"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-tool-race
  BOOTNEXT_FAILPOINT=after-bootnext-record
  BOOTNEXT_FAIL_ACTION=change-tool
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "efibootmgr identity race reported BootNext success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "efibootmgr identity race reached mutation"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-boot-race
  BOOTNEXT_FAILPOINT=after-bootnext-record
  BOOTNEXT_FAIL_ACTION=change-boot
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "boot-ID race reported BootNext success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "boot-ID race reached efibootmgr"
  assert_bootnext_recovery set-bootnext
}

test_bootnext_command_failures() {
  local state
  setup_bootnext_fixture bootnext-command-no-effect
  BOOTNEXT_COMMAND_EFFECT=false
  BOOTNEXT_COMMAND_RC=23
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "failed no-effect efibootmgr command reported success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 1 ]] || fail_test "failed efibootmgr command was not bounded"
  state=$(read_windows_bootnext_state)
  jq -e '.present == false and .boot_number == null' <<< "$state" >/dev/null \
    || fail_test "no-effect efibootmgr failure changed BootNext"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-command-effect
  BOOTNEXT_COMMAND_RC=23
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "failed after-effect efibootmgr command reported success"
  fi
  state=$(read_windows_bootnext_state)
  jq -e '.present == true and .boot_number == "0007"' <<< "$state" >/dev/null \
    || fail_test "after-effect efibootmgr failure lost its observable state"
  assert_bootnext_recovery set-bootnext
}

test_bootnext_readback_and_interruption() {
  local state signal_rc
  setup_bootnext_fixture bootnext-mismatch
  BOOTNEXT_EFFECT_NUMBER=0008
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "mismatched BootNext readback reported success"
  fi
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-unreadable-readback
  BOOTNEXT_FAILPOINT=after-bootnext-command
  BOOTNEXT_FAIL_ACTION=corrupt-attributes
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "malformed post-write BootNext readback reported success"
  fi
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-interruption
  BOOTNEXT_FAILPOINT=after-bootnext-command
  BOOTNEXT_FAIL_ACTION=signal-term
  signal_rc=0
  { (run_windows_bootnext >/dev/null 2>&1) || signal_rc=$?; } 2>/dev/null
  [[ $signal_rc -eq 143 ]] || fail_test "post-write TERM did not propagate"
  state=$(read_windows_bootnext_state)
  jq -e '.present == true and .boot_number == "0007"' <<< "$state" >/dev/null \
    || fail_test "post-write interruption did not preserve observable BootNext"
  assert_bootnext_recovery set-bootnext
}

test_bootnext_commit_failure() {
  local manifest state
  setup_bootnext_fixture bootnext-commit-failure
  LIFECYCLE_FAILPOINT=before-stable-state-write
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "BootNext stable-state publication failure reported success"
  fi
  state=$(read_windows_bootnext_state)
  jq -e '.present == true and .boot_number == "0007"' <<< "$state" >/dev/null \
    || fail_test "stable-state failure lost the verified BootNext value"
  read_lifecycle || fail_test "BootNext stable-state failure damaged lifecycle"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "BootNext stable-state failure did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .operation == "windows-bootnext" and .status == "completed" and
    .completed_phases == ["record-bootnext","set-bootnext"] and
    .domain_records.bootnext != null
  ' "$manifest" >/dev/null \
    || fail_test "BootNext stable-state failure lost completed transaction evidence"
}

recover_windows_incident() {
  local rc=0
  with_boot_repair_lock || return 1
  run_windows_recovery_locked || rc=$?
  release_boot_repair_lock
  return "$rc"
}

create_bootnext_effect_incident() {
  BOOTNEXT_COMMAND_RC=23
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "BootNext recovery fixture reported root success"
  fi
  BOOTNEXT_COMMAND_RC=0
  BOOTNEXT_COMMAND_CALLS=0
  : > "$BOOTNEXT_CALL_LOG"
}

assert_windows_recovery_result() {
  local expected_outcome="$1" expected_action="$2" lifecycle recovery_id manifest record proof
  read_lifecycle || fail_test "Windows recovery result was unreadable"
  [[ "$_lifecycle_state" == active ]] || fail_test "Windows recovery did not restore active state"
  lifecycle="$_lifecycle_json"
  recovery_id=$(jq -r '.last_recovery.final_attempt.id' <<< "$lifecycle")
  manifest=$(lifecycle_manifest_path "$recovery_id")
  jq -e --arg outcome "$expected_outcome" --arg action "$expected_action" '
    .kind == "recovery-attempt" and .operation == "windows-recovery" and
    .status == "completed" and .completed_phases ==
      ["classify-bootnext","restore-bootnext","prove-bootnext"] and
    .domain_records.windows != null and .domain_records.final_proof != null and
    .domain_records.firmware == null and .domain_records.producer == null
  ' "$manifest" >/dev/null || fail_test "completed Windows recovery manifest is incomplete"
  record=$(jq -r '.domain_records.windows.path' "$manifest")
  proof=$(jq -r '.domain_records.final_proof.path' "$manifest")
  jq -e --arg outcome "$expected_outcome" --arg action "$expected_action" '
    .planned_outcome == $outcome and .action == $action
  ' "$record" >/dev/null || fail_test "Windows recovery record has the wrong classification"
  jq -e --arg outcome "$expected_outcome" \
    '.outcome == $outcome' "$proof" >/dev/null \
    || fail_test "Windows recovery proof has the wrong outcome"
  validate_windows_recovery_record_reference "$recovery_id" \
    "$(jq -c '.domain_records.windows' "$manifest")" \
    "$(read_control_document "$manifest")" \
    || fail_test "Windows recovery record reference is invalid"
  validate_windows_recovery_proof_reference "$recovery_id" \
    "$(jq -c '.domain_records.final_proof' "$manifest")" \
    "$(read_control_document "$manifest")" \
    || fail_test "Windows recovery proof reference is invalid"
}

test_windows_recovery_restores_absence() {
  local root_id root_manifest_hash root_incident_hash state proof
  setup_bootnext_fixture recovery-absence
  create_bootnext_effect_incident
  read_lifecycle || fail_test "absence recovery root was unreadable"
  root_id="$_lifecycle_transaction_id"
  root_manifest_hash=$(sha256_file "$(lifecycle_manifest_path "$root_id")")
  root_incident_hash=$(sha256_file "$(lifecycle_incident_path "$root_id")")
  UNLINK_COMMAND_RC=23
  recover_windows_incident || fail_test "recorded absence was not restored"
  [[ $UNLINK_COMMAND_CALLS -eq 1 && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "absence recovery used the wrong mutation boundary"
  state=$(read_windows_bootnext_state) || fail_test "restored absence was unreadable"
  jq -e '.present == false and .boot_number == null' <<< "$state" >/dev/null \
    || fail_test "Windows recovery did not restore BootNext absence"
  assert_windows_recovery_result prior-restored delete
  proof=$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")
  jq -e '.command_exit_code == 23 and
    .final_state == {boot_number:null,present:false}' "$proof" >/dev/null \
    || fail_test "absence recovery proof omitted direct readback"
  [[ $(sha256_file "$(lifecycle_manifest_path "$root_id")") == "$root_manifest_hash" \
    && $(sha256_file "$(lifecycle_incident_path "$root_id")") == "$root_incident_hash" ]] \
    || fail_test "Windows recovery rewrote root evidence"
}

test_windows_recovery_restores_value() {
  local state proof
  setup_bootnext_fixture recovery-value
  write_bootnext_variable 0042
  create_bootnext_effect_incident
  BOOTNEXT_COMMAND_RC=23
  recover_windows_incident \
    || fail_test "recorded BootNext value was not restored from direct readback"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 1 && $(<"$BOOTNEXT_CALL_LOG") == '-n 0042' \
    && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "value recovery did not issue one exact efibootmgr restoration"
  state=$(read_windows_bootnext_state) || fail_test "restored BootNext value was unreadable"
  jq -e '.present == true and .boot_number == "0042"' <<< "$state" >/dev/null \
    || fail_test "Windows recovery did not restore the prior BootNext value"
  assert_windows_recovery_result prior-restored set-prior
  proof=$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")
  jq -e '.command_exit_code == 23 and
    .final_state == {boot_number:"0042",present:true}' "$proof" >/dev/null \
    || fail_test "readback-authoritative value recovery proof is incomplete"
}

test_windows_recovery_prior_unchanged() {
  local state
  setup_bootnext_fixture recovery-unchanged
  BOOTNEXT_COMMAND_EFFECT=false
  BOOTNEXT_COMMAND_RC=23
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "unchanged recovery fixture reported root success"
  fi
  BOOTNEXT_COMMAND_RC=0
  BOOTNEXT_COMMAND_EFFECT=true
  BOOTNEXT_COMMAND_CALLS=0
  recover_windows_incident || fail_test "unchanged prior state did not recover"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "unchanged prior state caused a recovery write"
  state=$(read_windows_bootnext_state) || fail_test "unchanged prior state was unreadable"
  jq -e '.present == false and .boot_number == null' <<< "$state" >/dev/null \
    || fail_test "unchanged recovery altered BootNext"
  assert_windows_recovery_result prior-unchanged none
}

test_windows_recovery_consumed_unknown() {
  local state proof
  setup_bootnext_fixture recovery-consumed
  create_bootnext_effect_incident
  rm -f "$(windows_bootnext_variable_path)"
  TEST_BOOT_ID='11111111-2222-4333-8444-555555555555'
  recover_windows_incident || fail_test "cross-boot absence did not resolve"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "cross-boot consumed state caused a write"
  state=$(read_windows_bootnext_state) || fail_test "consumed BootNext state was unreadable"
  jq -e '.present == false and .boot_number == null' <<< "$state" >/dev/null \
    || fail_test "consumed-unknown recovery changed BootNext"
  assert_windows_recovery_result consumed-unknown none
  proof=$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")
  jq -e '.command_exit_code == null and
    .final_state == {boot_number:null,present:false}' "$proof" >/dev/null \
    || fail_test "consumed-unknown proof made an unsupported claim"
}

test_windows_recovery_cross_boot_before_write() {
  local manifest state
  setup_bootnext_fixture recovery-cross-boot-before-write
  BOOTNEXT_FAILPOINT=after-bootnext-record
  BOOTNEXT_FAIL_ACTION=fail
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "pre-write cross-boot fixture reported success"
  fi
  read_lifecycle || fail_test "pre-write cross-boot root was unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.domain_records.bootnext != null and
    (.completed_phases | index("record-bootnext")) == null' "$manifest" >/dev/null \
    || fail_test "pre-write root did not preserve its exact frontier"
  TEST_BOOT_ID='11111111-2222-4333-8444-555555555555'
  BOOTNEXT_FAILPOINT=""
  BOOTNEXT_FAIL_ACTION=""
  recover_windows_incident || fail_test "proved pre-write incident did not recover"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "proved pre-write incident caused a recovery write"
  state=$(read_windows_bootnext_state) || fail_test "pre-write prior state was unreadable"
  jq -e '.present == false and .boot_number == null' <<< "$state" >/dev/null \
    || fail_test "pre-write cross-boot recovery changed BootNext"
  assert_windows_recovery_result prior-unchanged none
  manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")")
  jq -e '.write_frontier == "not-reached"' \
    "$(jq -r '.domain_records.windows.path' "$manifest")" >/dev/null \
    || fail_test "pre-write recovery record lost the no-write frontier"
}

test_windows_recovery_refuses_changed_before_write() {
  local root_id attempt_count
  setup_bootnext_fixture recovery-changed-before-write
  BOOTNEXT_FAILPOINT=after-bootnext-record
  BOOTNEXT_FAIL_ACTION=fail
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "changed pre-write fixture reported root success"
  fi
  read_lifecycle || fail_test "changed pre-write root was unreadable"
  root_id="$_lifecycle_transaction_id"
  write_bootnext_variable 0008
  TEST_BOOT_ID='11111111-2222-4333-8444-555555555555'
  BOOTNEXT_FAILPOINT=""
  BOOTNEXT_FAIL_ACTION=""
  if recover_windows_incident >/dev/null 2>&1; then
    fail_test "changed state before the write frontier reported recovery success"
  fi
  read_lifecycle || fail_test "changed pre-write refusal damaged lifecycle"
  attempt_count=$(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json")
  [[ "$_lifecycle_state" == recovery-required && "$_lifecycle_transaction_id" == "$root_id" \
    && $attempt_count -eq 0 && $BOOTNEXT_COMMAND_CALLS -eq 0 \
    && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "changed pre-write state acquired unauthorized recovery authority"
}

test_windows_recovery_without_published_record() {
  local root_id manifest
  setup_bootnext_fixture recovery-not-published
  RESOLVE_FAIL_AT=2
  if run_windows_bootnext >/dev/null 2>&1; then
    fail_test "recordless BootNext fixture reported success"
  fi
  read_lifecycle || fail_test "recordless root was unreadable"
  root_id="$_lifecycle_transaction_id"
  manifest=$(lifecycle_manifest_path "$root_id")
  jq -e '.domain_records.bootnext == null and .current_phase == "record-bootnext"' \
    "$manifest" >/dev/null || fail_test "recordless root published mutation authority"
  BOOTNEXT_MOUNT_FAIL_AT=1
  recover_windows_incident || fail_test "recordless BootNext incident did not resolve"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "recordless recovery reached a mutation boundary"
  assert_windows_recovery_result not-published none
}

test_windows_recovery_refuses_unrelated_state() {
  local root_id attempt_count
  setup_bootnext_fixture recovery-unrelated
  create_bootnext_effect_incident
  write_bootnext_variable 0008
  read_lifecycle || fail_test "unrelated-state root was unreadable"
  root_id="$_lifecycle_transaction_id"
  if recover_windows_incident >/dev/null 2>&1; then
    fail_test "unrelated BootNext state reported recovery success"
  fi
  read_lifecycle || fail_test "unrelated-state refusal damaged lifecycle"
  attempt_count=$(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json")
  [[ "$_lifecycle_state" == recovery-required && "$_lifecycle_transaction_id" == "$root_id" \
    && $attempt_count -eq 0 && $BOOTNEXT_COMMAND_CALLS -eq 0 \
    && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "unrelated-state refusal published an unauthorized attempt"
}

test_windows_recovery_refuses_unreadable_state() {
  local root_id attempt_count
  setup_bootnext_fixture recovery-unreadable
  create_bootnext_effect_incident
  write_bootnext_variable 0007 3
  read_lifecycle || fail_test "unreadable-state root was unreadable"
  root_id="$_lifecycle_transaction_id"
  if recover_windows_incident >/dev/null 2>&1; then
    fail_test "unsupported BootNext attributes reported recovery success"
  fi
  read_lifecycle || fail_test "unreadable-state refusal damaged lifecycle"
  attempt_count=$(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json")
  [[ "$_lifecycle_state" == recovery-required && "$_lifecycle_transaction_id" == "$root_id" \
    && $attempt_count -eq 0 && $BOOTNEXT_COMMAND_CALLS -eq 0 \
    && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "unreadable-state refusal published an unauthorized attempt"
}

test_windows_recovery_refuses_execute_time_unreadable_state() {
  local point expected_unlink_calls manifest
  for point in after-recovery-record after-recovery-command; do
    setup_bootnext_fixture "recovery-execute-unreadable-${point}"
    create_bootnext_effect_incident
    WINDOWS_RECOVERY_FAILPOINT="$point"
    WINDOWS_RECOVERY_FAIL_ACTION=corrupt-attributes
    if recover_windows_incident >/dev/null 2>&1; then
      fail_test "${point} unreadable BootNext state reported recovery success"
    fi
    read_lifecycle || fail_test "${point} unreadable-state attempt was unreadable"
    if [[ "$point" == after-recovery-record ]]; then
      expected_unlink_calls=0
    else
      expected_unlink_calls=1
    fi
    [[ "$_lifecycle_state" == recovery-required \
      && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 1 \
      && $UNLINK_COMMAND_CALLS -eq expected_unlink_calls ]] \
      || fail_test "${point} unreadable state did not fail at the expected boundary"
    manifest=$(lifecycle_manifest_path \
      "$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")")
    jq -e '.failure.reason | startswith("BootNext") and contains("unreadable")' \
      "$manifest" >/dev/null \
      || fail_test "${point} unreadable state did not preserve its failure reason"
  done
}

test_windows_recovery_restores_cross_boot_target() {
  local state
  setup_bootnext_fixture recovery-cross-boot-target
  create_bootnext_effect_incident
  TEST_BOOT_ID='11111111-2222-4333-8444-555555555555'
  recover_windows_incident || fail_test "cross-boot exact target was not restored"
  [[ $UNLINK_COMMAND_CALLS -eq 1 && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "cross-boot exact target used the wrong restoration boundary"
  state=$(read_windows_bootnext_state) || fail_test "cross-boot restoration was unreadable"
  jq -e '.present == false and .boot_number == null' <<< "$state" >/dev/null \
    || fail_test "cross-boot target was not restored to recorded absence"
  assert_windows_recovery_result prior-restored delete
}

test_windows_recovery_restores_cross_boot_present_prior() {
  local state
  setup_bootnext_fixture recovery-cross-boot-present-prior
  write_bootnext_variable 0042
  create_bootnext_effect_incident
  TEST_BOOT_ID='11111111-2222-4333-8444-555555555555'
  recover_windows_incident || fail_test "cross-boot present prior was not restored"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 1 && $(<"$BOOTNEXT_CALL_LOG") == '-n 0042' \
    && $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "cross-boot present prior used the wrong restoration boundary"
  state=$(read_windows_bootnext_state) \
    || fail_test "cross-boot present-prior restoration was unreadable"
  jq -e '.present == true and .boot_number == "0042"' <<< "$state" >/dev/null \
    || fail_test "cross-boot target was not restored to the recorded prior value"
  assert_windows_recovery_result prior-restored set-prior
}

test_windows_recovery_retries_failed_delete() {
  local first_attempt first_manifest first_hash state
  setup_bootnext_fixture recovery-delete-retry
  create_bootnext_effect_incident
  UNLINK_COMMAND_EFFECT=false
  UNLINK_COMMAND_RC=23
  if recover_windows_incident >/dev/null 2>&1; then
    fail_test "no-effect unlink failure reported recovery success"
  fi
  read_lifecycle || fail_test "failed delete attempt was unreadable"
  [[ "$_lifecycle_state" == recovery-required \
    && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 1 ]] \
    || fail_test "failed delete did not preserve the recovery incident"
  first_attempt=$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")
  first_manifest=$(lifecycle_manifest_path "$first_attempt")
  first_hash=$(sha256_file "$first_manifest")
  jq -e '.operation == "windows-recovery" and .status == "failed" and
    .failure.phase == "restore-bootnext" and
    .failure.reason == "BootNext recovery readback does not match the recorded prior state" and
    .domain_records.windows != null and
    .domain_records.final_proof == null' "$first_manifest" >/dev/null \
    || fail_test "failed delete attempt evidence is incomplete"
  UNLINK_COMMAND_EFFECT=true
  UNLINK_COMMAND_RC=0
  recover_windows_incident || fail_test "failed delete retry did not recover"
  [[ $UNLINK_COMMAND_CALLS -eq 2 \
    && $(sha256_file "$first_manifest") == "$first_hash" ]] \
    || fail_test "delete retry rewrote prior attempt evidence"
  state=$(read_windows_bootnext_state) || fail_test "delete retry state was unreadable"
  jq -e '.present == false' <<< "$state" >/dev/null \
    || fail_test "delete retry did not restore absence"
  assert_windows_recovery_result prior-restored delete
}

test_windows_recovery_retries_failed_value_restore() {
  local state first_manifest
  setup_bootnext_fixture recovery-value-retry
  write_bootnext_variable 0042
  create_bootnext_effect_incident
  BOOTNEXT_COMMAND_EFFECT=false
  BOOTNEXT_COMMAND_RC=23
  if recover_windows_incident >/dev/null 2>&1; then
    fail_test "no-effect value restoration reported recovery success"
  fi
  read_lifecycle || fail_test "failed value restoration was unreadable"
  [[ "$_lifecycle_state" == recovery-required \
    && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 1 \
    && $BOOTNEXT_COMMAND_CALLS -eq 1 ]] \
    || fail_test "failed value restoration did not preserve the recovery incident"
  first_manifest=$(lifecycle_manifest_path \
    "$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")")
  jq -e '.failure.reason ==
    "BootNext recovery readback does not match the recorded prior state"' \
    "$first_manifest" >/dev/null \
    || fail_test "failed value restoration did not preserve its failure reason"
  BOOTNEXT_COMMAND_EFFECT=true
  BOOTNEXT_COMMAND_RC=0
  recover_windows_incident || fail_test "failed value restoration did not retry"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 2 ]] \
    || fail_test "value restoration retry did not use one fresh write"
  state=$(read_windows_bootnext_state) || fail_test "value restoration retry was unreadable"
  jq -e '.present == true and .boot_number == "0042"' <<< "$state" >/dev/null \
    || fail_test "value restoration retry did not restore the recorded prior"
  assert_windows_recovery_result prior-restored set-prior
}

test_windows_recovery_resolves_interrupted_delete() {
  local state proof
  setup_bootnext_fixture recovery-delete-interruption
  create_bootnext_effect_incident
  WINDOWS_RECOVERY_FAILPOINT=after-recovery-command
  WINDOWS_RECOVERY_FAIL_ACTION=fail
  if recover_windows_incident >/dev/null 2>&1; then
    fail_test "post-delete interruption reported recovery success"
  fi
  state=$(read_windows_bootnext_state) || fail_test "post-delete state was unreadable"
  jq -e '.present == false' <<< "$state" >/dev/null \
    || fail_test "post-delete interruption lost the observed deletion"
  WINDOWS_RECOVERY_FAILPOINT=""
  WINDOWS_RECOVERY_FAIL_ACTION=""
  UNLINK_COMMAND_CALLS=0
  recover_windows_incident || fail_test "post-delete retry did not resolve"
  [[ $UNLINK_COMMAND_CALLS -eq 0 ]] \
    || fail_test "post-delete retry replayed an already observed deletion"
  assert_windows_recovery_result prior-unchanged none
  proof=$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")
  jq -e '.command_exit_code == null' "$proof" >/dev/null \
    || fail_test "post-delete retry invented a command result"
}

test_windows_recovery_resolves_interrupted_value_restore() {
  local state
  setup_bootnext_fixture recovery-value-interruption
  write_bootnext_variable 0042
  create_bootnext_effect_incident
  WINDOWS_RECOVERY_FAILPOINT=after-recovery-command
  WINDOWS_RECOVERY_FAIL_ACTION=fail
  if recover_windows_incident >/dev/null 2>&1; then
    fail_test "post-value-restore interruption reported recovery success"
  fi
  state=$(read_windows_bootnext_state) || fail_test "post-value-restore state was unreadable"
  jq -e '.present == true and .boot_number == "0042"' <<< "$state" >/dev/null \
    || fail_test "post-value-restore interruption lost the observed restoration"
  WINDOWS_RECOVERY_FAILPOINT=""
  WINDOWS_RECOVERY_FAIL_ACTION=""
  BOOTNEXT_COMMAND_CALLS=0
  : > "$BOOTNEXT_CALL_LOG"
  recover_windows_incident || fail_test "post-value-restore retry did not resolve"
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "post-value-restore retry replayed an observed restoration"
  assert_windows_recovery_result prior-unchanged none
}

test_windows_recovery_reconciles_completed_transition() {
  local attempt_id attempt_manifest attempt_hash child_rc=0
  setup_bootnext_fixture recovery-completed-transition
  create_bootnext_effect_incident
  LIFECYCLE_FAILPOINT=before-recovery-resolved-state-write
  (recover_windows_incident >/dev/null 2>&1) || child_rc=$?
  [[ $child_rc -ne 0 ]] || fail_test "failed stable recovery publication reported success"
  LIFECYCLE_FAILPOINT=""
  read_lifecycle || fail_test "completed recovery transition was unreadable"
  [[ "$_lifecycle_state" == transition ]] \
    || fail_test "failed stable recovery publication did not retain its transition"
  attempt_id="$_lifecycle_transaction_id"
  attempt_manifest=$(lifecycle_manifest_path "$attempt_id")
  jq -e '.kind == "recovery-attempt" and .operation == "windows-recovery" and
    .status == "completed" and .domain_records.final_proof != null' \
    "$attempt_manifest" >/dev/null \
    || fail_test "completed Windows recovery transition lost its proof"
  attempt_hash=$(sha256_file "$attempt_manifest")
  recover_windows_incident || fail_test "completed Windows recovery transition did not reconcile"
  read_lifecycle || fail_test "reconciled Windows recovery was unreadable"
  [[ "$_lifecycle_state" == active \
    && $(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json") == "$attempt_id" \
    && $(sha256_file "$attempt_manifest") == "$attempt_hash" ]] \
    || fail_test "stale reconciliation replayed or rewrote completed Windows recovery"
}

test_windows_recovery_prewrite_races() {
  local action manifest
  for action in change-boot change-state replace-variable; do
    setup_bootnext_fixture "recovery-race-${action}"
    create_bootnext_effect_incident
    WINDOWS_RECOVERY_FAILPOINT=after-recovery-record
    WINDOWS_RECOVERY_FAIL_ACTION="$action"
    if recover_windows_incident >/dev/null 2>&1; then
      fail_test "${action} Windows recovery race reported success"
    fi
    read_lifecycle || fail_test "${action} recovery race damaged lifecycle"
    [[ "$_lifecycle_state" == recovery-required && $UNLINK_COMMAND_CALLS -eq 0 ]] \
      || fail_test "${action} recovery race reached unlink"
    if [[ "$action" == change-state ]]; then
      manifest=$(lifecycle_manifest_path \
        "$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")")
      jq -e '.failure.reason ==
        "BootNext changed after Windows recovery evidence was recorded"' \
        "$manifest" >/dev/null \
        || fail_test "changed-state race did not preserve its failure reason"
    fi
  done
}

test_windows_recovery_set_prior_prewrite_races() {
  local action
  for action in change-boot change-state change-tool; do
    setup_bootnext_fixture "recovery-set-prior-race-${action}"
    write_bootnext_variable 0042
    create_bootnext_effect_incident
    WINDOWS_RECOVERY_FAILPOINT=after-recovery-record
    WINDOWS_RECOVERY_FAIL_ACTION="$action"
    if recover_windows_incident >/dev/null 2>&1; then
      fail_test "${action} set-prior recovery race reported success"
    fi
    read_lifecycle || fail_test "${action} set-prior race damaged lifecycle"
    [[ "$_lifecycle_state" == recovery-required && $BOOTNEXT_COMMAND_CALLS -eq 0 \
      && $UNLINK_COMMAND_CALLS -eq 0 ]] \
      || fail_test "${action} set-prior race reached a mutation boundary"
  done
}

test_windows_recovery_schema_tamper() {
  local manifest transaction_id record proof tampered
  setup_bootnext_fixture recovery-schema
  create_bootnext_effect_incident
  recover_windows_incident || fail_test "schema fixture recovery failed"
  read_lifecycle || fail_test "schema fixture lifecycle was unreadable"
  transaction_id=$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")
  manifest=$(lifecycle_manifest_path "$transaction_id")
  record=$(jq -r '.domain_records.windows.path' "$manifest")
  proof=$(jq -r '.domain_records.final_proof.path' "$manifest")
  tampered=$(jq '.planned_outcome = "consumed-unknown"' "$record")
  if validate_windows_recovery_record_json "$transaction_id" "$tampered" \
    "$(read_control_document "$manifest")"; then
    fail_test "Windows recovery record accepted a contradictory outcome"
  fi
  tampered=$(jq '.unexpected = true' "$proof")
  if validate_windows_recovery_proof_json "$transaction_id" "$tampered" \
    "$(read_control_document "$manifest")"; then
    fail_test "Windows recovery proof accepted an unknown field"
  fi
}

run_case() {
  local name="$1" function="$2" log pid registration_signal=""
  log="${TEST_DIR}/case-${name}.log"
  trap 'registration_signal=INT' INT
  trap 'registration_signal=TERM' TERM
  trap 'registration_signal=HUP' HUP
  (
    trap - EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    "$function"
  ) > "$log" 2>&1 &
  pid=$!
  run_case_pids+=("$pid")
  run_case_names+=("$name")
  run_case_logs+=("$log")
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  case "$registration_signal" in
    INT) return 130 ;;
    TERM) return 143 ;;
    HUP) return 129 ;;
  esac
  if (( ${#run_case_pids[@]} >= windows_entry_test_jobs )); then
    wait_for_cases || fail_test "Windows entry test batch failed"
  fi
}

replay_case_log() {
  local log="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&2
  done < "$log"
}

wait_for_cases() {
  local index rc failed=false
  for index in "${!run_case_pids[@]}"; do
    rc=0
    wait "${run_case_pids[$index]}" || rc=$?
    replay_case_log "${run_case_logs[$index]}"
    if (( rc != 0 )); then
      printf 'FAIL: case failed: %s\n' "${run_case_names[$index]}" >&2
      failed=true
    fi
  done
  run_case_pids=()
  run_case_names=()
  run_case_logs=()
  [[ "$failed" == false ]]
}

windows_entry_test_jobs=${WINDOWS_ENTRY_TEST_JOBS:-4}
[[ "$windows_entry_test_jobs" =~ ^[1-9][0-9]*$ && $windows_entry_test_jobs -le 16 ]] \
  || fail_test "WINDOWS_ENTRY_TEST_JOBS must be between 1 and 16"
declare -a run_case_pids=() run_case_names=() run_case_logs=()

run_case successful-setup test_successful_setup
run_case label-round-trip test_label_round_trip
run_case config-boundaries test_config_boundaries
run_case state-schema test_state_schema_rejection
run_case artifact-failure test_artifact_failure_rollback
run_case config-failure test_config_failure_rollback
run_case final-proof-failure test_final_proof_failure_rollback
run_case non-active-refusal test_non_active_refusal
run_case ownership-consistency test_setup_ownership_consistency
run_case legacy-migration test_legacy_state_without_block_migration
run_case stale-suppression test_stale_suppression
run_case valid-suppression-refusal test_valid_target_suppression_refusal
run_case suppression-preflight test_suppression_preflight_failure
run_case legacy-suppression test_legacy_block_suppression
run_case malformed-suppression test_malformed_block_suppression_refusal
run_case unprovable-suppression test_unprovable_target_suppression
run_case suppression-revalidation test_in_transaction_proof_failure_suppression
run_case valid-again-rollback test_valid_again_suppression_rollback
run_case suppression-artifact-rollback test_suppression_artifact_failure_rollback
run_case suppression-proof-rollback test_suppression_final_proof_rollback
run_case bootnext-success test_bootnext_success_and_schema
run_case bootnext-prior test_bootnext_prior_value
run_case bootnext-preflight test_bootnext_preflight_boundaries
run_case bootnext-races test_bootnext_prewrite_races
run_case bootnext-command-failures test_bootnext_command_failures
run_case bootnext-readback test_bootnext_readback_and_interruption
run_case bootnext-commit-failure test_bootnext_commit_failure
run_case recovery-absence test_windows_recovery_restores_absence
run_case recovery-value test_windows_recovery_restores_value
run_case recovery-unchanged test_windows_recovery_prior_unchanged
run_case recovery-consumed test_windows_recovery_consumed_unknown
run_case recovery-cross-boot-before-write test_windows_recovery_cross_boot_before_write
run_case recovery-changed-before-write test_windows_recovery_refuses_changed_before_write
run_case recovery-not-published test_windows_recovery_without_published_record
run_case recovery-unrelated test_windows_recovery_refuses_unrelated_state
run_case recovery-unreadable test_windows_recovery_refuses_unreadable_state
run_case recovery-execute-unreadable test_windows_recovery_refuses_execute_time_unreadable_state
run_case recovery-cross-boot-target test_windows_recovery_restores_cross_boot_target
run_case recovery-cross-boot-present-prior test_windows_recovery_restores_cross_boot_present_prior
run_case recovery-delete-retry test_windows_recovery_retries_failed_delete
run_case recovery-value-retry test_windows_recovery_retries_failed_value_restore
run_case recovery-delete-interruption test_windows_recovery_resolves_interrupted_delete
run_case recovery-value-interruption test_windows_recovery_resolves_interrupted_value_restore
run_case recovery-completed-transition test_windows_recovery_reconciles_completed_transition
run_case recovery-races test_windows_recovery_prewrite_races
run_case recovery-set-prior-races test_windows_recovery_set_prior_prewrite_races
run_case recovery-schema test_windows_recovery_schema_tamper
wait_for_cases || fail_test "Windows entry test batch failed"

printf 'windows entry tests passed\n'
