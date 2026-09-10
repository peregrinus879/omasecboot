#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329 # Hermetic overrides are intentional.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init unconfigure

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=../lib/records.sh
source "${ROOT_DIR}/lib/records.sh"
# shellcheck source=../lib/software.sh
source "${ROOT_DIR}/lib/software.sh"
# shellcheck source=../lib/discover.sh
source "${ROOT_DIR}/lib/discover.sh"
# shellcheck source=../lib/sign.sh
source "${ROOT_DIR}/lib/sign.sh"
# shellcheck source=../lib/producers.sh
source "${ROOT_DIR}/lib/producers.sh"
# shellcheck source=../lib/enroll.sh
source "${ROOT_DIR}/lib/enroll.sh"
# shellcheck source=../lib/windows.sh
source "${ROOT_DIR}/lib/windows.sh"

QUIET=true
UNCONFIGURE_RECOVERY_FAILPOINT=""

limine_targets_are_unenrolled() {
  [[ $(read_limine_embedded_checksum "$(limine_primary_binary_path)") == "$LIMINE_ZERO_CHECKSUM" ]] \
    || return 1
  [[ ! -e "$(limine_fallback_binary_path)" ]] \
    || [[ $(read_limine_embedded_checksum "$(limine_fallback_binary_path)") == \
      "$LIMINE_ZERO_CHECKSUM" ]]
}

unconfigure_recovery_failpoint() {
  [[ "$1" != "$UNCONFIGURE_RECOVERY_FAILPOINT" ]]
}

state_dir_path() { printf '%s/state\n' "$CASE_DIR"; }
limine_lock_path() { printf '%s/boot-partition.lock\n' "$CASE_DIR"; }
snapshot_restore_lock_path() { printf '%s/restore.lock\n' "$CASE_DIR"; }
pacman_database_lock_path() { printf '%s/pacman-db.lck\n' "$CASE_DIR"; }
esp_path() { printf '%s/boot\n' "$CASE_DIR"; }
limine_config_path() { printf '%s/boot/limine.conf\n' "$CASE_DIR"; }
limine_default_config_path() { printf '%s/limine-defaults\n' "$CASE_DIR"; }
limine_entry_tool_config_files() { printf '%s\n' "$(limine_default_config_path)"; }
limine_unsigned_binary_path() { printf '%s/stock-BOOTX64.EFI\n' "$CASE_DIR"; }
sbctl_config_path() { printf '%s/sbctl.conf\n' "$CASE_DIR"; }
sbctl_database_candidate_paths() { printf '%s\n' "$SBCTL_FILES_DB"; }
control_owner_uid() { id -u; }
require_control_root() { :; }
durable_sync() {
  if [[ "$ESP_SYNC_FAIL" == true && "$1" == "$(esp_path)" \
    && $(grep -Fxc reset "$COMMAND_LOG" 2>/dev/null || true) -eq 2 ]]; then
    return 1
  fi
}
mountpoint() { [[ "$1" == -q && "$2" == "$(esp_path)" ]]; }
findmnt() {
  [[ "$1" == -n && "$2" == -T && "$3" == "$(esp_path)" && "$4" == -o \
    && "$5" == FSTYPE ]] || return 1
  printf 'vfat\n'
}
limine_enrollment_hooks_present() { return 1; }
limine_install_path() { printf 'limine-install\n'; }
limine_mkinitcpio_path() { printf 'limine-mkinitcpio\n'; }
limine_reset_enroll_path() { printf 'limine-reset-enroll\n'; }
unconfigure_limine_tools_are_pinned() { return 0; }
# The recorded tool version differs from the current pin on purpose: every
# read of a completed unconfiguration below is a read under a later release.
RECORDED_TOOL_VERSION=1.37.1-1
[[ "$RECORDED_TOOL_VERSION" != "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" ]] \
  || fail_test "the recorded tool version fixture must differ from the pin"
capture_unconfigure_limine_tools() {
  jq -cn --arg version "$RECORDED_TOOL_VERSION" '{
    package: "limine-mkinitcpio-hook",
    version: $version,
    install: {path: "limine-install", identity: "1:1", sha256: ("a" * 64)},
    mkinitcpio: {path: "limine-mkinitcpio", identity: "1:2", sha256: ("b" * 64)},
    reset: {path: "limine-reset-enroll", identity: "1:3", sha256: ("c" * 64)}
  }'
}
unconfigure_limine_tools_match_intent() { return 0; }
run_bound_unconfigure_limine_tool() {
  local key="$1" handoff="$2" command
  shift 2
  case "$key" in
    install) command=limine-install ;;
    mkinitcpio) command=limine-mkinitcpio ;;
    reset) command=limine-reset-enroll ;;
    *) return 1 ;;
  esac
  if [[ "$handoff" == true ]]; then
    with_limine_lock_handoff "$command" "$@"
  else
    "$command" "$@"
  fi
}
read_current_firmware_modes() {
  _setup_mode=0
  _audit_mode=0
  _deployed_mode=0
  _secure_boot_mode="$SECURE_BOOT_MODE"
}

write_limine_binary() {
  local path="$1" checksum="$2" prefix="${3:-FAKE_EFI}"
  printf '%s\n%s%s\n' "$prefix" "$LIMINE_CONFIG_MARKER" "$checksum" > "$path"
}

limine-reset-enroll() {
  local reset
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 2
  reset=$(printf '0%.0s' {1..128})
  printf 'reset\n' >> "$COMMAND_LOG"
  if [[ "$LIMINE_INSTALLED" == true ]]; then
    cp "$(limine_unsigned_binary_path)" "$(limine_primary_binary_path)" || return 1
  else
    write_limine_binary "$(limine_primary_binary_path)" "$reset" RESET_EFI
  fi
}

# limine-install 1.38.0 deploys the fallback with --fallback (or with
# ENABLE_LIMINE_FALLBACK unset and the loader missing, which the fixtures
# never combine); the arguments are logged for the fallback-policy cases.
limine-install() {
  local fallback=false
  case "$*" in
    '--no-efi-register') ;;
    '--no-efi-register --fallback') fallback=true ;;
    *) return 2 ;;
  esac
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 2
  printf 'install\n' >> "$COMMAND_LOG"
  printf '%s\n' "$*" >> "${COMMAND_LOG}.install"
  if [[ "$INSTALL_NOOP" == false ]]; then
    cp "$(limine_unsigned_binary_path)" "$(limine_primary_binary_path)" || return 1
    if [[ "$fallback" == true ]]; then
      cp "$(limine_unsigned_binary_path)" "$(limine_fallback_binary_path)" || return 1
    fi
    LIMINE_INSTALLED=true
  fi
}

limine-mkinitcpio() {
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 2
  printf 'mkinitcpio\n' >> "$COMMAND_LOG"
  [[ "$REBUILD_FAIL" == false ]] || return 1
  if [[ "$(limine_managed_setting_state ENABLE_ENROLL_LIMINE_CONFIG)" == yes ]]; then
    write_limine_binary "$(limine_primary_binary_path)" "$(printf 'e%.0s' {1..128})" \
      ENROLLED_EFI
  fi
}

sbctl() {
  local path
  case "$1" in
    list-files)
      [[ "${2:-}" == --json ]] || return 2
      jq '[to_entries[] | .value + {is_signed: true}]' "$SBCTL_FILES_DB"
      ;;
    remove-file)
      [[ $# -eq 2 ]] || return 2
      [[ "$SBCTL_REMOVE_FAIL" == false ]] || return 47
      path="$2"
      jq --arg path "$path" 'del(.[$path])' "$SBCTL_FILES_DB" \
        > "${SBCTL_FILES_DB}.tmp" || return 1
      mv "${SBCTL_FILES_DB}.tmp" "$SBCTL_FILES_DB"
      ;;
    *) return 2 ;;
  esac
}

seed_tracking_ownership() {
  local settings
  load_lifecycle_ownership_records || return 1
  settings=$(jq -c '.settings' <<< "$_managed_settings_record_json") || return 1
  transaction_phase_start seed-ownership || return 1
  persist_managed_settings_record repair "$settings" || return 1
  persist_tracking_ownership_record "$(jq -cn --arg path "$PRIMARY" '[$path]')" \
    || return 1
  transaction_phase_complete seed-ownership
}

setup_fixture() {
  local name="$1" original_verification="${2:-yes}" original_enrollment="${3:-no}"
  local checksum external
  release_boot_repair_lock 2>/dev/null || true
  CASE_DIR="${TEST_DIR}/${name}"
  PRIMARY="${CASE_DIR}/boot/EFI/limine/limine_x64.efi"
  FALLBACK="${CASE_DIR}/boot/EFI/BOOT/BOOTX64.EFI"
  EXTERNAL="${CASE_DIR}/boot/EFI/Tools/external.efi"
  SBCTL_FILES_DB="${CASE_DIR}/files.json"
  COMMAND_LOG="${CASE_DIR}/commands.log"
  SECURE_BOOT_MODE=0
  REBUILD_FAIL=false
  SBCTL_REMOVE_FAIL=false
  INSTALL_NOOP=false
  LIMINE_INSTALLED=false
  ESP_SYNC_FAIL=false
  UNCONFIGURE_RECOVERY_FAILPOINT=""
  _recovery_previous_manifest_json=""
  mkdir -p "$(state_dir_path)" "$(dirname "$PRIMARY")" "$(dirname "$FALLBACK")" \
    "$(dirname "$EXTERNAL")"
  chmod 755 "$(state_dir_path)"
  printf '%s\n' \
    'ENABLE_VERIFICATION=no' \
    'ENABLE_ENROLL_LIMINE_CONFIG=yes' \
    'COMMANDS_BEFORE_SAVE="other limine-reset-enroll"' \
    'COMMANDS_AFTER_SAVE="limine-enroll-config other"' \
    > "$(limine_default_config_path)"
  printf '%s\n' \
    'TIMEOUT=5' \
    "$WINDOWS_ENTRY_MARKER" \
    '/Windows' \
    '    comment: Windows Boot Manager' \
    '    protocol: efi_boot_entry' \
    '    entry: Windows Boot Manager' \
    "$WINDOWS_ENTRY_END_MARKER" \
    '/Native' \
    '    protocol: efi' \
    > "$(limine_config_path)"
  checksum=$(printf 'f%.0s' {1..128})
  write_limine_binary "$PRIMARY" "$checksum" MANAGED_EFI
  # FIXTURE_FALLBACK=absent models a stock install with
  # ENABLE_LIMINE_FALLBACK=no and no fallback loader; it applies to one fixture.
  if [[ "${FIXTURE_FALLBACK:-managed}" == absent ]]; then
    printf 'ENABLE_LIMINE_FALLBACK=no\n' >> "$(limine_default_config_path)"
  else
    write_limine_binary "$FALLBACK" "$checksum" MANAGED_EFI
  fi
  FIXTURE_FALLBACK=managed
  write_limine_binary "$(limine_unsigned_binary_path)" "$(printf '0%.0s' {1..128})" STOCK_EFI
  printf 'EXTERNAL\n' > "$EXTERNAL"
  jq -cn --arg primary "$PRIMARY" --arg external "$EXTERNAL" '{
    ($primary): {file: $primary, output: $primary},
    ($external): {file: $external, output: $external}
  }' > "$SBCTL_FILES_DB"
  printf 'files_db: %s\n' "$SBCTL_FILES_DB" > "$(sbctl_config_path)"
  : > "$COMMAND_LOG"
  jq -cn --arg loader "$WINDOWS_LOADER_UEFI" '{
    schema_version: 1,
    writer_version: "1.0.0",
    enabled: true,
    boot_number: "0007",
    label: "Windows Boot Manager",
    loader_path: $loader,
    partuuid: "12345678-1234-1234-1234-123456789abc"
  }' > "$(windows_target_state_path)"
  chmod 644 "$(windows_target_state_path)"
  mkdir -p "${CASE_DIR}/key-state"
  printf 'unchanged\n' > "${CASE_DIR}/key-state/marker"

  adopt_lifecycle : no "$original_verification" yes "$original_enrollment" \
    present absent present absent || fail_test "${name}: adoption failed"
}

test_successful_unconfigure() {
  local windows_hash key_hash manifest intent forged_intent
  setup_fixture success
  run_lifecycle_transaction seed-ownership active active seed_tracking_ownership \
    || fail_test "ownership seed failed"
  windows_hash=$(sha256_file "$(windows_target_state_path)")
  key_hash=$(sha256_file "${CASE_DIR}/key-state/marker")

  run_unconfigure || fail_test "unconfiguration failed"
  read_lifecycle || fail_test "disabled lifecycle is unreadable"
  [[ "$_lifecycle_state" == disabled ]] || fail_test "disabled state was not committed"
  jq -e '
    .managed_settings == null and .tracking_ownership == null and
    .last_transaction.operation == "unconfigure"
  ' <<< "$_lifecycle_json" >/dev/null || fail_test "ownership was not retired at commit"
  manifest=$(jq -r '.last_transaction.manifest' <<< "$_lifecycle_json")
  jq -e '
    .status == "completed" and .file_rollback_policy == "preserve" and
    .completed_phases == [
      "record-unconfigure","backup-software-state","restore-managed-settings",
      "remove-windows-entry","remove-owned-tracking","reset-config-enrollment",
      "rebuild-stock-limine","prove-unconfigured"
    ] and .domain_records.unconfigure != null and .domain_records.final_proof != null
  ' "$manifest" >/dev/null || fail_test "completed unconfiguration proof is incomplete"
  intent=$(jq -r '.domain_records.unconfigure.path' "$manifest")
  jq -e --arg version "$RECORDED_TOOL_VERSION" '
    .operation == "unconfigure" and .managed_settings != null and
    .tracking_ownership != null and .limine_source.sha256 != null and
    .limine_tools.package == "limine-mkinitcpio-hook" and
    .limine_tools.version == $version and
    ([.limine_tools.install, .limine_tools.mkinitcpio, .limine_tools.reset] |
      all(.identity != null and .sha256 != null))
  ' "$intent" >/dev/null \
    || fail_test "unconfiguration intent is incomplete"
  forged_intent=$(jq '.limine_tools.version = "not a version!"' "$intent")
  if validate_unconfigure_intent_json "$(jq -r '.id' "$manifest")" \
    "$forged_intent" "$(<"$manifest")"; then
    fail_test "unconfiguration intent accepted a malformed tool version"
  fi
  forged_intent=$(jq '.limine_tools.version = "1.99.0-1"' "$intent")
  validate_unconfigure_intent_json "$(jq -r '.id' "$manifest")" \
    "$forged_intent" "$(<"$manifest")" \
    || fail_test "unconfiguration intent rejected another release's tool version"
  jq -e '
    .limine.source.sha256 == .limine.primary.sha256 and
    .limine.source.sha256 == .limine.fallback.sha256
  ' "$(jq -r '.domain_records.final_proof.path' "$manifest")" >/dev/null \
    || fail_test "unconfiguration proof is not bound to the stock Limine binary"
  [[ "$(limine_managed_setting_state ENABLE_VERIFICATION)" == yes \
    && "$(limine_managed_setting_state ENABLE_ENROLL_LIMINE_CONFIG)" == no \
    && "$(limine_managed_token_state COMMANDS_BEFORE_SAVE limine-reset-enroll)" == absent \
    && "$(limine_managed_token_state COMMANDS_AFTER_SAVE limine-enroll-config)" == absent ]] \
    || fail_test "managed Limine settings were not restored"
  windows_managed_block_state 'Windows Boot Manager' || fail_test "Windows block is invalid"
  [[ "$_windows_block_state" == absent ]] || fail_test "owned Windows block remains"
  grep -Fxq '/Native' "$(limine_config_path)" || fail_test "native Limine entry was removed"
  jq -e --arg primary "$PRIMARY" --arg external "$EXTERNAL" '
    (has($primary) | not) and has($external)
  ' "$SBCTL_FILES_DB" >/dev/null || fail_test "tracking ownership removal was not selective"
  limine_targets_are_unenrolled || fail_test "Limine enrollment was not reset"
  [[ "$(sha256_file "$(windows_target_state_path)")" == "$windows_hash" \
    && "$(sha256_file "${CASE_DIR}/key-state/marker")" == "$key_hash" ]] \
    || fail_test "Windows opt-in or local keys changed"
  [[ "$(tr '\n' ' ' < "$COMMAND_LOG")" == 'reset install mkinitcpio reset ' ]] \
    || fail_test "stock Limine children did not run in order"
  lifecycle_removal_is_allowed || fail_test "proved disabled state did not allow removal"
}

# Stock Omarchy without a fallback loader (ENABLE_LIMINE_FALLBACK=no, as the
# Vivobook TP3402VA's 4.0.3 install): the intent records the fallback as
# absent, the stock rebuild runs without --fallback, and the proof carries no
# fallback target.
test_unconfigure_without_fallback() {
  local manifest intent proof
  FIXTURE_FALLBACK=absent
  setup_fixture no-fallback
  [[ ! -e "$FALLBACK" ]] || fail_test "the no-fallback fixture wrote a fallback"
  run_lifecycle_transaction seed-ownership active active seed_tracking_ownership \
    || fail_test "no-fallback ownership seed failed"
  run_unconfigure || fail_test "unconfiguration without a fallback failed"
  read_lifecycle || fail_test "no-fallback disabled lifecycle is unreadable"
  [[ "$_lifecycle_state" == disabled ]] || fail_test "no-fallback disabled state was not committed"
  manifest=$(jq -r '.last_transaction.manifest' <<< "$_lifecycle_json")
  intent=$(jq -r '.domain_records.unconfigure.path' "$manifest")
  jq -e '.limine_fallback == "absent"' "$intent" >/dev/null \
    || fail_test "the intent did not record the fallback as absent"
  proof=$(jq -r '.domain_records.final_proof.path' "$manifest")
  jq -e '.limine.fallback == null and .limine.primary.sha256 == .limine.source.sha256' \
    "$proof" >/dev/null || fail_test "the proof did not record the primary alone"
  [[ "$(<"${COMMAND_LOG}.install")" == '--no-efi-register' ]] \
    || fail_test "limine-install was asked to deploy a fallback: $(<"${COMMAND_LOG}.install")"
  [[ ! -e "$FALLBACK" ]] || fail_test "unconfiguration created a fallback loader"
  jq -e --arg fallback "$FALLBACK" \
    '([.backups[] | select(.target == $fallback)] | length) == 0' "$manifest" >/dev/null \
    || fail_test "the transaction backed up an absent fallback"
  limine_targets_are_unenrolled || fail_test "the primary was not reset without a fallback"
  lifecycle_removal_is_allowed || fail_test "disabled state without a fallback refused removal"
}

# Recovery on that machine follows the intent's record: a fallback loader
# that appears after the intent blocks recovery, and its removal lets the
# attempt complete with the fallback still recorded absent.
test_recovery_without_fallback() {
  local rc=0 proof
  FIXTURE_FALLBACK=absent
  setup_fixture no-fallback-recovery
  run_lifecycle_transaction seed-ownership active active seed_tracking_ownership \
    || fail_test "no-fallback recovery seed failed"
  REBUILD_FAIL=true
  if run_unconfigure; then
    fail_test "no-fallback recovery fixture unexpectedly completed"
  fi
  read_lifecycle || fail_test "no-fallback recovery fixture is unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "the failed rebuild did not require recovery"
  REBUILD_FAIL=false
  write_limine_binary "$FALLBACK" "$(printf '0%.0s' {1..128})" FOREIGN_EFI
  with_boot_repair_lock || fail_test "could not lock no-fallback recovery"
  if run_unconfigure_recovery_locked; then
    release_boot_repair_lock
    fail_test "recovery accepted a fallback that appeared after the intent"
  fi
  release_boot_repair_lock
  read_lifecycle || fail_test "blocked recovery damaged the lifecycle"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "a foreign fallback did not keep recovery pending"
  rm -f "$FALLBACK"
  with_boot_repair_lock || fail_test "could not relock no-fallback recovery"
  run_unconfigure_recovery_locked || rc=$?
  release_boot_repair_lock
  [[ $rc -eq 0 ]] || fail_test "no-fallback recovery failed"
  read_lifecycle || fail_test "recovered no-fallback lifecycle is unreadable"
  [[ "$_lifecycle_state" == disabled ]] || fail_test "no-fallback recovery did not publish disabled"
  proof=$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")
  jq -e '.operation == "unconfigure-recovery" and .limine.fallback == null' "$proof" >/dev/null \
    || fail_test "no-fallback recovery proof recorded a fallback"
  [[ ! -e "$FALLBACK" ]] || fail_test "no-fallback recovery created a fallback loader"
}

test_unknown_original_blocks_before_transition() {
  setup_fixture unknown unknown
  if run_unconfigure; then
    fail_test "unknown original value allowed unconfiguration"
  fi
  read_lifecycle || fail_test "unknown-original lifecycle became unreadable"
  [[ "$_lifecycle_state" == active && ! -s "$COMMAND_LOG" ]] \
    || fail_test "unknown original value crossed the mutation boundary"
}

test_three_way_conflict_blocks_before_transition() {
  setup_fixture conflict
  replace_limine_default_entry ENABLE_VERIFICATION || fail_test "could not create conflict"
  if run_unconfigure; then
    fail_test "managed-setting conflict allowed unconfiguration"
  fi
  read_lifecycle || fail_test "conflict lifecycle became unreadable"
  [[ "$_lifecycle_state" == active && ! -s "$COMMAND_LOG" ]] \
    || fail_test "three-way conflict crossed the mutation boundary"
}

test_rebuild_failure_preserves_files() {
  local manifest forged
  setup_fixture rebuild-failure
  run_lifecycle_transaction seed-ownership active active seed_tracking_ownership \
    || fail_test "failure ownership seed failed"
  REBUILD_FAIL=true
  if run_unconfigure; then
    fail_test "failed stock rebuild committed disabled state"
  fi
  read_lifecycle || fail_test "failed rebuild lifecycle became unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "failed external rebuild did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .operation == "unconfigure" and .status == "failed" and
    .failure.phase == "rebuild-stock-limine" and
    .file_rollback_policy == "preserve" and .rollback.status == "preserved"
  ' "$manifest" >/dev/null || fail_test "failed rebuild did not preserve its frontier"
  forged=$(jq -c '.file_rollback_policy = "restore"' "$manifest")
  if validate_transaction_manifest_json "$_lifecycle_transaction_id" "$forged"; then
    fail_test "post-reset manifest accepted restore rollback policy"
  fi
  limine_targets_are_unenrolled || fail_test "preserved rebuild frontier was rolled back"
  if lifecycle_removal_is_allowed; then
    fail_test "recovery-required state allowed package removal"
  fi
}

test_rebuild_failure_recovers_disabled() {
  local manifest proof rc=0
  setup_fixture rebuild-recovery
  run_lifecycle_transaction seed-ownership active active seed_tracking_ownership \
    || fail_test "recovery ownership seed failed"
  REBUILD_FAIL=true
  if run_unconfigure; then
    fail_test "recovery fixture unexpectedly completed unconfiguration"
  fi
  read_lifecycle || fail_test "unconfigure recovery fixture is unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  [[ $(recovery_operation_for_root_manifest "$(<"$manifest")") == \
    unconfigure-recovery ]] || fail_test "preserved unconfigure selected the wrong recovery"

  REBUILD_FAIL=false
  with_boot_repair_lock || fail_test "could not lock unconfigure recovery"
  run_unconfigure_recovery_locked || rc=$?
  release_boot_repair_lock
  [[ $rc -eq 0 ]] || fail_test "unconfigure recovery failed"
  read_lifecycle || fail_test "recovered disabled lifecycle is unreadable"
  jq -e '
    .state == "disabled" and .managed_settings == null and
    .tracking_ownership == null and
    .last_transaction.operation == "unconfigure-recovery"
  ' <<< "$_lifecycle_json" >/dev/null \
    || fail_test "unconfigure recovery did not publish clean disabled state"
  proof=$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")
  jq -e '
    .operation == "unconfigure-recovery" and .root_incident != null and
    .intent != null and .settings == "original" and
    .windows == "managed-block-absent"
  ' "$proof" >/dev/null || fail_test "unconfigure recovery proof is incomplete"
  lifecycle_removal_is_allowed \
    || fail_test "recovered disabled state did not allow package removal"
}

test_pre_reset_failure_rolls_back_files() {
  local defaults_hash config_hash database_hash manifest forged
  setup_fixture pre-reset-failure
  run_lifecycle_transaction seed-ownership active active seed_tracking_ownership \
    || fail_test "pre-reset ownership seed failed"
  defaults_hash=$(sha256_file "$(limine_default_config_path)")
  config_hash=$(sha256_file "$(limine_config_path)")
  database_hash=$(sha256_file "$SBCTL_FILES_DB")
  SBCTL_REMOVE_FAIL=true
  if run_unconfigure; then
    fail_test "pre-reset tracking failure reported success"
  fi
  read_lifecycle || fail_test "pre-reset failure lifecycle became unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .failure.phase == "remove-owned-tracking" and
    .file_rollback_policy == "restore" and .rollback.status == "completed"
  ' "$manifest" >/dev/null || fail_test "pre-reset failure crossed the preserve frontier"
  forged=$(jq -c '.file_rollback_policy = "preserve"' "$manifest")
  if validate_transaction_manifest_json "$_lifecycle_transaction_id" "$forged"; then
    fail_test "pre-reset manifest accepted preserve rollback policy"
  fi
  [[ "$(sha256_file "$(limine_default_config_path)")" == "$defaults_hash" \
    && "$(sha256_file "$(limine_config_path)")" == "$config_hash" \
    && "$(sha256_file "$SBCTL_FILES_DB")" == "$database_hash" ]] \
    || fail_test "pre-reset failure did not restore software state"
}

test_noop_install_rejects_non_stock_targets() {
  local manifest
  setup_fixture noop-install
  INSTALL_NOOP=true
  if run_unconfigure; then
    fail_test "no-op Limine install proved non-stock targets"
  fi
  read_lifecycle || fail_test "no-op install lifecycle became unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "no-op install did not preserve a recovery frontier"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .failure.phase == "rebuild-stock-limine" and
    .file_rollback_policy == "preserve" and .domain_records.unconfigure != null and
    .domain_records.final_proof == null
  ' "$manifest" >/dev/null || fail_test "non-stock target failure frontier is invalid"
}

test_esp_sync_failure_blocks_disabled_commit() {
  local manifest
  setup_fixture esp-sync-failure
  ESP_SYNC_FAIL=true
  if run_unconfigure; then
    fail_test "ESP sync failure committed disabled state"
  fi
  read_lifecycle || fail_test "ESP sync failure lifecycle became unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "ESP sync failure did not preserve a recovery frontier"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '
    .failure.phase == "rebuild-stock-limine" and
    .file_rollback_policy == "preserve" and .domain_records.unconfigure != null and
    .domain_records.final_proof == null
  ' "$manifest" >/dev/null || fail_test "ESP sync failure frontier is invalid"
}

test_legacy_windows_block_is_removed() {
  setup_fixture legacy-windows
  : > "$(windows_target_state_path)"
  sed -i \
    -e "s/^${WINDOWS_ENTRY_MARKER//\//\\/}$/${WINDOWS_LEGACY_ENTRY_MARKER//\//\\/}/" \
    -e "/^${WINDOWS_ENTRY_END_MARKER//\//\\/}$/d" \
    "$(limine_config_path)"
  run_unconfigure || fail_test "legacy Windows ownership blocked unconfiguration"
  windows_managed_block_state '' || fail_test "legacy Windows block left invalid markers"
  [[ "$_windows_block_state" == absent && ! -s "$(windows_target_state_path)" ]] \
    || fail_test "legacy Windows block or empty opt-in marker was changed incorrectly"
}

test_original_enrollment_setting_is_restored() {
  setup_fixture original-enrollment yes yes
  run_unconfigure || fail_test "original config-enrollment setting blocked unconfiguration"
  [[ "$(limine_managed_setting_state ENABLE_ENROLL_LIMINE_CONFIG)" == yes ]] \
    || fail_test "original config-enrollment setting was not restored"
  unconfigured_limine_targets_match_source \
    || fail_test "final reset did not remove nested rebuild enrollment"
}

test_recovery_phase_failpoints() (
  local phase expected phase_index
  local -a phases=(
    restore-managed-settings
    remove-windows-entry
    remove-owned-tracking
    reset-config-enrollment
    rebuild-stock-limine
    prove-unconfigured
  )
  local effect_log completed_log current_phase recovery_failpoint
  phase_prefix() {
    local count="$1" index
    for ((index = 0; index < count; index++)); do
      printf '%s ' "${phases[$index]}"
    done
  }
  unconfigure_inputs_are_current() { return 0; }
  preserve_transaction_files_on_failure() { return 0; }
  transaction_phase_start() { current_phase="$1"; }
  transaction_phase_complete() {
    completed_log+="${1} "
    current_phase=""
  }
  restore_limine_managed_settings() { effect_log+="restore-managed-settings "; }
  remove_windows_managed_block_for_unconfigure() { effect_log+="remove-windows-entry "; }
  remove_owned_tracking_entries() { effect_log+="remove-owned-tracking "; }
  run_bound_unconfigure_limine_tool() { effect_log+="reset-config-enrollment "; }
  run_checked_stock_limine_rebuild() { effect_log+="rebuild-stock-limine "; }
  read_current_firmware_modes() { _secure_boot_mode=0; }
  limine_managed_settings_are_original() { return 0; }
  owned_tracking_is_absent() { return 0; }
  windows_unconfigure_preflight() { _windows_block_state=absent; }
  unconfigure_windows_state_identity() { printf '%s\n' fixture-windows; }
  unconfigured_limine_targets_match_source() { return 0; }
  persist_unconfigure_proof() { effect_log+="prove-unconfigured "; }
  unconfigure_recovery_failpoint() { [[ "$1" != "$recovery_failpoint" ]]; }
  _unconfigure_managed_settings_json='{}'
  _unconfigure_tracking_paths_json='[]'
  _unconfigure_windows_identity=fixture-windows

  for phase_index in "${!phases[@]}"; do
    phase=${phases[$phase_index]}
    recovery_failpoint="after-${phase}"
    effect_log=""
    completed_log=""
    current_phase=""
    if unconfigure_recovery_transaction; then
      fail_test "recovery phase failpoint succeeded: ${phase}"
    fi
    expected=$(phase_prefix "$((phase_index + 1))")
    [[ "$effect_log" == "$expected" && "$current_phase" == "$phase" ]] \
      || fail_test "recovery failure crossed the ${phase} frontier"
    expected=$(phase_prefix "$phase_index")
    [[ "$completed_log" == "$expected" ]] \
      || fail_test "recovery failure completed the ${phase} phase"
    recovery_failpoint=""
    unconfigure_recovery_transaction \
      || fail_test "recovery retry failed after ${phase} interruption"
    expected=$(phase_prefix "${#phases[@]}")
    [[ "$current_phase" == "" && "$completed_log" == \
      "$(phase_prefix "$phase_index")${expected}" ]] \
      || fail_test "recovery retry did not complete after ${phase} interruption"
  done
)

test_recovery_phase_failure_chain() {
  local root_id root_incident root_hash phase attempt_id attempt_manifest rc
  local expected_attempt=0
  local -a phases=(
    restore-managed-settings
    remove-windows-entry
    remove-owned-tracking
    reset-config-enrollment
    rebuild-stock-limine
    prove-unconfigured
  )
  setup_fixture recovery-phase-chain
  run_lifecycle_transaction seed-ownership active active seed_tracking_ownership \
    || fail_test "recovery phase ownership seed failed"
  REBUILD_FAIL=true
  if run_unconfigure; then
    fail_test "recovery phase root unexpectedly completed"
  fi
  read_lifecycle || fail_test "recovery phase root is unreadable"
  root_id="$_lifecycle_transaction_id"
  root_incident=$(lifecycle_incident_path "$root_id")
  root_hash=$(sha256_file "$root_incident") || fail_test "could not hash recovery root"
  REBUILD_FAIL=false

  for phase in "${phases[@]}"; do
    UNCONFIGURE_RECOVERY_FAILPOINT="after-${phase}"
    rc=0
    with_boot_repair_lock || fail_test "${phase} recovery lock failed"
    run_unconfigure_recovery_locked >/dev/null 2>&1 || rc=$?
    release_boot_repair_lock
    [[ $rc -ne 0 ]] || fail_test "${phase} recovery interruption reported success"
    expected_attempt=$((expected_attempt + 1))
    read_lifecycle || fail_test "${phase} recovery state is unreadable"
    attempt_id=$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")
    attempt_manifest=$(lifecycle_manifest_path "$attempt_id")
    jq -e --arg root "$root_id" --arg phase "$phase" \
      --argjson count "$expected_attempt" '
        .state == "recovery-required" and
        .transaction.root_incident.id == $root and
        .transaction.attempt_count == $count
      ' <<< "$_lifecycle_json" >/dev/null \
      || fail_test "${phase} interruption lost recovery authority"
    jq -e --arg root "$root_id" --arg phase "$phase" '
      .kind == "recovery-attempt" and .operation == "unconfigure-recovery" and
      .status == "failed" and .failure.phase == $phase and
      .recovery.root_incident.id == $root and .file_rollback_policy == "preserve"
    ' "$attempt_manifest" >/dev/null \
      || fail_test "${phase} failed attempt frontier is invalid"
    [[ $(sha256_file "$root_incident") == "$root_hash" ]] \
      || fail_test "${phase} interruption rewrote the immutable root"
  done

  UNCONFIGURE_RECOVERY_FAILPOINT=""
  rc=0
  with_boot_repair_lock || fail_test "final recovery retry lock failed"
  run_unconfigure_recovery_locked || rc=$?
  release_boot_repair_lock
  [[ $rc -eq 0 ]] || fail_test "final recovery retry failed"
  read_lifecycle || fail_test "final recovery state is unreadable"
  jq -e --arg root "$root_id" --argjson count "$((expected_attempt + 1))" '
    .state == "disabled" and .managed_settings == null and
    .tracking_ownership == null and .last_recovery.root_incident.id == $root and
    .last_recovery.attempt_count == $count and
    .last_recovery.final_attempt.status == "completed"
  ' <<< "$_lifecycle_json" >/dev/null \
    || fail_test "final recovery retry did not prove disabled state"
  [[ $(sha256_file "$root_incident") == "$root_hash" ]] \
    || fail_test "final recovery retry rewrote the immutable root"
}

# Emit the exact schema-1 record shape before hashing/publication, as the
# pre-ada6c3f writer did. Every lifecycle reader, reference validator, recovery
# selector and proof below is the real implementation. No sealed fixture is
# rewritten to make an old record look current.
test_schema_one_unconfigure_compatibility() (
  local writer write_schema_one=true kind document schema root_id root_manifest
  local root_hash intent_path intent_hash proof_path invalid reference
  writer=$(declare -f persist_transaction_domain_record)
  eval "${writer/persist_transaction_domain_record/persist_current_domain_record}"
  persist_transaction_domain_record() {
    local record="$1" filename="$2" record_schema="$3" validator="$4" ignored="$5"
    local record_document="$6"
    if [[ "$write_schema_one" == true && "$_transaction_operation" == unconfigure ]]; then
      case "$record" in
        unconfigure)
          record_document=$(jq -c '.schema_version = 1 | del(.limine_fallback)' \
            <<< "$record_document") || return 1
          record_schema=1
          ;;
        final_proof)
          record_document=$(jq -c '.schema_version = 1' <<< "$record_document") || return 1
          record_schema=1
          ;;
      esac
    fi
    persist_current_domain_record "$record" "$filename" "$record_schema" \
      "$validator" "$ignored" "$record_document"
  }
  for kind in completed interrupted; do
    setup_fixture "schema-one-${kind}"
    write_schema_one=true
    if [[ "$kind" == interrupted ]]; then
      REBUILD_FAIL=true
      if run_unconfigure; then
        fail_test "historical interrupted unconfiguration reported success"
      fi
    else
      run_unconfigure || fail_test "historical completed unconfiguration was rejected"
    fi
    read_lifecycle || fail_test "schema-1 lifecycle references are unreadable"
    if [[ "$kind" == completed ]]; then
      root_id=$(jq -r '.last_transaction.id' <<< "$_lifecycle_json")
    else
      root_id="$_lifecycle_transaction_id"
    fi
    root_manifest=$(lifecycle_manifest_path "$root_id")
    document=$(read_control_document "$root_manifest")
    root_hash=$(sha256_file "$root_manifest")
    intent_path=$(jq -r '.domain_records.unconfigure.path' <<< "$document")
    intent_hash=$(sha256_file "$intent_path")
    jq -e '.schema_version == 1 and (has("limine_fallback") | not)' "$intent_path" \
      >/dev/null || fail_test "historical intent fixture has the wrong shape"
    [[ $(unconfigure_intent_fallback_state "$(read_control_document "$intent_path")") == managed ]] \
      || fail_test "historical intent lost its original fallback requirement"
    for schema in 0 3; do
      invalid=$(jq --argjson schema "$schema" '.schema_version = $schema' "$intent_path")
      if validate_unconfigure_intent_json "$root_id" "$invalid" "$document"; then
        fail_test "unsupported unconfigure schema ${schema} was accepted"
      fi
    done
    invalid=$(jq '.limine_fallback = "absent"' "$intent_path")
    if validate_unconfigure_intent_json "$root_id" "$invalid" "$document"; then
      fail_test "schema-1 intent accepted a new fallback authority field"
    fi
    reference=$(jq -c '.domain_records.unconfigure | .schema_version = 2' <<< "$document")
    if validate_unconfigure_intent_reference "$root_id" "$reference" "$document"; then
      fail_test "record-reference schema did not match the historical document"
    fi
    if [[ "$kind" == completed ]]; then
      proof_path=$(jq -r '.domain_records.final_proof.path' <<< "$document")
      jq -e '.schema_version == 1 and .intent.schema_version == 1 and
        .limine.fallback != null' "$proof_path" >/dev/null \
        || fail_test "historical proof fixture has the wrong shape"
      lifecycle_removal_is_allowed || fail_test "schema-1 disabled state refused removal"
    else
      REBUILD_FAIL=false
      write_schema_one=false
      with_boot_repair_lock || fail_test "historical recovery lock failed"
      run_unconfigure_recovery_locked || fail_test "schema-1 incident did not recover"
      release_boot_repair_lock
      read_lifecycle || fail_test "recovery of schema-1 intent was unreadable"
      [[ "$_lifecycle_state" == disabled ]] || fail_test "historical recovery did not disable management"
      proof_path=$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")
      jq -e '.schema_version == 2 and .intent.schema_version == 1 and
        .limine.fallback != null' "$proof_path" >/dev/null \
        || fail_test "new recovery proof did not retain schema-1 intent authority"
      [[ "$(<"${COMMAND_LOG}.install")" == *'--no-efi-register --fallback'* ]] \
        || fail_test "historical recovery did not rebuild its managed fallback"
      lifecycle_removal_is_allowed || fail_test "recovered schema-1 intent refused removal"
    fi
    [[ $(sha256_file "$root_manifest") == "$root_hash" \
      && $(sha256_file "$intent_path") == "$intent_hash" ]] \
      || fail_test "compatibility reader or recovery rewrote historical records"
  done
)

case "${TEST_CASE:-all}" in
  success) test_successful_unconfigure ;;
  recovery) test_rebuild_failure_recovers_disabled ;;
  recovery-phases) test_recovery_phase_failpoints ;;
  recovery-phase-chain) test_recovery_phase_failure_chain ;;
  no-fallback) test_unconfigure_without_fallback ;;
  no-fallback-recovery) test_recovery_without_fallback ;;
  legacy-schema) test_schema_one_unconfigure_compatibility ;;
  all)
    test_successful_unconfigure
    test_unconfigure_without_fallback
    test_recovery_without_fallback
    test_unknown_original_blocks_before_transition
    test_three_way_conflict_blocks_before_transition
    test_rebuild_failure_preserves_files
    test_rebuild_failure_recovers_disabled
    test_pre_reset_failure_rolls_back_files
    test_noop_install_rejects_non_stock_targets
    test_esp_sync_failure_blocks_disabled_commit
    test_legacy_windows_block_is_removed
    test_original_enrollment_setting_is_restored
    test_recovery_phase_failpoints
    test_recovery_phase_failure_chain
    test_schema_one_unconfigure_compatibility
    ;;
  *) fail_test "unknown TEST_CASE: ${TEST_CASE}" ;;
esac

printf 'unconfigure tests passed\n'
