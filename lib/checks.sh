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

# The Limine hook tools are proved by exact package version at activation;
# here only the executables this code runs itself are required.
check_deps() {
  check_core_deps
  command -v limine >/dev/null 2>&1 \
    || die "limine not installed. Run: ${BOLD}sudo pacman -S limine${NC}"
  command -v b2sum >/dev/null 2>&1 \
    || die "b2sum not installed. Run: ${BOLD}sudo pacman -S coreutils${NC}"
  command -v openssl >/dev/null 2>&1 \
    || die "openssl not installed. Run: ${BOLD}sudo pacman -S openssl${NC}"
  check_esp_mount
}

check_esp_mount() {
  local esp
  esp=$(esp_path)
  { command -v mountpoint && command -v findmnt; } >/dev/null 2>&1 \
    || die "util-linux (mountpoint, findmnt) not installed. Run: ${BOLD}sudo pacman -S util-linux${NC}"
  [[ -d "${esp}/EFI" ]] \
    || die "${esp}/EFI not found. Is the EFI partition mounted?"
  esp_is_mounted_vfat \
    || die "${esp} is not mounted as the FAT32 ESP. Refusing to modify a stale directory."
}

check_efi_mode() {
  local efivars
  efivars=$(efivars_path)
  [[ -d "${efivars%/*}" ]] \
    || die "System did not boot in UEFI mode. Secure Boot requires UEFI."
}

require_gum() {
  command -v gum >/dev/null 2>&1 \
    || die "gum not installed. Run: ${BOLD}sudo pacman -S gum${NC}"
  # gum choose returns its selection on stdout, which may be captured. Input
  # and the prompt's stderr must remain attached to an interactive terminal.
  [[ -t 0 && -t 2 ]] \
    || die "An interactive terminal is required for confirmation. Run this command in a terminal with stdin and stderr attached."
}

# --- Lifecycle activation environment -----------------------------------------
# Before a lifecycle may publish `active`: exact producer package versions, the
# efibootmgr floor, the pinned unconfiguration tools, and every OmaSecBoot hook
# by canonical content and executing command target.

current_omasecboot_executable_path() {
  printf '%s\n' "$OMASECBOOT_COMMAND_PATH"
}

activation_hook_path() {
  case "$1" in
    removal) printf '/usr/share/libalpm/hooks/00-omasecboot-removal-guard.hook\n' ;;
    transaction) printf '/usr/share/libalpm/hooks/00-omasecboot-transition-guard.hook\n' ;;
    package-sign) printf '/usr/share/libalpm/hooks/zzz-omasecboot.hook\n' ;;
    limine-pre) printf '/etc/boot/hooks/pre.d/000-omasecboot-guard\n' ;;
    limine-post) printf '/etc/boot/hooks/post.d/zzz-omasecboot-sign\n' ;;
    *) return 1 ;;
  esac
}

validate_activation_hook() {
  local key="$1" command="$2" path expected template expected_hash
  local document normalized actual_hash executable=false
  path=$(activation_hook_path "$key") || return 1
  case "$key" in
    removal)
      expected="Exec = ${command} --quiet guard removal"
      expected_hash=f70bc5a660776e2a5dd4ea5e8184a61b1adc547db4c3286a69b355383f1eb56d
      ;;
    transaction)
      expected="Exec = ${command} --quiet guard transaction"
      expected_hash=cedd35b7b7209cb01587649fba225907c3552b837a03f8f609fd063154e99f5f
      ;;
    package-sign)
      expected="Exec = ${command} --quiet hook package-sign"
      expected_hash=6250350574ba80e09c65a1f49571df2e925e6976254b32868fae3ea132b4a0c9
      ;;
    limine-pre)
      expected="exec ${command} --quiet hook pre"
      expected_hash=ea5485e3cc7a1470329f54b96bee38cc5edc1a9746878bf241183144432a2807
      executable=true
      ;;
    limine-post)
      expected="exec ${command} --quiet hook post"
      expected_hash=0ecf4826228641befc2bff8df14ad28c0b0431e23b8366353b63cebac7eb7d05
      executable=true
      ;;
    *) return 1 ;;
  esac
  validate_control_file "$path" || return 1
  [[ "$executable" == false || -x "$path" ]] || return 1
  if [[ "$executable" == false ]] && pacman_hook_is_shadowed "$path"; then
    return 1
  fi
  document=$(<"$path") || return 1
  [[ "$document" == *"$expected"* ]] || return 1
  template=${expected/"$command"/@BINDIR@\/omasecboot}
  normalized=${document/"$expected"/"$template"}
  actual_hash=$(sha256_text "$normalized") || return 1
  [[ "$actual_hash" == "$expected_hash" ]]
}

lifecycle_activation_environment_is_ready() {
  local command key
  command=$(current_omasecboot_executable_path) || return 1
  validate_control_file "$command" && [[ -x "$command" ]] || return 1
  [[ $(producer_package_version limine-mkinitcpio-hook) == \
      "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" \
    && $(producer_package_version limine-snapper-sync) == \
      "$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION" \
    && $(producer_package_version sbctl) == "$SUPPORTED_SBCTL_VERSION" ]] || {
    fail "Lifecycle activation requires the exact supported producer packages"
    return 1
  }
  version_at_least "$(producer_package_version efibootmgr)" \
    "$WINDOWS_EFIBOOTMGR_MINIMUM_VERSION" || {
    fail "Lifecycle activation requires efibootmgr ${WINDOWS_EFIBOOTMGR_MINIMUM_VERSION} or newer"
    return 1
  }
  unconfigure_limine_tools_are_pinned || {
    fail "Lifecycle activation requires the supported unconfiguration tools"
    return 1
  }
  for key in removal transaction package-sign limine-pre limine-post; do
    validate_activation_hook "$key" "$command" || {
      fail "Lifecycle activation requires the current installed, unshadowed ${key} hook"
      return 1
    }
  done
}
