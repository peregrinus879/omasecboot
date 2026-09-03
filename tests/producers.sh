#!/bin/bash
# shellcheck disable=SC1091,SC2154,SC2218,SC2329 # Tests source modules and override functions.
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
REAL_CAPTURE_PRODUCER_BASELINE=$(declare -f capture_producer_baseline)
REAL_RESOLVE_PACKAGE_PRODUCER_CONTEXT=$(declare -f resolve_package_producer_context)
REAL_FULL_RESTORE_RUNTIME_STATE=$(declare -f full_restore_runtime_state)

CASE_DIR="${TEST_DIR}/case"
CONFIG_FILE="${CASE_DIR}/limine.conf"
DEFAULTS_FILE="${CASE_DIR}/limine-defaults"
EFI_FILE="${CASE_DIR}/boot/EFI/Linux/test.efi"
SERVICE_ACTIVE_FILE="${CASE_DIR}/service-active"
SERVICE_ACTION_LOG="${CASE_DIR}/service-actions"
REGISTRY_LOG="${CASE_DIR}/registry-actions"
PRODUCTION_GATE=false
OWNER_ALIVE=true
ROOT_ALLOWED=true
LIMINE_CONTEXT=restore
LIMINE_OWNER_PID_OVERRIDE=""
RESTORE_RUNTIME_STATE=clear
MKINITCPIO_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"
SNAPPER_VERSION="$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION"
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

lifecycle_repair_is_available() {
  [[ "$PRODUCTION_GATE" == true ]]
}

process_matches_identity() {
  [[ "$1" =~ ^[1-9][0-9]*$ && ( "$2" == executable || "$2" == script ) \
    && "$3" == /* ]]
}

manifest_owner_is_alive() {
  [[ "$OWNER_ALIVE" == true ]]
}

full_restore_runtime_state() {
  printf '%s\n' "$RESTORE_RUNTIME_STATE"
}

producer_package_version() {
  case "$1" in
    limine-mkinitcpio-hook) printf '%s\n' "$MKINITCPIO_VERSION" ;;
    limine-snapper-sync) printf '%s\n' "$SNAPPER_VERSION" ;;
    *) return 1 ;;
  esac
}

lifecycle_failpoint() {
  [[ "$1" != "$PRODUCER_FAILPOINT" ]]
}

capture_service_state() {
  printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"inactive","unit_file_state":"disabled"}}'
}

systemctl() {
  local unit="$TRANSACTION_SERVICE_UNIT"
  case "$*" in
    "show --property=ActiveState --value ${unit}")
      printf '%s\n' "$(<"$SERVICE_ACTIVE_FILE")"
      ;;
    "stop ${unit}")
      printf 'stop\n' >> "$SERVICE_ACTION_LOG"
      printf 'inactive\n' > "$SERVICE_ACTIVE_FILE"
      ;;
    "start ${unit}")
      printf 'start\n' >> "$SERVICE_ACTION_LOG"
      printf 'active\n' > "$SERVICE_ACTIVE_FILE"
      ;;
    *) return 1 ;;
  esac
}

producer_reconstruction_preflight() {
  :
}

capture_producer_baseline() {
  local transaction_id="$1" timestamp artifacts document path entry
  timestamp=$(utc_timestamp)
  artifacts='[]'
  for path in "$CONFIG_FILE" "$DEFAULTS_FILE"; do
    entry=$(jq -cn \
      --arg kind "$([[ "$path" == "$CONFIG_FILE" ]] && printf config || printf defaults)" \
      --arg path "$path" \
      --arg hash "$(sha256_file "$path")" \
      --arg identity "$(control_file_identity "$path")" '{
        identity: $identity,
        kind: $kind,
        path: $path,
        presence: "present",
        sha256: $hash
      }')
    artifacts=$(jq -c --argjson entry "$entry" '. + [$entry]' <<< "$artifacts")
  done
  artifacts=$(jq -c 'sort_by(.path)' <<< "$artifacts")
  document=$(jq -cn \
    --argjson schema "$PRODUCER_BASELINE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg timestamp "$timestamp" \
    --argjson artifacts "$artifacts" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      captured_at: $timestamp,
      artifacts: $artifacts
    }')
  validate_producer_baseline_json "$transaction_id" "$document"
  printf '%s\n' "$document"
}

resolve_package_producer_context() {
  reset_producer_context
  _producer_class=package
  _producer_subtype=package-transaction
  _producer_owner_pid=$BASHPID
  _producer_owner_kind=executable
  _producer_owner_identity=/usr/bin/pacman
  _producer_caller=pacman
  _producer_lock_policy=coordinator-lease
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
      _producer_lock_policy=inherited
      ;;
    snapshot)
      _producer_class=snapshot
      _producer_subtype=snapshot-sync
      _producer_owner_identity=/usr/bin/limine-snapper-sync
      _producer_caller=limine-snapper-sync
      _producer_lock_policy=inherited
      ;;
    restore)
      _producer_class=restore
      _producer_subtype=full-restore
      _producer_owner_identity=/usr/bin/limine-snapper-sync
      _producer_caller=limine-snapper-sync
      _producer_restore=true
      _producer_no_mutex=true
      _producer_lock_policy=restore-window
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
      obligations: {kind: "not-applicable", paths: []},
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

registered_producer_repair() {
  transaction_phase_start "test-producer-repair" || return 1
  write_test_final_proof || return 1
  transaction_phase_complete "test-producer-repair"
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
  printf 'inactive\n' > "$SERVICE_ACTIVE_FILE"
  : > "$SERVICE_ACTION_LOG"
  : > "$REGISTRY_LOG"
  PRODUCTION_GATE=false
  OWNER_ALIVE=true
  ROOT_ALLOWED=true
  LIMINE_CONTEXT=restore
  LIMINE_OWNER_PID_OVERRIDE=""
  RESTORE_RUNTIME_STATE=clear
  MKINITCPIO_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"
  SNAPPER_VERSION="$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION"
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
(
  eval "$REAL_CAPTURE_PRODUCER_BASELINE"
  inventory_extra_efi=false
  inventory_extra_tracking=false
  extra_efi="$CASE_DIR/boot/EFI/Linux/extra.efi"
  tracking_path="$CASE_DIR/tracking.json"
  extra_tracking_path="$CASE_DIR/tracking-extra.json"
  discover_efi_files() {
    printf '%s\n' "$EFI_FILE"
    [[ "$inventory_extra_efi" == false ]] || printf '%s\n' "$extra_efi"
  }
  sbctl_database_candidate_paths() {
    printf '%s\n' "$tracking_path"
    [[ "$inventory_extra_tracking" == false ]] || printf '%s\n' "$extra_tracking_path"
  }
  baseline=$(capture_producer_baseline 11111111-1111-1111-1111-111111111111) \
    || fail_test "real producer baseline capture failed"
  producer_baseline_matches_current "$baseline" \
    || fail_test "unchanged complete producer baseline did not revalidate"
  printf 'CHANGED EFI\n' > "$EFI_FILE"
  if producer_baseline_matches_current "$baseline"; then
    fail_test "changed producer baseline artifact revalidated"
  fi
  printf 'SIGNED EFI\n' > "$EFI_FILE"
  printf 'EXTRA EFI\n' > "$extra_efi"
  inventory_extra_efi=true
  if producer_baseline_matches_current "$baseline"; then
    fail_test "new EFI artifact was omitted from baseline revalidation"
  fi
  inventory_extra_efi=false
  rm -f "$extra_efi"
  inventory_extra_tracking=true
  if producer_baseline_matches_current "$baseline"; then
    fail_test "new tracking candidate was omitted from baseline revalidation"
  fi
)
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
  eval "$REAL_FULL_RESTORE_RUNTIME_STATE"
  scanner_root="${TEST_DIR}/scanner-proc"
  scanner_cwd="${TEST_DIR}/scanner-cwd"
  scanner_pid=91021
  mkdir -p "${scanner_root}/${scanner_pid}" "$scanner_cwd"
  : > "${scanner_cwd}/relative-restore"
  ln -s "$scanner_cwd" "${scanner_root}/${scanner_pid}/cwd"
  [[ $(full_restore_process_script "${scanner_root}/${scanner_pid}" relative-restore) == \
    "${scanner_cwd}/relative-restore" ]] \
    || fail_test "restore process script was not resolved through its own cwd"

  SCAN_FAILURE=""
  SCAN_EXECUTABLE=/usr/bin/bash
  SCAN_SCRIPT=/usr/bin/limine-snapper-restore
  full_restore_process_root() {
    if [[ "$SCAN_FAILURE" == root ]]; then
      printf 'relative\n'
    else
      printf '%s\n' "$scanner_root"
    fi
  }
  validate_control_file() {
    [[ "$SCAN_FAILURE" != validate ]]
  }
  process_start_time() {
    [[ "$1" == "$scanner_pid" && "$SCAN_FAILURE" != start ]] || return 1
    printf '910210\n'
  }
  process_effective_uid() {
    [[ "$1" == "$scanner_pid" && "$SCAN_FAILURE" != uid ]] || return 1
    id -u
  }
  process_state() {
    [[ "$1" == "$scanner_pid" && "$SCAN_FAILURE" != state ]] || return 1
    printf 'S\n'
  }
  full_restore_process_executable() {
    [[ "$SCAN_FAILURE" != executable ]] || return 1
    printf '%s\n' "$SCAN_EXECUTABLE"
  }
  full_restore_process_script() {
    [[ "$SCAN_FAILURE" != script ]] || return 1
    printf '%s\n' "$SCAN_SCRIPT"
  }
  write_scanner_cmdline() {
    printf '%s\0' "$@" > "${scanner_root}/${scanner_pid}/cmdline"
  }
  assert_scanner_state() {
    local expected="$1" reason="$2" actual
    actual=$(full_restore_runtime_state)
    [[ "$actual" == "$expected" ]] || fail_test "$reason"
  }

  write_scanner_cmdline bash relative-restore
  assert_scanner_state running "restore wrapper process was not detected"
  SCAN_SCRIPT=/usr/bin/limine-snapper-sync
  write_scanner_cmdline bash relative-restore --restore --no-mutex
  assert_scanner_state running "restore sync shell was not detected"
  write_scanner_cmdline bash relative-restore --restore
  assert_scanner_state clear "non-full sync shell was treated as a full restore"
  SCAN_EXECUTABLE=/usr/lib/limine/limine-snapper-sync
  SCAN_SCRIPT=""
  write_scanner_cmdline /usr/lib/limine/limine-snapper-sync --restore
  assert_scanner_state running "native restore worker was not detected"
  write_scanner_cmdline /usr/lib/limine/limine-snapper-sync --update
  assert_scanner_state clear "unrelated native worker was treated as a restore"

  SCAN_EXECUTABLE=/usr/bin/bash
  SCAN_SCRIPT=/usr/bin/limine-snapper-sync
  for SCAN_FAILURE in validate root start uid state executable script; do
    write_scanner_cmdline bash relative-restore --restore --no-mutex
    assert_scanner_state unknown \
      "restore process scan did not fail closed for ${SCAN_FAILURE} uncertainty"
  done
  SCAN_FAILURE=""
  rm -f "${scanner_root}/${scanner_pid}/cmdline"
  assert_scanner_state unknown \
    "restore process scan did not fail closed for cmdline uncertainty"
)
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
read_package_producer_targets < "$large_targets" \
  || fail_test "package target reader rejected a realistic transaction"
jq -e 'length == 7000' <<< "$_producer_targets_json" >/dev/null \
  || fail_test "package target reader truncated a realistic transaction"
boundary_targets="$TEST_DIR/package-target-boundary"
: > "$boundary_targets"
for ((target_index = 0; target_index < 120; target_index++)); do
  printf '%04095d\n' 0 >> "$boundary_targets"
done
read_package_producer_targets < "$boundary_targets" \
  || fail_test "package target reader rejected its exact byte boundary"
printf '%04095d\n' 0 >> "$boundary_targets"
if read_package_producer_targets < "$boundary_targets"; then
  fail_test "package target reader accepted input above its byte boundary"
fi
count_boundary_targets="$TEST_DIR/package-target-count-boundary"
: > "$count_boundary_targets"
for ((target_index = 0; target_index < MAX_PRODUCER_TARGETS; target_index++)); do
  printf 'usr/lib/x/%016x\n' "$target_index" >> "$count_boundary_targets"
done
read_package_producer_targets < "$count_boundary_targets" \
  || fail_test "package target reader rejected its exact count boundary"
jq -e --argjson count "$MAX_PRODUCER_TARGETS" 'length == $count' \
  <<< "$_producer_targets_json" >/dev/null \
  || fail_test "package target reader truncated its exact count boundary"
printf 'usr/lib/x/overflow\n' >> "$count_boundary_targets"
if read_package_producer_targets < "$count_boundary_targets"; then
  fail_test "package target reader accepted input above its count boundary"
fi
stream_package_targets() {
  local target
  while IFS= read -r target; do printf '%s\n' "$target"; done < "$large_targets"
}
stream_malformed_package_targets() {
  printf '%04100d\n' 0
  stream_package_targets
}
set +e
stream_malformed_package_targets | read_package_producer_targets
malformed_pipe_status=("${PIPESTATUS[@]}")
set -e
[[ ${malformed_pipe_status[0]} -eq 0 && ${malformed_pipe_status[1]} -ne 0 ]] \
  || fail_test "malformed package targets were not drained before rejection"
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

activate_case
if producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' >/dev/null 2>&1; then
  fail_test "closed production gate admitted a package producer"
fi
set +e
stream_package_targets | producer_package_pre >/dev/null 2>&1
closed_pipe_status=("${PIPESTATUS[@]}")
set -e
[[ ${closed_pipe_status[0]} -eq 0 && ${closed_pipe_status[1]} -ne 0 ]] \
  || fail_test "closed package gate returned before draining NeedsTargets input"
read_lifecycle || fail_test "closed package gate damaged lifecycle state"
[[ "$_lifecycle_state" == active ]] || fail_test "closed package gate changed active state"
producer_recovery_is_available \
  || fail_test "producer component capability was not available"
if lifecycle_repair_is_available; then
  fail_test "consolidated production gate unexpectedly opened"
fi
firmware_recovery_is_available \
  || fail_test "firmware recovery component capability was not available"

for producer_failpoint in after-producer-manifest-write after-producer-transition-write; do
  reset_case
  activate_case
  PRODUCTION_GATE=true
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
PRODUCTION_GATE=true
invalid_targets_output="$CASE_DIR/invalid-targets.out"
set +e
stream_malformed_package_targets \
  | producer_package_pre > "$invalid_targets_output" 2>&1
invalid_targets_status=("${PIPESTATUS[@]}")
set -e
[[ ${invalid_targets_status[0]} -eq 0 && ${invalid_targets_status[1]} -ne 0 ]] \
  || fail_test "active malformed package targets were not drained before rejection"
grep -Fq 'package targets are invalid' "$invalid_targets_output" \
  || fail_test "malformed package targets omitted their rejection reason"
for pinned_target in limine-snapper-sync efibootmgr coreutils; do
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
package_baseline=$(jq -r '.baseline.path' "$package_record")
jq -e '
  .producer_class == "package" and .subtype == "package-transaction" and
  .service_policy == "quiesce" and
  .invocation.targets == [
    "usr/lib/initcpio/install/base",
    "usr/lib/modules/6.18.0/modules.builtin"
  ]
' "$package_record" >/dev/null || fail_test "package producer record was incomplete"
[[ $(stat -Lc '%a' "$package_record") == 600 \
  && $(stat -Lc '%a' "$package_baseline") == 600 ]] \
  || fail_test "producer evidence was not private"
package_state_hash=$(sha256_file "$(lifecycle_file_path)")
process_has_ancestor_definition=$(declare -f process_has_ancestor)
process_has_ancestor() { return 1; }
if producer_package_checkpoint >/dev/null 2>&1; then
  fail_test "package checkpoint accepted a caller outside the recorded coordinator"
fi
eval "$process_has_ancestor_definition"
read_lifecycle || fail_test "rejected package checkpoint damaged lifecycle state"
[[ "$_lifecycle_state" == transition \
  && "$_lifecycle_transaction_id" == "$package_root_id" \
  && $(sha256_file "$(lifecycle_file_path)") == "$package_state_hash" ]] \
  || fail_test "rejected package checkpoint changed the producer lease"
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
producer_package_checkpoint || fail_test "package checkpoint failed"
jq -e '.completed_phases == ["package-pre-sbctl"]' "$package_manifest" >/dev/null \
  || fail_test "package checkpoint was not durable"
producer_package_checkpoint || fail_test "package checkpoint was not idempotent"
producer_package_post || fail_test "package final repair failed"
read_lifecycle || fail_test "completed package lifecycle was unreadable"
[[ "$_lifecycle_state" == active ]] || fail_test "package repair did not restore active state"
jq -e '
  .status == "completed" and .file_rollback_policy == "preserve" and
  .domain_records.producer != null and .domain_records.final_proof != null and
  (.completed_phases | index("package-pre-sbctl") != null) and
  (.completed_phases | index("test-producer-repair") != null)
' "$package_manifest" >/dev/null || fail_test "package final proof was not committed"

run_limine_admission_case() {
  local context="$1" expected_class="$2" root_id record
  reset_case
  activate_case
  PRODUCTION_GATE=true
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
}

run_limine_admission_case entry-tool limine
run_limine_admission_case snapshot snapshot
eval "$producer_limine_lock_definition"

reset_case
activate_case
PRODUCTION_GATE=true
producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
  || fail_test "stale package fixture lease failed"
read_lifecycle || fail_test "stale package lease was unreadable"
stale_root_id="$_lifecycle_transaction_id"
stale_root_incident=$(lifecycle_incident_path "$stale_root_id")
OWNER_ALIVE=false
producer_package_pre <<< 'usr/lib/modules/6.18.1/modules.builtin' \
  || fail_test "next package admission did not recover the failed transaction"
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
producer_package_checkpoint || fail_test "recovered package checkpoint failed"
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
  PRODUCTION_GATE=true
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
    prepare_stale_transition_reconciliation_locked \
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
PRODUCTION_GATE=true
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
run_registered_producer_preparation \
  '{"producer_class":"package","subtype":"package-transaction"}' \
  || fail_test "package registry entry was unavailable"
run_registered_producer_preparation \
  '{"producer_class":"limine","subtype":"uki-build"}' \
  || fail_test "UKI registry entry was unavailable"
run_registered_producer_preparation \
  '{"producer_class":"limine","subtype":"entry-tool"}' \
  || fail_test "entry-tool registry entry was unavailable"
run_registered_producer_preparation \
  '{"producer_class":"snapshot","subtype":"snapshot-sync"}' \
  || fail_test "root snapshot completion was unavailable"
run_registered_producer_preparation \
  '{"producer_class":"restore","subtype":"full-restore"}' \
  || fail_test "root restore completion was unavailable"
if grep -Fq snapshot "$REGISTRY_LOG"; then
  fail_test "root snapshot or restore completion reran snapshot sync"
fi
run_registered_producer_preparation \
  '{"producer_class":"snapshot","subtype":"snapshot-sync"}' true \
  || fail_test "snapshot registry entry was unavailable"
run_registered_producer_preparation \
  '{"producer_class":"restore","subtype":"full-restore"}' true \
  || fail_test "restore registry entry was unavailable"
if run_registered_producer_preparation \
  '{"producer_class":"package","subtype":"injected-callback"}' >/dev/null 2>&1; then
  fail_test "unknown durable producer subtype selected executable code"
fi
[[ $(grep -Fxc package "$REGISTRY_LOG") -eq 2 \
  && $(grep -Fxc snapshot "$REGISTRY_LOG") -eq 2 ]] \
  || fail_test "static registry selected the wrong fixed handlers"

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
with_registry_limine_handoff /usr/bin/timeout 5 \
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
  with_registry_limine_handoff replace_limine_lock_path
  handoff_rc=$?
else
  with_registry_limine_handoff /usr/bin/true
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
  PRODUCTION_GATE=true
  producer_package_pre <<< 'usr/lib/modules/6.18.0/modules.builtin' \
    || fail_test "unrecoverable-lock fixture lease was rejected"
  producer_package_checkpoint \
    || fail_test "unrecoverable-lock fixture checkpoint failed"
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
    with_registry_limine_handoff break_current_limine_lock_path
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
PRODUCTION_GATE=true
SNAPPER_VERSION=1.30.0-1
: > "$(snapshot_restore_lock_path)"
chmod 644 "$(snapshot_restore_lock_path)"
if producer_limine_hook_pre >/dev/null 2>&1; then
  fail_test "unsupported snapshot producer version received a restore lease"
fi
read_lifecycle || fail_test "unsupported-version state became unreadable"
[[ "$_lifecycle_state" == active ]] \
  || fail_test "unsupported snapshot producer version changed lifecycle state"

(
  reset_case
  activate_case
  PRODUCTION_GATE=true
  marker_path=$(snapshot_restore_lock_path)
  : > "$marker_path"
  chmod 644 "$marker_path"
  marker_identity=$(control_file_identity "$marker_path")
  producer_limine_hook_pre || fail_test "stale-restore fixture lease was rejected"
  read_lifecycle || fail_test "stale-restore fixture was unreadable"
  restore_id="$_lifecycle_transaction_id"
  restore_record=$(jq -r '.domain_records.producer.path' \
    "$(lifecycle_manifest_path "$restore_id")")
  jq -e --arg path "$marker_path" --arg identity "$marker_identity" '
    .producer_class == "restore" and
    .restore_marker == {path: $path, identity: $identity}
  ' "$restore_record" >/dev/null \
    || fail_test "restore lease did not bind the upstream marker inode"

  OWNER_ALIVE=false
  RESTORE_RUNTIME_STATE=running
  with_boot_repair_lock || fail_test "stale-restore running check could not lock"
  if reconcile_and_recover_producer_locked; then
    fail_test "stale restore reconciled while its native worker survived"
  fi
  release_boot_repair_lock
  read_lifecycle || fail_test "live stale-restore state became unreadable"
  [[ "$_lifecycle_state" == transition \
    && $(control_file_identity "$marker_path") == "$marker_identity" ]] \
    || fail_test "live stale-restore reconciliation changed durable state or marker"

  registered_producer_repair() {
    local path producer
    path=$(jq -r '.path' <<< "$_recovery_producer_reference") || return 1
    producer=$(read_control_document "$path") || return 1
    run_registered_producer_preparation "$producer" true || return 1
    transaction_phase_start "test-producer-repair" || return 1
    write_test_final_proof || return 1
    transaction_phase_complete "test-producer-repair"
  }
  RESTORE_RUNTIME_STATE=clear
  with_boot_repair_lock || fail_test "stale-restore recovery could not lock"
  reconcile_and_recover_producer_locked \
    || fail_test "quiescent stale restore did not recover"
  release_boot_repair_lock
  [[ ! -e "$marker_path" && ! -L "$marker_path" ]] \
    || fail_test "stale full-restore marker was not removed"
  [[ $(grep -Fxc snapshot "$REGISTRY_LOG") -eq 1 ]] \
    || fail_test "stale full restore did not use snapshot reconstruction"
  read_lifecycle || fail_test "recovered stale-restore state became unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "stale full restore did not return to active state"
)

(
  reset_case
  activate_case
  PRODUCTION_GATE=true
  marker_path=$(snapshot_restore_lock_path)
  : > "$marker_path"
  chmod 644 "$marker_path"
  producer_limine_hook_pre || fail_test "replaced-marker fixture lease was rejected"
  OWNER_ALIVE=false
  rm -f "$marker_path"
  : > "$marker_path"
  chmod 644 "$marker_path"
  replacement_identity=$(control_file_identity "$marker_path")
  with_boot_repair_lock || fail_test "replaced-marker check could not lock"
  if reconcile_and_recover_producer_locked; then
    fail_test "stale restore accepted a replacement marker inode"
  fi
  release_boot_repair_lock
  read_lifecycle || fail_test "replaced-marker state became unreadable"
  [[ "$_lifecycle_state" == transition \
    && $(control_file_identity "$marker_path") == "$replacement_identity" ]] \
    || fail_test "replaced marker was removed or lifecycle state changed"
)

(
  reset_case
  activate_case
  PRODUCTION_GATE=true
  CURRENT_BOOT_ID=$(boot_id_value)
  boot_id_value() { printf '%s\n' "$CURRENT_BOOT_ID"; }
  marker_path=$(snapshot_restore_lock_path)
  : > "$marker_path"
  chmod 644 "$marker_path"
  producer_limine_hook_pre || fail_test "cross-boot restore fixture lease was rejected"
  OWNER_ALIVE=false
  rm -f "$marker_path"
  with_boot_repair_lock || fail_test "same-boot missing-marker check could not lock"
  if reconcile_and_recover_producer_locked; then
    fail_test "same-boot stale restore accepted a missing marker"
  fi
  release_boot_repair_lock
  read_lifecycle || fail_test "same-boot missing-marker state became unreadable"
  [[ "$_lifecycle_state" == transition ]] \
    || fail_test "same-boot missing marker changed lifecycle state"

  CURRENT_BOOT_ID=11111111-2222-4333-8444-555555555555
  registered_producer_repair() {
    local path producer
    path=$(jq -r '.path' <<< "$_recovery_producer_reference") || return 1
    producer=$(read_control_document "$path") || return 1
    run_registered_producer_preparation "$producer" true || return 1
    transaction_phase_start "test-producer-repair" || return 1
    write_test_final_proof || return 1
    transaction_phase_complete "test-producer-repair"
  }
  with_boot_repair_lock || fail_test "cross-boot stale-restore check could not lock"
  prepare_stale_transition_reconciliation_locked \
    || fail_test "cross-boot marker absence was not admitted"
  reconcile_stale_lifecycle || fail_test "cross-boot stale restore did not publish recovery"
  release_boot_repair_lock
  read_lifecycle || fail_test "cross-boot recovery incident became unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "cross-boot stale restore did not enter recovery-required"

  with_boot_repair_lock || fail_test "cross-boot recovery retry could not lock"
  reconcile_and_recover_producer_locked \
    || fail_test "existing restore incident rejected an absent runtime marker"
  release_boot_repair_lock
  read_lifecycle || fail_test "cross-boot recovered state became unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "cross-boot stale restore did not return to active state"
)

reset_case
activate_case
PRODUCTION_GATE=true
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

reset_case
activate_case
(
  snapshot_hook_pid=$BASHPID
  snapshot_watcher_pid=91011
  snapshot_owner_pid=91012
  printf 'active\n' > "$SERVICE_ACTIVE_FILE"
  transaction_service_main_pid() { printf '%s\n' "$snapshot_watcher_pid"; }
  process_effective_uid() {
    [[ "$1" == "$snapshot_watcher_pid" || "$1" == "$snapshot_owner_pid" ]] \
      || return 1
    id -u
  }
  process_parent_pid() {
    case "$1" in
      "$snapshot_hook_pid") printf '%s\n' "$snapshot_owner_pid" ;;
      "$snapshot_owner_pid") printf '%s\n' "$snapshot_watcher_pid" ;;
      "$snapshot_watcher_pid") printf '1\n' ;;
      1) printf '1\n' ;;
      *) return 1 ;;
    esac
  }
  process_start_time() {
    case "$1" in
      "$snapshot_owner_pid") printf '910120\n' ;;
      "$snapshot_watcher_pid") printf '910110\n' ;;
      *) return 1 ;;
    esac
  }
  process_runs_script() {
    [[ "$1" == "$snapshot_watcher_pid" \
      && "$2" == /usr/bin/limine-snapper-watcher ]]
  }
  capture_service_state() {
    printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"active","unit_file_state":"enabled"}}'
  }
  producer_limine_lock() { with_boot_repair_lock; }
  PRODUCTION_GATE=true
  LIMINE_CONTEXT=snapshot
  LIMINE_OWNER_PID_OVERRIDE=$snapshot_owner_pid
  producer_limine_hook_pre \
    || fail_test "watcher-owned snapshot lease could not be published"
  read_lifecycle || fail_test "watcher-owned snapshot lease was unreadable"
  snapshot_id="$_lifecycle_transaction_id"
  snapshot_record=$(jq -r '.domain_records.producer.path' \
    "$(lifecycle_manifest_path "$snapshot_id")")
  jq -e --argjson watcher "$snapshot_watcher_pid" \
    --argjson owner "$snapshot_owner_pid" '
    .producer_class == "snapshot" and .service_policy == "preserve-owner" and
    .service_owner.pid == $watcher and .owner.pid == $owner
  ' "$snapshot_record" >/dev/null \
    || fail_test "watcher descendant did not record preserve-owner"
  jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" \
    '.service_state[$unit].quiesce_status == "completed"' \
    "$(lifecycle_manifest_path "$snapshot_id")" >/dev/null \
    || fail_test "preserve-owner policy was not applied"
  [[ ! -s "$SERVICE_ACTION_LOG" ]] \
    || fail_test "snapshot policy stopped its own watcher service"
  producer_limine_hook_post \
    || fail_test "watcher-owned snapshot lease did not complete"
  read_lifecycle || fail_test "watcher-owned snapshot completion was unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "watcher-owned snapshot completion did not restore active state"
)

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

reset_case
VENDOR_CONFIG_DIR="$CASE_DIR/config/vendor"
SYSTEM_CONFIG_PATH="$CASE_DIR/config/limine-entry-tool.conf"
SYSTEM_CONFIG_DIR="$CASE_DIR/config/system"
SNAPPER_CONFIG_PATH="$CASE_DIR/config/limine-snapper-sync.conf"
MACHINE_ID_PATH="$CASE_DIR/machine-id"
KERNEL_MODULES_DIR="$CASE_DIR/modules"
MKINITCPIO_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"
SNAPPER_VERSION="$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION"
esp_path() { printf '%s/boot\n' "$CASE_DIR"; }
limine_vendor_config_dir() { printf '%s\n' "$VENDOR_CONFIG_DIR"; }
limine_system_config_path() { printf '%s\n' "$SYSTEM_CONFIG_PATH"; }
limine_system_config_dir() { printf '%s\n' "$SYSTEM_CONFIG_DIR"; }
limine_snapper_config_path() { printf '%s\n' "$SNAPPER_CONFIG_PATH"; }
machine_id_path() { printf '%s\n' "$MACHINE_ID_PATH"; }
kernel_modules_dir() { printf '%s\n' "$KERNEL_MODULES_DIR"; }
producer_uefi_is_available() { return 0; }
producer_package_version() {
  case "$1" in
    limine-mkinitcpio-hook) printf '%s\n' "$MKINITCPIO_VERSION" ;;
    limine-snapper-sync) printf '%s\n' "$SNAPPER_VERSION" ;;
    *) return 1 ;;
  esac
}
OWNER_QUERY_FAIL=false
producer_file_owner_package() {
  if [[ "$OWNER_QUERY_FAIL" == true && "$1" == */6.18.1/modules.builtin ]]; then
    return 1
  fi
  case "$1" in
    */6.18.0/modules.builtin) printf 'linux\n' ;;
    */6.18.1/modules.builtin) printf 'linux-lts\n' ;;
    *) return 1 ;;
  esac
}

mkdir -p "$VENDOR_CONFIG_DIR" "$SYSTEM_CONFIG_DIR" \
  "$KERNEL_MODULES_DIR/6.18.0" "$KERNEL_MODULES_DIR/6.18.1"
printf 'ENABLE_UKI=no\n' > "$VENDOR_CONFIG_DIR/defaults.conf"
printf '%s\n' 'ENABLE_UKI=yes' 'CUSTOM_UKI_NAME="omarchy"' \
  > "$SYSTEM_CONFIG_DIR/omarchy-uki.conf"
: > "$KERNEL_MODULES_DIR/6.18.0/modules.builtin"
: > "$KERNEL_MODULES_DIR/6.18.1/modules.builtin"
printf '0123456789abcdef0123456789abcdef\n' > "$MACHINE_ID_PATH"
cat >> "$DEFAULTS_FILE" <<EOF
ESP_PATH="$(esp_path)"
MKINITCPIO_FALLBACK=linux-lts
EOF

uki_obligations=$(derive_uki_inventory_obligations) \
  || fail_test "UKI inventory obligations could not be derived"
jq -e --arg linux "$(esp_path)/EFI/Linux/omarchy_linux.efi" \
  --arg lts "$(esp_path)/EFI/Linux/omarchy_linux-lts.efi" \
  --arg fallback "$(esp_path)/EFI/Linux/omarchy_linux-lts-fallback.efi" '
    .kind == "uki-inventory" and
    .paths == ([$linux, $lts, $fallback] | sort)
  ' <<< "$uki_obligations" >/dev/null \
  || fail_test "UKI inventory obligations did not follow effective configuration"
while IFS= read -r expected_uki; do
  [[ "$expected_uki" == *-fallback.efi ]] && continue
  printf 'EXPECTED UKI\n' > "$expected_uki"
done < <(jq -r '.paths[]' <<< "$uki_obligations")
if verify_obligated_efi_artifacts_exist "$uki_obligations" >/dev/null 2>&1; then
  fail_test "missing fallback UKI satisfied producer obligations"
fi
fallback_uki=$(jq -r '.paths[] | select(endswith("-fallback.efi"))' \
  <<< "$uki_obligations")
printf 'EXPECTED FALLBACK UKI\n' > "$fallback_uki"
verify_obligated_efi_artifacts_exist "$uki_obligations" \
  || fail_test "complete UKI inventory did not satisfy producer obligations"
printf 'MKINITCPIO_FALLBACK=yes\n' >> "$DEFAULTS_FILE"
all_fallback_obligations=$(derive_uki_inventory_obligations) \
  || fail_test "all-kernel fallback obligations could not be derived"
jq -e --arg linux_fallback "$(esp_path)/EFI/Linux/omarchy_linux-fallback.efi" '
  .kind == "uki-inventory" and (.paths | length) == 4 and
  (.paths | index($linux_fallback)) != null
' <<< "$all_fallback_obligations" >/dev/null \
  || fail_test "MKINITCPIO_FALLBACK=yes omitted an expected UKI"
printf 'CUSTOM_UKI_NAME="unsupported-name"\n' >> "$DEFAULTS_FILE"
invalid_name_obligations=$(derive_uki_inventory_obligations) \
  || fail_test "invalid custom UKI name did not use the producer fallback"
jq -e --arg prefix "$(esp_path)/EFI/Linux/0123456789abcdef0123456789abcdef_" '
  .kind == "uki-inventory" and (.paths | length) == 4 and
  all(.paths[]; startswith($prefix))
' <<< "$invalid_name_obligations" >/dev/null \
  || fail_test "invalid custom UKI name did not fall back to machine ID"
printf 'CUSTOM_UKI_NAME="omarchy"\n' >> "$DEFAULTS_FILE"
OWNER_QUERY_FAIL=true
if derive_uki_inventory_obligations >/dev/null 2>&1; then
  fail_test "failed package ownership query weakened UKI obligations"
fi
OWNER_QUERY_FAIL=false
MKINITCPIO_VERSION=1.37.1-1
if derive_uki_inventory_obligations >/dev/null 2>&1; then
  fail_test "unsupported UKI producer version bypassed obligation pinning"
fi
MKINITCPIO_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"

printf 'ENABLE_UKI=no\nESP_PATH="%s"\n' "$(esp_path)" >> "$DEFAULTS_FILE"
non_uki_obligations=$(derive_uki_inventory_obligations) \
  || fail_test "non-UKI mode could not be classified"
jq -e '.kind == "not-applicable" and .paths == []' \
  <<< "$non_uki_obligations" >/dev/null \
  || fail_test "non-UKI mode created false EFI obligations"

printf 'ENABLE_UKI=yes\nESP_PATH="%s"\n' "$(esp_path)" >> "$DEFAULTS_FILE"
history_dir="$(esp_path)/0123456789abcdef0123456789abcdef/limine_history"
mkdir -p "$history_dir"
snapshot_name="omarchy_linux.efi_sha256_$(printf 'a%.0s' {1..64})"
nested_snapshot_name="omarchy_linux-lts.efi_xxh_$(printf 'b%.0s' {1..16})"
deep_snapshot_name="omarchy_linux-zen.efi_b3_$(printf 'c%.0s' {1..64})"
jq -n --arg snapshot "$snapshot_name" --arg nested "$nested_snapshot_name" \
  --arg deep "$deep_snapshot_name" '{
  jsonFormatVersion: "1.3.0",
  snapshotEntries: [{
    kernelEntries: [{
      imageDetails: [
        {fileName: "omarchy_linux.efi", fileHashName: $snapshot},
        {fileName: "initramfs-linux", fileHashName: "initramfs-linux_sha256_deadbeef"}
      ],
      subKernels: [{
        imageDetails: [{fileName: "omarchy_linux-lts.efi", fileHashName: $nested}],
        subKernels: [{
          imageDetails: [{fileName: "omarchy_linux-zen.efi", fileHashName: $deep}],
          subKernels: []
        }]
      }]
    }]
  }]
}' > "$history_dir/snapshots.json"
snapshot_obligations=$(derive_snapshot_manifest_obligations) \
  || fail_test "snapshot manifest obligations could not be derived"
jq -e --arg path "$history_dir/$snapshot_name" \
  --arg nested "$history_dir/$nested_snapshot_name" \
  --arg deep "$history_dir/$deep_snapshot_name" '
  .kind == "snapshot-manifest" and .paths == ([$path, $nested, $deep] | sort)
' <<< "$snapshot_obligations" >/dev/null \
  || fail_test "snapshot manifest selected the wrong EFI obligations"
if verify_obligated_efi_artifacts_exist "$snapshot_obligations" >/dev/null 2>&1; then
  fail_test "missing snapshot UKI satisfied producer obligations"
fi
printf 'SNAPSHOT UKI\n' > "$history_dir/$snapshot_name"
if verify_obligated_efi_artifacts_exist "$snapshot_obligations" >/dev/null 2>&1; then
  fail_test "missing nested snapshot UKI satisfied producer obligations"
fi
printf 'NESTED SNAPSHOT UKI\n' > "$history_dir/$nested_snapshot_name"
if verify_obligated_efi_artifacts_exist "$snapshot_obligations" >/dev/null 2>&1; then
  fail_test "missing deeply nested snapshot UKI satisfied producer obligations"
fi
printf 'DEEP SNAPSHOT UKI\n' > "$history_dir/$deep_snapshot_name"
verify_obligated_efi_artifacts_exist "$snapshot_obligations" \
  || fail_test "present snapshot UKI did not satisfy producer obligations"
jq --arg mismatch "$nested_snapshot_name" '
  .snapshotEntries[0].kernelEntries[0].imageDetails[0].fileHashName = $mismatch
' "$history_dir/snapshots.json" > "$history_dir/snapshots.json.tmp"
mv "$history_dir/snapshots.json.tmp" "$history_dir/snapshots.json"
if derive_snapshot_manifest_obligations >/dev/null 2>&1; then
  fail_test "snapshot hash name was not bound to its EFI source name"
fi
jq --arg snapshot "$snapshot_name" '
  .snapshotEntries[0].kernelEntries[0].imageDetails[0].fileHashName = $snapshot
' "$history_dir/snapshots.json" > "$history_dir/snapshots.json.tmp"
mv "$history_dir/snapshots.json.tmp" "$history_dir/snapshots.json"
jq '.snapshotEntries[0].kernelEntries[0].imageDetails[0].fileHashName = "is_not_available"' \
  "$history_dir/snapshots.json" > "$history_dir/snapshots.json.tmp"
mv "$history_dir/snapshots.json.tmp" "$history_dir/snapshots.json"
if derive_snapshot_manifest_obligations >/dev/null 2>&1; then
  fail_test "unavailable snapshot UKI produced a complete obligation set"
fi
jq '.snapshotEntries[0].kernelEntries[0].imageDetails[0].fileHashName =
  "omarchy_linux.efi_sha256_deadbeef"' \
  "$history_dir/snapshots.json" > "$history_dir/snapshots.json.tmp"
mv "$history_dir/snapshots.json.tmp" "$history_dir/snapshots.json"
if derive_snapshot_manifest_obligations >/dev/null 2>&1; then
  fail_test "malformed snapshot hash produced a complete obligation set"
fi

COMPOSED_CLASS=""
COMPOSED_SUBTYPE=""
COMPOSED_DERIVE_MISMATCH_AT=0
COMPOSED_PREPARATION_CALLS=0
COMPOSED_VERIFY_CALLS=0
COMPOSED_REPAIR_CALLS=0
COMPOSED_PHASE_LOG=""
COMPOSED_DERIVE_LOG="$CASE_DIR/composed-derive"
_transaction_id=00000000-0000-0000-0000-000000000001
read_transaction_manifest() {
  _manifest_json='{"kind":"root","domain_records":{"producer":{"path":"/producer.json"}}}'
}
validate_producer_record_reference() { return 0; }
read_control_document() {
  jq -cn --arg class "$COMPOSED_CLASS" --arg subtype "$COMPOSED_SUBTYPE" \
    '{producer_class: $class, subtype: $subtype}'
}
transaction_phase_start() { COMPOSED_PHASE_LOG+="start:$1 "; }
transaction_phase_complete() { COMPOSED_PHASE_LOG+="complete:$1 "; }
producer_reconstruction_preflight() { return 0; }
derive_registered_producer_obligations() {
  local call_count=0
  if [[ -f "$COMPOSED_DERIVE_LOG" ]]; then
    while IFS= read -r _; do call_count=$((call_count + 1)); done \
      < "$COMPOSED_DERIVE_LOG"
  fi
  call_count=$((call_count + 1))
  printf 'call\n' >> "$COMPOSED_DERIVE_LOG"
  if [[ $call_count -eq $COMPOSED_DERIVE_MISMATCH_AT ]]; then
    printf '%s\n' '{"kind":"uki-inventory","paths":["/boot/EFI/Linux/raced.efi"]}'
  else
    printf '%s\n' '{"kind":"not-applicable","paths":[]}'
  fi
}
run_registered_producer_preparation() {
  [[ "$2" == false ]] || return 1
  COMPOSED_PREPARATION_CALLS=$((COMPOSED_PREPARATION_CALLS + 1))
}
verify_obligated_efi_artifacts_exist() {
  COMPOSED_VERIFY_CALLS=$((COMPOSED_VERIFY_CALLS + 1))
}
artifact_repair_preflight() { return 0; }
repair_boot_artifacts() {
  validate_efi_obligations_json "$1" || return 1
  COMPOSED_REPAIR_CALLS=$((COMPOSED_REPAIR_CALLS + 1))
}

run_composed_repair_case() {
  local class="$1" subtype="$2" expected_derivations="$3"
  COMPOSED_CLASS="$class"
  COMPOSED_SUBTYPE="$subtype"
  : > "$COMPOSED_DERIVE_LOG"
  COMPOSED_DERIVE_MISMATCH_AT=0
  COMPOSED_PREPARATION_CALLS=0
  COMPOSED_VERIFY_CALLS=0
  COMPOSED_REPAIR_CALLS=0
  COMPOSED_PHASE_LOG=""
  registered_producer_repair_impl \
    || fail_test "composed ${class}:${subtype} repair failed"
  [[ $(grep -Fxc call "$COMPOSED_DERIVE_LOG") -eq $expected_derivations \
    && $COMPOSED_PREPARATION_CALLS -eq 1 \
    && $COMPOSED_VERIFY_CALLS -eq 2 \
    && $COMPOSED_REPAIR_CALLS -eq 1 \
    && "$COMPOSED_PHASE_LOG" == \
      "start:reconstruct-producer complete:reconstruct-producer start:confirm-producer-output complete:confirm-producer-output " ]] \
    || fail_test "composed ${class}:${subtype} repair skipped an orchestration boundary"
}

run_composed_repair_case package package-transaction 3
run_composed_repair_case limine uki-build 3
run_composed_repair_case limine entry-tool 2
run_composed_repair_case snapshot snapshot-sync 2
run_composed_repair_case restore full-restore 2

COMPOSED_CLASS=package
COMPOSED_SUBTYPE=package-transaction
: > "$COMPOSED_DERIVE_LOG"
COMPOSED_DERIVE_MISMATCH_AT=2
COMPOSED_PREPARATION_CALLS=0
COMPOSED_VERIFY_CALLS=0
COMPOSED_REPAIR_CALLS=0
COMPOSED_PHASE_LOG=""
if registered_producer_repair_impl; then
  fail_test "pre-reconstruction package inventory race reported success"
fi
[[ $COMPOSED_PREPARATION_CALLS -eq 1 \
  && $COMPOSED_VERIFY_CALLS -eq 0 \
  && $COMPOSED_REPAIR_CALLS -eq 0 \
  && "$COMPOSED_PHASE_LOG" == "start:reconstruct-producer " ]] \
  || fail_test "pre-reconstruction package race crossed the repair boundary"

COMPOSED_CLASS=snapshot
COMPOSED_SUBTYPE=snapshot-sync
: > "$COMPOSED_DERIVE_LOG"
COMPOSED_DERIVE_MISMATCH_AT=2
COMPOSED_PREPARATION_CALLS=0
COMPOSED_VERIFY_CALLS=0
COMPOSED_REPAIR_CALLS=0
COMPOSED_PHASE_LOG=""
if registered_producer_repair_impl; then
  fail_test "post-proof producer inventory race reported success"
fi
[[ $COMPOSED_REPAIR_CALLS -eq 1 \
  && "$COMPOSED_PHASE_LOG" == *"start:confirm-producer-output " \
  && "$COMPOSED_PHASE_LOG" != *"complete:confirm-producer-output "* ]] \
  || fail_test "post-proof inventory race crossed the confirmation boundary"

printf 'producer tests passed\n'
