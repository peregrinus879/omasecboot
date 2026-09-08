#!/bin/bash
# shellcheck disable=SC1091,SC2154 # Fixtures source modules and inspect their globals.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init producer-repair

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

export QUIET=true

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

esp_path() {
  printf '%s/boot\n' "$CASE_DIR"
}

limine_config_path() {
  printf '%s/boot/limine.conf\n' "$CASE_DIR"
}

limine_default_config_path() {
  printf '%s/limine-defaults\n' "$CASE_DIR"
}

limine_unsigned_binary_path() {
  printf '%s/BOOTX64.EFI\n' "$CASE_DIR"
}

sbctl_config_path() {
  printf '%s/sbctl.conf\n' "$CASE_DIR"
}

sbctl_database_candidate_paths() {
  printf '%s/files.json\n%s/files.db\n' "$CASE_DIR" "$CASE_DIR"
}

control_owner_uid() {
  id -u
}

require_control_root() {
  return 0
}

limine_enrollment_hooks_present() {
  return 0
}

mountpoint() {
  [[ "$1" == -q && "$2" == "$(esp_path)" ]]
}

findmnt() {
  [[ "$1" == -n && "$2" == -T && "$3" == "$(esp_path)" && "$4" == -o \
    && "$5" == FSTYPE ]] || return 2
  printf 'vfat\n'
}

producer_package_version() {
  case "$1" in
    limine-mkinitcpio-hook) printf '%s\n' "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" ;;
    limine-snapper-sync) printf '%s\n' "$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION" ;;
    sbctl) printf '%s\n' "$SUPPORTED_SBCTL_VERSION" ;;
    *) return 1 ;;
  esac
}

process_matches_identity() {
  [[ "$1" == "$BASHPID" && "$2" == "$_producer_owner_kind" \
    && "$3" == "$_producer_owner_identity" ]]
}

write_binary() {
  local path="$1" checksum="$2" signature="${3:-}"
  {
    printf 'FAKE_EFI\n%s%s\n' "$LIMINE_CONFIG_MARKER" "$checksum"
    [[ -z "$signature" ]] || printf '%s\n' "$signature"
  } > "$path"
}

update_tracking_db() {
  local file="$1" database tmp
  database="${CASE_DIR}/files.json"
  tmp="${database}.tmp"
  [[ -s "$database" ]] || printf '{}\n' > "$database"
  jq --arg file "$file" '.[$file] = {file: $file, output: $file}' \
    "$database" > "$tmp" || return 1
  mv "$tmp" "$database"
}

limine() {
  local binary checksum
  [[ "$1" == enroll-config ]] || return 2
  shift
  if [[ "${1:-}" == --quiet ]]; then
    shift
  fi
  [[ $# -eq 2 ]] || return 2
  binary="$1"
  checksum="$2"
  if grep -aFxq LOCAL_SIGNATURE "$binary"; then
    return 3
  fi
  write_binary "$binary" "$checksum"
}

sbctl() {
  local file save=false valid=true database
  database="${CASE_DIR}/files.json"
  case "$1" in
    list-files)
      [[ "${2:-}" == --json && $# -eq 2 ]] || return 2
      if [[ -f "$database" ]]; then
        jq . "$database"
      else
        printf '{}\n'
      fi
      ;;
    verify)
      [[ "${2:-}" == --json && $# -eq 3 ]] || return 2
      file="$3"
      grep -aFxq LOCAL_SIGNATURE "$file" || valid=false
      jq -cn --arg path "$file" --argjson valid "$valid" \
        '[{file_name: $path, is_signed: (if $valid then 1 else 0 end)}]'
      ;;
    sign)
      shift
      if [[ "${1:-}" == -s ]]; then
        save=true
        shift
      fi
      [[ $# -eq 1 ]] || return 2
      file="$1"
      printf 'LOCAL_SIGNATURE\n' >> "$file"
      [[ "$save" == false ]] || update_tracking_db "$file"
      ;;
    remove-file)
      [[ $# -eq 2 ]] || return 2
      file="$2"
      jq --arg file "$file" 'del(.[$file])' "$database" \
        > "${database}.tmp" || return 1
      mv "${database}.tmp" "$database"
      ;;
    *) return 2 ;;
  esac
}

create_uki_output() {
  local path
  path="$(esp_path)/EFI/Linux/omarchy_linux.efi"
  mkdir -p "$(dirname "$path")"
  printf 'RECONSTRUCTED UKI\n' > "$path"
}

create_snapshot_output() {
  local history name
  history="$(esp_path)/0123456789abcdef0123456789abcdef/limine_history"
  name="snapshot.efi_sha256_$(printf 'a%.0s' {1..64})"
  mkdir -p "$history"
  jq -n --arg name "$name" '{
    jsonFormatVersion: "1.3.0",
    snapshotEntries: [{
      kernelEntries: [{
        imageDetails: [{fileName: "snapshot.efi", fileHashName: $name}],
        subKernels: []
      }]
    }]
  }' > "${history}/snapshots.json"
  printf 'RECONSTRUCTED SNAPSHOT\n' > "${history}/${name}"
}

run_package_producer_reconstruction() {
  printf 'package\n' >> "$REGISTRY_LOG"
  create_uki_output
}

run_snapshot_producer_reconstruction() {
  printf 'snapshot\n' >> "$REGISTRY_LOG"
  create_snapshot_output
}

setup_fixture() {
  local name="$1" old_checksum
  CASE_DIR="${TEST_DIR}/${name}"
  REGISTRY_LOG="${CASE_DIR}/registry.log"
  mkdir -p "${CASE_DIR}/boot/EFI/limine" "${CASE_DIR}/boot/EFI/BOOT"
  printf 'TIMEOUT=5\n' > "$(limine_config_path)"
  printf '%s\n' \
    'ENABLE_VERIFICATION=yes' \
    'ENABLE_ENROLL_LIMINE_CONFIG=no' \
    'COMMANDS_BEFORE_SAVE="other limine-reset-enroll"' \
    'COMMANDS_AFTER_SAVE="limine-enroll-config other"' \
    > "$(limine_default_config_path)"
  old_checksum=$(printf '0%.0s' {1..128})
  write_binary "$(limine_unsigned_binary_path)" "$old_checksum"
  write_binary "$(limine_primary_binary_path)" "$old_checksum"
  write_binary "$(limine_fallback_binary_path)" "$old_checksum"
  printf '{}\n' > "${CASE_DIR}/files.json"
  printf 'files_db: %s/files.json\n' "$CASE_DIR" > "$(sbctl_config_path)"
  : > "$REGISTRY_LOG"

  adopt_lifecycle : "yes" "no" "no" "yes" \
    "present" "absent" "present" "absent" \
    || fail_test "${name}: active lifecycle adoption failed"
}

set_producer_context() {
  local context="$1"
  reset_producer_context
  _producer_owner_pid=$BASHPID
  case "$context" in
    package)
      _producer_class=package
      _producer_subtype=package-transaction
      _producer_owner_kind=executable
      _producer_owner_identity=/usr/bin/pacman
      _producer_caller=pacman
      ;;
    uki-build)
      _producer_class=limine
      _producer_subtype=uki-build
      _producer_owner_kind=script
      _producer_owner_identity=/usr/share/libalpm/scripts/limine-mkinitcpio-install
      _producer_caller=limine-mkinitcpio-install
      ;;
    entry-tool)
      _producer_class=limine
      _producer_subtype=entry-tool
      _producer_owner_kind=script
      _producer_owner_identity=/usr/bin/limine-entry-tool
      _producer_caller=limine-entry-tool
      ;;
    snapshot-sync)
      _producer_class=snapshot
      _producer_subtype=snapshot-sync
      _producer_owner_kind=script
      _producer_owner_identity=/usr/bin/limine-snapper-sync
      _producer_caller=limine-snapper-sync
      ;;
    full-restore)
      _producer_class=restore
      _producer_subtype=full-restore
      _producer_owner_kind=script
      _producer_owner_identity=/usr/bin/limine-snapper-sync
      _producer_caller=limine-snapper-sync
      : > "$(snapshot_restore_lock_path)"
      chmod 644 "$(snapshot_restore_lock_path)"
      ;;
    *) return 1 ;;
  esac
}

assert_recovered_case() {
  local context="$1" root_id="$2" attempt_id attempt_manifest proof_reference proof_path
  local producer_reference expected_action
  read_lifecycle || fail_test "${context}: recovered lifecycle was unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "${context}: recovery did not restore active state"
  jq -e --arg root "$root_id" '
    .last_recovery.root_incident.id == $root and
    .last_recovery.attempt_count == 1 and
    .last_recovery.final_attempt.status == "completed" and
    .last_transaction.id == .last_recovery.final_attempt.id and
    .last_transaction.operation == "producer-recovery" and
    .managed_settings != null and .tracking_ownership != null
  ' <<< "$_lifecycle_json" >/dev/null \
    || fail_test "${context}: stable recovery references were incomplete"

  read_transaction_manifest "$root_id" \
    || fail_test "${context}: failed producer root was unreadable"
  jq -e '.kind == "root" and .status == "failed" and
    .file_rollback_policy == "preserve" and .completed_phases == [] and
    .domain_records.producer != null' <<< "$_manifest_json" >/dev/null \
    || fail_test "${context}: failed producer root evidence was incomplete"
  producer_reference=$(jq -c '.domain_records.producer' <<< "$_manifest_json")
  validate_producer_record_reference "$root_id" "$producer_reference" \
    || fail_test "${context}: producer record reference did not revalidate"

  attempt_id=$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")
  attempt_manifest=$(lifecycle_manifest_path "$attempt_id")
  read_transaction_manifest "$attempt_id" \
    || fail_test "${context}: recovery attempt was unreadable"
  jq -e '.kind == "recovery-attempt" and .operation == "producer-recovery" and
    .status == "completed" and .completed_phases == [
      "reconstruct-producer","backup-artifacts","configure-limine","enroll-config",
      "verify-config","clean-tracking","sign-efi","prove-artifacts"
    ]' <<< "$_manifest_json" >/dev/null \
    || fail_test "${context}: recovery phases were incomplete or out of order"
  proof_reference=$(jq -c '.domain_records.final_proof' <<< "$_manifest_json")
  validate_final_proof_reference "$attempt_id" "$proof_reference" \
    || fail_test "${context}: final proof reference did not revalidate"
  proof_path=$(jq -r '.path' <<< "$proof_reference")
  validate_final_proof_json "$attempt_id" "$(read_control_document "$proof_path")" \
    || fail_test "${context}: final proof document did not revalidate"
  [[ "$attempt_manifest" == "$(jq -r '.last_transaction.manifest' <<< "$_lifecycle_json")" ]] \
    || fail_test "${context}: stable state selected the wrong recovery manifest"

  case "$context" in
    package|uki-build) expected_action=package ;;
    entry-tool) expected_action="" ;;
    snapshot-sync|full-restore) expected_action=snapshot ;;
  esac
  if [[ -n "$expected_action" ]]; then
    [[ $(grep -Fxc "$expected_action" "$REGISTRY_LOG") -eq 1 ]] \
      || fail_test "${context}: recovery selected the wrong reconstruction handler"
  elif [[ -s "$REGISTRY_LOG" ]]; then
    fail_test "${context}: no-op registry entry executed a reconstruction handler"
  fi
}

run_repair_case() (
  local context="$1" root_id
  setup_fixture "$context"
  set_producer_context "$context" || fail_test "${context}: producer context failed"

  with_boot_repair_lock || fail_test "${context}: producer root could not lock"
  read_lifecycle || fail_test "${context}: active lifecycle was unreadable"
  begin_registered_producer_lease || fail_test "${context}: producer lease failed"
  read_lifecycle || fail_test "${context}: producer lease was unreadable"
  root_id=$_lifecycle_transaction_id
  adopt_transaction_context "$root_id" \
    || fail_test "${context}: producer root context was not adopted"
  rollback_and_mark_recovery 97 "fixture producer interruption" failed \
    || fail_test "${context}: failed root incident was not published"
  release_boot_repair_lock

  rm -f "$(snapshot_restore_lock_path)"
  with_boot_repair_lock || fail_test "${context}: producer recovery could not lock"
  reconcile_and_recover_producer_locked \
    || fail_test "${context}: lifecycle-integrated producer recovery failed"
  release_boot_repair_lock
  assert_recovered_case "$context" "$root_id"
)

run_repair_case package
run_repair_case uki-build
run_repair_case entry-tool
run_repair_case snapshot-sync
run_repair_case full-restore

printf 'producer repair integration tests passed\n'
