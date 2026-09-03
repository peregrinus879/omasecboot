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
# shellcheck source=../lib/windows.sh
source "${ROOT_DIR}/lib/windows.sh"

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
RESOLVE_BOOTNEXT_CHANGE_AT=0
ARTIFACT_FAIL=false
PREFLIGHT_FAIL=false
CONFIG_SYNC_FAIL=false
REINSERT_BLOCK_AFTER_REPAIR=false
REPAIR_BODY_CALLS=0
PREFLIGHT_CONFIG_CHECKSUM=""
REPAIR_CONFIG_CHECKSUM=""
_repair_config_checksum=""
BOOTNEXT_CAPABILITY=true
BOOTNEXT_TOOL_VALID=true
BOOTNEXT_TOOL_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
BOOTNEXT_COMMAND_RC=0
BOOTNEXT_COMMAND_EFFECT=true
BOOTNEXT_EFFECT_NUMBER=""
BOOTNEXT_COMMAND_CALLS=0
BOOTNEXT_FAILPOINT=""
BOOTNEXT_FAIL_ACTION=""
BOOTNEXT_CALL_LOG=""
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

windows_bootnext_efivars_dir() {
  printf '%s/efivars\n' "$CASE_DIR"
}

windows_validate_efivarfs_mount() {
  local directory
  BOOTNEXT_MOUNT_VALIDATIONS=$((BOOTNEXT_MOUNT_VALIDATIONS + 1))
  (( BOOTNEXT_MOUNT_FAIL_AT == 0 \
    || BOOTNEXT_MOUNT_VALIDATIONS != BOOTNEXT_MOUNT_FAIL_AT )) || return 1
  directory=$(windows_bootnext_efivars_dir) || return 1
  [[ -d "$directory" && ! -L "$directory" ]]
}

windows_bootnext_mutation_is_available() {
  [[ "$BOOTNEXT_CAPABILITY" == true ]]
}

validate_windows_efibootmgr_boundary() {
  [[ "$BOOTNEXT_TOOL_VALID" == true \
    && "$BOOTNEXT_TOOL_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
  _windows_efibootmgr_hash="$BOOTNEXT_TOOL_HASH"
}

hash_bound_windows_efibootmgr() {
  [[ "$BOOTNEXT_TOOL_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$BOOTNEXT_TOOL_HASH"
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
    disable-capability) BOOTNEXT_CAPABILITY=false ;;
    corrupt-attributes) write_bootnext_variable 0007 3 ;;
    signal-term) kill -TERM "$BASHPID" ;;
    fail) return 75 ;;
    *) return 1 ;;
  esac
}

capture_service_state() {
  printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"inactive","unit_file_state":"disabled"}}'
}

systemctl() {
  [[ "$*" == "show --property=ActiveState --value ${TRANSACTION_SERVICE_UNIT}" ]] \
    || return 1
  printf 'inactive\n'
}

resolve_windows_target() {
  RESOLVE_CALLS=$((RESOLVE_CALLS + 1))
  if [[ "$RESOLVE_ALWAYS_FAIL" == true ]] \
    || (( RESOLVE_FAIL_AT > 0 && RESOLVE_CALLS == RESOLVE_FAIL_AT )); then
    return 1
  fi
  if (( RESOLVE_BOOTNEXT_CHANGE_AT > 0 \
    && RESOLVE_CALLS == RESOLVE_BOOTNEXT_CHANGE_AT )); then
    write_bootnext_variable 0008 || return 1
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

artifact_repair_preflight() {
  [[ "$PREFLIGHT_FAIL" == false ]] || return 1
  _repair_config_checksum=$(current_limine_config_checksum) || return 1
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
  rm -rf "$CASE_DIR"
  mkdir -p "$(dirname "$CONFIG_FILE")" "${CASE_DIR}/efivars"
  chmod 755 "$CASE_DIR" "$(dirname "$CONFIG_FILE")" "${CASE_DIR}/efivars"
  printf 'original\n' > "$ARTIFACT_FILE"
  : > "$BOOTNEXT_CALL_LOG"
  TARGET_BOOT=0007
  TARGET_LABEL='Windows Boot Manager'
  TARGET_PARTUUID='11111111-2222-3333-4444-555555555555'
  RESOLVE_CALLS=0
  RESOLVE_FAIL_AT=0
  RESOLVE_ALWAYS_FAIL=false
  RESOLVE_BOOTNEXT_CHANGE_AT=0
  ARTIFACT_FAIL=false
  PREFLIGHT_FAIL=false
  CONFIG_SYNC_FAIL=false
  REINSERT_BLOCK_AFTER_REPAIR=false
  REPAIR_BODY_CALLS=0
  PREFLIGHT_CONFIG_CHECKSUM=""
  REPAIR_CONFIG_CHECKSUM=""
  _repair_config_checksum=""
  BOOTNEXT_CAPABILITY=true
  BOOTNEXT_TOOL_VALID=true
  BOOTNEXT_TOOL_HASH='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  BOOTNEXT_COMMAND_RC=0
  BOOTNEXT_COMMAND_EFFECT=true
  BOOTNEXT_EFFECT_NUMBER=""
  BOOTNEXT_COMMAND_CALLS=0
  BOOTNEXT_FAILPOINT=""
  BOOTNEXT_FAIL_ACTION=""
  BOOTNEXT_MOUNT_VALIDATIONS=0
  BOOTNEXT_MOUNT_FAIL_AT=0
  TEST_BOOT_ID='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
  LIFECYCLE_FAILPOINT=""
  _windows_bootnext_record_json=""
  _windows_bootnext_record_path=""
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

  run_windows_handoff_setup || fail_test "dormant Windows setup transaction failed"
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
  run_lifecycle_transaction "disable-windows-test" "disabled" "active" : \
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
  run_dormant_windows_bootnext || fail_test "dormant BootNext transaction failed"
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
    --arg package "$WINDOWS_EFIBOOTMGR_PACKAGE_IDENTITY" '
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
  run_dormant_windows_bootnext || fail_test "BootNext replacement transaction failed"
  manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
  record=$(jq -r '.domain_records.bootnext.path' "$manifest")
  jq -e '.prior == {boot_number:"0042",present:true}' "$record" >/dev/null \
    || fail_test "BootNext transaction did not preserve the prior exact value"
}

test_bootnext_preflight_boundaries() {
  local lifecycle_hash variable
  setup_bootnext_fixture bootnext-gate
  lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
  BOOTNEXT_CAPABILITY=false
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "closed BootNext capability opened a transaction"
  fi
  [[ $(sha256_file "$(lifecycle_file_path)") == "$lifecycle_hash" \
    && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "closed BootNext capability changed durable state"

  setup_bootnext_fixture bootnext-attributes
  write_bootnext_variable 0009 3
  lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "unsupported BootNext attributes passed preflight"
  fi
  [[ $(sha256_file "$(lifecycle_file_path)") == "$lifecycle_hash" \
    && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "BootNext attribute uncertainty opened a transaction"

  setup_bootnext_fixture bootnext-tool
  BOOTNEXT_TOOL_VALID=false
  lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "unverified efibootmgr passed BootNext preflight"
  fi
  [[ $(sha256_file "$(lifecycle_file_path)") == "$lifecycle_hash" \
    && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "efibootmgr uncertainty opened a transaction"

  setup_bootnext_fixture bootnext-truncated
  variable=$(windows_bootnext_variable_path)
  printf '\x07\x00\x00\x00\x09' > "$variable"
  chmod 600 "$variable"
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "truncated BootNext payload passed preflight"
  fi
  read_lifecycle || fail_test "truncated BootNext preflight damaged lifecycle"
  [[ "$_lifecycle_state" == active && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "truncated BootNext payload opened a transaction"

  setup_bootnext_fixture bootnext-symlink
  variable=$(windows_bootnext_variable_path)
  ln -s "$(windows_target_state_path)" "$variable"
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "symlink BootNext variable passed preflight"
  fi
  read_lifecycle || fail_test "symlink BootNext preflight damaged lifecycle"
  [[ "$_lifecycle_state" == active && $BOOTNEXT_COMMAND_CALLS -eq 0 ]] \
    || fail_test "symlink BootNext variable opened a transaction"

  setup_bootnext_fixture bootnext-mount-race
  BOOTNEXT_MOUNT_FAIL_AT=2
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
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
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "BootNext prior-value race reported success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "prior-value race reached efibootmgr"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-target-race
  BOOTNEXT_FAILPOINT=before-target-revalidation
  BOOTNEXT_FAIL_ACTION=change-target
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "Windows target race reported BootNext success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "target race reached efibootmgr"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-tool-race
  BOOTNEXT_FAILPOINT=after-bootnext-record
  BOOTNEXT_FAIL_ACTION=change-tool
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "efibootmgr identity race reported BootNext success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "efibootmgr identity race reached mutation"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-boot-race
  BOOTNEXT_FAILPOINT=after-bootnext-record
  BOOTNEXT_FAIL_ACTION=change-boot
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "boot-ID race reported BootNext success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "boot-ID race reached efibootmgr"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-capability-race
  BOOTNEXT_FAILPOINT=before-target-revalidation
  BOOTNEXT_FAIL_ACTION=disable-capability
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "closed second BootNext gate reported success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 0 ]] || fail_test "closed second gate reached efibootmgr"
  assert_bootnext_recovery set-bootnext
}

test_bootnext_command_failures() {
  local state
  setup_bootnext_fixture bootnext-command-no-effect
  BOOTNEXT_COMMAND_EFFECT=false
  BOOTNEXT_COMMAND_RC=23
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "failed no-effect efibootmgr command reported success"
  fi
  [[ $BOOTNEXT_COMMAND_CALLS -eq 1 ]] || fail_test "failed efibootmgr command was not bounded"
  state=$(read_windows_bootnext_state)
  jq -e '.present == false and .boot_number == null' <<< "$state" >/dev/null \
    || fail_test "no-effect efibootmgr failure changed BootNext"
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-command-effect
  BOOTNEXT_COMMAND_RC=23
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
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
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "mismatched BootNext readback reported success"
  fi
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-unreadable-readback
  BOOTNEXT_FAILPOINT=after-bootnext-command
  BOOTNEXT_FAIL_ACTION=corrupt-attributes
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "malformed post-write BootNext readback reported success"
  fi
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-postwrite-target
  BOOTNEXT_FAILPOINT=after-bootnext-command
  BOOTNEXT_FAIL_ACTION=change-target
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "post-write Windows target drift reported success"
  fi
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-final-readback-race
  RESOLVE_BOOTNEXT_CHANGE_AT=4
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
    fail_test "BootNext change during final target proof reported success"
  fi
  assert_bootnext_recovery set-bootnext

  setup_bootnext_fixture bootnext-interruption
  BOOTNEXT_FAILPOINT=after-bootnext-command
  BOOTNEXT_FAIL_ACTION=signal-term
  signal_rc=0
  { (run_dormant_windows_bootnext >/dev/null 2>&1) || signal_rc=$?; } 2>/dev/null
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
  if run_dormant_windows_bootnext >/dev/null 2>&1; then
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
wait_for_cases || fail_test "Windows entry test batch failed"

printf 'windows entry tests passed\n'
