#!/bin/bash
# OmaSecBoot: prerequisite validation

check_root() {
  [[ $EUID -eq 0 ]] || die "Root required. Run: ${BOLD}sudo omasecboot ${1:-}${NC}"
}

check_core_deps() {
  command -v sbctl >/dev/null 2>&1 \
    || die "sbctl not installed. Run: ${BOLD}sudo pacman -S sbctl${NC}"
  command -v jq >/dev/null 2>&1 \
    || die "jq not installed. Run: ${BOLD}sudo pacman -S jq${NC}"
}

check_recovery_deps() {
  local command
  for command in flock jq sha256sum stat; do
    command -v "$command" >/dev/null 2>&1 \
      || die "Recovery dependency not installed: ${command}"
  done
}

check_deps() {
  check_core_deps
  command -v limine-update >/dev/null 2>&1 \
    || die "limine-update not installed. Install: ${BOLD}limine-mkinitcpio-hook${NC}"
  command -v limine-enroll-config >/dev/null 2>&1 \
    || die "limine-enroll-config not installed. Update: ${BOLD}limine-mkinitcpio-hook${NC}"
  command -v limine-reset-enroll >/dev/null 2>&1 \
    || die "limine-reset-enroll not installed. Update: ${BOLD}limine-mkinitcpio-hook${NC}"
  check_esp_mount
}

check_esp_mount() {
  command -v mountpoint >/dev/null 2>&1 \
    || die "mountpoint not installed. Run: ${BOLD}sudo pacman -S util-linux${NC}"
  command -v findmnt >/dev/null 2>&1 \
    || die "findmnt not installed. Run: ${BOLD}sudo pacman -S util-linux${NC}"

  [[ -d "${ESP}/EFI" ]] \
    || die "${ESP}/EFI not found. Is the EFI partition mounted?"
  mountpoint -q "$ESP" \
    || die "${ESP} is not a mountpoint. Refusing to modify a stale ESP directory."

  local fstype=""
  fstype=$(findmnt -n -T "$ESP" -o FSTYPE 2>/dev/null) || fstype=""
  [[ "$fstype" == "vfat" ]] \
    || die "${ESP} is mounted as ${fstype:-unknown}, expected vfat/FAT32 ESP"
}

check_efi_mode() {
  [[ -d /sys/firmware/efi ]] \
    || die "System did not boot in UEFI mode. Secure Boot requires UEFI."
}

require_gum() {
  command -v gum >/dev/null 2>&1 \
    || die "gum not installed. Run: ${BOLD}sudo pacman -S gum${NC}"
}
