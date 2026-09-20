#!/bin/bash
# OmaSecBoot: the read-only report. It states what is true, counts what needs
# attention and ends with the one next step.

# "sign" repairs a problem unless it says otherwise: setup_problem marks what
# only setup repairs, blocking_problem what no command of this tool repairs,
# which includes everything that could not be read. The next step is chosen
# from the worst kind seen.
_status_problems=0 _status_next=sign _status_firmware=pending _status_sealed=true
problem() {
  fail "$@"
  _status_problems=$((_status_problems + 1))
}
setup_problem() {
  problem "$@"
  [[ $_status_next == blocked ]] || _status_next=setup
}
blocking_problem() {
  problem "$@"
  _status_next=blocked
}

enabled_marker() { printf '%s/enabled\n' "$(state_dir)"; }
is_set_up() { [[ -e $(enabled_marker) ]]; }

limine_hook_path() { printf '/etc/boot/hooks/post.d/90-omasecboot-sign\n'; }

# Where an earlier install that was copied into place without pacman put its
# files. Its hooks keep running the old tool, and its Limine hook fails the
# Limine tools once the old command is gone.
leftover_candidates() {
  printf '%s\n' /usr/local/bin/omasecboot /usr/local/lib/omasecboot \
    /etc/pacman.d/hooks/*omasecboot* /etc/boot/hooks/post.d/zzz-omasecboot-sign
}

list_leftovers() {
  local path
  while IFS= read -r path; do
    [[ ! -e $path && ! -L $path ]] || printf '%s\n' "$path"
  done < <(leftover_candidates)
}

# The menu entry that owns a limine.conf line: the nearest entry line above it.
entry_title_for_line() {
  awk -v target="$1" '
    NR > target { exit }
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line ~ /^\// { sub(/^\/+\+?/, "", line); title = line }
    END { print title }
  ' "$(limine_config_path)"
}

show_firmware_status() {
  local secure_boot setup_mode
  if ! secure_boot=$(read_mode_variable SecureBoot) || ! setup_mode=$(read_mode_variable SetupMode); then
    blocking_problem "Could not read the firmware's Secure Boot variables"
    return
  fi
  if [[ $secure_boot == 1 ]]; then
    pass "Secure Boot is on"
  else
    note "Secure Boot is off"
  fi
  [[ $setup_mode == 0 ]] || note "The firmware is in Setup Mode"
  # Without keys there is no certificate to look for; the files section says so.
  is_set_up && sbctl_keys_exist || return 0
  if ! read_enrollment_plan 2>/dev/null || ! local_certificates_are_identified; then
    blocking_problem "Could not tell from sbctl which certificates are yours, so the firmware's keys cannot be judged"
  elif firmware_is_enrolled; then
    pass "Your keys are enrolled in the firmware"
    _status_firmware=enrolled
    # SetupMode keeps reading 1 in the boot that wrote the PK (C6).
    [[ $setup_mode == 0 ]] || _status_firmware=reboot
    [[ $secure_boot == 0 ]] || _status_firmware=complete
  elif [[ $secure_boot == 1 ]]; then
    blocking_problem "Secure Boot is on, but the firmware does not hold your keys: it will refuse these boot files. Turn Secure Boot off, then run setup."
  else
    note "Your keys are not enrolled in the firmware yet"
  fi
}

show_settings_status() {
  local setting
  for setting in "${MANAGED_SETTINGS[@]}"; do
    if [[ $(effective_setting "${setting%%=*}") == "${setting#*=}" ]]; then
      pass "${setting} is in effect"
    else
      problem "${setting} is not in effect; check $(limine_default_config)"
    fi
  done
}

show_loader_status() {
  local shadow
  if primary_is_proved; then
    pass "The Limine loader is sealed with the current limine.conf and signed"
  else
    problem "The Limine loader is not sealed with the current limine.conf and signed"
    _status_sealed=false
  fi
  while IFS= read -r shadow; do
    [[ -z $shadow ]] || blocking_problem "A second limine.conf shadows the real one; remove it: ${shadow}"
  done < <(list_shadowing_configs)
  case $(fallback_state) in
    absent) note "No fallback loader: after a limine.conf mistake only rescue media can boot this machine" ;;
    raw) pass "The fallback loader is upstream's raw copy, the rescue loader when Secure Boot is off" ;;
    altered) problem "The fallback loader is signed or sealed; it must stay upstream's raw copy" ;;
    foreign) note "EFI/BOOT/BOOTX64.EFI is not Limine's and is left alone" ;;
  esac
}

show_files_status() {
  local files file state rows stale line old_snapshots=0 size largest=0 available
  if sbctl_keys_exist; then
    pass "sbctl's signing keys exist"
  else
    blocking_problem "sbctl has no signing keys, so nothing can be signed"
  fi
  files=$(list_signable_files) || {
    blocking_problem "Could not list the EFI files on the ESP"
    return
  }
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    state=0
    signature_state "$file" || state=$?
    case $state in
      0) pass "Signed: ${file}" ;;
      1) problem "Not signed: ${file}" ;;
      *) blocking_problem "sbctl could not tell whether this file is signed: ${file}" ;;
    esac
    size=$(stat -c %s -- "$file" 2>/dev/null) || size=0
    (( size <= largest )) || largest=$size
  done <<<"$files"
  # A kernel update writes a whole new image and upstream reports success when
  # that fails; an image that is rebuilt and signed again never deduplicates
  # against its predecessor in the snapshot history, so the ESP fills faster
  # than it did before setup (C2).
  if available=$(free_bytes "$(esp_path)" 2>/dev/null) && (( available < largest )); then
    note "The ESP has $((available / 1048576)) MiB free, less than its largest boot file needs ($(((largest + 1048575) / 1048576)) MiB): the next kernel update may not fit. Deleting old snapshots frees space."
  fi

  if rows=$(list_harmful_sbctl_rows); then
    while IFS= read -r file; do
      [[ -z $file ]] || setup_problem "sbctl would sign this file in place at the next update: ${file}"
    done <<<"$rows"
  else
    blocking_problem "Could not read sbctl's file list"
  fi

  if stale=$(list_stale_os_hashes); then
    while IFS= read -r line; do
      [[ -z $line ]] ||
        setup_problem "Stale path hash in limine.conf line ${line%%:*} (entry: $(entry_title_for_line "${line%%:*}"))"
    done <<<"$stale"
  else
    blocking_problem "Could not check the path hashes in limine.conf"
  fi

  while IFS= read -r file; do
    [[ -z $file ]] || signature_state "$file" || old_snapshots=$((old_snapshots + 1))
  done < <(list_history_files)
  (( old_snapshots == 0 )) ||
    note "${old_snapshots} snapshot image(s) predate Secure Boot setup and are unsigned: those entries boot only with Secure Boot off. They leave with snapshot rotation, or within seconds when those snapshots are deleted (${BOLD}sudo snapper -c root delete NUMBER${NC})"
}

# The Windows entry is in limine.conf exactly when it is enabled; the pass
# keeps that so and leaves everything it cannot settle to this report.
show_windows_status() {
  local status=0 state
  if [[ ! -e $(windows_flag) ]]; then
    case $(windows_entry_state '') in
      absent) ;;
      misplaced) blocking_problem "$WINDOWS_ENTRY_MISPLACED" ;;
      unknown) blocking_problem "Could not read $(limine_config_path)" ;;
      *) problem "limine.conf holds a Windows entry of this tool although the entry is not enabled" ;;
    esac
    return
  fi
  resolve_windows_target || status=$?
  if (( status == 2 )); then
    blocking_problem "The Windows entry is enabled, but the firmware's boot entries could not be read"
    return
  elif (( status != 0 )); then
    blocking_problem "The Windows entry is enabled, but the firmware has no single active Windows Boot Manager entry with a name of its own. Take the entry out with: sudo omasecboot windows remove"
    return
  fi
  state=$(windows_entry_state "$(windows_target_label)")
  case $state in
    current) pass "The Windows entry restarts the machine into $(windows_target_label)" ;;
    absent) problem "The Windows entry is missing from limine.conf" ;;
    stale) problem "The Windows entry in limine.conf is not the one for $(windows_target_label)" ;;
    misplaced) blocking_problem "$WINDOWS_ENTRY_MISPLACED" ;;
    unknown) blocking_problem "Could not read $(limine_config_path)" ;;
  esac
}

show_integration_status() {
  local hook
  hook=$(limine_hook_path)
  if [[ -x $hook ]]; then
    pass "The Limine hook is installed"
  else
    blocking_problem "The Limine hook is missing; reinstall the package: ${hook}"
  fi
  if watch_is_active; then
    pass "The watchers of limine.conf and the loader are active"
  else
    problem "The watchers of limine.conf and the loader are not both active"
  fi
}

# An earlier install's hooks keep running the old tool, set up or not, and
# setup refuses beside them; the report names them either way.
show_leftovers_status() {
  local leftover
  while IFS= read -r leftover; do
    [[ -z $leftover ]] || blocking_problem "Leftover of an earlier install; remove it: ${leftover}"
  done < <(list_leftovers)
}

show_next_step() {
  if ! is_set_up; then
    (( _status_problems > 0 )) || act "Next: ${BOLD}sudo omasecboot setup${NC}"
  elif (( _status_problems == 0 )); then
    case $_status_firmware in
      complete) act "Nothing to do" ;;
      reboot) act "Next: reboot, then run ${BOLD}sudo omasecboot setup${NC} once more" ;;
      enrolled) act "Next: turn Secure Boot on in the firmware, or run ${BOLD}sudo omasecboot setup${NC} for the steps" ;;
      pending) act "Next: ${BOLD}sudo omasecboot setup${NC} for the firmware step" ;;
    esac
  else
    case $_status_next in
      sign) act "Next: ${BOLD}sudo omasecboot sign${NC}" ;;
      setup) act "Next: ${BOLD}sudo omasecboot setup${NC}" ;;
      blocked) act "Next: resolve what is marked above, then run ${BOLD}sudo omasecboot setup${NC}" ;;
    esac
    if [[ $_status_sealed == true ]]; then
      act "Do not reboot with Secure Boot on until this report is clean"
    else
      # A loader that is not sealed over limine.conf does not start at all (C1).
      act "Do not reboot, with Secure Boot on or off, until the loader is sealed again"
    fi
  fi
}

# Exit 0 when nothing needs attention, 1 otherwise.
show_status() {
  local marker
  _status_problems=0 _status_next=sign _status_firmware=pending _status_sealed=true
  header "Status"
  show_firmware_status
  if ! is_set_up; then
    # setup records the settings' originals before it writes "enabled", and
    # remove deletes "enabled" first and the originals last. Originals without
    # "enabled" are one of the two stopped half way, and either finishes it.
    if [[ -e $(settings_originals_file) ]]; then
      problem "An earlier setup or remove did not finish. Run ${BOLD}sudo omasecboot remove${NC} to return to stock, or ${BOLD}sudo omasecboot setup${NC} to set up again"
    else
      note "OmaSecBoot is not set up on this machine"
    fi
    show_leftovers_status
  elif ! esp_is_mounted_vfat; then
    blocking_problem "The EFI system partition is not mounted; mount it and run this again"
  else
    show_settings_status
    show_loader_status
    show_files_status
    show_windows_status
    show_integration_status
    show_leftovers_status
    marker=$(attention_marker)
    [[ ! -e $marker ]] || problem "An earlier pass could not finish: $(<"$marker")"
  fi
  show_next_step
  (( _status_problems == 0 ))
}
