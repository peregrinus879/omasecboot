#!/bin/bash
# Foundation: settings lookup exactly as upstream reads it, file writes, the
# needs-attention file, the boot lock, the prompts, and the guard that keeps the
# contract suites' cases inside their sandbox.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init common

settings_follow_upstream_layers() {
  [[ $(effective_setting ENABLE_UKI) == yes ]] || fail_test "a later layer did not win"
  [[ $(effective_setting ENABLE_VERIFICATION) == yes ]] || fail_test "an earlier layer was lost"
  [[ -z $(effective_setting NOT_SET) ]] || fail_test "an unset key had a value"
  # One trailing and one leading double quote are dropped, nothing else (C3).
  printf 'ESP_PATH = "/efi"\nODD=""quoted""\n' >>"$FIX/etc/default-limine"
  [[ $(setting_in_file "$FIX/etc/default-limine" ESP_PATH) == /efi ]] || fail_test "quotes or spaces"
  [[ $(setting_in_file "$FIX/etc/default-limine" ODD) == '"quoted"' ]] || fail_test "more than one quote pair was dropped"
  # The array-style command line is not a plain assignment and never matches.
  ! setting_in_file "$FIX/etc/default-limine" KERNEL_CMDLINE >/dev/null || fail_test "array assignment matched"
}

enrollment_counts_only_in_the_default_file() {
  printf 'ENABLE_ENROLL_LIMINE_CONFIG=yes\n' >"$FIX/etc/layers/30-stray.conf"
  [[ -z $(effective_setting ENABLE_ENROLL_LIMINE_CONFIG) ]] || fail_test "a drop-in enabled enrollment"
  printf 'ENABLE_ENROLL_LIMINE_CONFIG=yes\n' >>"$FIX/etc/default-limine"
  [[ $(effective_setting ENABLE_ENROLL_LIMINE_CONFIG) == yes ]] || fail_test "the default file was ignored"
}

atomic_write_replaces_whole_files() {
  printf 'new\n' | atomic_write "$FIX/state/file" 600 || fail_test "write failed"
  [[ $(<"$FIX/state/file") == new && $(stat -c %a "$FIX/state/file") == 600 ]] || fail_test "content or mode"
  [[ -z $(find "$FIX/state" -name '.file.*') ]] || fail_test "a temporary file was left behind"
  ! printf 'x' | atomic_write "$FIX/missing/file" 600 2>/dev/null || fail_test "wrote into a missing directory"
}

needs_attention_round_trip() {
  set_attention "reason one" || fail_test "set"
  [[ $(<"$(attention_file)") == "reason one" ]] || fail_test "content"
  clear_attention
  [[ ! -e $(attention_file) ]] || fail_test "clear"
}

file_safety_refuses_what_others_can_change() {
  local dir=$FIX/state file=$FIX/state/record
  : >"$file"
  { is_safe_directory "$dir" && is_safe_file "$file"; } || fail_test "a plain owned file and directory were refused"
  chmod 664 "$file"
  ! is_safe_file "$file" || fail_test "a group-writable file was accepted"
  chmod 644 "$file"
  ln "$file" "$FIX/state/second-name"
  ! is_safe_file "$file" || fail_test "a file with a second hard link was accepted"
  rm "$FIX/state/second-name"
  ln -s "$dir" "$FIX/link"
  ! is_safe_file "$FIX/link/record" || fail_test "a path through a symlink was accepted"
  ! is_safe_directory "$FIX/link" || fail_test "a symlinked directory was accepted"
  chmod 777 "$dir"
  ! is_safe_directory "$dir" || fail_test "a world-writable directory was accepted"
  owner_uid() { printf '%s\n' "$((EUID + 1))"; }
  chmod 755 "$dir"
  ! is_safe_file "$file" || fail_test "another user's file was accepted"
}

lock_is_taken_and_released() {
  boot_lock_acquire || fail_test "could not take a free lock"
  # shellcheck disable=SC2154 # lib/common.sh owns the lock state.
  [[ $_boot_lock == local ]] || fail_test "state"
  ! flock -n "$(boot_lock_path)" true || fail_test "the lock was not held"
  boot_lock_release
  flock -n "$(boot_lock_path)" true || fail_test "the lock was not released"
}

# The lock is a pathname in a directory root shares with other tools: a lock
# taken on a file that was replaced meanwhile serializes nothing.
replaced_lock_file_is_not_a_lock() {
  flock() {
    command flock "$@" || return
    rm -f "$(boot_lock_path)" && : >"$(boot_lock_path)"
  }
  ! boot_lock_acquire 2>/dev/null || fail_test "a lock on a replaced file was accepted"
  [[ $_boot_lock == false ]] || fail_test "state ${_boot_lock}"
}

busy_lock_is_status_75() {
  local rc=0
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  boot_lock_acquire 2>/dev/null || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "busy lock returned ${rc}"
  [[ $_boot_lock == false ]] || fail_test "state after busy"
}

# A Limine tool that timed out on the lock carries on unlocked and still hands
# descriptor 200 down (C2); the hook's wait is spent inside a package
# transaction and must be the short one.
inherited_unlocked_descriptor_waits_briefly() {
  local rc=0 started=$SECONDS
  boot_lock_wait() { printf '30\n'; }
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  exec 200>>"$(boot_lock_path)"
  boot_lock_acquire 2>/dev/null || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "returned ${rc}"
  (( SECONDS - started < 4 )) || fail_test "the hook path took the long wait"
}

inherited_descriptor_is_reused() {
  # A Limine tool holds the lock on descriptor 200 and runs us as a child (C2).
  exec 200>>"$(boot_lock_path)"
  flock 200
  boot_lock_acquire || fail_test "could not lock the inherited descriptor"
  [[ $_boot_lock == inherited ]] || fail_test "state ${_boot_lock}"
  boot_lock_release
  ! flock -n "$(boot_lock_path)" true || fail_test "releasing unlocked the calling tool's lock"
}

children_run_unlocked() {
  boot_lock_acquire || fail_test "acquire"
  run_unlocked flock -n "$(boot_lock_path)" true || fail_test "the child could not take the lock"
  [[ $_boot_lock == local ]] || fail_test "the lock was not taken again"
  boot_lock_release
  # The calling tool's lock is not ours to release.
  exec 200>>"$(boot_lock_path)"
  flock 200
  boot_lock_acquire || fail_test "inherited acquire"
  ! run_unlocked true || fail_test "a child ran unlocked under an inherited lock"
}

# Without a terminal gum declines silently, which reads as a refusal nobody
# gave (C10); and a declined prompt says what was cancelled.
prompts_need_a_terminal_and_name_what_was_cancelled() {
  local output
  # shellcheck source=lib/checks.sh
  source "$ROOT_DIR/lib/checks.sh"
  printf '#!/bin/bash\nexit 1\n' >"$FIX/bin/gum" && chmod 755 "$FIX/bin/gum"
  output=$(confirm "the test step" "Go on?" </dev/null 2>&1) && fail_test "a prompt without a terminal was answered"
  [[ $output == *'needs a terminal'* ]] || fail_test "no terminal: ${output}"
  require_terminal() { :; }
  output=$(confirm "the test step" "Go on?" 2>&1) && fail_test "a declined prompt read as yes"
  [[ $output == *'Cancelled: the test step'* ]] || fail_test "declined: ${output}"
}

# The contract suites delete and write firmware variables, keys and settings,
# which are fixtures only inside their sandbox. in_sandbox_answer CLAIM
# TOKEN-FILE FILESYSTEM is the guard's answer with its two probes pointed at
# fixtures.
in_sandbox_answer() {
  # shellcheck disable=SC2016 # The inner shell expands its own variables.
  OMASECBOOT_SANDBOX=$1 TOKEN_FILE=$2 FILESYSTEM=$3 bash -c '
    SUITE_NAME=guard
    source "$1" || exit 2
    sandbox_token_file() { printf "%s\n" "$TOKEN_FILE"; }
    filesystem_type() { printf "%s\n" "$FILESYSTEM"; }
    in_sandbox' guard "$ROOT_DIR/tests/lib/sandbox.sh"
}

# Upstream accepts ESP_PATH with a trailing or doubled slash (C3). This tool
# compares paths as text, so it keeps one form: otherwise the fallback loader
# is not recognised and the pass would sign it in place.
esp_path_has_one_form() {
  local value
  # The library's own esp_path, which the fixture replaces with a location.
  # shellcheck source=/dev/null
  source <(sed -n '/^esp_path() {$/,/^}$/p' "$ROOT_DIR/lib/common.sh")
  for value in "$FIX/esp/" "$FIX//esp" "$FIX/esp//"; do
    printf 'ESP_PATH="%s"\n' "$value" >"$FIX/etc/default-limine"
    [[ $(esp_path) == "$FIX/esp" ]] || fail_test "ESP_PATH=${value} read as $(esp_path)"
    is_fallback_loader "$(find "$(esp_path)/" -name BOOTX64.EFI)" || fail_test "the fallback loader was not recognised under ESP_PATH=${value}"
  done
  printf 'ESP_PATH="/"\n' >"$FIX/etc/default-limine"
  [[ $(esp_path) == / ]] || fail_test "the root was lost: $(esp_path)"
}

contract_cases_run_only_in_their_sandbox() {
  local token=$FIX/run/sandbox-token
  printf 'token\n' >"$token"
  in_sandbox_answer token "$token" tmpfs || fail_test "the sandbox itself is not recognised"
  in_sandbox_answer '' "$FIX/run/no-token" tmpfs
  (( $? == 1 )) || fail_test "a plain shell, with no claim and no token, counts as the sandbox"
  in_sandbox_answer forged "$token" tmpfs
  (( $? == 1 )) || fail_test "a claim that does not match the token counts as the sandbox"
  in_sandbox_answer token "$FIX/run/no-token" tmpfs
  (( $? == 1 )) || fail_test "a claim without a token file counts as the sandbox"
  in_sandbox_answer token "$token" efivarfs
  (( $? == 1 )) || fail_test "the firmware's own variables count as a fixture"
}

run_case settings-follow-upstream-layers settings_follow_upstream_layers
run_case enrollment-counts-only-in-the-default-file enrollment_counts_only_in_the_default_file
run_case atomic-write-replaces-whole-files atomic_write_replaces_whole_files
run_case needs-attention-round-trip needs_attention_round_trip
run_case file-safety-refuses-what-others-can-change file_safety_refuses_what_others_can_change
run_case lock-is-taken-and-released lock_is_taken_and_released
run_case replaced-lock-file-is-not-a-lock replaced_lock_file_is_not_a_lock
run_case busy-lock-is-status-75 busy_lock_is_status_75
run_case inherited-unlocked-descriptor-waits-briefly inherited_unlocked_descriptor_waits_briefly
run_case inherited-descriptor-is-reused inherited_descriptor_is_reused
run_case children-run-unlocked children_run_unlocked
run_case prompts-need-a-terminal-and-name-what-was-cancelled prompts_need_a_terminal_and_name_what_was_cancelled
run_case contract-cases-run-only-in-their-sandbox contract_cases_run_only_in_their_sandbox
run_case esp-path-has-one-form esp_path_has_one_form
finish_suite
