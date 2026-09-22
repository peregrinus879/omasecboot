#!/bin/bash
# OmaSecBoot: preconditions and prompts.

check_root() {
  (( EUID == 0 )) || die "Run as root: ${BOLD}sudo omasecboot $1${NC}"
}

# Omarchy and the Limine paths this tool knows are x86_64 only.
check_architecture() {
  [[ $(uname -m) == x86_64 ]] || {
    fail "Unsupported architecture $(uname -m); OmaSecBoot supports x86_64"
    return 1
  }
}

check_uefi() {
  local dir
  dir=$(efivars_dir)
  [[ -d $dir && $(findmnt -n -T "$dir" -o FSTYPE 2>/dev/null) == efivarfs ]] || {
    fail "Not booted in UEFI mode: ${dir} is not an efivarfs mount"
    return 1
  }
}

check_esp() {
  esp_is_mounted_vfat || {
    fail "The EFI system partition is not mounted as vfat; set ESP_PATH in $(limine_default_config)"
    return 1
  }
}

check_tools() {
  local tool missing=()
  for tool in sbctl jq limine limine-install limine-mkinitcpio limine-reset-enroll b2sum flock findmnt tar; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  (( ${#missing[@]} == 0 )) || {
    fail "Missing tools: ${missing[*]}"
    return 1
  }
}

# Prompts need a terminal on both ends: without one gum declines silently,
# which reads as a refusal nobody gave (C10).
require_terminal() {
  [[ -t 0 && -t 2 ]] || {
    fail "This step asks for confirmation and needs a terminal"
    return 1
  }
  command -v gum >/dev/null 2>&1 || {
    fail "gum is not installed. Run: ${BOLD}sudo pacman -S gum${NC}"
    return 1
  }
}

# confirm WHAT QUESTION: default No; a declined prompt says what was cancelled.
confirm() {
  local what=$1 question=$2
  require_terminal || {
    warn "Cancelled: ${what}. The step it guarded did not run"
    return 1
  }
  if gum confirm --default=false "$question"; then
    return 0
  else
    warn "Cancelled: ${what}. The step it guarded did not run"
    return 1
  fi
}
