#!/bin/bash
# The Limine contracts (docs/upstream-contracts.md C1 to C3) checked against
# the installed packages, because the hermetic suites only know stubs of them:
# upstream's own shell library and loader backup code run on fixture settings,
# hooks and an ESP in the sandbox of tests/lib/sandbox.sh, and the real
# "limine enroll-config" and sbctl build the loader this tool has to prove.
# What Limine does with that loader at boot belongs to hardware acceptance.
# shellcheck disable=SC2329 # Case functions are called through run_case.
# shellcheck disable=SC2154 # Upstream's library sets the variables it is asked for.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
SUITE_NAME=contract-limine
# shellcheck source=tests/lib/sandbox.sh
source "$ROOT_DIR/tests/lib/sandbox.sh" || exit 1

readonly UPSTREAM_LIBRARY=/usr/lib/limine/limine-common-functions
readonly UPSTREAM_INSTALLER=/usr/bin/limine-install

if ! in_sandbox; then
  require_command limine sbctl jq pacman
  require_file /usr/share/limine/BOOTX64.EFI limine
  require_file "$UPSTREAM_LIBRARY" limine-mkinitcpio-hook
  require_file "$UPSTREAM_INSTALLER" limine-mkinitcpio-hook
  enter_sandbox "${BASH_SOURCE[0]}"
fi

for module in common checks files firmware limine; do
  # shellcheck source=/dev/null
  source "$ROOT_DIR/lib/${module}.sh"
done
HOOK_NAME=$(basename "$ROOT_DIR"/limine/*)
readonly HOOK_NAME

# Upstream's library in the case's own subshell. It is not written for
# "set -u", and its callers do not use it either.
source_upstream() {
  set +u
  # shellcheck source=/dev/null
  source "$UPSTREAM_LIBRARY" || fail_test "upstream's library cannot be sourced"
}

# The paths upstream's tools work with, from upstream's own initialize_header.
# The sandbox's ESP is a directory and the machine-id is not under test.
upstream_header() {
  source_upstream
  check_boot_partition() { return 0; }
  get_machine_id() { return 0; }
  initialize_header >/dev/null || fail_test "upstream's initialize_header failed"
}

# limine-install's own function that deploys the primary loader and writes the
# backup beside it, taken from the installed script. Its version checks
# compare with a primary that is already there, so the cases deploy onto a
# fresh ESP.
source_upstream_deploy() { source_installer_function update_limine_efi; }

# source_installer_function NAME: one function of limine-install's own.
source_installer_function() {
  # shellcheck source=/dev/null
  source <(sed -n "/^$1() {\$/,/^}\$/p" "$UPSTREAM_INSTALLER")
  declare -F "$1" >/dev/null || fail_test "limine-install no longer defines $1 this way: recheck C2"
}

# The sandbox has no pacman.conf; the defaults find the package database.
shipped_files() { pacman --config /dev/null -Qlq limine-mkinitcpio-hook; }

fresh_esp() {
  rm -rf /boot/EFI /boot/limine.conf
  mkdir -p /boot/EFI/limine /boot/EFI/BOOT
  printf 'timeout: 5\n\n/Omarchy\n  protocol: efi\n' >/boot/limine.conf
}

# write_hook DIRECTORY NAME STATUS [MODE]: a hook that records that it ran.
write_hook() {
  local hook=/etc/boot/hooks/$1.d/$2
  mkdir -p "${hook%/*}"
  # shellcheck disable=SC2016 # The hook expands its own name when it runs.
  printf '#!/bin/bash\nprintf "%%s\\n" "${0##*/}" >>/tmp/hooks-run\nexit %s\n' "$3" >"$hook"
  chmod "${4:-755}" "$hook"
}

# The value upstream's load_config ends up with, from a shell of its own.
upstream_setting() (
  source_upstream
  unset "$1"
  load_config >/dev/null 2>&1 || exit 1
  printf '%s\n' "${!1}"
)

settings_are_read_as_upstream_reads_them() {
  local key expected
  local -A values=(
    [ESP_PATH]=/boot [LOWEST_ONLY]=lowest [OVERRIDDEN]=drop-in [TOOL_ONLY]='quoted value'
    [SPACED]='spaced value  ' [COMMENTED]='' [TRAILING]='value # kept' [TWICE]=second
    [UNTERMINATED]='no newline' [ENABLE_ENROLL_LIMINE_CONFIG]=''
  )
  mkdir -p /usr/share/limine-entry-tool.d /etc/limine-entry-tool.d
  printf 'ESP_PATH=/wrong\nLOWEST_ONLY=lowest\nOVERRIDDEN=lowest\n' >/usr/share/limine-entry-tool.d/10-contract.conf
  printf 'OVERRIDDEN=tool\nTOOL_ONLY="quoted value"\nENABLE_ENROLL_LIMINE_CONFIG=yes\n' >/etc/limine-entry-tool.conf
  printf '  SPACED  =  spaced value  \n# COMMENTED=yes\nOVERRIDDEN=drop-in\nENABLE_ENROLL_LIMINE_CONFIG=yes\n' >/etc/limine-entry-tool.d/20-contract.conf
  sandbox_settings $'TRAILING=value # kept\nTWICE=first\nTWICE=second\nUNTERMINATED="no newline'
  for key in "${!values[@]}"; do
    expected=${values[$key]}
    [[ $(upstream_setting "$key") == "$expected" ]] || fail_test "${key}: upstream reads '$(upstream_setting "$key")', C3 says '${expected}'"
    [[ $(effective_setting "$key") == "$expected" ]] || fail_test "${key}: this tool reads '$(effective_setting "$key")', upstream '${expected}'"
  done
  sandbox_settings $'ENABLE_ENROLL_LIMINE_CONFIG=yes\n'
  [[ $(upstream_setting ENABLE_ENROLL_LIMINE_CONFIG) == yes && $(effective_setting ENABLE_ENROLL_LIMINE_CONFIG) == yes ]] ||
    fail_test "the enrollment setting does not count in /etc/default/limine"
  rm -rf /usr/share/limine-entry-tool.d /etc/limine-entry-tool.d /etc/limine-entry-tool.conf
}

hooks_run_as_the_contract_says() {
  local status=0
  source_upstream
  rm -rf /etc/boot/hooks /tmp/hooks-run
  write_hook post 10-first 0
  write_hook post 20-warns 3
  write_hook post 30-switched-off.disabled 0
  write_hook post 40-not-executable 0 644
  write_hook post 50-last 0
  run_boot_hooks post 2>/dev/null || status=$?
  [[ $(</tmp/hooks-run) == $'10-first\n20-warns\n50-last' ]] || fail_test "ran: $(tr '\n' ' ' </tmp/hooks-run)"
  (( status == 0 )) || fail_test "a warning from an earlier hook became the caller's status ${status}"
  write_hook post 60-last-warns 7
  status=0
  run_boot_hooks post 2>/dev/null || status=$?
  (( status == 7 )) || fail_test "the last hook's status 7 reached the caller as ${status}"
  : >/tmp/hooks-run
  write_hook pre 10-aborts 100
  write_hook pre 20-never 0
  status=0
  run_boot_hooks pre 2>/dev/null || status=$?
  [[ $status == 100 && $(</tmp/hooks-run) == 10-aborts ]] || fail_test "status ${status}, ran: $(tr '\n' ' ' </tmp/hooks-run)"
}

# Upstream's post-hooks under the names the package ships them with, the
# disabled example switched on, and ours among them.
our_hook_runs_between_upstreams() {
  local name index
  local -a shipped ran
  source_upstream
  mapfile -t shipped < <(shipped_files | sed -n 's|^/etc/boot/hooks/post\.d/\(..*\)$|\1|p')
  [[ " ${shipped[*]} " == *' 90-limine-enroll-config '* && " ${shipped[*]} " == *' 91-example-esp-set-ro.disabled '* ]] ||
    fail_test "the package ships ${shipped[*]:-no post-hooks}: recheck C2"
  rm -rf /etc/boot/hooks /tmp/hooks-run
  for name in "${shipped[@]}"; do
    write_hook post "${name%.disabled}" 0
  done
  write_hook post "$HOOK_NAME" 0
  run_boot_hooks post || fail_test "run_boot_hooks"
  mapfile -t ran </tmp/hooks-run
  for index in "${!ran[@]}"; do
    [[ ${ran[$index]} != "$HOOK_NAME" ]] || break
  done
  [[ ${ran[$index]} == "$HOOK_NAME" && ${ran[$((index - 1))]} == 90-limine-enroll-config && ${ran[$((index + 1))]} == 91-example-esp-set-ro ]] ||
    fail_test "order: ${ran[*]}"
}

# What this tool asks of upstream by name. limine-install prints its usage and
# exits 0 on a flag it does not know, so a renamed flag would go unnoticed.
upstream_still_offers_what_this_tool_uses() {
  local clause
  grep -q -e '--no-efi-register' "$UPSTREAM_INSTALLER" || fail_test "limine-install no longer knows --no-efi-register: recheck C2"
  grep -q -e '--fallback' "$UPSTREAM_INSTALLER" || fail_test "limine-install no longer knows --fallback, which setup runs: recheck C2"
  # When the fallback is deployed (C2, C3): the setting, the flag, or an empty place.
  # shellcheck disable=SC2016 # The clauses are upstream's source text.
  for clause in '[[ "${ENABLE_LIMINE_FALLBACK:-}" == "yes" ]] ||' \
    '[[ "${SET_LIMINE_AS_FALLBACK:-}" == "yes" ]] ||' \
    '[[ ! -f "${BINARY_FALLBACK_PATH}" && -z "${ENABLE_LIMINE_FALLBACK:-}" ]]; then'; do
    grep -qF -- "$clause" "$UPSTREAM_INSTALLER" || fail_test "limine-install no longer decides the fallback by: ${clause} (recheck C2 and C3)"
  done
  shipped_files | grep -qx '/etc/boot/hooks/pre.d/10-limine-reset-enroll' ||
    fail_test "the package no longer ships pre.d/10-limine-reset-enroll, which puts the primary loader back before every operation: recheck C2"
  shipped_files | grep -qx '/usr/bin/limine-reset-enroll' || fail_test "the package no longer ships limine-reset-enroll: recheck C2"
}

lock_is_the_one_upstream_holds() {
  source_upstream
  [[ $BOOT_PARTITION_LOCK == "$(boot_lock_path)" ]] || fail_test "upstream locks ${BOOT_PARTITION_LOCK}"
  boot_lock_wait() { printf '1\n'; }
  mutex_lock contract || fail_test "upstream's mutex_lock"
  [[ /proc/self/fd/200 -ef $BOOT_PARTITION_LOCK ]] || fail_test "upstream no longer holds the lock on descriptor 200"
  # A hook inherits the descriptor of the tool that holds the lock.
  (boot_lock_acquire && [[ $_boot_lock == inherited ]]) || fail_test "the inherited lock was not recognised"
  # Anyone else finds the boot files busy, and free once upstream unlocks.
  (
    exec 200>&-
    boot_lock_acquire 2>/dev/null
    (( $? == 75 ))
  ) || fail_test "upstream's lock did not keep a second process out"
  mutex_unlock
  (exec 200>&- && boot_lock_acquire && [[ $_boot_lock == local ]]) || fail_test "the lock was not free after upstream's unlock"
}

loader_paths_and_backup_are_upstreams() {
  sandbox_settings
  fresh_esp
  upstream_header
  [[ $BINARY_SOURCE_PATH == "$(package_loader_path)" ]] || fail_test "upstream deploys ${BINARY_SOURCE_PATH}"
  [[ $BINARY_TARGET_PATH == "$(primary_loader_path)" ]] || fail_test "upstream's primary loader is ${BINARY_TARGET_PATH}"
  [[ $BINARY_BACKUP_PATH == "$(loader_backup_path)" ]] || fail_test "upstream's loader backup is ${BINARY_BACKUP_PATH}"
  [[ $BINARY_FALLBACK_PATH == "$(fallback_loader_path)" ]] || fail_test "upstream's fallback loader is ${BINARY_FALLBACK_PATH}"
  [[ $LIMINE_CONFIG_PATH == "$(limine_config_path)" ]] || fail_test "upstream's limine.conf is ${LIMINE_CONFIG_PATH}"
  source_upstream_deploy
  update_limine_efi >/dev/null || fail_test "upstream's update_limine_efi failed: recheck C2"
  [[ -f $(loader_backup_path) ]] || fail_test "upstream's deploy wrote no backup at $(loader_backup_path): recheck C2"
  cmp -s <(raw_loader) "$(package_loader_path)" || fail_test "raw_loader does not read what upstream's backup holds: recheck C2"
  # Upstream puts the primary back from that backup before every operation.
  printf 'altered' >>"$(primary_loader_path)"
  restore_limine_binary || fail_test "upstream's restore_limine_binary failed: recheck C2"
  cmp -s "$(primary_loader_path)" <(raw_loader) || fail_test "upstream restored something other than raw_loader reads"
}

# What the guard of add_fallback_loader rests on: upstream's fallback step
# deploys the package's raw loader, reads a file that is not Limine as
# version 0 and copies over it.
fallback_step_copies_over_whatever_is_there() {
  local name
  sandbox_settings
  fresh_esp
  upstream_header
  for name in check_limine_downgrade check_limine_upgrade update_limine_fallback; do
    source_installer_function "$name"
  done
  update_limine_fallback >/dev/null || fail_test "upstream's update_limine_fallback failed: recheck C2"
  cmp -s "$(fallback_loader_path)" "$(package_loader_path)" || fail_test "upstream's fallback is not the package's raw loader: recheck C2"
  printf 'another system' >"$(fallback_loader_path)"
  update_limine_fallback >/dev/null || fail_test "upstream's update_limine_fallback failed over a foreign file: recheck C2"
  cmp -s "$(fallback_loader_path)" "$(package_loader_path)" || fail_test "upstream did not copy over a loader that is not Limine's: it spares one now, or does not know the packaged Limine's major (recheck C2 and the guard of add_fallback_loader)"
}

# The pre-hook's command puts the primary back from the backup, and without
# one resets the checksum in place; it runs no hook of either kind (C2), which
# is why remove's reset comes last.
reset_enroll_runs_no_hook_and_restores_the_loader() {
  sandbox_settings
  fresh_esp
  upstream_header
  source_upstream_deploy
  update_limine_efi >/dev/null || fail_test "upstream's deploy failed: recheck C2"
  rm -rf /etc/boot/hooks /tmp/hooks-run
  write_hook pre 10-marker 0
  write_hook post 10-marker 0
  printf 'altered' >>"$(primary_loader_path)"
  reset_enroll_config >/dev/null 2>&1 || fail_test "upstream's reset_enroll_config failed: recheck C2"
  cmp -s "$(primary_loader_path)" <(raw_loader) || fail_test "the reset did not put upstream's copy back"
  [[ ! -e /tmp/hooks-run ]] || fail_test "the reset ran hooks: $(tr '\n' ' ' </tmp/hooks-run)"
  limine enroll-config "$(primary_loader_path)" "$(config_checksum)" >/dev/null 2>&1 || fail_test "limine enroll-config"
  rm "$(loader_backup_path)"
  reset_enroll_config >/dev/null 2>&1 || fail_test "upstream's reset without a backup failed: recheck C2"
  checksum_is_zero "$(embedded_checksum "$(primary_loader_path)")" || fail_test "without a backup the checksum was not reset in place"
}

# The real enroll-config refuses a file without the marker and a checksum
# that is not 128 hex digits, and changes nothing then (C1); the harness's
# stub refuses the same input.
enroll_config_refuses_bad_input() {
  local loader=/tmp/bad-input.efi checksum
  sandbox_settings
  fresh_esp
  checksum=$(config_checksum) || fail_test "config_checksum"
  printf 'no marker here' >"$loader"
  ! limine enroll-config "$loader" "$checksum" >/dev/null 2>&1 || fail_test "a file without the marker was enrolled"
  cp "$(package_loader_path)" "$loader" || fail_test "fixture loader"
  ! limine enroll-config "$loader" zz >/dev/null 2>&1 || fail_test "a checksum that is not 128 hex digits was enrolled"
  cmp -s "$loader" "$(package_loader_path)" || fail_test "a refused enrollment changed the file"
}

enrollment_is_read_back() {
  local loader=/tmp/enrollment.efi checksum
  sandbox_settings
  fresh_esp
  cp "$(package_loader_path)" "$loader" || fail_test "fixture loader"
  checksum=$(embedded_checksum "$loader") || fail_test "the package's loader does not carry exactly one marker with 128 hex digits behind it: recheck C1"
  checksum_is_zero "$checksum" || fail_test "the package's loader is not unenrolled"
  checksum=$(b2sum </boot/limine.conf)
  checksum=${checksum%% *}
  [[ $(config_checksum) == "$checksum" ]] || fail_test "config_checksum"
  limine enroll-config "$loader" "$checksum" >/dev/null 2>&1 || fail_test "limine enroll-config"
  [[ $(embedded_checksum "$loader") == "$checksum" ]] || fail_test "the enrolled checksum reads back as $(embedded_checksum "$loader")"
}

# The whole exchange of the two tools over one loader: upstream's hook work,
# this tool's proof of it, this tool's own rebuild after limine.conf changed,
# and upstream's next operation on top of that.
upstreams_enrollment_and_ours_prove_the_same_loader() {
  sandbox_settings $'ENABLE_ENROLL_LIMINE_CONFIG=yes\n'
  fresh_esp
  printf '\x06\x00\x00\x00\x01' >"$(firmware_variable_path SetupMode)"
  printf '\x06\x00\x00\x00\x00' >"$(firmware_variable_path SecureBoot)"
  run_sbctl create-keys >/dev/null 2>&1 || fail_test "create-keys"
  upstream_header
  source_upstream_deploy
  update_limine_efi >/dev/null || fail_test "upstream's update_limine_efi failed: recheck C2"
  is_sb_installed || fail_test "upstream does not see sbctl's keys, so it would not sign"
  enroll_config >/dev/null 2>&1 || fail_test "upstream's enroll_config"
  primary_is_proved || fail_test "the loader upstream enrolled and signed does not pass primary_is_proved"
  printf '  comment: changed\n' >>/boot/limine.conf
  primary_is_proved && fail_test "a changed limine.conf still passes the proof"
  ensure_primary_loader >/dev/null 2>&1 || fail_test "the real limine and sbctl did not build a loader that passes the proof"
  cmp -s <(raw_loader) "$(package_loader_path)" || fail_test "the rebuild touched upstream's backup"
  enroll_config >/dev/null 2>&1 || fail_test "upstream's enroll_config over this tool's loader"
  primary_is_proved || fail_test "upstream's next operation broke the proof"
}

run_case settings-are-read-as-upstream-reads-them settings_are_read_as_upstream_reads_them
run_case hooks-run-as-the-contract-says hooks_run_as_the_contract_says
run_case our-hook-runs-between-upstreams our_hook_runs_between_upstreams
run_case upstream-still-offers-what-this-tool-uses upstream_still_offers_what_this_tool_uses
run_case lock-is-the-one-upstream-holds lock_is_the_one_upstream_holds
run_case loader-paths-and-backup-are-upstreams loader_paths_and_backup_are_upstreams
run_case fallback-step-copies-over-whatever-is-there fallback_step_copies_over_whatever_is_there
run_case enrollment-is-read-back enrollment_is_read_back
run_case reset-enroll-runs-no-hook-and-restores-the-loader reset_enroll_runs_no_hook_and_restores_the_loader
run_case enroll-config-refuses-bad-input enroll_config_refuses_bad_input
run_case upstreams-enrollment-and-ours-prove-the-same-loader upstreams_enrollment_and_ours_prove_the_same_loader
finish_suite "$(limine --version | head -n 1), $(pacman --config /dev/null -Q limine-mkinitcpio-hook 2>/dev/null), sbctl $(sbctl version 2>/dev/null | head -n 1)"
