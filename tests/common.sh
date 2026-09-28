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

# One dated line per kind; a kind is replaced, cleared alone, or all at once.
needs_attention_round_trip() {
  local first
  set_attention "$ATTENTION_PASS" || fail_test "set"
  [[ $(<"$(attention_file)") == "sign could not finish on "* ]] || fail_test "content: $(<"$(attention_file)")"
  { set_attention "$ATTENTION_SEAL" && set_attention "$ATTENTION_SEAL"; } || fail_test "set a second kind"
  [[ $(grep -c . "$(attention_file)") == 2 ]] || fail_test "kinds: $(<"$(attention_file)")"
  clear_attention "$ATTENTION_SEAL"
  [[ $(<"$(attention_file)") == "sign could not finish on "* && $(grep -c . "$(attention_file)") == 1 ]] || fail_test "clear one kind: $(<"$(attention_file)")"
  clear_attention "$ATTENTION_PASS"
  [[ ! -e $(attention_file) ]] || fail_test "clearing the last kind left the file"
  # An incident carries an ID, a new one for every failure.
  set_attention "$ATTENTION_SYNC" || fail_test "set an incident"
  first=$(esp_incident)
  [[ $first =~ ^[0-9a-f]{12}\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || fail_test "incident: ${first}"
  set_attention "$ATTENTION_SYNC"
  [[ $(esp_incident) != "${first%% *} "* && $(grep -c . "$(attention_file)") == 1 ]] || fail_test "a second failure: $(<"$(attention_file)")"
  clear_attention "$ATTENTION_SYNC"
  [[ ! -e $(attention_file) ]] || fail_test "clear"
  # esp_incident reads no other form, so an ID that is not one is refused.
  ( new_incident_id() { printf 'x\n'; }; ! set_attention "$ATTENTION_SYNC" ) || fail_test "an incident without an ID was recorded"
  [[ ! -e $(attention_file) ]] || fail_test "a refused incident left: $(<"$(attention_file)")"
  # A last line without its newline, as a hand edit leaves it, is a line.
  printf '%s on a day\n%s on a day' "$ATTENTION_PASS" "$ATTENTION_SEAL" >"$(attention_file)"
  clear_attention "$ATTENTION_PASS"
  [[ $(<"$(attention_file)") == "${ATTENTION_SEAL} on a day" ]] || fail_test "the last line was lost: $(cat "$(attention_file)" 2>&1)"
  # In a state directory others can write, nothing is rewritten.
  chmod o+w "$FIX/state"
  ! clear_attention "$ATTENTION_SEAL" 2>/dev/null || fail_test "rewritten in an unsafe state directory"
  [[ -e $(attention_file) ]] || fail_test "cleared in an unsafe state directory"
  chmod o-w "$FIX/state"
}

# What cannot be read, or holds an incident in a form set_attention does not
# write, is never taken for no incident, and no rewrite drops the lines it
# could not read (7.3).
unreadable_attention_is_no_absence() {
  local before line output bytes
  [[ -z $(esp_incident) ]] || fail_test "an incident without a file"
  printf '%s on a day\n%s on a day, incident 0123456789ab\n' "$ATTENTION_PASS" "$ATTENTION_SYNC" >"$(attention_file)"
  [[ $(esp_incident) == '0123456789ab a day' ]] || fail_test "a valid incident: $(esp_incident)"
  # Any line set_attention does not write, a second incident included.
  for line in "${ATTENTION_SYNC} on a day" "${ATTENTION_SYNC} on a day, incident 0123" "${ATTENTION_SYNC}" \
    " ${ATTENTION_SYNC} on a day, incident 0123456789ab" "${ATTENTION_SYNC^} on a day, incident 0123456789ab" "${ATTENTION_PASS}" 'anything' \
    "${ATTENTION_SEAL}" "${ATTENTION_PASS} on a day, more" "${ATTENTION_SEAL} on " \
    $'the ESP reported a write error on a day, incident 0123456789ab\nthe ESP reported a write error on a day, incident ba9876543210'; do
    printf '%s\n' "$line" >"$(attention_file)"
    ! esp_incident >/dev/null || fail_test "taken for an incident or none: ${line}"
    [[ $(esp_incident_or_unknown) == unknown ]] || fail_test "not unknown: ${line}"
  done
  rm "$(attention_file)"
  ln -s "$FIX/nowhere" "$(attention_file)"
  [[ $(esp_incident_or_unknown 2>/dev/null) == unknown ]] || fail_test "a dangling link was taken for no record"
  ! clear_attention "$ATTENTION_PASS" 2>/dev/null || fail_test "a dangling link was cleared as no record"
  rm "$(attention_file)"
  # A write error recorded beside a line the tool does not write is said as
  # recorded, and the kind's own damaged line is no finding of a pass.
  printf 'anything\n' >"$(attention_file)"
  output=$(
    sync_path() { [[ $1 == "$FIX/state" || $1 == "$FIX/state/."* ]]; }
    durable_sync "$FIX/esp" 2>&1
  ) && fail_test "a failed sync passed"
  [[ $output == *'recorded in'*'beside a line OmaSecBoot does not write'* ]] || fail_test "recorded beside a foreign line: ${output}"
  # A rejected line survives every rewrite, also of its own kind, and is no
  # finding of a pass.
  for line in "$ATTENTION_PASS" "$ATTENTION_SEAL" "$ATTENTION_SYNC" "${ATTENTION_PASS} on a day, more"; do
    printf '%s\n' "$line" >"$(attention_file)"
    if ! { clear_attention "$ATTENTION_PASS" && clear_attention "$ATTENTION_SEAL" && clear_attention "$ATTENTION_SYNC" && set_attention "$ATTENTION_SEAL"; }; then
      fail_test "${line}: a rewrite failed"
    fi
    grep -qxF -- "$line" "$(attention_file)" || fail_test "${line}: dropped by a rewrite"
    [[ $(pass_findings) == "${ATTENTION_SEAL} on "* ]] || fail_test "${line}: listed as a finding: $(pass_findings)"
  done
  # Bytes set_attention never writes, a NUL among them, which Bash would drop.
  for bytes in '\0\0\0\0\n' '\t\n' '\xc3\xa9\n'; do
    printf '%b' "$bytes" >"$(attention_file)"
    cp "$(attention_file)" "$FIX/run/record"
    [[ $(esp_incident_or_unknown) == unknown ]] || fail_test "${bytes}: not unknown"
    ! clear_attention "$ATTENTION_PASS" || fail_test "${bytes}: rewritten"
    cmp -s "$(attention_file)" "$FIX/run/record" || fail_test "${bytes}: the record changed"
  done
  rm "$(attention_file)"
  printf '%s on a day\n%s on a day, incident 0123456789ab\n' "$ATTENTION_PASS" "$ATTENTION_SYNC" >"$(attention_file)"
  before=$(<"$(attention_file)")
  chmod 000 "$(attention_file)"
  ! esp_incident >/dev/null 2>&1 || fail_test "an unreadable record was taken for an answer"
  ! set_attention "$ATTENTION_SEAL" 2>/dev/null || fail_test "a finding was written over lines that could not be read"
  ! clear_attention "$ATTENTION_PASS" 2>/dev/null || fail_test "a finding was cleared from lines that could not be read"
  chmod 644 "$(attention_file)"
  [[ $(<"$(attention_file)") == "$before" ]] || fail_test "the record changed: $(<"$(attention_file)")"
}

# A failed sync records an ESP incident, and says it, only for a path on the
# ESP: the state directory and the firmware backup are elsewhere (C2).
only_the_esp_records_an_incident() {
  local path output
  # Every sync fails but those that write the incident into the state directory.
  sync_path() { [[ $1 == "$FIX/state" || $1 == "$FIX/state/."* ]]; }
  mkdir -p "$FIX/esp-other" "$FIX/esp/EFI" "$FIX/state/backup"
  # A path that is gone fails the sync without a writeback error.
  for path in "$FIX/state/backup" "$FIX/esp-other" "$FIX/esp/../esp-other" "$FIX/esp/gone"; do
    ! durable_sync "$path" 2>/dev/null || fail_test "${path}: a failed sync passed"
    # shellcheck disable=SC2154 # _esp_sync_failed belongs to lib/common.sh.
    [[ -z $(esp_incident) && $_esp_sync_failed == false ]] || fail_test "${path}: recorded as the ESP's"
  done
  output=$(durable_sync "$FIX/esp/EFI" 2>&1) && fail_test "a failed sync of the ESP passed"
  [[ -n $(esp_incident) && $output == *"The ESP reported a write error at ${FIX}/esp/EFI (incident $(esp_incident | cut -d' ' -f1))"* ]] || fail_test "the ESP's failure was not recorded and said: ${output}"
  durable_sync "$FIX/esp/EFI" 2>/dev/null
  [[ $_esp_sync_failed == true ]] || fail_test "the ESP's failure did not mark the command"
  sync_path() { :; }
}

# Who can write the ESP is the mount's to say (C2), in the kernel's own format:
# uid only when it is not root, fmask and dmask always. Root alone may write,
# whatever the group; an idmapped mount of the same device, a mount without
# masks and a mount that cannot be read fail the rule too.
esp_mount_rule_follows_the_kernels_options() {
  local tail=',codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro' options unsafe
  for options in "rw,relatime,fmask=0022,dmask=0022${tail}" "rw,relatime,fmask=0077,dmask=0077${tail}"; do
    printf '259:1 %s %s\n' "$FIX/esp" "$options" >"$FIX/run/mounts"
    esp_mount_is_safe >/dev/null || fail_test "a mount only root can write was refused: ${options}"
  done
  for options in "rw,relatime,uid=1000,fmask=0077,dmask=0077${tail}" "rw,relatime,fmask=0002,dmask=0022${tail}" \
    "rw,relatime,fmask=0020,dmask=0022${tail}" "rw,relatime,fmask=0022,dmask=0000${tail}"; do
    printf '259:1 %s %s\n' "$FIX/esp" "$options" >"$FIX/run/mounts"
    unsafe=$(esp_mount_is_safe) && fail_test "a mount others can write passed: ${options}"
    [[ $unsafe == "users other than root can write to it through $FIX/esp (${options})" ]] || fail_test "the mount named: ${unsafe}"
  done
  printf '259:1 %s rw,relatime%s\n' "$FIX/esp" "$tail" >"$FIX/run/mounts"
  unsafe=$(esp_mount_is_safe) && fail_test "a mount without masks passed"
  [[ $unsafe == "its mount at $FIX/esp shows no fmask and dmask (rw,relatime${tail})" ]] || fail_test "no masks: ${unsafe}"
  # Another device's loose mount is no concern of the ESP's; an idmapped mount
  # of the ESP's own device is.
  printf '259:1 %s rw,fmask=0077,dmask=0077%s\n259:9 /mnt/usb rw,uid=1000,fmask=0000,dmask=0000%s\n' "$FIX/esp" "$tail" "$tail" >"$FIX/run/mounts"
  esp_mount_is_safe >/dev/null || fail_test "another device's mount was counted"
  printf '259:1 /mnt/esp rw,relatime,idmapped,fmask=0077,dmask=0077%s\n' "$tail" >>"$FIX/run/mounts"
  unsafe=$(esp_mount_is_safe) && fail_test "an idmapped mount passed"
  [[ $unsafe == 'users other than root can write to it through /mnt/esp ('* ]] || fail_test "the idmapped mount was not named: ${unsafe}"
  rm "$FIX/run/mounts"
  unsafe=$(esp_mount_is_safe) && fail_test "a mount that could not be read passed"
  [[ $unsafe == "its mount at $FIX/esp could not be read" ]] || fail_test "unreadable: ${unsafe}"
  # The table cannot be listed although the ESP's mount is found: no answer.
  printf '259:1 %s rw,fmask=0077,dmask=0077%s\n' "$FIX/esp" "$tail" >"$FIX/run/mounts"
  : >"$FIX/run/findmnt-list-fails"
  ! esp_mount_is_safe >/dev/null || fail_test "a mount table that could not be listed passed"
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
# taken on a file that was replaced meanwhile serialises nothing.
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
run_case only-the-esp-records-an-incident only_the_esp_records_an_incident
run_case unreadable-attention-is-no-absence unreadable_attention_is_no_absence
run_case file-safety-refuses-what-others-can-change file_safety_refuses_what_others_can_change
run_case esp-mount-rule-follows-the-kernels-options esp_mount_rule_follows_the_kernels_options
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
