#!/bin/bash
# shellcheck disable=SC2154,SC2329 # Tests use sourced globals and child overrides.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ${1:-} == _delegated_wrapper ]]; then
  exec 200> "${TEST_DIR}/boot-partition.lock"
  flock -w 1 200 || exit 1
  bash "$0" _hook_child pre
  exit
fi

if [[ ${1:-} == _hook_child ]]; then
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/common.sh"
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/lifecycle.sh"

  state_dir_path() {
    printf '%s/state\n' "$TEST_DIR"
  }

  limine_lock_path() {
    printf '%s/boot-partition.lock\n' "$TEST_DIR"
  }

  snapshot_restore_lock_path() {
    printf '%s/limine-snapper-restore.lock\n' "$TEST_DIR"
  }

  control_owner_uid() {
    id -u
  }

  require_control_root() {
    :
  }

  durable_sync() {
    :
  }

  capture_service_state() {
    printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"inactive","unit_file_state":"disabled"}}'
  }

  lifecycle_repair_is_available() {
    [[ ${REPAIR_AVAILABLE:-false} == true ]]
  }

  full_restore_sync_process_is_valid() {
    [[ ${RESTORE_SYNC_VALID:-true} == true ]]
    [[ " ${HOOK_CMDLINE:-} " == *' --restore '* \
      && " ${HOOK_CMDLINE:-} " == *' --no-mutex '* ]]
  }

  full_restore_wrapper_process_is_valid() {
    [[ ${RESTORE_WRAPPER_VALID:-true} == true ]]
  }

  repair_probe() {
    printf 'repair\n' >> "$CALL_LOG"
    if [[ ${REPAIR_TRANSACTION:-false} == true ]]; then
      run_lifecycle_transaction "repair" "active" "active" repair_transaction
    fi
  }

  repair_transaction() {
    transaction_phase_start "repair"
    transaction_phase_complete "repair"
  }

  case "$2" in
    pre) lifecycle_hook_pre ;;
    post) lifecycle_hook_post repair_probe ;;
    restore-identity) full_snapshot_restore_caller_is_valid ;;
    *) exit 2 ;;
  esac
  exit
fi

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-hooks.XXXXXX")
CALL_LOG="${TEST_DIR}/calls.log"
export TEST_DIR CALL_LOG

cleanup() {
  release_boot_repair_lock 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/lifecycle.sh"

state_dir_path() {
  printf '%s/state\n' "$TEST_DIR"
}

limine_lock_path() {
  printf '%s/boot-partition.lock\n' "$TEST_DIR"
}

snapshot_restore_lock_path() {
  printf '%s/limine-snapper-restore.lock\n' "$TEST_DIR"
}

control_owner_uid() {
  id -u
}

require_control_root() {
  :
}

durable_sync() {
  :
}

capture_service_state() {
  printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"inactive","unit_file_state":"disabled"}}'
}

run_child_without_fd() {
  (
    exec 200>&-
    bash "$0" _hook_child "$1"
  )
}

: > "$CALL_LOG"
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "active fixture adoption failed"

lock_file=$(limine_lock_path)
: > "$lock_file"
chmod 644 "$lock_file"
exec 200> "$lock_file"
flock -w 1 200 || fail_test "could not acquire fixture lock"
if bash "$0" _hook_child pre >/dev/null 2>&1; then
  fail_test "active mutation entered while repair capability was unavailable"
fi
REPAIR_AVAILABLE=true bash "$0" _hook_child pre \
  || fail_test "valid inherited lock was rejected"

if REPAIR_AVAILABLE=true run_child_without_fd pre >/dev/null 2>&1; then
  fail_test "active pre-hook accepted a missing inherited lock"
else
  missing_lock_rc=$?
fi
[[ $missing_lock_rc -eq 100 ]] || fail_test "missing inherited lock was not fatal"

if HOOK_CALLER=limine-snapper-sync HOOK_CMDLINE='--restore --no-mutex' \
  run_child_without_fd pre >/dev/null 2>&1; then
  fail_test "active full restore entered while repair capability was unavailable"
fi
HOOK_CALLER=limine-snapper-sync HOOK_CMDLINE='--restore --no-mutex' \
  REPAIR_AVAILABLE=true \
  run_child_without_fd pre || fail_test "stable full restore was not admitted"
HOOK_CALLER=limine-snapper-restore HOOK_CMDLINE='--restore --no-mutex' \
  REPAIR_AVAILABLE=true \
  run_child_without_fd pre || fail_test "official full restore wrapper was not admitted"
HOOK_CALLER=limine-snapper-sync HOOK_CMDLINE='--restore --no-mutex' \
  bash "$0" _hook_child restore-identity \
  || fail_test "direct restore process identity was rejected"
HOOK_CALLER=limine-snapper-restore HOOK_CMDLINE='--restore --no-mutex' \
  bash "$0" _hook_child restore-identity \
  || fail_test "wrapper restore process identity was rejected"
if HOOK_CALLER=forged HOOK_CMDLINE='--restore --no-mutex' \
  bash "$0" _hook_child restore-identity >/dev/null 2>&1; then
  fail_test "forged full restore caller identity was trusted"
fi
if HOOK_CALLER=limine-snapper-restore HOOK_CMDLINE='--restore --no-mutex' \
  RESTORE_WRAPPER_VALID=false \
  bash "$0" _hook_child restore-identity >/dev/null 2>&1; then
  fail_test "invalid full restore wrapper ancestry was trusted"
fi

exec 200>&-
: > "$(snapshot_restore_lock_path)"
: > "$CALL_LOG"
HOOK_CALLER=limine-snapper-sync HOOK_CMDLINE='--restore --no-mutex' \
  REPAIR_AVAILABLE=true REPAIR_TRANSACTION=true run_child_without_fd post \
  || fail_test "full restore post-hook did not serialize repair"
rm -f "$(snapshot_restore_lock_path)"
grep -Fxq repair "$CALL_LOG" || fail_test "full restore post-hook skipped repair"

exec 200> "$lock_file"
flock -w 1 200 || fail_test "could not reacquire fixture lock"
mv "$lock_file" "${lock_file}.old"
: > "$lock_file"
chmod 644 "$lock_file"
if REPAIR_AVAILABLE=true bash "$0" _hook_child pre >/dev/null 2>&1; then
  fail_test "inherited descriptor for replaced lock path was trusted"
else
  replaced_lock_rc=$?
fi
[[ $replaced_lock_rc -eq 100 ]] || fail_test "replaced inherited lock was not fatal"
exec 200>&-
rm -f "${lock_file}.old"

: > "$CALL_LOG"
run_child_without_fd post || fail_test "post-hook fallback repair failed"
grep -Fxq repair "$CALL_LOG" || fail_test "post-hook fallback skipped repair"

: > "$CALL_LOG"
with_boot_repair_lock
begin_lifecycle_transaction "repair" "active" || fail_test "owned transaction did not start"
bash "$0" _hook_child pre || fail_test "owned nested pre-hook was rejected"
bash "$0" _hook_child post || fail_test "owned nested post-hook was rejected"
[[ ! -s "$CALL_LOG" ]] || fail_test "owned nested post-hook ran repair"
with_delegated_limine_lock bash "$0" _delegated_wrapper \
  || fail_test "nested wrapper lock handoff failed"

if HOOK_CALLER=limine-snapper-sync HOOK_CMDLINE='--restore --no-mutex' \
  bash "$0" _hook_child pre >/dev/null 2>&1; then
  fail_test "full snapshot restore entered during an owned transition"
else
  transition_restore_rc=$?
fi
[[ $transition_restore_rc -eq 100 ]] \
  || fail_test "transition-time full restore was not fatal"

if OMASECBOOT_TRANSACTION_TOKEN=forged bash "$0" _hook_child pre >/dev/null 2>&1; then
  fail_test "forged transition token was trusted"
else
  forged_rc=$?
fi
[[ $forged_rc -eq 100 ]] || fail_test "forged transition was not fatal"

if env -u OMASECBOOT_TRANSACTION_ID -u OMASECBOOT_TRANSACTION_TOKEN \
  bash "$0" _hook_child pre >/dev/null 2>&1; then
  fail_test "external mutation entered an owned transition"
else
  external_rc=$?
fi
[[ $external_rc -eq 100 ]] || fail_test "external transition was not fatal"

transaction_phase_start "repair"
transaction_phase_complete "repair"
commit_lifecycle_transaction || fail_test "owned transaction did not commit"
release_boot_repair_lock

with_boot_repair_lock
begin_lifecycle_transaction "repair" "active" || fail_test "stale hook fixture did not start"
stale_manifest=$(lifecycle_manifest_path "$_transaction_id")
stale_tmp="${TEST_DIR}/stale-hook-manifest.json"
jq '.owner.start_time = "0"' "$stale_manifest" > "$stale_tmp"
atomic_write_control_file "$stale_manifest" 600 < "$stale_tmp"
release_boot_repair_lock
: > "$lock_file"
chmod 644 "$lock_file"
exec 200> "$lock_file"
flock -w 1 200 || fail_test "could not lock stale hook fixture"
if env -u OMASECBOOT_TRANSACTION_ID -u OMASECBOOT_TRANSACTION_TOKEN \
  bash "$0" _hook_child pre >/dev/null 2>&1; then
  fail_test "stale transition admitted external mutation"
else
  stale_hook_rc=$?
fi
[[ $stale_hook_rc -eq 100 ]] || fail_test "stale hook transition was not fatal"
read_lifecycle || fail_test "stale hook reconciliation damaged lifecycle state"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "stale hook transition was not reconciled"
_transaction_active=false
unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
exec 200>&-

rm -rf "$(state_dir_path)"
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "unsafe lock fixture adoption failed"
chmod 666 "$lock_file"
if run_child_without_fd post >/dev/null 2>&1; then
  fail_test "unsafe fallback lock file was trusted"
fi

printf 'hook tests passed\n'
