#!/bin/bash
# The commands end to end on a fixture machine, each as a process of its own
# (run_cli), and the Limine hook's contract with its caller.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init commands

setup_from_stock_and_again() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  [[ -e $FIX/sbctl/keys ]] || fail_test "no keys"
  grep -qx 'pacman -D --asexplicit sbctl' "$FIX/run/calls" || fail_test "sbctl was not marked as explicitly installed"
  grep -q $'^ENABLE_VERIFICATION\tabsent$' "$(settings_originals_file)" || fail_test "originals"
  grep -q '^limine-mkinitcpio' "$FIX/run/calls" || fail_test "hashed OS entries were not regenerated"
  ! grep -q '#' <(grep 'path:' "$FIX/esp/limine.conf") || fail_test "the OS entry still carries a hash"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "primary"
  file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "UKI"
  cmp -s "$(fallback_loader_path)" "$FIX/share/BOOTX64.EFI" || fail_test "the fallback must stay raw"
  [[ -e $(enabled_marker) && $(enabled_watchers) == 2 ]] || fail_test "marker or watchers"
  [[ $(<"$FIX/run/output") == *'Take a snapshot now'* ]] || fail_test "no snapshot advice"

  : >"$FIX/run/calls"
  run_cli setup || fail_test "second setup failed: $(<"$FIX/run/output")"
  ! grep -qE '^(limine-mkinitcpio|sbctl create-keys|sbctl sign|limine enroll-config)' "$FIX/run/calls" ||
    fail_test "a second setup repeated work: $(<"$FIX/run/calls")"
}

upstream_masked_failure_is_repaired() {
  # Upstream's enroll hook hides its own failure and leaves a raw primary (C2).
  : >"$FIX/run/upstream-hook-fails"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the raw primary was not rebuilt"
}

unsigned_arrival_is_signed() {
  # sbctl's build hook did not sign the UKI (keys lost their way, hook failed).
  : >"$FIX/run/uki-arrives-unsigned"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "the unsigned arrival was not signed"
}

setup_refuses_before_changing_anything() {
  local before
  before=$(find "$FIX/esp" "$FIX/etc" "$FIX/state" -type f -exec sha256sum {} + | sort)
  mkdir -p "$FIX/old"
  : >"$FIX/old/omasecboot"
  run_cli setup && fail_test "setup ran beside an earlier install"
  grep -qF "sudo rm -rf $FIX/old/omasecboot" "$FIX/run/output" || fail_test "the removal command was not printed"
  rm "$FIX/old/omasecboot"
  printf 'ENABLE_UKI=no\n' >"$FIX/etc/layers/90-no-uki.conf"
  run_cli setup && fail_test "setup ran without UKIs"
  rm "$FIX/etc/layers/90-no-uki.conf"
  cp "$FIX/esp/limine.conf" "$FIX/esp/EFI/limine/limine.conf"
  run_cli setup && fail_test "setup ran with a shadowing limine.conf"
  rm "$FIX/esp/EFI/limine/limine.conf"
  # remove refuses without a readable SecureBoot variable, so setup must too.
  mv "$FIX/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" "$FIX/run/SecureBoot"
  run_cli setup && fail_test "setup ran on firmware whose SecureBoot variable cannot be read"
  mv "$FIX/run/SecureBoot" "$FIX/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  [[ $(find "$FIX/esp" "$FIX/etc" "$FIX/state" -type f -exec sha256sum {} + | sort) == "$before" ]] ||
    fail_test "a refused setup changed the machine"
  [[ ! -e $FIX/sbctl/keys ]] || fail_test "a refused setup created keys"
}

# Whatever /etc/default/limine said before is the user's and comes back with
# remove, including values equal to the managed ones.
earlier_values_are_the_users() {
  printf 'ENABLE_ENROLL_LIMINE_CONFIG=yes\n' >>"$FIX/etc/default-limine"
  cp "$FIX/etc/default-limine" "$FIX/run/default-limine-before"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  grep -q $'^ENABLE_ENROLL_LIMINE_CONFIG\tpresent\tENABLE_ENROLL_LIMINE_CONFIG=yes$' "$(settings_originals_file)" || fail_test "originals"
  run_cli remove || fail_test "remove failed: $(<"$FIX/run/output")"
  cmp -s "$FIX/etc/default-limine" "$FIX/run/default-limine-before" || fail_test "the user's own setting did not come back"
}

remove_returns_to_stock() {
  local secure_boot=$FIX/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
  cp "$FIX/etc/default-limine" "$FIX/run/default-limine-before"
  run_cli remove && fail_test "remove ran on a machine that was never set up"
  [[ $(<"$FIX/run/output") == *'Nothing to remove'* ]] || fail_test "refusal: $(<"$FIX/run/output")"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  # The stock boot files are unsigned: on, unreadable and absent all refuse.
  set_mode_variable SecureBoot 1
  run_cli remove && fail_test "remove ran with Secure Boot on"
  printf 'garbage' >"$secure_boot"
  run_cli remove && fail_test "remove ran with an unreadable SecureBoot variable"
  rm "$secure_boot"
  run_cli remove && fail_test "remove ran without a SecureBoot variable"
  [[ -e $(enabled_marker) ]] || fail_test "a refused remove changed state"
  set_mode_variable SecureBoot 0
  CONFIRM_ANSWER=no run_cli remove && fail_test "a declined remove went on"
  [[ -e $(enabled_marker) ]] || fail_test "a declined remove changed state"
  run_cli remove || fail_test "remove failed: $(<"$FIX/run/output")"
  cmp -s "$FIX/etc/default-limine" "$FIX/run/default-limine-before" || fail_test "settings are not back to stock"
  cmp -s "$(primary_loader_path)" "$FIX/share/BOOTX64.EFI" || fail_test "the primary is not the raw executable"
  [[ ! -e $(enabled_marker) && ! -e $(settings_originals_file) && $(enabled_watchers) == 0 ]] || fail_test "state left behind"
  [[ -e $FIX/sbctl/keys ]] || fail_test "remove deleted the keys"
}

# A busy lock must leave the hook and the watcher at work on the sealed loader.
busy_remove_changes_nothing() {
  local rc=0
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  run_cli remove || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "remove returned ${rc}"
  [[ -e $(enabled_marker) && $(enabled_watchers) == 2 ]] || fail_test "a busy remove switched the protection off"
}

# Upstream can hold a new Limine major back (C2): stock is then the loader it
# deployed, not the package's file.
remove_accepts_the_loader_upstream_kept() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  write_raw_loader "$FIX/share/BOOTX64.EFI" 13.0.0
  : >"$FIX/run/upstream-holds-back"
  run_cli remove || fail_test "remove failed: $(<"$FIX/run/output")"
  grep -aq 'LIMINE-12.8.0' "$(primary_loader_path)" || fail_test "the primary is not the loader upstream kept"
}

remove_can_be_run_again() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$FIX/run/limine-install-fails"
  run_cli remove && fail_test "a failed Limine tool went unnoticed"
  [[ -e $(settings_originals_file) ]] || fail_test "the originals were dropped before the work was done"
  rm "$FIX/run/limine-install-fails"
  run_cli remove || fail_test "second remove failed: $(<"$FIX/run/output")"
  [[ ! -e $(settings_originals_file) ]] || fail_test "originals remain"
}

# limine-mkinitcpio reports success after a failed build (C2). Signing the UKI
# in place would then make its hashed entry stale, so setup stops first.
silent_build_failure_stops_setup() {
  cp "$FIX/esp/EFI/Linux/omarchy_linux.efi" "$FIX/run/uki-before"
  : >"$FIX/run/uki-build-fails-silently"
  run_cli setup && fail_test "setup passed although the entries still carry hashes"
  [[ $(<"$FIX/run/output") == *'could not be regenerated without path hashes'* ]] || fail_test "message: $(<"$FIX/run/output")"
  cmp -s "$FIX/esp/EFI/Linux/omarchy_linux.efi" "$FIX/run/uki-before" || fail_test "a hashed UKI was signed in place"
  rm "$FIX/run/uki-build-fails-silently"
  run_cli setup || fail_test "setup after the repair failed: $(<"$FIX/run/output")"
}

# A machine coming from an earlier version of this tool.
setup_removes_harmful_sbctl_rows() {
  local history=$FIX/esp/machine/limine_history/old.efi_sha256_abc
  mkdir -p "${history%/*}" && printf 'snapshot image' | tee "$history" "$FIX/run/history-before" >/dev/null
  printf '%s\n' "$history" "$(fallback_loader_path)" >"$FIX/sbctl/files"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  [[ ! -s $FIX/sbctl/files ]] || fail_test "rows left: $(<"$FIX/sbctl/files")"
  cmp -s "$history" "$FIX/run/history-before" || fail_test "setup changed a history file"
}

busy_boot_files_exit_75() {
  local rc=0
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  run_cli sign || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "sign returned ${rc}: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'Boot files are busy'* ]] || fail_test "message: $(<"$FIX/run/output")"
}

# The hook's pass as a Limine tool runs it: a child that inherits the lock on
# descriptor 200 (C2), works under it and leaves it held.
hook_pass_works_under_the_callers_lock() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  printf 'a new unsigned uki' >"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  (
    exec 200>>"$(boot_lock_path)"
    flock 200
    run_cli sign --quiet || exit 1
    ! flock -n "$(boot_lock_path)" true || exit 2
  ) || fail_test "status $? under the caller's lock: $(<"$FIX/run/output")"
  file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "the arrival was not signed"
}

usage_errors_exit_2() {
  local rc
  for arguments in nonsense 'sign --config-onyl' 'status extra' 'setup --force' 'remove now'; do
    rc=0
    # shellcheck disable=SC2086 # The words are the command line.
    run_cli $arguments || rc=$?
    (( rc == 2 )) || fail_test "'${arguments}' returned ${rc}"
  done
  [[ ! -e $(enabled_marker) && ! -e $FIX/sbctl/keys ]] || fail_test "a usage error changed the machine"
  run_cli version || fail_test "version"
  [[ $(<"$FIX/run/output") =~ ^omasecboot\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_test "version output"
  run_cli sign && fail_test "sign ran on a machine that was never set up"
  # --quiet is accepted anywhere on the line.
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  run_cli sign --seal-only --quiet || fail_test "--quiet after an option: $(<"$FIX/run/output")"
  [[ ! -s $FIX/run/output ]] || fail_test "a quiet clean pass printed: $(<"$FIX/run/output")"
}

status_quiet_prints_nothing() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  run_cli status --quiet || fail_test "quiet status failed on a clean machine"
  [[ ! -s $FIX/run/output ]] || fail_test "quiet status printed: $(<"$FIX/run/output")"
  printf 'unsigned' >"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  run_cli --quiet status && fail_test "quiet status missed an unsigned UKI"
  [[ ! -s $FIX/run/output ]] || fail_test "quiet status printed on failure"
}

# The hook as installed: the state check and the command path are the only
# things substituted, exactly as the Makefile and a fixture need them.
hook_never_fails_its_caller() {
  local hook=$FIX/bin/hook-under-test
  sed -e "s|@BINDIR@|$FIX/bin|g" -e "s|/var/lib/omasecboot/enabled|$FIX/state/enabled|" \
    "$ROOT_DIR/limine-hooks/90-omasecboot-sign" >"$hook" && chmod 755 "$hook"
  printf '#!/bin/bash\nprintf ran >>"%s/run/hook-ran"\nexit 1\n' "$FIX" >"$FIX/bin/omasecboot" && chmod 755 "$FIX/bin/omasecboot"
  "$hook" || fail_test "the dormant hook failed"
  [[ ! -e $FIX/run/hook-ran ]] || fail_test "the dormant hook ran the tool"
  : >"$FIX/state/enabled"
  "$hook" || fail_test "a failing tool made the hook fail its caller"
  [[ -e $FIX/run/hook-ran ]] || fail_test "the hook did not run the tool"
  rm "$FIX/bin/omasecboot"
  "$hook" 2>/dev/null || fail_test "a missing tool made the hook fail its caller"
}

# remove that stops half way leaves a machine that reads as neither set up
# nor stock; the report says so instead of passing it as "not set up".
unfinished_remove_is_reported() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$FIX/run/limine-install-fails"
  run_cli remove && fail_test "a failed Limine tool went unnoticed"
  [[ ! -e $(enabled_marker) && -e $(settings_originals_file) ]] || fail_test "the fixture is not a remove that stopped half way"
  run_cli status && fail_test "status passed over a remove that did not finish"
  [[ $(<"$FIX/run/output") == *'did not finish'* && $(<"$FIX/run/output") != *'Next:'* ]] || fail_test "report: $(<"$FIX/run/output")"
  rm "$FIX/run/limine-install-fails"
  run_cli remove || fail_test "second remove failed: $(<"$FIX/run/output")"
  run_cli status || fail_test "status after a finished remove: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'is not set up on this machine'* && $(<"$FIX/run/output") == *'Next:'*'omasecboot setup'* ]] || fail_test "report: $(<"$FIX/run/output")"
}

# A reboot straight after an update stops the watchers' service while its pass
# is rebuilding the loader. The unit's KillMode signals the pass alone; cut off
# between the raw loader and the sealed one it would leave a machine that does
# not boot, so it finishes.
watchers_pass_finishes_through_a_stop() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  cp "$FIX/share/BOOTX64.EFI" "$(primary_loader_path)"
  : >"$FIX/run/limine-enroll-is-slow"
  start_cli sign --quiet --seal-only
  sleep 1
  kill -TERM "$CLI_PID"
  wait "$CLI_PID" || fail_test "the stopped pass failed: $(<"$FIX/run/output")"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "a stop cut the watchers' pass short and left the loader raw"
  # Any other pass is an ordinary process and ends when it is told to.
  cp "$FIX/share/BOOTX64.EFI" "$(primary_loader_path)"
  start_cli sign --quiet
  sleep 1
  kill -TERM "$CLI_PID"
  ! wait "$CLI_PID" || fail_test "a plain sign ignored the signal"
}

run_case setup-from-stock-and-again setup_from_stock_and_again
run_case upstream-masked-failure-is-repaired upstream_masked_failure_is_repaired
run_case unsigned-arrival-is-signed unsigned_arrival_is_signed
run_case setup-refuses-before-changing-anything setup_refuses_before_changing_anything
run_case earlier-values-are-the-users earlier_values_are_the_users
run_case remove-returns-to-stock remove_returns_to_stock
run_case busy-remove-changes-nothing busy_remove_changes_nothing
run_case remove-accepts-the-loader-upstream-kept remove_accepts_the_loader_upstream_kept
run_case remove-can-be-run-again remove_can_be_run_again
run_case silent-build-failure-stops-setup silent_build_failure_stops_setup
run_case setup-removes-harmful-sbctl-rows setup_removes_harmful_sbctl_rows
run_case busy-boot-files-exit-75 busy_boot_files_exit_75
run_case hook-pass-works-under-the-callers-lock hook_pass_works_under_the_callers_lock
run_case usage-errors-exit-2 usage_errors_exit_2
run_case status-quiet-prints-nothing status_quiet_prints_nothing
run_case hook-never-fails-its-caller hook_never_fails_its_caller
run_case unfinished-remove-is-reported unfinished_remove_is_reported
run_case watchers-pass-finishes-through-a-stop watchers_pass_finishes_through_a_stop
finish_suite
