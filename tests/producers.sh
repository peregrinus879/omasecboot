#!/bin/bash
# shellcheck disable=SC1091,SC2030,SC2031,SC2154,SC2218,SC2329 # Tests source modules and override functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-producers.XXXXXX")

cleanup() {
  release_boot_repair_lock 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=../lib/discover.sh
source "${ROOT_DIR}/lib/discover.sh"
# shellcheck source=../lib/sign.sh
source "${ROOT_DIR}/lib/sign.sh"
# shellcheck source=../lib/producers.sh
source "${ROOT_DIR}/lib/producers.sh"
REAL_RESOLVE_PACKAGE_PRODUCER_CONTEXT=$(declare -f resolve_package_producer_context)

CASE_DIR="${TEST_DIR}/case"
CONFIG_FILE="${CASE_DIR}/limine.conf"
DEFAULTS_FILE="${CASE_DIR}/limine-defaults"
EFI_FILE="${CASE_DIR}/boot/EFI/Linux/test.efi"
REGISTRY_LOG="${CASE_DIR}/registry-actions"
OWNER_ALIVE=true
ROOT_ALLOWED=true
LIMINE_CONTEXT=restore
LIMINE_OWNER_PID_OVERRIDE=""
MKINITCPIO_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"
SNAPPER_VERSION="$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION"
SBCTL_VERSION="$SUPPORTED_SBCTL_VERSION"
PRODUCER_FAILPOINT=""

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

limine_config_path() {
  printf '%s\n' "$CONFIG_FILE"
}

limine_default_config_path() {
  printf '%s\n' "$DEFAULTS_FILE"
}

control_owner_uid() {
  id -u
}

require_control_root() {
  [[ "$ROOT_ALLOWED" == true ]]
}

durable_sync() {
  :
}

process_matches_identity() {
  [[ "$1" =~ ^[1-9][0-9]*$ && ( "$2" == executable || "$2" == script ) \
    && "$3" == /* ]]
}

manifest_owner_is_alive() {
  [[ "$OWNER_ALIVE" == true ]]
}

producer_package_version() {
  case "$1" in
    limine-mkinitcpio-hook) printf '%s\n' "$MKINITCPIO_VERSION" ;;
    limine-snapper-sync) printf '%s\n' "$SNAPPER_VERSION" ;;
    sbctl) printf '%s\n' "$SBCTL_VERSION" ;;
    *) return 1 ;;
  esac
}

lifecycle_failpoint() {
  [[ "$1" != "$PRODUCER_FAILPOINT" ]]
}

producer_reconstruction_preflight() {
  :
}

resolve_package_producer_context() {
  reset_producer_context
  _producer_class=package
  _producer_subtype=package-transaction
  _producer_owner_pid=$BASHPID
  _producer_owner_kind=executable
  _producer_owner_identity=/usr/bin/pacman
  _producer_caller=pacman
}

resolve_limine_producer_context() {
  local owner_pid="${LIMINE_OWNER_PID_OVERRIDE:-$BASHPID}"
  reset_producer_context
  _producer_owner_pid=$owner_pid
  _producer_owner_kind=script
  case "$LIMINE_CONTEXT" in
    entry-tool)
      _producer_class=limine
      _producer_subtype="entry-tool"
      _producer_owner_identity=/usr/bin/limine-entry-tool
      _producer_caller=limine-entry-tool
      ;;
    snapshot)
      _producer_class=snapshot
      _producer_subtype=snapshot-sync
      _producer_owner_identity=/usr/bin/limine-snapper-sync
      _producer_caller=limine-snapper-sync
      ;;
    restore)
      _producer_class=restore
      _producer_subtype=full-restore
      _producer_owner_identity=/usr/bin/limine-snapper-sync
      _producer_caller=limine-snapper-sync
      ;;
    *) return 1 ;;
  esac
}

write_test_final_proof() {
  local transaction_dir path timestamp document reference
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  path="${transaction_dir}/final-proof.json"
  timestamp=$(utc_timestamp)
  document=$(jq -cn \
    --argjson schema "$FINAL_PROOF_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg timestamp "$timestamp" \
    --arg config "$CONFIG_FILE" \
    --arg config_hash "$(sha256_file "$CONFIG_FILE")" \
    --arg config_identity "$(control_file_identity "$CONFIG_FILE")" \
    --arg artifact "$EFI_FILE" \
    --arg artifact_hash "$(sha256_file "$EFI_FILE")" \
    --arg artifact_identity "$(control_file_identity "$EFI_FILE")" \
    --arg checksum "$(printf '0%.0s' {1..128})" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      proved_at: $timestamp,
      config: {
        path: $config,
        checksum: $checksum,
        sha256: $config_hash,
        identity: $config_identity
      },
      artifacts: [{
        path: $artifact,
        sha256: $artifact_hash,
        identity: $artifact_identity,
        signature: "local",
        tracking: "tracked"
      }]
    }')
  validate_final_proof_json "$_transaction_id" "$document"
  printf '%s\n' "$document" | atomic_create_control_file "$path" 600
  reference=$(transaction_artifact_reference "$path" "$FINAL_PROOF_SCHEMA_VERSION")
  transaction_set_domain_record final_proof "$reference"
}

run_test_producer_repair_phases() {
  local phase
  for phase in reconstruct-producer backup-artifacts configure-limine enroll-config \
    verify-config clean-tracking sign-efi prove-artifacts; do
    transaction_phase_start "$phase" || return 1
    if [[ "$phase" == prove-artifacts ]]; then
      write_test_final_proof || return 1
    fi
    transaction_phase_complete "$phase" || return 1
  done
}

registered_producer_repair() {
  run_test_producer_repair_phases
}

run_package_producer_reconstruction() {
  printf 'package\n' >> "$REGISTRY_LOG"
}

run_snapshot_producer_reconstruction() {
  printf 'snapshot\n' >> "$REGISTRY_LOG"
}

noop_transaction() {
  transaction_phase_start "noop"
  transaction_phase_complete "noop"
}

reset_case() {
  release_boot_repair_lock
  rm -rf "$CASE_DIR"
  mkdir -p "$(dirname "$EFI_FILE")"
  printf 'TIMEOUT=5\n' > "$CONFIG_FILE"
  printf 'ENABLE_VERIFICATION=no\n' > "$DEFAULTS_FILE"
  printf 'SIGNED EFI\n' > "$EFI_FILE"
  : > "$REGISTRY_LOG"
  OWNER_ALIVE=true
  ROOT_ALLOWED=true
  LIMINE_CONTEXT=restore
  LIMINE_OWNER_PID_OVERRIDE=""
  MKINITCPIO_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"
  SNAPPER_VERSION="$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION"
  SBCTL_VERSION="$SUPPORTED_SBCTL_VERSION"
  PRODUCER_FAILPOINT=""
  reset_recovery_context
  reset_producer_context
  detach_transaction_context
  _lifecycle_state=unmanaged
  _lifecycle_generation=0
  _lifecycle_transaction_id=""
  _lifecycle_json=""
  _lifecycle_read_status=absent
  _manifest_json=""
  _manifest_id=""
  _manifest_sha256=""
  _incident_json=""
  _incident_read_status=absent
}

activate_case() {
  adopt_lifecycle : "no" "no" "yes" "yes" \
    "absent" "absent" "absent" "absent" \
    || fail_test "active producer fixture adoption failed"
}

reset_case
[[ $(parse_pacman_query_version limine-mkinitcpio-hook \
  'limine-mkinitcpio-hook 1.38.0-1') == 1.38.0-1 ]] \
  || fail_test "pacman package version was not parsed"
for invalid_query in \
  'other-package 1.38.0-1' \
  'limine-mkinitcpio-hook 1.38.0-1 trailing' \
  $'limine-mkinitcpio-hook 1.38.0-1\nother-package 1.0-1'; do
  if parse_pacman_query_version limine-mkinitcpio-hook "$invalid_query" >/dev/null; then
    fail_test "malformed pacman package query was accepted"
  fi
done
(
  process_effective_uid() { id -u; }
  process_matches_identity() {
    [[ "$1" == 91001 && "$2" == executable && "$3" == /usr/bin/pacman ]]
  }
  process_parent_pid() {
    case "$1" in
      91003) printf '91002\n' ;;
      91002) printf '91001\n' ;;
      91001) printf '1\n' ;;
      1) printf '1\n' ;;
      *) return 1 ;;
    esac
  }
  [[ $(find_root_process_ancestor 91003 executable /usr/bin/pacman) == 91001 ]] \
    || fail_test "package root ancestor was not resolved"
  if find_root_process_ancestor 91003 executable /usr/bin/not-pacman >/dev/null; then
    fail_test "package ancestry accepted the wrong executable identity"
  fi
  eval "$REAL_RESOLVE_PACKAGE_PRODUCER_CONTEXT"
  find_root_process_ancestor() {
    [[ "$1" == "$PPID" && "$2" == executable && "$3" == /usr/bin/pacman ]] \
      || return 1
    printf '91001\n'
  }
  resolve_package_producer_context \
    || fail_test "package producer context did not bind the resolved ancestor"
  [[ "$_producer_class" == package && "$_producer_subtype" == package-transaction \
    && "$_producer_owner_pid" == 91001 \
    && "$_producer_owner_identity" == /usr/bin/pacman ]] \
    || fail_test "package producer context selected the wrong root owner"
)
large_targets="$TEST_DIR/package-targets"
: > "$large_targets"
for ((target_index = 0; target_index < 7000; target_index++)); do
  printf 'usr/lib/modules/test-%05d/vmlinuz\n' "$target_index" >> "$large_targets"
done
if package_targets_change_pinned_producer < "$large_targets"; then
  fail_test "package target policy blocked a realistic transaction"
else
  [[ $? -eq 1 ]] || fail_test "package target policy rejected a realistic transaction"
fi
if package_targets_change_pinned_producer < /dev/null; then
  fail_test "package target policy accepted an empty target list"
else
  [[ $? -eq 2 ]] || fail_test "empty package target list was not classified as unusable"
fi
stream_package_targets() {
  local target
  while IFS= read -r target; do printf '%s\n' "$target"; done < "$large_targets"
}
ROOT_ALLOWED=false
set +e
stream_package_targets | producer_package_pre >/dev/null 2>&1
root_pipe_status=("${PIPESTATUS[@]}")
set -e
ROOT_ALLOWED=true
[[ ${root_pipe_status[0]} -eq 0 && ${root_pipe_status[1]} -ne 0 ]] \
  || fail_test "non-root package rejection did not drain NeedsTargets input"
producer_package_pre < "$large_targets" \
  || fail_test "unmanaged package producer did not no-op"
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "unmanaged package producer wrote lifecycle state"

(
  reset_case
  read_lifecycle() {
    _lifecycle_read_status=supported
    _lifecycle_state=invented
    _lifecycle_transaction_id=""
  }
  set +e
  stream_package_targets | producer_package_pre >/dev/null 2>&1
  unknown_pipe_status=("${PIPESTATUS[@]}")
  set -e
  [[ ${unknown_pipe_status[0]} -eq 0 && ${unknown_pipe_status[1]} -eq 1 ]] \
    || fail_test "unknown-state package rejection did not drain NeedsTargets input"
  if producer_package_post >/dev/null 2>&1; then
    fail_test "package completion accepted an unsupported lifecycle state"
  else
    [[ $? -eq 1 ]] || fail_test "unknown package completion status was not blocking"
  fi
  if producer_limine_hook_pre >/dev/null 2>&1; then
    fail_test "Limine pre-hook accepted an unsupported lifecycle state"
  else
    [[ $? -eq 100 ]] || fail_test "unknown Limine pre-hook status was not fatal"
  fi
  if producer_limine_hook_post >/dev/null 2>&1; then
    fail_test "Limine post-hook accepted an unsupported lifecycle state"
  else
    [[ $? -eq 100 ]] || fail_test "unknown Limine post-hook status was not fatal"
  fi
)

(
  reset_case
  LIMINE_CONTEXT=restore
  restore_read_count=0
  read_lifecycle() {
    restore_read_count=$((restore_read_count + 1))
    _lifecycle_read_status=supported
    if [[ $restore_read_count -eq 1 ]]; then
      _lifecycle_state=disabled
    else
      _lifecycle_state=active
    fi
  }
  if producer_limine_hook_pre >/dev/null 2>&1; then
    fail_test "full-restore admission ignored a concurrent active lifecycle"
  else
    [[ $? -eq 100 ]] || fail_test "full-restore race used a non-blocking status"
  fi
  [[ $restore_read_count -eq 2 ]] \
    || fail_test "full-restore admission was not repeated under the repair lock"
  [[ ! -e "$(lifecycle_file_path)" ]] \
    || fail_test "blocked full-restore race wrote lifecycle state"
)

(
  reset_case
  LIMINE_CONTEXT="entry-tool"
  producer_limine_lock() { with_boot_repair_lock; }
  limine_read_count=0
  read_lifecycle() {
    limine_read_count=$((limine_read_count + 1))
    _lifecycle_read_status=supported
    if [[ $limine_read_count -eq 1 ]]; then
      _lifecycle_state=disabled
    else
      _lifecycle_state=active
    fi
  }
  if producer_limine_hook_pre >/dev/null 2>&1; then
    fail_test "Limine producer admission ignored a concurrent active lifecycle"
  else
    [[ $? -eq 100 ]] || fail_test "Limine producer race used a non-blocking status"
  fi
  [[ $limine_read_count -ge 2 ]] \
    || fail_test "Limine producer admission was not repeated under both locks"
  [[ ! -e "$(lifecycle_file_path)" ]] \
    || fail_test "blocked Limine producer race wrote lifecycle state"
)

(
  reset_case
  package_read_count=0
  read_lifecycle() {
    package_read_count=$((package_read_count + 1))
    _lifecycle_read_status=supported
    if [[ $package_read_count -eq 1 ]]; then
      _lifecycle_state=disabled
    else
      [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
        && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
      _lifecycle_state=active
    fi
  }
  if producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    >/dev/null 2>&1; then
    fail_test "package producer admission ignored a concurrent active lifecycle"
  fi
  [[ $package_read_count -eq 2 ]] \
    || fail_test "inactive package admission was not repeated under both locks"
  [[ ! -e "$(lifecycle_file_path)" ]] \
    || fail_test "blocked package producer race wrote lifecycle state"
)

(
  reset_case
  LIMINE_CONTEXT=snapshot
  producer_limine_lock() { with_boot_repair_lock; }
  touch "$(snapshot_restore_lock_path)"
  if producer_limine_hook_pre >/dev/null 2>&1; then
    fail_test "inactive snapshot producer overlapped a full snapshot restore"
  else
    [[ $? -eq 100 ]] || fail_test "full-restore overlap used a non-blocking status"
  fi
  [[ ! -e "$(lifecycle_file_path)" ]] \
    || fail_test "blocked inactive snapshot producer wrote lifecycle state"
)

for producer_failpoint in after-producer-manifest-write after-producer-transition-write; do
  reset_case
  activate_case
  PRODUCER_FAILPOINT="$producer_failpoint"
  if producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    >/dev/null 2>&1; then
    fail_test "${producer_failpoint} failure reported producer admission success"
  fi
  read_lifecycle || fail_test "${producer_failpoint} damaged lifecycle state"
  if [[ "$producer_failpoint" == after-producer-manifest-write ]]; then
    [[ "$_lifecycle_state" == active ]] \
      || fail_test "pre-publication producer failure changed stable state"
  else
    [[ "$_lifecycle_state" == recovery-required ]] \
      || fail_test "published producer failure did not require recovery"
  fi
done
reset_case
activate_case
for pinned_target in limine-mkinitcpio-hook limine-snapper-sync sbctl; do
  pinned_targets_output="${CASE_DIR}/pinned-targets-${pinned_target}.out"
  if producer_package_pre <<< "$pinned_target" \
    > "$pinned_targets_output" 2>&1; then
    fail_test "active lifecycle admitted pinned package change: ${pinned_target}"
  fi
  grep -Fq 'disable lifecycle before changing pinned producers' "$pinned_targets_output" \
    || fail_test "pinned package change omitted its rejection reason: ${pinned_target}"
  read_lifecycle || fail_test "pinned package rejection damaged lifecycle state"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "pinned package rejection changed lifecycle state: ${pinned_target}"
done
producer_package_pre <<'EOF' || fail_test "package producer lease was not published"
usr/lib/modules/6.18.0/modules.builtin
usr/lib/initcpio/install/base
usr/lib/modules/6.18.0/modules.builtin
EOF
read_lifecycle || fail_test "package lease lifecycle was unreadable"
[[ "$_lifecycle_state" == transition ]] || fail_test "package pre-hook did not publish a lease"
package_root_id="$_lifecycle_transaction_id"
package_manifest=$(lifecycle_manifest_path "$package_root_id")
package_record=$(jq -r '.domain_records.producer.path' "$package_manifest")
jq -e '.producer_class == "package" and .subtype == "package-transaction" and
  .caller == "pacman"' "$package_record" >/dev/null \
  || fail_test "package producer record was incomplete"
[[ $(stat -Lc '%a' "$package_record") == 600 ]] \
  || fail_test "producer evidence was not private"
package_state_hash=$(sha256_file "$(lifecycle_file_path)")
process_has_ancestor_definition=$(declare -f process_has_ancestor)
process_has_ancestor() { return 1; }
if producer_package_post >/dev/null 2>&1; then
  fail_test "package completion accepted a caller outside the recorded coordinator"
fi
eval "$process_has_ancestor_definition"
read_lifecycle || fail_test "rejected package completion damaged lifecycle state"
[[ "$_lifecycle_state" == transition \
  && "$_lifecycle_transaction_id" == "$package_root_id" \
  && $(sha256_file "$(lifecycle_file_path)") == "$package_state_hash" ]] \
  || fail_test "rejected package completion changed the producer lease"
producer_limine_lock_definition=$(declare -f producer_limine_lock)
producer_limine_lock() { with_boot_repair_lock; }
LIMINE_CONTEXT="entry-tool"
producer_limine_hook_post \
  || fail_test "cross-class Limine post-hook did not suppress nested repair"
read_lifecycle || fail_test "cross-class Limine suppression damaged lifecycle state"
[[ "$_lifecycle_state" == transition \
  && "$_lifecycle_transaction_id" == "$package_root_id" ]] \
  || fail_test "cross-class Limine post-hook altered the package lease"
LIMINE_CONTEXT=restore
invalid_package_phase=$(jq -c '.current_phase = "configure-limine"' "$package_manifest")
if validate_transaction_manifest_json "$package_root_id" "$invalid_package_phase" false; then
  fail_test "package producer accepted an out-of-order next phase"
fi
producer_package_post || fail_test "package final repair failed"
read_lifecycle || fail_test "completed package lifecycle was unreadable"
[[ "$_lifecycle_state" == active ]] || fail_test "package repair did not restore active state"
jq -e '
  .status == "completed" and .file_rollback_policy == "preserve" and
  .domain_records.producer != null and .domain_records.final_proof != null and
  .completed_phases == [
    "reconstruct-producer","backup-artifacts","configure-limine","enroll-config",
    "verify-config","clean-tracking","sign-efi","prove-artifacts"
  ]
' "$package_manifest" >/dev/null || fail_test "package final proof was not committed"

run_limine_admission_case() {
  local context="$1" expected_class="$2" root_id record
  reset_case
  activate_case
  LIMINE_CONTEXT="$context"
  producer_limine_hook_pre \
    || fail_test "${context} Limine pre-hook did not publish a lease"
  read_lifecycle || fail_test "${context} Limine lease was unreadable"
  root_id="$_lifecycle_transaction_id"
  record=$(jq -r '.domain_records.producer.path' \
    "$(lifecycle_manifest_path "$root_id")")
  jq -e --arg class "$expected_class" '.producer_class == $class' "$record" >/dev/null \
    || fail_test "${context} Limine pre-hook selected the wrong producer class"
  if [[ "$context" == entry-tool ]]; then
    process_has_ancestor_definition=$(declare -f process_has_ancestor)
    process_has_ancestor() { return 0; }
    LIMINE_OWNER_PID_OVERRIDE=$((BASHPID + 1))
    producer_limine_hook_post \
      || fail_test "nested Limine post-hook was not suppressed"
    read_lifecycle || fail_test "nested Limine suppression damaged lifecycle state"
    [[ "$_lifecycle_state" == transition \
      && "$_lifecycle_transaction_id" == "$root_id" ]] \
      || fail_test "nested Limine post-hook altered the owner lease"
    LIMINE_OWNER_PID_OVERRIDE=""
    eval "$process_has_ancestor_definition"
  fi
  producer_limine_hook_post \
    || fail_test "${context} Limine post-hook did not complete repair"
  read_lifecycle || fail_test "${context} Limine completion was unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "${context} Limine completion did not restore active state"
  jq -e '.completed_phases == [
    "reconstruct-producer","backup-artifacts","configure-limine","enroll-config",
    "verify-config","clean-tracking","sign-efi","prove-artifacts"
  ]' "$(lifecycle_manifest_path "$root_id")" >/dev/null \
    || fail_test "${context} producer committed an incomplete phase sequence"
}

run_limine_admission_case entry-tool limine
run_limine_admission_case snapshot snapshot
eval "$producer_limine_lock_definition"

(
  reset_case
  activate_case
  LIMINE_CONTEXT="entry-tool"
  with_boot_repair_lock || fail_test "owned-transition fixture could not lock"
  begin_lifecycle_transaction repair active \
    || fail_test "owned-transition fixture did not start"
  owned_id=$_transaction_id
  owned_token=$OMASECBOOT_TRANSACTION_TOKEN
  release_boot_repair_lock
  owned_hash=$(sha256_file "$(lifecycle_file_path)")
  producer_limine_lock() { with_boot_repair_lock; }

  producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    || fail_test "owned transition did not suppress nested package admission"
  producer_limine_hook_pre \
    || fail_test "owned transition did not suppress nested Limine admission"
  producer_limine_hook_post \
    || fail_test "owned transition did not suppress nested Limine completion"
  [[ $(sha256_file "$(lifecycle_file_path)") == "$owned_hash" ]] \
    || fail_test "owned producer suppression changed the lifecycle transition"

  printf -v OMASECBOOT_TRANSACTION_TOKEN '%s' forged
  if producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    > "$CASE_DIR/forged-transition.out" 2>&1; then
    fail_test "forged transition token admitted a package producer"
  fi
  grep -Fq "$owned_id" "$CASE_DIR/forged-transition.out" \
    || fail_test "transition rejection omitted the transaction identifier"
  if producer_limine_hook_pre >/dev/null 2>&1; then
    fail_test "forged transition token admitted a Limine producer"
  else
    [[ $? -eq 100 ]] || fail_test "forged Limine transition was not fatal"
  fi
  printf -v OMASECBOOT_TRANSACTION_TOKEN '%s' "$owned_token"
  LIMINE_CONTEXT=restore
  if producer_limine_hook_pre >/dev/null 2>&1; then
    fail_test "full snapshot restore entered during an owned transition"
  else
    [[ $? -eq 100 ]] || fail_test "transition-time full restore was not fatal"
  fi

  LIMINE_CONTEXT="entry-tool"
  with_boot_repair_lock || fail_test "owned-transition completion could not lock"
  transaction_phase_start repair || fail_test "owned repair phase did not start"
  transaction_phase_complete repair || fail_test "owned repair phase did not complete"
  commit_lifecycle_transaction || fail_test "owned transition did not commit"
  release_boot_repair_lock
)

(
  reset_case
  activate_case
  with_boot_repair_lock || fail_test "recovery-required fixture could not lock"
  begin_lifecycle_transaction repair active \
    || fail_test "recovery-required fixture did not start"
  recovery_root_id=$_transaction_id
  rollback_and_mark_recovery 17 "injected producer guard failure" failed \
    || fail_test "recovery-required fixture was not published"
  release_boot_repair_lock
  recovery_state_hash=$(sha256_file "$(lifecycle_file_path)")
  if producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    > "$CASE_DIR/recovery-required.out" 2>&1; then
    fail_test "package producer entered during recovery-required"
  fi
  grep -Fq 'recovery-required' "$CASE_DIR/recovery-required.out" \
    || fail_test "package rejection omitted recovery-required state"
  grep -Fq "$recovery_root_id" "$CASE_DIR/recovery-required.out" \
    || fail_test "package rejection omitted the recovery transaction identifier"
  [[ $(sha256_file "$(lifecycle_file_path)") == "$recovery_state_hash" ]] \
    || fail_test "package guard mutated the recovery incident"
)

(
  reset_case
  activate_case
  LIMINE_CONTEXT="entry-tool"
  producer_limine_lock() { with_boot_repair_lock; }
  with_boot_repair_lock || fail_test "stale non-producer fixture could not lock"
  begin_lifecycle_transaction repair active \
    || fail_test "stale non-producer fixture did not start"
  stale_nonproducer_id=$_transaction_id
  stale_nonproducer_manifest=$(lifecycle_manifest_path "$stale_nonproducer_id")
  stale_nonproducer_tmp="$CASE_DIR/stale-nonproducer.json"
  jq '.owner.start_time = "0"' "$stale_nonproducer_manifest" \
    > "$stale_nonproducer_tmp"
  atomic_write_control_file "$stale_nonproducer_manifest" 600 \
    < "$stale_nonproducer_tmp"
  detach_transaction_context
  release_boot_repair_lock
  stale_nonproducer_hash=$(sha256_file "$(lifecycle_file_path)")
  if producer_limine_hook_pre >/dev/null 2>&1; then
    fail_test "stale non-producer transition admitted a Limine producer"
  else
    [[ $? -eq 100 ]] || fail_test "stale non-producer transition was not fatal"
  fi
  [[ $(sha256_file "$(lifecycle_file_path)") == "$stale_nonproducer_hash" \
    && ! -e "$(lifecycle_incident_path "$stale_nonproducer_id")" ]] \
    || fail_test "producer entry point claimed an unrelated stale transition"
)

reset_case
activate_case
producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
  || fail_test "stale package fixture lease failed"
read_lifecycle || fail_test "stale package lease was unreadable"
stale_root_id="$_lifecycle_transaction_id"
stale_root_incident=$(lifecycle_incident_path "$stale_root_id")
OWNER_ALIVE=false
touch "$(pacman_database_lock_path)"
if producer_package_pre <<< 'usr/lib/modules/6.18.1/modules.builtin'; then
  fail_test "package guard recovered a stale transaction while pacman was active"
fi
rm -f "$(pacman_database_lock_path)"
read_lifecycle || fail_test "blocked stale package state was unreadable"
[[ "$_lifecycle_state" == transition \
  && "$_lifecycle_transaction_id" == "$stale_root_id" ]] \
  || fail_test "package guard mutated a stale transaction"
[[ ! -e "$stale_root_incident" ]] \
  || fail_test "package guard sealed an incident while pacman was active"
with_boot_repair_lock || fail_test "stale package recovery lock acquisition failed"
reconcile_and_recover_producer_locked \
  || fail_test "external stale package recovery failed"
release_boot_repair_lock
producer_package_pre <<< 'usr/lib/modules/6.18.1/modules.builtin' \
  || fail_test "post-recovery package admission failed"
OWNER_ALIVE=true
read_lifecycle || fail_test "post-recovery package lease was unreadable"
[[ "$_lifecycle_state" == transition \
  && "$_lifecycle_transaction_id" != "$stale_root_id" ]] \
  || fail_test "recovered admission did not publish a new package lease"
[[ "$_manifest_id" == "$_lifecycle_transaction_id" ]] \
  || fail_test "historical recovery validation replaced the active lease context"
jq -e --arg root "$stale_root_id" '
  .last_recovery.attempt_count == 1 and
  .last_recovery.root_incident.id == $root and
  .last_recovery.final_attempt.status == "completed" and
  .last_transaction.id == .last_recovery.final_attempt.id and
  .last_recovery.proof != null
' "$(lifecycle_file_path)" >/dev/null \
  || fail_test "failed package recovery cross-references were incomplete"
[[ -f "$stale_root_incident" ]] || fail_test "failed package root was not sealed"
stale_root_hash=$(sha256_file "$stale_root_incident")
producer_package_post || fail_test "recovered package final repair failed"
read_lifecycle || fail_test "recovered package completion was unreadable"
[[ "$_lifecycle_state" == active \
  && "$_manifest_id" == "$(jq -r '.last_transaction.id' <<< "$_lifecycle_json")" ]] \
  || fail_test "historical recovery validation replaced the stable transaction context"
[[ $(sha256_file "$stale_root_incident") == "$stale_root_hash" ]] \
  || fail_test "later package completion rewrote the root incident"

for recovery_failpoint in after-attempt-manifest-write after-attempt-transition-write \
  after-attempt-completed-manifest-write after-attempt-incident-write \
  before-recovery-resolved-state-write; do
  reset_case
  activate_case
  producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    || fail_test "${recovery_failpoint} fixture lease was rejected"
  read_lifecycle || fail_test "${recovery_failpoint} fixture was unreadable"
  recovery_root_id="$_lifecycle_transaction_id"
  OWNER_ALIVE=false
  PRODUCER_FAILPOINT="$recovery_failpoint"
  with_boot_repair_lock || fail_test "${recovery_failpoint} could not acquire locks"
  if reconcile_and_recover_producer_locked >/dev/null 2>&1; then
    release_boot_repair_lock
    fail_test "${recovery_failpoint} reported recovery success"
  fi
  release_boot_repair_lock
  read_lifecycle || fail_test "${recovery_failpoint} damaged lifecycle state"
  if [[ "$_lifecycle_state" == active ]]; then
    case "$recovery_failpoint" in
      after-attempt-completed-manifest-write|after-attempt-incident-write) ;;
      *) fail_test "${recovery_failpoint} discarded the recovery incident" ;;
    esac
    [[ $(jq -r '.last_recovery.root_incident.id' <<< "$_lifecycle_json") == \
      "$recovery_root_id" ]] \
      || fail_test "${recovery_failpoint} roll-forward replaced the recovery root"
    PRODUCER_FAILPOINT=""
    continue
  fi
  [[ "$_lifecycle_state" == recovery-required || "$_lifecycle_state" == transition ]] \
    || fail_test "${recovery_failpoint} lost the durable recovery incident"
  PRODUCER_FAILPOINT=""
  with_boot_repair_lock || fail_test "${recovery_failpoint} retry could not lock"
  read_lifecycle || fail_test "${recovery_failpoint} retry could not read lifecycle"
  if [[ "$_lifecycle_state" == transition ]]; then
    prepare_registered_stale_recovery_runtime_locked \
      || fail_test "${recovery_failpoint} retry rejected stale attempt context"
    reconcile_stale_lifecycle \
      || fail_test "${recovery_failpoint} retry could not reconcile stale attempt"
  fi
  if ! reconcile_and_recover_producer_locked; then
    release_boot_repair_lock
    read_lifecycle || fail_test "${recovery_failpoint} retry state became invalid"
    retry_detail="$_lifecycle_state"
    if [[ "$_lifecycle_state" == transition ]] \
      && read_transaction_manifest "$_lifecycle_transaction_id"; then
      retry_detail+="/$(jq -r '.kind + ":" + .status' <<< "$_manifest_json")"
    fi
    fail_test "${recovery_failpoint} retry did not recover from ${retry_detail}"
  fi
  release_boot_repair_lock
  read_lifecycle || fail_test "${recovery_failpoint} retry state was unreadable"
  [[ "$_lifecycle_state" == active \
    && $(jq -r '.last_recovery.root_incident.id' <<< "$_lifecycle_json") == \
      "$recovery_root_id" ]] \
    || fail_test "${recovery_failpoint} retry did not preserve and resolve the root"
done

reset_case
activate_case
producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
  || fail_test "failed-attempt publication fixture lease was rejected"
OWNER_ALIVE=false
PRODUCER_FAILPOINT=before-recovery-attempt-state-write
registered_producer_repair_definition=$(declare -f registered_producer_repair)
registered_producer_repair() { return 47; }
with_boot_repair_lock || fail_test "failed-attempt publication fixture could not lock"
if reconcile_and_recover_producer_locked >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "failed recovery-attempt publication reported success"
fi
release_boot_repair_lock
read_lifecycle || fail_test "failed recovery-attempt publication damaged lifecycle state"
[[ "$_lifecycle_state" == transition ]] \
  || fail_test "failed recovery-attempt publication lost its transition"
PRODUCER_FAILPOINT=""
eval "$registered_producer_repair_definition"
with_boot_repair_lock || fail_test "failed recovery-attempt publication retry could not lock"
reconcile_and_recover_producer_locked \
  || fail_test "failed recovery-attempt publication retry did not recover"
release_boot_repair_lock
read_lifecycle || fail_test "failed recovery-attempt publication retry was unreadable"
[[ "$_lifecycle_state" == active ]] \
  || fail_test "failed recovery-attempt publication retry did not return to active"


: > "$REGISTRY_LOG"
for entry in package:package-transaction limine:uki-build limine:entry-tool \
  snapshot:snapshot-sync restore:full-restore; do
  run_registered_producer_preparation \
    "{\"producer_class\":\"${entry%%:*}\",\"subtype\":\"${entry#*:}\"}" \
    || fail_test "root completion registry entry was unavailable: ${entry}"
done
[[ ! -s "$REGISTRY_LOG" ]] || fail_test "root completion reran a producer"
for entry in package:package-transaction limine:uki-build limine:entry-tool \
  snapshot:snapshot-sync restore:full-restore; do
  run_registered_producer_preparation \
    "{\"producer_class\":\"${entry%%:*}\",\"subtype\":\"${entry#*:}\"}" true \
    || fail_test "recovery registry entry was unavailable: ${entry}"
done
if run_registered_producer_preparation \
  '{"producer_class":"package","subtype":"injected-callback"}' true >/dev/null 2>&1; then
  fail_test "unknown durable producer subtype selected executable code"
fi
[[ $(grep -Fxc package "$REGISTRY_LOG") -eq 2 \
  && $(grep -Fxc snapshot "$REGISTRY_LOG") -eq 2 ]] \
  || fail_test "recovery registry selected the wrong fixed handlers"

reset_case
lock_probe="$CASE_DIR/lock-probe"
lock_probe_output="$CASE_DIR/lock-probe-output"
cat > "$lock_probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root_dir="$1"
case_dir="$2"
output="$3"

# shellcheck source=../lib/common.sh
source "$root_dir/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "$root_dir/lib/lifecycle.sh"

control_owner_uid() { id -u; }
require_control_root() { return 0; }
state_dir_path() { printf '%s/state\n' "$case_dir"; }
transactions_dir_path() { printf '%s/transactions\n' "$(state_dir_path)"; }
limine_lock_path() { printf '%s/boot-partition.lock\n' "$case_dir"; }

with_limine_lock
with_repair_lock
printf '%s:%s\n' "$_OMASECBOOT_LIMINE_LOCK_OWNED" \
  "$_OMASECBOOT_REPAIR_LOCK_MODE" > "$output"
release_repair_lock
release_limine_lock
EOF
chmod 755 "$lock_probe"
ensure_state_layout || fail_test "nested lock fixture layout failed"
: > "$(limine_lock_path)"
chmod 644 "$(limine_lock_path)"
with_boot_repair_lock || fail_test "parent boot repair lock failed"
with_limine_lock_handoff /usr/bin/timeout 5 \
  "$lock_probe" "$ROOT_DIR" "$CASE_DIR" "$lock_probe_output" \
  || fail_test "nested producer lock handoff failed"
[[ $(< "$lock_probe_output") == local:inherited ]] \
  || fail_test "nested producer did not inherit the parent repair lock"
[[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == local \
  && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true \
  && "$_OMASECBOOT_REPAIR_LOCK_MODE" == local ]] \
  || fail_test "parent lock ownership was not restored after handoff"
if flock -n "$(state_dir_path)/repair.lock" true 2>/dev/null; then
  fail_test "nested producer release unlocked the parent repair lock"
fi
release_boot_repair_lock

inherited_probe="$CASE_DIR/inherited-lock-probe"
inherited_probe_output="$CASE_DIR/inherited-lock-output"
cat > "$inherited_probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root_dir="$1"
case_dir="$2"
mode="$3"
output="$4"

# shellcheck source=../lib/common.sh
source "$root_dir/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "$root_dir/lib/lifecycle.sh"
# shellcheck source=../lib/producers.sh
source "$root_dir/lib/producers.sh"

control_owner_uid() { id -u; }
require_control_root() { return 0; }
state_dir_path() { printf '%s/state\n' "$case_dir"; }
limine_lock_path() { printf '%s/boot-partition.lock\n' "$case_dir"; }
replace_limine_lock_path() {
  local path
  path=$(limine_lock_path)
  mv "$path" "${path}.old"
  : > "$path"
  chmod 644 "$path"
}

lock_inherited_limine_fd
with_repair_lock
set +e
if [[ "$mode" == replace ]]; then
  with_limine_lock_handoff replace_limine_lock_path
  handoff_rc=$?
else
  with_limine_lock_handoff /usr/bin/true
  handoff_rc=$?
fi
set -e
printf '%s:%s:%s\n' "$handoff_rc" "$_OMASECBOOT_LIMINE_LOCK_OWNED" \
  "$_OMASECBOOT_REPAIR_LOCK_MODE" > "$output"
[[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false ]]
release_boot_repair_lock
EOF
chmod 755 "$inherited_probe"
with_boot_repair_lock || fail_test "inherited handoff parent lock failed"
"$inherited_probe" "$ROOT_DIR" "$CASE_DIR" stable "$inherited_probe_output" \
  || fail_test "inherited Limine handoff failed"
[[ $(< "$inherited_probe_output") == 0:inherited:inherited ]] \
  || fail_test "inherited Limine handoff did not restore delegated locks"
"$inherited_probe" "$ROOT_DIR" "$CASE_DIR" replace "$inherited_probe_output" \
  || fail_test "replaced inherited lock path was not recovered"
[[ $(< "$inherited_probe_output") == 1:local:inherited ]] \
  || fail_test "replaced inherited lock path returned without a current lock"
if flock -n "$(state_dir_path)/repair.lock" true 2>/dev/null; then
  fail_test "inherited child release unlocked the parent repair lock"
fi
release_boot_repair_lock
with_boot_repair_lock || fail_test "current Limine lock path was not reusable"
limine_policy_probe="$CASE_DIR/limine-policy-probe"
limine_policy_output="$CASE_DIR/limine-policy-output"
cat > "$limine_policy_probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

root_dir="$1"
case_dir="$2"
phase="$3"
output="$4"

# shellcheck source=../lib/common.sh
source "$root_dir/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "$root_dir/lib/lifecycle.sh"
# shellcheck source=../lib/producers.sh
source "$root_dir/lib/producers.sh"

control_owner_uid() { id -u; }
require_control_root() { return 0; }
state_dir_path() { printf '%s/state\n' "$case_dir"; }
limine_lock_path() { printf '%s/boot-partition.lock\n' "$case_dir"; }

_producer_class=limine
set +e
producer_limine_lock "$phase"
policy_rc=$?
set -e
printf '%s:%s:%s\n' "$policy_rc" "$_OMASECBOOT_LIMINE_LOCK_OWNED" \
  "$_OMASECBOOT_REPAIR_LOCK_MODE" > "$output"
release_boot_repair_lock
EOF
chmod 755 "$limine_policy_probe"
for policy_phase in pre post; do
  "$limine_policy_probe" "$ROOT_DIR" "$CASE_DIR" "$policy_phase" \
    "$limine_policy_output" \
    || fail_test "non-restore ${policy_phase} lock policy probe failed"
  [[ $(< "$limine_policy_output") == 0:inherited:inherited ]] \
    || fail_test "non-restore ${policy_phase} did not inherit both locks"
done
if flock -n "$(state_dir_path)/repair.lock" true 2>/dev/null; then
  fail_test "non-restore lock policy released the parent repair lock"
fi
release_boot_repair_lock
(
  exec 200>&-
  exec 201>&-
  "$limine_policy_probe" "$ROOT_DIR" "$CASE_DIR" pre "$limine_policy_output"
) || fail_test "missing inherited lock policy probe failed"
[[ $(< "$limine_policy_output") == 1:false:false ]] \
  || fail_test "non-restore pre-hook accepted a missing inherited Limine lock"

signal_probe="$CASE_DIR/signal-probe"
set +e
{
  (
    _transaction_active=true
    _OMASECBOOT_LIMINE_LOCK_OWNED=false
    _OMASECBOOT_REPAIR_LOCK_OWNED=true
    with_boot_repair_lock() {
      _OMASECBOOT_LIMINE_LOCK_OWNED=local
      _OMASECBOOT_REPAIR_LOCK_OWNED=true
      printf 'reacquired\n' >> "$signal_probe"
    }
    rollback_and_mark_recovery() {
      [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
        && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
      printf 'rolled-back\n' >> "$signal_probe"
    }
    transaction_signal_handler TERM 143
  )
  signal_status=$?
} 2>/dev/null
set -e
[[ $signal_status -eq 143 \
  && $(grep -Fxc reacquired "$signal_probe") -eq 1 \
  && $(grep -Fxc rolled-back "$signal_probe") -eq 1 ]] \
  || fail_test "signal rollback did not reacquire delegated locks"

(
  reset_case
  activate_case
  producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    || fail_test "unrecoverable-lock fixture lease was rejected"
  read_lifecycle || fail_test "unrecoverable-lock fixture was unreadable"
  lock_failure_id="$_lifecycle_transaction_id"
  lock_failure_state_hash=$(sha256_file "$(lifecycle_file_path)")
  break_current_limine_lock_path() {
    local path
    path=$(limine_lock_path)
    mv "$path" "${path}.recorded"
    : > "$path"
    chmod 666 "$path"
  }
  run_package_producer_reconstruction() {
    with_limine_lock_handoff break_current_limine_lock_path
  }
  registered_producer_repair() {
    run_package_producer_reconstruction
  }
  if producer_package_post >/dev/null 2>&1; then
    fail_test "producer repair succeeded after both Limine lock paths failed"
  fi
  read_lifecycle || fail_test "unrecoverable-lock transition became unreadable"
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$lock_failure_id" \
    && $(sha256_file "$(lifecycle_file_path)") == "$lock_failure_state_hash" ]] \
    || fail_test "unrecoverable lock failure changed the durable transition"
  rm -f "$(limine_lock_path)"
  mv "$(limine_lock_path).recorded" "$(limine_lock_path)"
  chmod 644 "$(limine_lock_path)"
)

reset_case
activate_case
(
  reset_case
  activate_case
  marker_path=$(snapshot_restore_lock_path)
  : > "$marker_path"
  chmod 644 "$marker_path"
  producer_limine_hook_pre || fail_test "stale-restore fixture lease was rejected"
  read_lifecycle || fail_test "stale-restore fixture was unreadable"
  restore_id="$_lifecycle_transaction_id"
  jq -e '.producer_class == "restore" and .caller == "limine-snapper-sync"' \
    "$(jq -r '.domain_records.producer.path' "$(lifecycle_manifest_path "$restore_id")")" \
    >/dev/null || fail_test "restore lease recorded the wrong producer"

  OWNER_ALIVE=false
  with_boot_repair_lock || fail_test "stale-restore marker check could not lock"
  if reconcile_and_recover_producer_locked; then
    fail_test "stale restore reconciled while its marker still existed"
  fi
  release_boot_repair_lock
  read_lifecycle || fail_test "marked stale-restore state became unreadable"
  [[ "$_lifecycle_state" == transition && -e "$marker_path" ]] \
    || fail_test "stale-restore reconciliation changed durable state or removed the marker"

  registered_producer_repair() {
    local path producer
    path=$(jq -r '.path' <<< "$_recovery_producer_reference") || return 1
    producer=$(read_control_document "$path") || return 1
    run_registered_producer_preparation "$producer" true || return 1
    run_test_producer_repair_phases
  }
  rm -f "$marker_path"
  with_boot_repair_lock || fail_test "stale-restore recovery could not lock"
  reconcile_and_recover_producer_locked \
    || fail_test "stale restore did not recover once its marker was gone"
  release_boot_repair_lock
  [[ $(grep -Fxc snapshot "$REGISTRY_LOG") -eq 1 ]] \
    || fail_test "stale full restore did not use snapshot reconstruction"
  read_lifecycle || fail_test "recovered stale-restore state became unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "stale full restore did not return to active state"
)

reset_case
activate_case
: > "$(snapshot_restore_lock_path)"
chmod 644 "$(snapshot_restore_lock_path)"
if producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' >/dev/null 2>&1; then
  fail_test "generic package admission accepted the full-restore marker"
fi
producer_limine_hook_pre || fail_test "specialized full-restore lease was rejected"
read_lifecycle || fail_test "full-restore lease was unreadable"
restore_id="$_lifecycle_transaction_id"
jq -e '
  .operation == "producer-restore" and .file_rollback_policy == "preserve" and
  .domain_records.producer != null
' "$(lifecycle_manifest_path "$restore_id")" >/dev/null \
  || fail_test "full-restore lease was not specialized"
producer_limine_hook_post || fail_test "full-restore post repair failed"
[[ -e "$(snapshot_restore_lock_path)" ]] \
  || fail_test "OmaSecBoot removed the upstream full-restore marker"
read_lifecycle || fail_test "full-restore completion was unreadable"
[[ "$_lifecycle_state" == active ]] || fail_test "full restore did not commit active state"


resolver_owner=91001
resolver_wrapper=91002
resolver_owner_script=/usr/bin/limine-entry-tool
resolver_owner_no_mutex=false
resolver_owner_restore=false
resolver_has_restore_wrapper=false
process_effective_uid() {
  id -u
}
process_runs_script() {
  local pid="$1" expected="$2"
  if [[ "$pid" == "$resolver_owner" ]]; then
    [[ "$expected" == "$resolver_owner_script" ]]
  elif [[ "$pid" == "$resolver_wrapper" \
    && "$resolver_has_restore_wrapper" == true ]]; then
    [[ "$expected" == /usr/bin/limine-snapper-restore ]]
  else
    return 1
  fi
}
process_cmdline_has_argument() {
  local pid="$1" expected="$2"
  if [[ "$pid" == "$resolver_owner" && "$expected" == --no-mutex ]]; then
    [[ "$resolver_owner_no_mutex" == true ]]
  elif [[ "$pid" == "$resolver_owner" && "$expected" == --restore ]]; then
    [[ "$resolver_owner_restore" == true ]]
  else
    return 1
  fi
}
process_parent_pid() {
  [[ "$1" == "$resolver_owner" ]] || return 1
  printf '%s\n' "$resolver_wrapper"
}

resolve_limine_producer_process "$resolver_owner" \
  || fail_test "entry-tool process identity was not resolved"
[[ "$_producer_class" == limine && "$_producer_subtype" == entry-tool \
  && "$_producer_caller" == limine-entry-tool ]] \
  || fail_test "entry-tool process identity selected the wrong producer"
resolver_owner_no_mutex=true
if resolve_limine_producer_process "$resolver_owner"; then
  fail_test "entry-tool --no-mutex bypassed producer admission"
fi

resolver_owner_script=/usr/share/libalpm/scripts/limine-mkinitcpio-install
resolver_owner_no_mutex=false
resolve_limine_producer_process "$resolver_owner" \
  || fail_test "UKI builder process identity was not resolved"
[[ "$_producer_class" == limine && "$_producer_subtype" == uki-build ]] \
  || fail_test "UKI builder process identity selected the wrong producer"

resolver_owner_script=/usr/bin/limine-snapper-sync
resolver_owner_no_mutex=false
resolver_owner_restore=false
resolve_limine_producer_process "$resolver_owner" \
  || fail_test "snapshot sync process identity was not resolved"
[[ "$_producer_class" == snapshot && "$_producer_subtype" == snapshot-sync ]] \
  || fail_test "snapshot sync process identity selected the wrong producer"
resolver_owner_no_mutex=true
if resolve_limine_producer_process "$resolver_owner"; then
  fail_test "snapshot sync --no-mutex bypassed producer admission"
fi

resolver_owner_script=/usr/bin/limine-snapper-sync
resolver_owner_restore=true
resolver_owner_no_mutex=true
resolver_has_restore_wrapper=true
resolve_limine_producer_process "$resolver_owner" \
  || fail_test "wrapped restore process identity was not resolved"
[[ "$_producer_class" == restore && "$_producer_subtype" == full-restore \
  && "$_producer_caller" == limine-snapper-restore \
  && "$_producer_owner_pid" == "$resolver_owner" ]] \
  || fail_test "wrapped restore identity selected the wrong producer"
resolver_has_restore_wrapper=false
resolve_limine_producer_process "$resolver_owner" \
  || fail_test "direct restore process identity was rejected"
[[ "$_producer_class" == restore && "$_producer_caller" == limine-snapper-sync ]] \
  || fail_test "invalid restore wrapper was attributed as authoritative"
resolver_owner_no_mutex=false
if resolve_limine_producer_process "$resolver_owner"; then
  fail_test "restore process without --no-mutex bypassed producer admission"
fi
resolver_owner_no_mutex=true
resolver_owner_script=/usr/bin/unrecognized-producer
if HOOK_CALLER=limine-snapper-restore HOOK_CMDLINE='--restore --no-mutex' \
  resolve_limine_producer_process "$resolver_owner" >/dev/null 2>&1; then
  fail_test "forged legacy hook environment selected a restore producer"
fi

printf 'producer tests passed\n'
