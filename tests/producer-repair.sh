#!/bin/bash
# shellcheck disable=SC1091,SC2154,SC2329 # Fixtures source modules, inspect globals and override indirect callbacks.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init producer-repair

# The public repair dispatcher must preserve the recovery callback's result.
# shellcheck source=../bin/omasecboot
source "${ROOT_DIR}/bin/omasecboot"

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

limine_entry_tool_config_files() {
  printf '%s\n' "$(limine_default_config_path)"
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
        jq '[to_entries[] | .value + {is_signed: true}]' "$database"
      else
        printf '[]\n'
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

# A managed setting outside its managed and recorded original values stops
# recovery before any reconstruction runs, without consuming an attempt.
run_conflict_case() (
  local context="$1" root_id primary_hash
  setup_fixture "conflict-${context}"
  set_producer_context "$context" || fail_test "conflict: producer context failed"
  with_boot_repair_lock || fail_test "conflict: producer root could not lock"
  read_lifecycle || fail_test "conflict: active lifecycle was unreadable"
  begin_registered_producer_lease || fail_test "conflict: producer lease failed"
  read_lifecycle || fail_test "conflict: producer lease was unreadable"
  root_id=$_lifecycle_transaction_id
  adopt_transaction_context "$root_id" \
    || fail_test "conflict: producer root context was not adopted"
  rollback_and_mark_recovery 97 "fixture producer interruption" failed \
    || fail_test "conflict: failed root incident was not published"
  release_boot_repair_lock

  sed -i 's/^ENABLE_VERIFICATION=.*/ENABLE_VERIFICATION=maybe/' \
    "$(limine_default_config_path)"
  primary_hash=$(sha256_file "$(limine_primary_binary_path)")
  rm -f "$(snapshot_restore_lock_path)"
  with_boot_repair_lock || fail_test "conflict: producer recovery could not lock"
  if reconcile_and_recover_producer_locked >/dev/null 2>&1; then
    release_boot_repair_lock
    fail_test "conflict: recovery proceeded despite a managed-settings conflict"
  fi
  release_boot_repair_lock
  [[ ! -s "$REGISTRY_LOG" ]] \
    || fail_test "conflict: reconstruction ran before the settings conflict was refused"
  [[ $(sha256_file "$(limine_primary_binary_path)") == "$primary_hash" ]] \
    || fail_test "conflict: boot artifacts changed under a settings conflict"
  read_lifecycle || fail_test "conflict: lifecycle unreadable after the refusal"
  [[ "$_lifecycle_state" == recovery-required \
    && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 0 ]] \
    || fail_test "conflict: the refusal consumed a recovery attempt"
  # The reconstruction preflight refuses the same conflict on its own, so a
  # recovery that reached reconstruction could not rebuild under it.
  if producer_reconstruction_preflight >/dev/null 2>&1; then
    fail_test "conflict: reconstruction preflight accepted a managed-settings conflict"
  fi

  sed -i 's/^ENABLE_VERIFICATION=.*/ENABLE_VERIFICATION=yes/' \
    "$(limine_default_config_path)"
  producer_reconstruction_preflight >/dev/null 2>&1 \
    || fail_test "conflict: reconstruction preflight refused the restored setting"
  with_boot_repair_lock || fail_test "conflict: producer recovery could not relock"
  reconcile_and_recover_producer_locked \
    || fail_test "conflict: recovery failed after the setting was restored"
  release_boot_repair_lock
  assert_recovered_case "$context" "$root_id"
)

run_recovery_contention_case() (
  trap - EXIT
  local root_id root_hash root_seal_hash attempt_id attempt_manifest rc=0
  local witness busy=true
  setup_fixture recovery-contention
  set_producer_context uki-build || fail_test "contention: producer context failed"
  with_boot_repair_lock || fail_test "contention: could not lock the producer root"
  read_lifecycle || fail_test "contention: active lifecycle was unreadable"
  begin_registered_producer_lease || fail_test "contention: producer lease failed"
  read_lifecycle || fail_test "contention: producer lease was unreadable"
  root_id=$_lifecycle_transaction_id
  adopt_transaction_context "$root_id" || fail_test "contention: could not adopt root context"
  rollback_and_mark_recovery 97 "fixture producer interruption" failed \
    || fail_test "contention: could not publish failed producer root"
  release_boot_repair_lock
  root_hash=$(sha256_file "$(lifecycle_manifest_path "$root_id")")
  root_seal_hash=$(sha256_file "$(lifecycle_incident_path "$root_id")")
  witness="${CASE_DIR}/contention-witness.json"

  check_root() { return 0; }
  rebuild_with_competing_lock() {
    create_uki_output || return 1
    [[ "$busy" == true ]] || return 0
    jq -cn --arg id "$_transaction_id" \
      --arg lifecycle_hash "$(sha256_file "$(lifecycle_file_path)")" \
      --arg manifest_hash "$(sha256_file "$(lifecycle_manifest_path "$_transaction_id")")" \
      '{id: $id, lifecycle_hash: $lifecycle_hash, manifest_hash: $manifest_hash}' \
      > "$witness" || return 1
    # A distinct open file description acquires FD 200's released lock. This
    # descriptor belongs to the command subshell and closes when it exits.
    exec 9>> "$(limine_lock_path)"
    command flock -n 9
  }
  run_package_producer_reconstruction() {
    with_limine_lock_handoff rebuild_with_competing_lock
  }
  flock() {
    if [[ "$*" == '-E 75 -w 30 200' ]]; then
      command flock -E 75 -w 0.05 200
    else
      command flock "$@"
    fi
  }

  (trap - EXIT; main repair) > "${CASE_DIR}/repair.out" 2> "${CASE_DIR}/repair.err" || rc=$?
  [[ $rc -eq 75 ]] || fail_test "contention: public repair lost temporary status (${rc})"
  grep -Fq 'lifecycle recovery did not complete' "${CASE_DIR}/repair.err" \
    || fail_test "contention: public repair omitted its incomplete-recovery outcome"
  if grep -Eqi 'recovery failed|nothing (was )?changed' "${CASE_DIR}/repair.err"; then
    fail_test "contention: public repair misreported the mutation or failure"
  fi
  grep -Fxq 'RECONSTRUCTED UKI' "$(esp_path)/EFI/Linux/omarchy_linux.efi" \
    || fail_test "contention: fixture never reached reconstruction"
  attempt_id=$(jq -r '.id' "$witness")
  attempt_manifest=$(lifecycle_manifest_path "$attempt_id")
  [[ $(sha256_file "$(lifecycle_file_path)") == "$(jq -r '.lifecycle_hash' "$witness")" \
    && $(sha256_file "$attempt_manifest") == "$(jq -r '.manifest_hash' "$witness")" ]] \
    || fail_test "contention: recovery published state after losing the shared lock"
  read_lifecycle || fail_test "contention: retained recovery transition is unreadable"
  [[ "$_lifecycle_state" == transition && "$_lifecycle_transaction_id" == "$attempt_id" ]] \
    || fail_test "contention: recovery lost its durable attempt"
  [[ ! -e "$(lifecycle_incident_path "$attempt_id")" ]] \
    || fail_test "contention: an unlocked attempt was sealed"
  [[ $(sha256_file "$(lifecycle_manifest_path "$root_id")") == "$root_hash" \
    && $(sha256_file "$(lifecycle_incident_path "$root_id")") == "$root_seal_hash" ]] \
    || fail_test "contention: recovery changed its sealed predecessor"

  # The prior command has exited and its competing descriptor is gone. The
  # actual public recovery path must reconcile and finish the retained attempt.
  busy=false
  main repair > "${CASE_DIR}/retry.out" 2> "${CASE_DIR}/retry.err" \
    || fail_test "contention: public repair did not recover on retry"
  read_lifecycle || fail_test "contention: recovered state is unreadable"
  [[ "$_lifecycle_state" == active ]] || fail_test "contention: retry did not restore active state"
  jq -e '.last_recovery.attempt_count == 2 and
    .last_recovery.final_attempt.status == "completed"' <<< "$_lifecycle_json" \
    >/dev/null || fail_test "contention: retry did not preserve the interrupted attempt"
)

case "${PRODUCER_REPAIR_TEST_CASE:-all}" in
  contention) run_recovery_contention_case ;;
  all)
    run_repair_case package
    run_repair_case uki-build
    run_repair_case entry-tool
    run_repair_case snapshot-sync
    run_repair_case full-restore
    run_conflict_case package
    run_recovery_contention_case
    ;;
  *) fail_test "unknown PRODUCER_REPAIR_TEST_CASE: ${PRODUCER_REPAIR_TEST_CASE}" ;;
esac

printf 'producer repair integration tests passed\n'
