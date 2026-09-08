#!/bin/bash
# Shared harness for the hermetic suites: one scratch directory, one failure
# reporter, and cleanup that ends parallel cases and releases the boot locks.
# A suite sets ROOT_DIR, sources this file, and calls test_harness_init.
# shellcheck disable=SC2154,SC2329 # Invoked through traps; run_case_pids belongs to the suites.

test_harness_init() {
  TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-${1}.XXXXXX")
  trap test_harness_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
}

test_harness_cleanup() {
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
  if declare -F release_boot_repair_lock >/dev/null; then
    release_boot_repair_lock 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}

# Reports the failure after any logs the suite registered in TEST_FAILURE_LOGS.
fail_test() {
  local log
  for log in "${TEST_FAILURE_LOGS[@]:-}"; do
    if [[ -n "$log" && -f "$log" ]]; then
      /usr/bin/cat "$log" >&2
    fi
  done
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A lifecycle transaction without a preflight step.
run_lifecycle_transaction() {
  run_lifecycle_transaction_with_preflight "$1" "$2" "$3" : "${@:4}"
}
