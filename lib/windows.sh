#!/bin/bash
# OmaSecBoot: Windows dual-boot via firmware BootNext

readonly WINDOWS_ENTRY_MARKER="# omasecboot:windows"

# Find the Windows Boot Manager firmware entry by loader path.
# Prints "bootnum<TAB>entry_name" or returns 1 if not found.
find_windows_boot_entry() {
  command -v efibootmgr >/dev/null 2>&1 || return 1

  local bootnum entry_name

  bootnum=$(efibootmgr -v 2>/dev/null \
    | grep -i 'bootmgfw\.efi' | head -1 \
    | grep -oP 'Boot\K[0-9A-Fa-f]+') || true
  [[ -n "$bootnum" ]] || return 1

  # Extract just the human-readable label, stripping any device path info
  # that efibootmgr may append (tab-separated or space-separated HD(...))
  entry_name=$(efibootmgr 2>/dev/null \
    | sed -n "s/^Boot${bootnum}\*\? //p" \
    | sed -e 's/\t.*//' -e 's/[[:space:]][[:space:]]*HD(.*//' -e 's/[[:space:]][[:space:]]*PciRoot(.*//' -e 's/[[:space:]]*$//') || true
  [[ -n "$entry_name" ]] || return 1

  printf '%s\t%s\n' "$bootnum" "$entry_name"
}

windows_entry_is_configured() {
  grep -Fq "$WINDOWS_ENTRY_MARKER" "$LIMINE_CONF" 2>/dev/null
}

# Write the Windows efi_boot_entry block to limine.conf.
# Uses Limine's efi_boot_entry protocol which sets BootNext and reboots,
# keeping limine_x64.efi out of the Windows TPM measurement chain.
update_windows_boot_entry() {
  local entry_name="$1"
  local backup tmp

  backup=$(backup_file "$LIMINE_CONF") || {
    fail "Could not back up ${LIMINE_CONF}"
    return 1
  }

  local conf_dir
  conf_dir=$(dirname "$LIMINE_CONF")
  tmp=$(mktemp "${conf_dir}/.omasecboot.limine.conf.XXXXXX") || {
    discard_file_backup "$backup"
    fail "Could not create temporary file for ${LIMINE_CONF}"
    return 1
  }

  if ! awk -v marker="$WINDOWS_ENTRY_MARKER" -v entry_name="$entry_name" '
    function print_block() {
      print ""
      print marker
      print "/Windows"
      print "    comment: " entry_name
      print "    protocol: efi_boot_entry"
      print "    entry: " entry_name
      inserted = 1
    }

    BEGIN {
      in_block = 0
      inserted = 0
    }

    $0 == marker {
      if (!inserted) {
        print_block()
      }
      in_block = 1
      next
    }

    in_block {
      if ($0 == "/Windows" || $0 ~ /^[[:space:]]+/ || $0 == "") {
        next
      }
      in_block = 0
    }

    {
      print
    }

    END {
      if (!inserted) {
        print_block()
      }
    }
  ' "$LIMINE_CONF" > "$tmp"; then
    rm -f "$tmp"
    discard_file_backup "$backup"
    fail "Failed to write Windows boot entry to ${LIMINE_CONF}"
    return 1
  fi

  if ! mv "$tmp" "$LIMINE_CONF"; then
    restore_file_backup "$backup" "$LIMINE_CONF" || true
    rm -f "$tmp"
    discard_file_backup "$backup"
    fail "Failed to update ${LIMINE_CONF}"
    return 1
  fi

  discard_file_backup "$backup"
}

# Add Windows to Limine boot menu using efi_boot_entry protocol (interactive).
add_windows_boot_entry() {
  header "Windows Dual-Boot"

  if windows_entry_is_configured; then
    pass "Windows boot entry already in limine.conf"
    return 0
  fi

  command -v efibootmgr >/dev/null 2>&1 \
    || die "efibootmgr not installed. Run: ${BOLD}sudo pacman -S efibootmgr${NC}"

  local boot_info bootnum entry_name
  boot_info=$(find_windows_boot_entry) || {
    fail "Windows Boot Manager not found in EFI boot entries"
    echo
    echo -e "  ${BOLD}Troubleshooting${NC}"
    echo "    - Ensure the Windows SSD is connected and visible in BIOS"
    echo "    - Check with: efibootmgr -v"
    echo
    return 1
  }
  IFS=$'\t' read -r bootnum entry_name <<< "$boot_info"

  pass "Found ${entry_name} (Boot${bootnum})"

  if ! gum confirm "Add Windows to Limine boot menu?"; then
    warn "Aborted"
    return 1
  fi

  with_boot_repair_lock
  update_windows_boot_entry "$entry_name" || return 1
  run_artifact_repair "windows-entry-repair" || return 1
  mkdir -p "$STATE_DIR"
  touch "${STATE_DIR}/windows-enabled"
  pass "Windows boot entry added to limine.conf"
  echo
  echo -e "  ${DIM}Windows will appear in the Limine boot menu. Selecting it triggers${NC}"
  echo -e "  ${DIM}a firmware reboot directly into Windows (bypasses limine_x64.efi).${NC}"
  echo
}

# Ensure the Windows boot entry is present and uses the efi_boot_entry protocol.
# Restores the entry if missing (when user previously opted in).
# Upgrades repo-managed protocol: efi entries to efi_boot_entry if needed.
ensure_windows_boot_entry() {
  [[ -f "$LIMINE_CONF" ]] || return 0

  # Act if user opted in via 'windows' command, or if a repo-managed block
  # already exists in limine.conf (a block can exist without the marker file)
  if [[ ! -f "${STATE_DIR}/windows-enabled" ]]; then
    windows_entry_is_configured || return 0
  fi

  # Already present with correct protocol
  if grep -Fq "$WINDOWS_ENTRY_MARKER" "$LIMINE_CONF" 2>/dev/null \
     && grep -F -A4 "$WINDOWS_ENTRY_MARKER" "$LIMINE_CONF" | grep -q "protocol: efi_boot_entry"; then
    return 0
  fi

  local boot_info bootnum entry_name
  boot_info=$(find_windows_boot_entry) || return 0
  IFS=$'\t' read -r bootnum entry_name <<< "$boot_info"

  update_windows_boot_entry "$entry_name" || return 1
  qact "Windows boot entry updated in limine.conf"
}

# Set firmware BootNext to Windows Boot Manager without rebooting.
# Detects by bootmgfw.efi loader path, not by label.
set_windows_bootnext() {
  command -v efibootmgr >/dev/null 2>&1 \
    || die "efibootmgr not installed. Run: ${BOLD}sudo pacman -S efibootmgr${NC}"

  local boot_info bootnum entry_name
  boot_info=$(find_windows_boot_entry) || {
    fail "Windows Boot Manager not found in EFI boot entries"
    echo -e "  ${DIM}Check with: efibootmgr -v${NC}"
    return 1
  }
  IFS=$'\t' read -r bootnum entry_name <<< "$boot_info"

  efibootmgr -n "$bootnum" >/dev/null || die "Could not set BootNext"
  pass "BootNext set to ${entry_name} (Boot${bootnum})"
  echo -e "  ${DIM}If reboot is cancelled, the next boot still enters Windows once.${NC}"
}

# Set firmware BootNext to Windows Boot Manager and reboot immediately.
reboot_to_windows() {
  set_windows_bootnext || return 1
  act "Rebooting to Windows. Linux resumes on the following boot."
  systemctl reboot
}
