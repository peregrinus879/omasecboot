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
  [[ -e $(enabled_file) && $(enabled_watchers) == 2 ]] || fail_test "enabled or watchers"
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

# The commands work on the ESP and on two files of root's: an ESP that is not
# mounted, or a file somebody else could write, stops them before any change.
unmounted_esp_and_unsafe_files_stop_the_commands() {
  : >"$FIX/run/esp-unmounted"
  run_cli setup && fail_test "setup ran without the ESP"
  [[ $(<"$FIX/run/output") == *'not mounted'* && ! -e $(enabled_file) ]] || fail_test "setup without the ESP: $(<"$FIX/run/output")"
  rm "$FIX/run/esp-unmounted"
  chmod 666 "$FIX/etc/default-limine"
  cp "$FIX/etc/default-limine" "$FIX/run/default-limine-before"
  run_cli setup && fail_test "setup wrote settings into a file anybody can write"
  cmp -s "$FIX/etc/default-limine" "$FIX/run/default-limine-before" || fail_test "a file anybody can write was changed"
  chmod 644 "$FIX/etc/default-limine"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$FIX/run/esp-unmounted"
  run_cli remove && fail_test "remove ran without the ESP"
  [[ -e $(enabled_file) ]] || fail_test "remove without the ESP changed state"
  rm "$FIX/run/esp-unmounted"
  # remove hands the ESP to upstream's install, which copies in place (C2).
  : >"$FIX/run/esp-is-full" && : >"$FIX/run/calls"
  run_cli remove && fail_test "remove ran on a full ESP"
  [[ $(<"$FIX/run/output") == *'Less than 2 MiB free'* && -e $(enabled_file) ]] || fail_test "remove on a full ESP: $(<"$FIX/run/output")"
  ! grep -q '^limine-install' "$FIX/run/calls" || fail_test "upstream's install ran on a full ESP"
  rm "$FIX/run/esp-is-full"
  chmod 666 "$(settings_originals_file)"
  run_cli remove && fail_test "remove trusted originals anybody can write"
  [[ -e $(enabled_file) ]] || fail_test "remove with unsafe originals changed state"
  [[ $(<"$FIX/run/output") == *'nothing was changed'* ]] || fail_test "report: $(<"$FIX/run/output")"
  # The record of the settings' originals lost on a machine that is set up.
  rm -f "$(settings_originals_file)"
  run_cli remove && fail_test "remove ran without its record of the original settings"
  [[ $(<"$FIX/run/output") == *'is set up, but'* && $(<"$FIX/run/output") != *'Nothing to remove'* ]] || fail_test "a set-up machine was called not set up: $(<"$FIX/run/output")"
}

# A machine that Omarchy installed beside another system: the installer wrote
# ENABLE_LIMINE_FALLBACK=no and there is no fallback loader (C6).
fallback_is_offered_only_into_an_empty_place() {
  local fallback
  fallback=$(fallback_loader_path)
  rm "$fallback"
  printf 'ENABLE_LIMINE_FALLBACK=no\n' >>"$FIX/etc/default-limine"
  CONFIRM_ANSWER=no run_cli setup || fail_test "a declined offer stopped setup: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'Cancelled: the fallback loader'*'sudo omasecboot setup offers to add one again'* ]] || fail_test "a declined offer: $(<"$FIX/run/output")"
  [[ ! -e $fallback ]] || fail_test "a declined offer added the fallback"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  grep -qx 'limine-install --fallback --no-efi-register' "$FIX/run/calls" || fail_test "upstream's step was not used: $(<"$FIX/run/calls")"
  cmp -s "$fallback" "$FIX/share/BOOTX64.EFI" || fail_test "the fallback is not upstream's raw copy"
  [[ $(<"$FIX/run/output") != *'only rescue media'* ]] || fail_test "the warning stayed after the fallback was added"
  grep -qx 'ENABLE_LIMINE_FALLBACK=no' "$FIX/etc/default-limine" || fail_test "the installer's own setting was changed"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the primary is not sealed and signed after upstream's step and the pass"

  # Another system's loader at that path is never asked about, let alone replaced.
  printf 'another system' >"$fallback"
  : >"$FIX/run/calls"
  run_cli setup || fail_test "setup failed beside a foreign loader: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") != *'QUESTION: This machine has no fallback loader'* ]] || fail_test "a foreign loader was offered for replacement"
  ! grep -q -e '--fallback' "$FIX/run/calls" || fail_test "upstream's step ran over a foreign loader"
  [[ $(<"$fallback") == 'another system' ]] || fail_test "a foreign loader was replaced"
}

# Upstream's step fails, does nothing (a flag it no longer knows) or leaves a
# torn copy: setup says so, goes on, and still warns that there is no rescue.
failed_fallback_step_is_reported() {
  local switch
  for switch in limine-install-fails limine-install-does-nothing fallback-copy-is-torn; do
    rm -f "$(fallback_loader_path)"
    : >"$FIX/run/$switch"
    run_cli setup || fail_test "${switch}: setup stopped: $(<"$FIX/run/output")"
    [[ $(<"$FIX/run/output") == *'did not add the packaged fallback loader'*'only rescue media'* ]] || fail_test "${switch}: $(<"$FIX/run/output")"
    loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "${switch}: the primary is not sealed and signed"
    rm "$FIX/run/$switch"
  done
}

remove_returns_to_stock() {
  local secure_boot=$FIX/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
  cp "$FIX/etc/default-limine" "$FIX/run/default-limine-before"
  # Every command is idempotent: with nothing to take back, remove says so, changes nothing and succeeds.
  run_cli remove || fail_test "remove failed on a machine that was never set up: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'Nothing to remove'* ]] || fail_test "no word about it: $(<"$FIX/run/output")"
  cmp -s "$FIX/etc/default-limine" "$FIX/run/default-limine-before" || fail_test "remove changed the settings of a machine that was never set up"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  # The stock boot files are unsigned: on, unreadable and absent all refuse.
  set_mode_variable SecureBoot 1
  run_cli remove && fail_test "remove ran with Secure Boot on"
  printf 'garbage' >"$secure_boot"
  run_cli remove && fail_test "remove ran with an unreadable SecureBoot variable"
  rm "$secure_boot"
  run_cli remove && fail_test "remove ran without a SecureBoot variable"
  [[ -e $(enabled_file) ]] || fail_test "a refused remove changed state"
  set_mode_variable SecureBoot 0
  CONFIRM_ANSWER=no run_cli remove && fail_test "a declined remove went on"
  [[ -e $(enabled_file) ]] || fail_test "a declined remove changed state"
  run_cli remove || fail_test "remove failed: $(<"$FIX/run/output")"
  cmp -s "$FIX/etc/default-limine" "$FIX/run/default-limine-before" || fail_test "settings are not back to stock"
  cmp -s "$(primary_loader_path)" "$FIX/share/BOOTX64.EFI" || fail_test "the primary is not the raw executable"
  [[ ! -e $(enabled_file) && ! -e $(settings_originals_file) && $(enabled_watchers) == 0 ]] || fail_test "state left behind"
  [[ -e $FIX/sbctl/keys ]] || fail_test "remove deleted the keys"
}

# Watchers that systemd would not disable are said, and remove still returns
# the boot files to stock: a watcher without `enabled` finds nothing to do.
failed_disable_is_said() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$FIX/run/systemctl-fails"
  run_cli remove || fail_test "remove failed: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'Could not disable the watchers'*'back to stock'* ]] || fail_test "report: $(<"$FIX/run/output")"
  cmp -s "$(primary_loader_path)" "$FIX/share/BOOTX64.EFI" || fail_test "the primary is not the raw executable"
}

# A busy lock must leave the hook and the watchers at work on the sealed loader.
busy_remove_changes_nothing() {
  local rc=0
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  run_cli remove || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "remove returned ${rc}"
  [[ -e $(enabled_file) && $(enabled_watchers) == 2 ]] || fail_test "a busy remove switched the protection off"
  # The advice must fit the command that met the lock, not only the pass.
  [[ $(<"$FIX/run/output") == *'Boot files are busy'*'run this command again'* ]] || fail_test "the busy advice: $(<"$FIX/run/output")"
}

# A lock that cannot be opened, a state directory that is not safe and a prompt
# without a terminal each stop the command with a line that says why.
refusals_say_why() {
  local lock
  chmod 777 "$FIX/state"
  run_cli setup && fail_test "setup ran with a state directory that others can write"
  [[ $(<"$FIX/run/output") == *'Unsafe state directory'*'writable by others'* ]] || fail_test "unsafe state directory: $(<"$FIX/run/output")"
  [[ ! -e $(settings_originals_file) ]] || fail_test "something was recorded in an unsafe state directory"
  chmod 755 "$FIX/state"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  lock=$(boot_lock_path)
  rm -f "$lock"
  mkdir "$lock"
  run_cli sign && fail_test "sign ran without the boot lock"
  [[ $(<"$FIX/run/output") == *'Could not open the boot lock'* ]] || fail_test "unopenable lock: $(<"$FIX/run/output")"
  rmdir "$lock"
  : >"$FIX/run/no-terminal"
  run_cli remove && fail_test "remove went on without a terminal"
  [[ $(<"$FIX/run/output") == *'Cancelled: the return to stock'* ]] || fail_test "no word on what was cancelled: $(<"$FIX/run/output")"
  [[ -e $(enabled_file) ]] || fail_test "a remove without a terminal changed the machine"
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
  [[ $(<"$FIX/run/output") == *'still holds path hashes after limine-mkinitcpio ran'*'boot():/EFI/Linux/omarchy_linux.efi#'*'run sudo omasecboot setup again'* ]] || fail_test "message: $(<"$FIX/run/output")"
  cmp -s "$FIX/esp/EFI/Linux/omarchy_linux.efi" "$FIX/run/uki-before" || fail_test "a hashed UKI was signed in place"
  rm "$FIX/run/uki-build-fails-silently"
  run_cli setup || fail_test "setup after the repair failed: $(<"$FIX/run/output")"
}

# limine-mkinitcpio keeps a foreign entry as it stands (C7), its hash included,
# and a signature would make that entry stale (D4): setup names the path and
# the way out, and goes on once the hash is off.
hand_written_hash_stops_setup_with_the_way_out() {
  local other=$FIX/esp/EFI/other/loader.efi
  mkdir -p "${other%/*}" && printf 'another loader' | tee "$other" "$FIX/run/other-before" >/dev/null
  printf '\n/Other\n    protocol: efi\n    path: boot():/EFI/other/loader.efi#%s\n' "$(b2sum <"$other" | cut -d' ' -f1)" >>"$FIX/esp/limine.conf"
  run_cli setup && fail_test "setup passed beside an entry that keeps its hash"
  [[ $(<"$FIX/run/output") == *'still holds path hashes'*'boot():/EFI/other/loader.efi#'*'take the #hash off its path'* ]] || fail_test "message: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") != *'omarchy_linux.efi#'* ]] || fail_test "an entry that lost its hash was listed: $(<"$FIX/run/output")"
  cmp -s "$other" "$FIX/run/other-before" || fail_test "a hashed file was signed in place"
  sed -i 's|^\(    path: boot():/EFI/other/loader.efi\)#.*|\1|' "$FIX/esp/limine.conf"
  run_cli setup || fail_test "setup after the hash was taken off failed: $(<"$FIX/run/output")"
  file_is_fixture_signed "$other" || fail_test "the file stayed unsigned once its hash was gone"
}

# A machine whose sbctl file list holds rows that would do damage (D7).
setup_removes_harmful_sbctl_rows() {
  local history=$FIX/esp/machine/limine_history/old.efi_sha256_abc
  mkdir -p "${history%/*}" && printf 'snapshot image' | tee "$history" "$FIX/run/history-before" >/dev/null
  printf '%s\n' "$history" "$(fallback_loader_path)" >"$FIX/sbctl/files"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  [[ ! -s $FIX/sbctl/files ]] || fail_test "rows left: $(<"$FIX/sbctl/files")"
  # A row that sbctl will not give up stops setup, with the reason.
  printf '%s\n' "$history" >"$FIX/sbctl/files"
  : >"$FIX/run/sbctl-cannot-remove-rows"
  run_cli setup && fail_test "setup went on beside a row that makes sbctl sign a history file in place"
  [[ $(<"$FIX/run/output") == *'sbctl could not remove'*'would sign that file in place'* ]] || fail_test "no reason: $(<"$FIX/run/output")"
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
    [[ $(<"$FIX/run/output") == *"${arguments##* }"*'omasecboot setup'* ]] || fail_test "'${arguments}' was not named before the usage text: $(<"$FIX/run/output")"
  done
  [[ ! -e $(enabled_file) && ! -e $FIX/sbctl/keys ]] || fail_test "a usage error changed the machine"
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
    "$ROOT_DIR/limine/90-omasecboot-sign" >"$hook" && chmod 755 "$hook"
  printf '#!/bin/bash\nprintf ran >>"%s/run/hook-ran"\nexit 1\n' "$FIX" >"$FIX/bin/omasecboot" && chmod 755 "$FIX/bin/omasecboot"
  "$hook" || fail_test "the dormant hook failed"
  [[ ! -e $FIX/run/hook-ran ]] || fail_test "the dormant hook ran the tool"
  : >"$FIX/state/enabled"
  "$hook" || fail_test "a failing tool made the hook fail its caller"
  [[ -e $FIX/run/hook-ran ]] || fail_test "the hook did not run the tool"
  rm "$FIX/bin/omasecboot"
  "$hook" 2>/dev/null || fail_test "a missing tool made the hook fail its caller"
}

# A full snapshot restore works on the boot files without the lock (C2), so
# nothing that rewrites them starts beside it.
setup_and_remove_wait_for_a_restore() {
  : >"$(restore_lock_path)"
  run_cli setup && fail_test "setup ran beside a snapshot restore"
  [[ $(<"$FIX/run/output") == *'snapshot restore is running'* ]] || fail_test "no reason: $(<"$FIX/run/output")"
  [[ ! -e $(enabled_file) && ! -e $(settings_originals_file) ]] || fail_test "a refused setup left state behind"
  ! grep -q '^limine-' "$FIX/run/calls" 2>/dev/null || fail_test "a refused setup ran a Limine tool: $(<"$FIX/run/calls")"
  rm "$(restore_lock_path)"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$(restore_lock_path)"
  : >"$FIX/run/calls"
  run_cli remove && fail_test "remove ran beside a snapshot restore"
  [[ $(<"$FIX/run/output") == *'snapshot restore is running'* ]] || fail_test "no reason: $(<"$FIX/run/output")"
  [[ -e $(enabled_file) && -e $(settings_originals_file) && ! -s $FIX/run/calls ]] || fail_test "a refused remove changed something: $(<"$FIX/run/calls")"
}

# remove that stops half way leaves a machine that reads as neither set up
# nor stock; the report says so instead of passing it as "not set up".
unfinished_remove_is_reported() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$FIX/run/limine-install-fails"
  run_cli remove && fail_test "a failed Limine tool went unnoticed"
  [[ ! -e $(enabled_file) && -e $(settings_originals_file) ]] || fail_test "the fixture is not a remove that stopped half way"
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
run_case unmounted-esp-and-unsafe-files-stop-the-commands unmounted_esp_and_unsafe_files_stop_the_commands
run_case earlier-values-are-the-users earlier_values_are_the_users
run_case fallback-is-offered-only-into-an-empty-place fallback_is_offered_only_into_an_empty_place
run_case failed-fallback-step-is-reported failed_fallback_step_is_reported
run_case remove-returns-to-stock remove_returns_to_stock
run_case failed-disable-is-said failed_disable_is_said
run_case busy-remove-changes-nothing busy_remove_changes_nothing
run_case refusals-say-why refusals_say_why
run_case remove-accepts-the-loader-upstream-kept remove_accepts_the_loader_upstream_kept
run_case remove-can-be-run-again remove_can_be_run_again
# With Secure Boot on, a loader signed with keys the firmware does not trust
# stops the machine, and the firmware step comes after the boot files (D10):
# setup refuses before it creates keys or writes anything.
secure_boot_on_needs_trusted_keys() {
  cp "$(primary_loader_path)" "$FIX/run/loader-before"
  set_mode_variable SecureBoot 1
  run_cli setup && fail_test "setup created keys with Secure Boot on"
  [[ $(<"$FIX/run/output") == *'has no signing keys'*'Turn Secure Boot off'* ]] || fail_test "no keys: $(<"$FIX/run/output")"
  [[ ! -e $FIX/sbctl/keys ]] || fail_test "keys were created"
  : >"$FIX/sbctl/keys"
  run_cli setup && fail_test "setup signed with keys the firmware does not hold"
  [[ $(<"$FIX/run/output") == *"db does not hold this machine's signing certificate"* ]] || fail_test "untrusted keys: $(<"$FIX/run/output")"
  : >"$FIX/run/sbctl-export-fails"
  run_cli setup && fail_test "setup went on without knowing which certificate is its own"
  [[ $(<"$FIX/run/output") == *'whether the firmware trusts these keys cannot be told'* ]] || fail_test "unreadable plan: $(<"$FIX/run/output")"
  rm "$FIX/run/sbctl-export-fails"
  cmp -s "$(primary_loader_path)" "$FIX/run/loader-before" || fail_test "the loader was replaced"
  [[ ! -e $(enabled_file) ]] || fail_test "the machine was marked set up"
}

# limine-mkinitcpio reports success after a failed build (C2). remove judges
# the entries against the settings it restored, keeps its record of the
# originals when they are not as stock has them, and finishes on a later run.
remove_keeps_its_record_after_a_masked_build_failure() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$FIX/run/uki-build-fails-silently"
  run_cli remove && fail_test "remove reported stock with the entries not rebuilt"
  [[ $(<"$FIX/run/output") == *'carry no path hashes although the restored settings ask for them'* ]] || fail_test "no reason: $(<"$FIX/run/output")"
  [[ -e $(settings_originals_file) ]] || fail_test "the originals were dropped on an unproved outcome"
  rm "$FIX/run/uki-build-fails-silently"
  run_cli remove || fail_test "the second remove failed: $(<"$FIX/run/output")"
  [[ ! -e $(settings_originals_file) ]] || fail_test "originals remain"
  grep -qE '^    path: boot\(\):/EFI/Linux/omarchy_linux\.efi#[0-9a-f]{128}$' "$FIX/esp/limine.conf" || fail_test "the entry carries no hash after the retry"
}

run_case silent-build-failure-stops-setup silent_build_failure_stops_setup
run_case hand-written-hash-stops-setup-with-the-way-out hand_written_hash_stops_setup_with_the_way_out
run_case setup-removes-harmful-sbctl-rows setup_removes_harmful_sbctl_rows
run_case busy-boot-files-exit-75 busy_boot_files_exit_75
run_case hook-pass-works-under-the-callers-lock hook_pass_works_under_the_callers_lock
run_case usage-errors-exit-2 usage_errors_exit_2
run_case status-quiet-prints-nothing status_quiet_prints_nothing
run_case hook-never-fails-its-caller hook_never_fails_its_caller
run_case setup-and-remove-wait-for-a-restore setup_and_remove_wait_for_a_restore
run_case unfinished-remove-is-reported unfinished_remove_is_reported
run_case watchers-pass-finishes-through-a-stop watchers_pass_finishes_through_a_stop
run_case secure-boot-on-needs-trusted-keys secure_boot_on_needs_trusted_keys
run_case remove-keeps-its-record-after-a-masked-build-failure remove_keeps_its_record_after_a_masked_build_failure
finish_suite
