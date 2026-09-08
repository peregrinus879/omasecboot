#!/bin/bash
# shellcheck disable=SC2154 # Lifecycle globals come from the sourced lifecycle module.
# OmaSecBoot: boot-artifact producer leases and registry-selected recovery

# shellcheck disable=SC2034 # Consumed by the dispatcher activation check.
readonly SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION=1.31.0-1

_producer_class=""
_producer_subtype=""
_producer_owner_pid=""
_producer_owner_kind=""
_producer_owner_identity=""
_producer_caller=""
_producer_record_json=""
_producer_transaction_id=""
_producer_reference=""
_producer_backups_json='[]'

reset_producer_context() {
  _producer_class=""
  _producer_subtype=""
  _producer_owner_pid=""
  _producer_owner_kind=""
  _producer_owner_identity=""
  _producer_caller=""
  _producer_record_json=""
  _producer_transaction_id=""
  _producer_reference=""
  _producer_backups_json='[]'
}

# --- Producer identity -------------------------------------------------------

# Reads pacman's NeedsTargets list to the end and reports whether it changes a
# pinned producer package: 0 blocked, 1 clear, 2 unusable.
package_targets_change_pinned_producer() {
  local line count=0 blocked=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    count=$((count + 1))
    case "$line" in
      limine-mkinitcpio-hook|limine-snapper-sync|sbctl) blocked=true ;;
    esac
  done
  (( count > 0 )) || return 2
  [[ "$blocked" == true ]]
}

drain_package_producer_targets() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do :; done
}

# A process runs as the control owner with the given identity.
process_is_owned_identity() {
  local pid="$1" kind="$2" identity="$3"
  [[ "$(process_effective_uid "$pid" 2>/dev/null || true)" == "$(control_owner_uid)" ]] \
    && process_matches_identity "$pid" "$kind" "$identity"
}

find_root_process_ancestor() {
  local start_pid="$1" kind="$2" identity="$3"
  find_process_ancestor "$start_pid" process_is_owned_identity "$kind" "$identity"
}

set_producer_owner() {
  local pid="$1" kind="$2" identity="$3"
  [[ "$(process_effective_uid "$pid")" == "$(control_owner_uid)" ]] || return 1
  process_matches_identity "$pid" "$kind" "$identity" || return 1
  _producer_owner_pid="$pid"
  _producer_owner_kind="$kind"
  _producer_owner_identity="$identity"
}

resolve_package_producer_context() {
  local owner
  reset_producer_context
  owner=$(find_root_process_ancestor "$PPID" executable /usr/bin/pacman) || return 1
  set_producer_owner "$owner" executable /usr/bin/pacman || return 1
  _producer_class=package
  _producer_subtype="package-transaction"
  _producer_caller=pacman
}

# Test seam: suites replace this to present a fixture parent process.
resolve_limine_producer_context() {
  resolve_limine_producer_process "$PPID"
}

resolve_limine_producer_process() {
  local owner="$1" wrapper
  [[ "$owner" =~ ^[1-9][0-9]*$ ]] || return 1
  reset_producer_context
  if process_runs_script "$owner" /usr/bin/limine-entry-tool; then
    set_producer_owner "$owner" script /usr/bin/limine-entry-tool || return 1
    process_cmdline_has_argument "$owner" --no-mutex && return 1
    _producer_class=limine
    _producer_subtype="entry-tool"
    _producer_caller=limine-entry-tool
  elif process_runs_script "$owner" \
    /usr/share/libalpm/scripts/limine-mkinitcpio-install; then
    set_producer_owner "$owner" script \
      /usr/share/libalpm/scripts/limine-mkinitcpio-install || return 1
    _producer_class=limine
    _producer_subtype=uki-build
    _producer_caller=limine-mkinitcpio-install
  elif process_runs_script "$owner" /usr/bin/limine-snapper-sync; then
    set_producer_owner "$owner" script /usr/bin/limine-snapper-sync || return 1
    if process_cmdline_has_argument "$owner" --restore \
      && process_cmdline_has_argument "$owner" --no-mutex; then
      _producer_class=restore
      _producer_subtype=full-restore
      wrapper=$(process_parent_pid "$owner") || return 1
      if [[ "$(process_effective_uid "$wrapper" 2>/dev/null || true)" == \
        "$(control_owner_uid)" ]] \
        && process_runs_script "$wrapper" /usr/bin/limine-snapper-restore; then
        _producer_caller=limine-snapper-restore
      else
        _producer_caller=limine-snapper-sync
      fi
    else
      process_cmdline_has_argument "$owner" --restore && return 1
      process_cmdline_has_argument "$owner" --restore-kernels && return 1
      process_cmdline_has_argument "$owner" --no-mutex && return 1
      _producer_class=snapshot
      _producer_subtype=snapshot-sync
      _producer_caller=limine-snapper-sync
    fi
  else
    return 1
  fi
  return 0
}

# --- Leases ------------------------------------------------------------------

producer_operation() {
  case "$_producer_class" in
    package) printf 'producer-package\n' ;;
    limine) printf 'producer-limine\n' ;;
    snapshot) printf 'producer-snapshot\n' ;;
    restore) printf 'producer-restore\n' ;;
    *) return 1 ;;
  esac
}

prepare_producer_transaction_documents() {
  local transaction_id transaction_dir producer_path producer operation timestamp
  transaction_id=$(new_transaction_id) || return 1
  transaction_dir=$(create_transaction_dir "$transaction_id") || return 1
  _producer_backups_json=$(prior_lifecycle_backups "$transaction_dir") || return 1
  operation=$(producer_operation) || return 1
  timestamp=$(utc_timestamp) || return 1
  producer=$(jq -cn \
    --argjson schema "$PRODUCER_RECORD_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg operation "$operation" \
    --arg timestamp "$timestamp" \
    --arg class "$_producer_class" \
    --arg subtype "$_producer_subtype" \
    --arg caller "$_producer_caller" \
    --arg boot_id "$(boot_id_value)" \
    --arg owner_kind "$_producer_owner_kind" \
    --arg owner_identity "$_producer_owner_identity" \
    --argjson owner_pid "$_producer_owner_pid" \
    --arg owner_start "$(process_start_time "$_producer_owner_pid")" \
    --argjson owner_uid "$(control_owner_uid)" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      operation: $operation,
      created_at: $timestamp,
      producer_class: $class,
      subtype: $subtype,
      caller: $caller,
      owner: {
        boot_id: $boot_id,
        identity: $owner_identity,
        identity_kind: $owner_kind,
        pid: $owner_pid,
        start_time: $owner_start,
        uid: $owner_uid
      }
    }') || return 1
  validate_producer_record_json "$transaction_id" "$producer" || return 1
  producer_path="${transaction_dir}/producer.json"
  printf '%s\n' "$producer" | atomic_create_control_file "$producer_path" 600 || return 1
  _producer_reference=$(transaction_artifact_reference "$producer_path" \
    "$PRODUCER_RECORD_SCHEMA_VERSION") || return 1
  _producer_transaction_id="$transaction_id"
  _producer_record_json="$producer"
}

begin_registered_producer_lease() {
  local rc=0
  [[ "$_lifecycle_state" == active ]] || return 1
  prepare_producer_transaction_documents || return 1
  begin_producer_lifecycle_transaction "$_producer_transaction_id" "$_producer_reference" \
    "$_producer_backups_json" || rc=$?
  if (( rc != 0 )); then
    abandon_failed_begin "$rc" "producer lease"
    return "$rc"
  fi
  detach_transaction_context
}

read_transition_producer_record() {
  local reference path
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition ]] || return 1
  read_transaction_manifest "$_lifecycle_transaction_id" || return 1
  [[ $(jq -r '.kind' <<< "$_manifest_json") == root \
    && $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
  reference=$(jq -c '.domain_records.producer' <<< "$_manifest_json") || return 1
  [[ "$reference" != null ]] || return 1
  validate_producer_record_reference "$_lifecycle_transaction_id" "$reference" || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  _producer_record_json=$(read_control_document "$path") || return 1
}

# The current transition is a producer lease whose owner is alive, still
# matches its recorded identity, and is an ancestor of this process; with a
# class argument the lease must also be of that class.
producer_transition_is_owned() {
  local expected_class="${1:-}" owner_pid
  read_transition_producer_record || return 1
  manifest_owner_is_alive || return 1
  owner_pid=$(jq -r '.owner.pid' <<< "$_producer_record_json") || return 1
  process_matches_identity "$owner_pid" \
    "$(jq -r '.owner.identity_kind' <<< "$_producer_record_json")" \
    "$(jq -r '.owner.identity' <<< "$_producer_record_json")" || return 1
  process_has_ancestor "$owner_pid" "$BASHPID" || return 1
  [[ -z "$expected_class" \
    || $(jq -r '.producer_class' <<< "$_producer_record_json") == "$expected_class" ]]
}

# The owned lease was published by this exact hook context.
producer_lease_is_current_context() {
  [[ $(jq -r '.producer_class' <<< "$_producer_record_json") == "$_producer_class" \
    && $(jq -r '.subtype' <<< "$_producer_record_json") == "$_producer_subtype" \
    && $(jq -r '.owner.pid' <<< "$_producer_record_json") == "$_producer_owner_pid" ]]
}

# The owned lease belongs to an enclosing producer: another class, or the
# same class started by an ancestor of this hook's owner.
producer_lease_is_nested_here() {
  local record_class record_owner
  record_class=$(jq -r '.producer_class' <<< "$_producer_record_json") || return 1
  [[ "$record_class" == "$_producer_class" ]] || return 0
  record_owner=$(jq -r '.owner.pid' <<< "$_producer_record_json") || return 1
  [[ "$record_owner" != "$_producer_owner_pid" ]] \
    && process_has_ancestor "$record_owner" "$_producer_owner_pid"
}

# --- Repair and recovery -----------------------------------------------------

limine_snapper_sync_path() {
  printf '%s\n' /usr/bin/limine-snapper-sync
}

# The producer's own build, run without the hook variables that would make it
# look like a nested hook, with the shared lock handed to it.
run_package_producer_reconstruction() {
  local tool
  tool=$(limine_mkinitcpio_path) || return 1
  validate_control_file /usr/bin/env || return 1
  validate_control_file "$tool" || return 1
  with_limine_lock_handoff /usr/bin/env -u HOOK_CALLER -u HOOK_CMDLINE "$tool"
}

run_snapshot_producer_reconstruction() {
  local tool
  tool=$(limine_snapper_sync_path) || return 1
  validate_control_file /usr/bin/env || return 1
  validate_control_file "$tool" || return 1
  producer_runtime_is_clear || return 1
  with_limine_lock_handoff /usr/bin/env -u HOOK_CALLER -u HOOK_CMDLINE "$tool" \
    --no-force-save
}

# Recovery rebuilds what the interrupted producer would have produced; a
# normal completion trusts the producer's own output.
run_registered_producer_preparation() {
  local producer="$1" recovery="${2:-false}" class subtype
  [[ "$recovery" == true || "$recovery" == false ]] || return 1
  class=$(jq -r '.producer_class' <<< "$producer") || return 1
  subtype=$(jq -r '.subtype' <<< "$producer") || return 1
  case "${class}:${subtype}" in
    package:package-transaction|limine:uki-build)
      [[ "$recovery" == false ]] || run_package_producer_reconstruction
      ;;
    limine:entry-tool) return 0 ;;
    snapshot:snapshot-sync|restore:full-restore)
      [[ "$recovery" == false ]] || run_snapshot_producer_reconstruction
      ;;
    *) return 1 ;;
  esac
}

registered_producer_repair() {
  local reference path producer root_id recovery=false
  read_transaction_manifest "$_transaction_id" || return 1
  if [[ $(jq -r '.kind' <<< "$_manifest_json") == recovery-attempt ]]; then
    reference="$_recovery_producer_reference"
    root_id=$(jq -r '.id' <<< "$_recovery_root_reference") || return 1
    recovery=true
  else
    reference=$(jq -c '.domain_records.producer' <<< "$_manifest_json") || return 1
    root_id="$_transaction_id"
  fi
  [[ "$reference" != null ]] || return 1
  validate_producer_record_reference "$root_id" "$reference" || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  producer=$(read_control_document "$path") || return 1

  transaction_phase_start "reconstruct-producer" || return 1
  producer_reconstruction_preflight || return 1
  run_registered_producer_preparation "$producer" "$recovery" || return 1
  transaction_phase_complete "reconstruct-producer" || return 1
  artifact_repair_preflight || return 1
  repair_boot_artifacts
}

run_registered_producer_recovery_locked() {
  boot_locks_are_held || return 1
  load_producer_recovery_context || return $?
  # A managed-settings conflict is refused before an attempt is consumed and
  # before any producer output is rebuilt under the conflicting configuration.
  artifact_managed_settings_are_repairable || return 1
  run_recovery_attempt_locked producer-recovery registered_producer_repair \
    "registered producer recovery"
}

reconcile_and_recover_producer_locked() {
  read_lifecycle || return 1
  if [[ "$_lifecycle_state" == transition ]]; then
    read_transaction_manifest "$_lifecycle_transaction_id" || return 1
    manifest_owner_is_alive && return 1
    producer_runtime_is_clear || return 1
    reconcile_stale_lifecycle || return 1
    read_lifecycle || return 1
  fi
  if [[ "$_lifecycle_state" == recovery-required ]]; then
    producer_runtime_is_clear || return 1
    run_registered_producer_recovery_locked || return 1
    read_lifecycle || return 1
  fi
  [[ "$_lifecycle_state" == active ]] && producer_runtime_is_clear
}

complete_registered_producer_locked() {
  local expected_class="$1" callback_rc=0
  producer_transition_is_owned "$expected_class" || return 1
  adopt_transaction_context "$_lifecycle_transaction_id" || return 1
  _transaction_failure_reason=""
  arm_transaction_traps
  registered_producer_repair || callback_rc=$?
  finish_armed_transaction commit_lifecycle_transaction "$callback_rc" \
    "producer post-repair" || callback_rc=$?
  restore_transaction_traps
  return "$callback_rc"
}

# --- Package hooks -----------------------------------------------------------

producer_package_pre_locked() {
  read_lifecycle || return 1
  case "$_lifecycle_state" in
    transition)
      if current_transition_is_owned || producer_transition_is_owned; then
        return 0
      fi
      fail "Boot-mutating package transaction blocked: lifecycle is transition for transaction ${_lifecycle_transaction_id}"
      return 1
      ;;
    recovery-required)
      fail "Boot-mutating package transaction blocked: lifecycle is recovery-required for transaction ${_lifecycle_transaction_id}"
      return 1
      ;;
    active)
      reconcile_and_recover_producer_locked || return 1
      begin_registered_producer_lease
      ;;
    *)
      fail "Boot-mutating package transaction blocked: lifecycle state is unsupported"
      return 1
      ;;
  esac
}

producer_package_inactive_pre_locked() {
  read_lifecycle || return 1
  case "$_lifecycle_state" in
    unmanaged|disabled)
      producer_runtime_is_clear || {
        fail "Boot-mutating package transaction blocked: full snapshot restore is running"
        return 1
      }
      return 0
      ;;
    active|transition|recovery-required)
      fail "Boot-mutating package transaction blocked: lifecycle activated during admission"
      return 1
      ;;
    *)
      fail "Boot-mutating package transaction blocked: lifecycle state is unsupported"
      return 1
      ;;
  esac
}

producer_package_pre() {
  local rc=0 policy_rc=0
  require_control_root || {
    drain_package_producer_targets
    return 1
  }
  read_lifecycle || {
    drain_package_producer_targets
    fail "Boot-mutating package transaction blocked: lifecycle state is invalid or unsafe"
    return 1
  }
  case "$_lifecycle_state" in
    unmanaged|disabled)
      drain_package_producer_targets
      with_boot_repair_lock || return 1
      producer_package_inactive_pre_locked || rc=$?
      release_boot_repair_lock
      return "$rc"
      ;;
    active|transition|recovery-required) ;;
    *)
      drain_package_producer_targets
      fail "Boot-mutating package transaction blocked: lifecycle state is unsupported"
      return 1
      ;;
  esac
  package_targets_change_pinned_producer || policy_rc=$?
  case "$policy_rc" in
    0)
      fail "Boot-mutating package transaction blocked: disable lifecycle before changing pinned producers"
      return 1
      ;;
    1) ;;
    *)
      fail "Boot-mutating package transaction blocked: package targets are invalid"
      return 1
      ;;
  esac
  resolve_package_producer_context || {
    fail "Boot-mutating package transaction blocked: producer context could not be resolved"
    return 1
  }
  with_boot_repair_lock || return 1
  producer_package_pre_locked || rc=$?
  release_boot_repair_lock
  return "$rc"
}

producer_package_post() {
  local rc=0
  require_control_root || return 1
  read_lifecycle || return 1
  case "$_lifecycle_state" in
    unmanaged|disabled) return 0 ;;
    active|transition) ;;
    recovery-required)
      fail "Package producer completion blocked: lifecycle is recovery-required for transaction ${_lifecycle_transaction_id}"
      return 1
      ;;
    *)
      fail "Package producer completion blocked: lifecycle state is unsupported"
      return 1
      ;;
  esac
  resolve_package_producer_context || {
    fail "Package producer completion blocked: producer context could not be resolved"
    return 1
  }
  with_boot_repair_lock || return 1
  complete_registered_producer_locked package || rc=$?
  detach_transaction_context
  release_boot_repair_lock
  return "$rc"
}

# --- Limine hooks ------------------------------------------------------------

producer_limine_lock() {
  local phase="$1"
  if [[ "$_producer_class" == restore ]]; then
    with_boot_repair_lock
  elif [[ "$phase" == pre ]]; then
    lock_inherited_limine_fd || return 1
    with_repair_lock
  else
    with_limine_lock || return 1
    with_repair_lock
  fi
}

producer_limine_pre_locked() {
  read_lifecycle || return 1
  if [[ "$_producer_class" == restore ]]; then
    case "$_lifecycle_state" in
      unmanaged|disabled) return 0 ;;
      active) ;;
      *) return 1 ;;
    esac
    validate_control_file "$(snapshot_restore_lock_path)" || return 1
    begin_registered_producer_lease
    return
  fi
  case "$_lifecycle_state" in
    unmanaged|disabled)
      producer_runtime_is_clear
      return
      ;;
    transition)
      if current_transition_is_owned || producer_transition_is_owned; then
        return 0
      fi
      ;;
    active|recovery-required) ;;
    *) return 1 ;;
  esac
  reconcile_and_recover_producer_locked || return 1
  begin_registered_producer_lease
}

producer_limine_hook_pre() {
  local rc=0
  require_control_root || return 100
  read_lifecycle || {
    fail "Lifecycle state is invalid or unsafe"
    return 100
  }
  case "$_lifecycle_state" in
    unmanaged|disabled|active|transition|recovery-required) ;;
    *)
      fail "Boot mutation blocked: lifecycle state is unsupported"
      return 100
      ;;
  esac
  resolve_limine_producer_context || {
    [[ "$_lifecycle_state" == unmanaged || "$_lifecycle_state" == disabled ]] \
      && return 0
    # An unrecognized child of the owning transaction (unconfiguration runs
    # limine-install, which runs these hooks) is admitted on its token,
    # manifest, and ancestry proofs; the parent holds the locks and waits.
    if [[ "$_lifecycle_state" == transition ]] && current_transition_is_owned; then
      return 0
    fi
    fail "Boot mutation blocked: the calling producer is not recognized"
    return 100
  }
  producer_limine_lock pre || return 100
  producer_limine_pre_locked || rc=$?
  release_boot_repair_lock
  [[ $rc -eq 0 ]] || return 100
}

producer_limine_hook_post() {
  local rc=0
  require_control_root || return 100
  read_lifecycle || return 100
  case "$_lifecycle_state" in
    unmanaged|disabled) return 0 ;;
    active|transition|recovery-required) ;;
    *)
      fail "Post-hook producer repair blocked: lifecycle state is unsupported"
      return 100
      ;;
  esac
  resolve_limine_producer_context || {
    if [[ "$_lifecycle_state" == transition ]] && current_transition_is_owned; then
      return 0
    fi
    fail "Post-hook producer repair blocked: the calling producer is not recognized"
    return 100
  }
  producer_limine_lock post || return 100
  if current_transition_is_owned; then
    release_boot_repair_lock
    return 0
  fi
  if ! producer_transition_is_owned; then
    rc=1
  elif producer_lease_is_current_context; then
    complete_registered_producer_locked "$_producer_class" || rc=$?
  elif ! producer_lease_is_nested_here; then
    rc=1
  fi
  detach_transaction_context
  release_boot_repair_lock
  [[ $rc -eq 0 ]] || {
    fail "Post-hook producer repair failed"
    return 100
  }
}
