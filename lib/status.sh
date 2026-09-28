#!/bin/bash
# OmaSecBoot: the read-only report. It states what is true, counts what needs
# attention and ends with the one next step.

# Every problem needs attention: the report exits 1. Each also says what a
# restart risks now, by the failure tables of the spec (section 7): none, on
# (Secure Boot on refuses what would start) or both (the machine does not start
# with Secure Boot on or off); what could not be read risks what it would
# have shown. And "sign" repairs it unless it says otherwise: setup_problem
# marks what only setup repairs, blocking_problem what neither sign nor setup
# repairs, which includes everything that could not be read; its line says
# what does. The next step follows the worst repair seen, the warning against
# a restart the worst risk.
_status_problems=0 _status_next=sign _status_firmware=pending _status_risk=none
problem() {
  local risk=$1
  shift
  fail "$@"
  _status_problems=$((_status_problems + 1))
  case $risk in
    both) _status_risk=both ;;
    on) [[ $_status_risk == both ]] || _status_risk=on ;;
  esac
}
setup_problem() {
  problem "$@"
  [[ $_status_next == blocked ]] || _status_next=setup
}
blocking_problem() {
  problem "$@"
  _status_next=blocked
}

enabled_file() { printf '%s/enabled\n' "$(state_dir)"; }
is_set_up() { [[ -e $(enabled_file) ]]; }

limine_hook_path() { printf '/etc/boot/hooks/post.d/90-omasecboot-sign\n'; }

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
    blocking_problem on "$(mode_variables_problem)"
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
    blocking_problem on "Could not tell from sbctl which certificates are yours, so the firmware's keys cannot be judged; look at the keys with ${BOLD}sudo sbctl status${NC}"
  elif firmware_is_enrolled; then
    pass "Your keys are enrolled in the firmware"
    _status_firmware=enrolled
    # SetupMode keeps reading 1 in the boot that wrote the PK (C10).
    [[ $setup_mode == 0 ]] || _status_firmware=reboot
    [[ $secure_boot == 0 ]] || _status_firmware=complete
  elif [[ $secure_boot == 1 ]]; then
    remind_of_windows_encryption off
    blocking_problem on "Secure Boot is on, but the firmware does not hold your keys: it will refuse these boot files. Turn Secure Boot off, then run ${BOLD}sudo omasecboot setup${NC}"
  else
    note "Your keys are not enrolled in the firmware yet"
  fi
}

# After remove sbctl's keys stay, and upstream signs the loader at every
# Limine operation without sealing it (C2). While the firmware trusts the key,
# Secure Boot on would start that loader without a check of limine.conf.
show_unsealed_signed_loader() {
  local primary secure_boot
  primary=$(primary_loader_path)
  sbctl_keys_exist && [[ -f $primary && $(limine_seal "$primary") == unsealed ]] && signature_state "$primary" || return 0
  if ! read_enrollment_plan 2>/dev/null; then
    warn "The Limine loader carries your signature and no seal, and whether the firmware trusts your key could not be read: if it does, keep Secure Boot off, or restore the factory keys in the firmware's key menu"
    return 0
  fi
  variable_holds_local_certificate db || return 0
  if ! secure_boot=$(read_mode_variable SecureBoot 2>/dev/null); then
    blocking_problem none "The Limine loader carries your signature and no seal, the firmware trusts your key, and whether Secure Boot is on could not be read: with it on, the loader starts without checking limine.conf"
  elif [[ $secure_boot == 0 ]]; then
    warn "The Limine loader carries your signature and no seal, and the firmware trusts your key: with Secure Boot on it would start without checking limine.conf. Keep Secure Boot off, or restore the factory keys in the firmware's key menu"
  else
    # Factory keys with Secure Boot on would refuse the loader signed here.
    remind_of_windows_encryption off
    blocking_problem none "Secure Boot is on, and the Limine loader carries your signature and no seal: it starts without checking limine.conf. Turn Secure Boot off, then restore the factory keys in the firmware's key menu, or run ${BOLD}sudo omasecboot setup${NC}"
  fi
}

# Names, one per line, as a sentence carries them: "A", "A or B", "A, B or C".
join_or() {
  awk 'NR > 1 { list = list (NR > 2 ? ", " : "") previous } { previous = $0 } END { print (NR > 1 ? list " or " previous : previous) }'
}

# Microsoft's 2023 certificates (C9). Notes: this machine's boot chain does
# not depend on them, what Microsoft can still deliver to it does.
show_microsoft_2023_status() {
  local name missing
  for name in KEK db; do
    if ! missing=$(missing_microsoft_2023 "$name"); then
      blocking_problem none "The firmware's ${name} variable cannot be read as a signature list; look at the firmware's keys with ${BOLD}sudo sbctl status${NC}"
      continue
    fi
    [[ -n $missing ]] || continue
    missing=$(join_or <<<"$missing")
    case $name in
      KEK) note "KEK does not hold ${missing}, which signs Microsoft's db and dbx updates from 2026 on: they cannot reach this machine" ;;
      db) note "db does not hold ${missing}: Microsoft's db updates deliver what is missing, and those need Microsoft's 2023 certificate in KEK" ;;
    esac
  done
}

show_settings_status() {
  local setting
  for setting in "${MANAGED_SETTINGS[@]}"; do
    if [[ $(effective_setting "${setting%%=*}") == "${setting#*=}" ]]; then
      pass "${setting} is in effect"
    else
      problem none "${setting} is not in effect; check $(limine_default_config)"
    fi
  done
}

show_loader_status() {
  local shadow content scanned=0 risk=both
  # Limine cannot start Omarchy from a limine.conf it cannot find or that
  # holds no menu entry besides this tool's, as Omarchy's template until
  # limine-update fills it (C1, C6), whatever the seal and the signatures say.
  # The scan's status 1, this tool's comment misplaced, still reads the rest.
  content=$(scan_windows_entries without 2>/dev/null) || scanned=$?
  if (( scanned > 1 )); then
    blocking_problem both "Could not read $(limine_config_path), which Limine starts from; look at the ESP"
  elif lacks_menu_entries "$content"; then
    blocking_problem both "limine.conf holds no menu entries besides OmaSecBoot's own, so Limine cannot start Omarchy: run ${BOLD}sudo limine-update${NC}"
  fi
  # The loader's signature is judged with the other files below, which says
  # what Secure Boot on would refuse; only a seal over another limine.conf
  # stops it with Secure Boot off as well (C1, section 7.1).
  if primary_is_proved; then
    pass "The Limine loader is sealed over the current limine.conf and signed"
  elif primary_is_sealed; then
    problem none "The Limine loader is sealed over the current limine.conf but not signed"
  elif [[ $(limine_seal "$(primary_loader_path)") == unsealed ]]; then
    problem none "The Limine loader is not sealed over the current limine.conf"
  else
    problem both "The Limine loader is not sealed over the current limine.conf"
  fi
  while IFS= read -r shadow; do
    [[ -z $shadow ]] || blocking_problem both "A second limine.conf shadows the real one; remove it: ${shadow}"
  done < <(list_shadowing_configs)
  # Without an entry for the primary loader the firmware takes the fallback
  # path, which starts Omarchy with Secure Boot off only while it holds the
  # raw loader (D6).
  [[ $(fallback_state) != raw ]] || risk=on
  case $(firmware_starts_primary; printf '%s' "$?") in
    0) ;;
    1)
      if [[ $risk == on ]]; then
        blocking_problem on "The firmware has no active boot entry for the Limine loader, so this machine starts through the fallback path, which the firmware refuses with Secure Boot on. Run ${BOLD}sudo limine-install${NC} and check with ${BOLD}efibootmgr${NC} before a restart with Secure Boot on"
      else
        blocking_problem both "The firmware has no active boot entry for the Limine loader, and the fallback path holds no raw Limine loader to start instead. Run ${BOLD}sudo limine-install${NC} and check with ${BOLD}efibootmgr${NC} before a restart"
      fi
      ;;
    *) blocking_problem "$risk" "Could not read the firmware's boot entries, so nothing shows that the firmware starts the Limine loader; check with ${BOLD}efibootmgr${NC}" ;;
  esac
  case $(fallback_state) in
    absent) note "No fallback loader: after a limine.conf mistake only rescue media can boot this machine; ${BOLD}sudo omasecboot setup${NC} offers to add one" ;;
    raw)
      # The bytes prove upstream's copy; sbctl can only say that no seal and no
      # signature by the current key are there (D6).
      if cmp -s -- "$(package_loader_path)" "$(fallback_loader_path)" || raw_loader 2>/dev/null | cmp -s -- - "$(fallback_loader_path)"; then
        pass "The fallback loader is upstream's raw copy, the rescue loader when Secure Boot is off"
      else
        note "The fallback loader carries no seal and no signature by the current key, as far as sbctl can tell; it is not byte for byte upstream's copy"
      fi
      # Upstream refreshes it only where its settings say so (C3), and never
      # on a machine that Omarchy installed beside another system (C6). While
      # upstream holds a Limine major back, its step would refresh nothing (C2).
      if raw_loader 2>/dev/null | cmp -s -- - "$(package_loader_path)" &&
        ! cmp -s -- "$(package_loader_path)" "$(fallback_loader_path)"; then
        note "The fallback loader is another Limine build than the primary loader; ${BOLD}sudo limine-install --fallback${NC} refreshes it"
      fi
      ;;
    altered) problem none "The fallback loader is signed or sealed; it must stay upstream's raw copy" ;;
    foreign) note "EFI/BOOT/BOOTX64.EFI is not a Limine loader and is left alone: after a limine.conf mistake only rescue media can boot this machine" ;;
  esac
}

# The signing keys, every signable file, and room on the ESP for the next one.
# Status 1 when the ESP cannot be listed: what follows reads the same files.
show_signable_files_status() {
  local files file state size largest=0 available primary seal
  if sbctl_keys_exist; then
    pass "sbctl's signing keys exist"
  else
    blocking_problem none "sbctl has no signing keys, so nothing can be signed; restore them from a snapshot or a backup"
  fi
  files=$(list_signable_files) || {
    blocking_problem on "Could not list the EFI files on the ESP; look at the ESP"
    return 1
  }
  primary=$(primary_loader_path)
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    state=0
    signature_state "$file" || state=$?
    # A Limine executable that is not sealed is never signed (D4); the
    # primary's seal has a proof of its own above.
    seal=none
    [[ ${file,,} == "${primary,,}" ]] || seal=$(limine_seal "$file") || seal=unreadable
    case $state:${seal%% *} in
      0:unsealed) blocking_problem none "A Limine loader that is not sealed carries your signature: ${file}. With Secure Boot on it starts and reads whatever limine.conf it finds without checking it; delete it if nothing starts from it, or seal it over its own limine.conf with its system's tools" ;;
      0:unsupported) blocking_problem none "A file with Limine's marker whose checksum slot does not tell whether it checks limine.conf carries your signature: ${file}. Delete it if nothing starts from it" ;;
      [01]:unreadable) blocking_problem on "Could not read ${file} to tell whether it is a Limine loader that is not sealed; check the ESP" ;;
      0:*) pass "Signed: ${file}" ;;
      1:unsealed) note "Left unsigned: ${file} is a Limine loader that is not sealed, which the firmware refuses with Secure Boot on. Delete it if nothing starts from it, or seal it over its own limine.conf with its system's tools, and the next pass signs it" ;;
      1:unsupported) blocking_problem on "Not signed: ${file} carries Limine's marker, and its checksum slot does not tell whether it checks limine.conf. Delete it if nothing starts from it" ;;
      1:*) problem on "Not signed: ${file}" ;;
      *) blocking_problem on "sbctl could not tell whether this file is signed: ${file}; check it with ${BOLD}sudo sbctl verify${NC}" ;;
    esac
    size=$(stat -c %s -- "$file" 2>/dev/null) || size=0
    (( size <= largest )) || largest=$size
  done <<<"$files"
  # A kernel update writes a whole new image and upstream reports success when
  # that fails; an image that is rebuilt and signed again never deduplicates
  # against its predecessor in the snapshot history, so the ESP fills faster
  # than it did before setup (C2).
  if available=$(free_bytes "$(esp_path)" 2>/dev/null) && (( available < largest )); then
    note "The ESP has $((available / 1048576)) MiB free, less than its largest boot file needs ($(((largest + 1048575) / 1048576)) MiB): the next kernel update may not fit. Deleting old snapshots frees space"
  fi
}

# Rows that would make sbctl sign a history file, the fallback or a Limine
# executable in place (D7).
show_sbctl_rows_status() {
  local rows file
  if rows=$(list_harmful_sbctl_rows); then
    while IFS= read -r file; do
      [[ -z $file ]] || setup_problem none "sbctl would sign this file in place at the next update: ${file}"
    done <<<"$rows"
  else
    blocking_problem none "Could not read sbctl's file list; check it with ${BOLD}sudo sbctl list-files${NC}"
  fi
}

# Path hashes of OS entries that no longer match, and the snapshot images
# from before setup, which are upstream's and stay unsigned (D5).
show_path_hash_status() {
  local stale kind line file missing old_snapshots=0 unread_snapshots=0
  if stale=$(list_stale_os_hashes); then
    while IFS=$'\t' read -r kind line; do
      [[ -n $line ]] || continue
      if [[ $kind == unchecked ]]; then
        note "Path hash in limine.conf line ${line%%:*} (entry: $(entry_title_for_line "${line%%:*}")) cannot be checked: the path is not under boot():/, so only the firmware can tell which volume it names"
      else
        setup_problem on "Stale path hash in limine.conf line ${line%%:*} (entry: $(entry_title_for_line "${line%%:*}"))"
      fi
    done <<<"$stale"
  else
    blocking_problem on "Could not check the path hashes in limine.conf; look at its entries"
  fi

  # A file an OS entry names and the ESP lacks stops that entry with Secure
  # Boot on or off, and neither sign nor setup builds it. A limine.conf
  # that cannot be read is said by the loader's section.
  if missing=$(list_missing_os_files 2>/dev/null); then
    while IFS= read -r line; do
      [[ -z $line ]] || blocking_problem both "limine.conf line ${line%%:*} (entry: $(entry_title_for_line "${line%%:*}")) names a file the ESP does not hold: ${line#*: }. Run ${BOLD}sudo limine-update${NC}, which builds it again"
    done <<<"$missing"
  fi

  while IFS= read -r file; do
    [[ -n $file ]] || continue
    signature_state "$file" || case $? in
      1) old_snapshots=$((old_snapshots + 1)) ;;
      *) unread_snapshots=$((unread_snapshots + 1)) ;;
    esac
  done < <(list_history_files)
  (( unread_snapshots == 0 )) || note "${unread_snapshots} snapshot image(s) could not be checked for a signature"
  (( old_snapshots == 0 )) ||
    note "${old_snapshots} snapshot image(s) predate Secure Boot setup and are unsigned: those entries boot only with Secure Boot off. They leave with snapshot rotation, or within seconds when those snapshots are deleted (${BOLD}sudo snapper -c root delete NUMBER${NC})"
}

show_files_status() {
  show_signable_files_status || return 0
  show_sbctl_rows_status
  show_path_hash_status
}

# The Windows entry is in limine.conf exactly when it is enabled; the pass
# keeps that so and leaves everything it cannot settle to this report.
show_windows_status() {
  local status=0 state
  if [[ ! -e $(windows_flag) ]]; then
    case $(windows_entry_state '') in
      absent) ;;
      misplaced) blocking_problem none "$WINDOWS_ENTRY_MISPLACED" ;;
      # The loader's section says that limine.conf could not be read.
      unknown) ;;
      *) problem none "limine.conf holds a Windows entry of OmaSecBoot's although the entry is not enabled" ;;
    esac
    return
  fi
  resolve_windows_target || status=$?
  if (( status == 2 )); then
    blocking_problem none "The Windows entry is enabled, but the firmware's boot entries could not be read; check with ${BOLD}efibootmgr${NC}"
    return
  elif (( status == 3 )); then
    blocking_problem none "The Windows entry is enabled, but ${WINDOWS_TARGET_NAME}. Take the entry out with ${BOLD}sudo omasecboot windows remove${NC}; the firmware's boot menu still starts Windows"
    return
  elif (( status != 0 )); then
    blocking_problem none "The Windows entry is enabled, but the firmware does not hold exactly one active Windows Boot Manager entry that BootOrder lists and whose name no other entry shares. Take the entry out with ${BOLD}sudo omasecboot windows remove${NC}, or leave the firmware one such entry (${BOLD}efibootmgr${NC} shows them)"
    return
  fi
  state=$(windows_entry_state "$(windows_target_label)")
  # The pass writes nothing into a limine.conf without entries (C6); the
  # loader's section blocks on it and names upstream's way out.
  if [[ $state == absent ]] && limine_conf_lacks_entries; then
    note "$WINDOWS_ENTRY_WAITS"
    return
  fi
  case $state in
    current) pass "The Windows entry restarts the machine into $(windows_target_label)" ;;
    absent) problem none "The Windows entry is missing from limine.conf" ;;
    stale) problem none "The Windows entry in limine.conf is not the one for $(windows_target_label)" ;;
    displaced) problem none "The Windows entry in limine.conf stands before the entries Omarchy orders, which shifts the entry Limine starts by default; ${BOLD}sudo omasecboot sign${NC} moves it after them" ;;
    misplaced) blocking_problem none "$WINDOWS_ENTRY_MISPLACED" ;;
    # The loader's section says that limine.conf could not be read.
    unknown) ;;
  esac
}

show_integration_status() {
  local hook
  hook=$(limine_hook_path)
  if [[ -x $hook ]]; then
    pass "The Limine hook is installed"
  else
    blocking_problem none "The Limine hook ${hook} is missing; reinstall the package"
  fi
  if watch_is_active; then
    pass "The watchers of limine.conf and the loader are active"
  else
    problem none "The watchers of limine.conf and the loader are not both active"
  fi
  # The pass does nothing beside a snapshot restore (C2), and nothing starts
  # one when the restore ends, so a restore lock that stays is said.
  if restore_in_progress; then
    problem none "A snapshot restore is running or was cut short: the hook and the watchers stay quiet while $(restore_lock_path) exists. When the restore has finished, run ${BOLD}sudo omasecboot sign${NC}. If no restore is running, the lock was left behind: remove it with ${BOLD}sudo rm $(restore_lock_path)${NC} first"
  fi
}

show_next_step() {
  if ! is_set_up; then
    (( _status_problems > 0 )) || act "Next: ${BOLD}sudo omasecboot setup${NC}"
  elif (( _status_problems == 0 )); then
    case $_status_firmware in
      complete) act "Nothing to do" ;;
      reboot) act "Next: restart (${BOLD}systemctl reboot${NC}), then run ${BOLD}sudo omasecboot setup${NC} once more" ;;
      enrolled) act "Next: ${BOLD}sudo omasecboot setup${NC} for the last step, turning Secure Boot on" ;;
      pending) act "Next: ${BOLD}sudo omasecboot setup${NC} for the firmware step" ;;
    esac
  else
    case $_status_next in
      sign) act "Next: ${BOLD}sudo omasecboot sign${NC}" ;;
      setup) act "Next: ${BOLD}sudo omasecboot setup${NC}" ;;
      blocked) act "Next: resolve what is marked above, then run ${BOLD}sudo omasecboot status${NC} again" ;;
    esac
    case $_status_risk in
      on) act "Do not reboot with Secure Boot on until this report no longer says so" ;;
      both) act "Do not reboot, with Secure Boot on or off, until this report no longer says so" ;;
    esac
  fi
}

# Exit 0 when nothing needs attention, 1 otherwise.
show_status() {
  local attention unsafe risk
  _status_problems=0 _status_next=sign _status_firmware=pending _status_risk=none
  header "Status"
  show_firmware_status
  if ! is_set_up; then
    # setup records the settings' originals before it writes "enabled", and
    # remove deletes "enabled" first and the originals last. Originals without
    # "enabled" are one of the two stopped half way, and either finishes it.
    if [[ -e $(settings_originals_file) ]]; then
      problem none "An earlier setup or remove did not finish. Run ${BOLD}sudo omasecboot remove${NC} to return to stock, or ${BOLD}sudo omasecboot setup${NC} to set up again"
    else
      note "OmaSecBoot is not set up on this machine"
      show_unsealed_signed_loader
    fi
  elif ! esp_is_mounted_vfat; then
    blocking_problem both "The EFI system partition is not mounted; mount it and run this again"
  else
    if ! unsafe=$(esp_mount_is_safe); then
      blocking_problem none "The ESP must be writable by root alone, but ${unsafe}. Anyone who can write it can change what boots, so OmaSecBoot seals and signs nothing until its mount shows that only root can; a change of limine.conf, or of the loader with Secure Boot on, meanwhile leaves a machine that does not start. $(unsafe_esp_remedy)"
    fi
    show_microsoft_2023_status
    show_settings_status
    show_loader_status
    show_files_status
    show_windows_status
    note_windows_chainloads
    show_integration_status
    attention=$(attention_file)
    if [[ -e $attention ]]; then
      # A write the ESP did not confirm is seen by nothing else here (7.3).
      risk=none
      ! grep -q "^${ATTENTION_SYNC} on " "$attention" || risk=both
      problem "$risk" "An earlier pass could not finish: $(awk 'NR > 1 { printf "; " } { printf "%s", $0 }' "$attention")"
    fi
  fi
  show_next_step
  (( _status_problems == 0 ))
}
