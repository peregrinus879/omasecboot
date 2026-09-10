#!/bin/bash
# shellcheck disable=SC2034,SC2154,SC2329 # Stubs set the globals the sections read.
# Hermetic checks for the status sections: each section reports its own
# verdict from stubbed collaborators, and the display fails only when a
# section fails.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init status

# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"

DEFAULTS_FILE="${TEST_DIR}/limine-defaults"
CONFIG_FILE="${TEST_DIR}/limine.conf"
STATE_FILE="${TEST_DIR}/windows-enabled"
ESP_DIR="${TEST_DIR}/esp"
mkdir -p "$ESP_DIR"

limine_default_config_path() { printf '%s\n' "$DEFAULTS_FILE"; }
limine_entry_tool_config_files() { printf '%s\n' "$DEFAULTS_FILE"; }
limine_config_path() { printf '%s\n' "$CONFIG_FILE"; }
esp_path() { printf '%s\n' "$ESP_DIR"; }
windows_target_state_path() { printf '%s\n' "$STATE_FILE"; }
control_owner_uid() { id -u; }
HOOK_DIR="${TEST_DIR}/hooks"
STALE_DIR="${TEST_DIR}/stale"
HOOK_INVALID=""
mkdir -p "$HOOK_DIR"
activation_hook_path() { printf '%s/%s\n' "$HOOK_DIR" "$1"; }
sbctl_resign_hook_path() { printf '%s/zz-sbctl.hook\n' "$HOOK_DIR"; }
stale_source_install_paths() { printf '%s\n' "${STALE_DIR}/bin" "${STALE_DIR}/lib"; }
validate_activation_hook() { [[ "$1" != "$HOOK_INVALID" ]]; }
pacman_hook_is_shadowed() { return 1; }
install_hooks() {
  local key
  for key in removal transaction package-sign limine-pre limine-post zz-sbctl.hook; do
    : > "${HOOK_DIR}/${key}"
  done
}
write_defaults() { printf '%s\n' "$@" > "$DEFAULTS_FILE"; }
write_config() { printf '%s\n' "$@" > "$CONFIG_FILE"; }

section_rc=0
section_output=""
run_section() {
  section_rc=0
  section_output=$("$@" 2>&1) || section_rc=$?
}
expect_status() {
  [[ "$section_rc" == "$1" ]] || fail_test "$2 returned ${section_rc}: ${section_output}"
}
expect_output() {
  [[ "$section_output" == *"$1"* ]] || fail_test "$2 did not report '$1': ${section_output}"
}
expect_no_output() {
  [[ "$section_output" != *"$1"* ]] || fail_test "$2 reported '$1': ${section_output}"
}
without_tools() {
  PATH=/nonexistent "$@"
}

# --- Firmware ---------------------------------------------------------------

good_json='{"installed":true,"setup_mode":false,"secure_boot":true,"vendors":["microsoft"]}'
run_section show_firmware_status "$good_json"
expect_status 0 "healthy firmware"
expect_output "sbctl keys installed" "healthy firmware"
expect_output "Secure Boot enabled" "healthy firmware"
expect_output "Setup Mode disabled" "healthy firmware"
expect_output "Vendor keys: microsoft" "healthy firmware"

run_section show_firmware_status '{"installed":false,"setup_mode":true,"secure_boot":false}'
expect_status 1 "unprovisioned firmware"
expect_output "sbctl keys not installed" "unprovisioned firmware"
expect_output "Secure Boot disabled" "unprovisioned firmware"
expect_output "Setup Mode active" "unprovisioned firmware"

sbctl() { printf 'raw sbctl status\n'; }
run_section show_firmware_status ""
expect_status 0 "raw firmware fallback"
expect_output "raw sbctl status" "raw firmware fallback"

# --- Hooks ------------------------------------------------------------------

install_hooks
run_section show_hook_status
expect_status 0 "installed hooks"
expect_output "removal present (dependency removal guard)" "installed hooks"
expect_output "limine-post present (Limine post-mutation checkpoint)" "installed hooks"
expect_output "zz-sbctl.hook present (re-signing)" "installed hooks"

HOOK_INVALID=limine-pre
run_section show_hook_status
expect_status 1 "altered hook"
expect_output "limine-pre is not the packaged hook or targets another command" "altered hook"
HOOK_INVALID=""

rm -f "${HOOK_DIR}/transaction"
_lifecycle_state=unmanaged
run_section show_hook_status
expect_status 0 "missing hook while unmanaged"
expect_output "transaction missing; install the packaged OmaSecBoot release" \
  "missing hook while unmanaged"
_lifecycle_state=active
run_section show_hook_status
expect_status 1 "missing hook while active"
install_hooks
rm -f "${HOOK_DIR}/zz-sbctl.hook"
run_section show_hook_status
expect_status 1 "missing sbctl hook while active"
expect_output "zz-sbctl.hook missing" "missing sbctl hook while active"
_lifecycle_state=unmanaged
install_hooks

mkdir -p "${STALE_DIR}/lib"
run_section show_hook_status
expect_status 1 "stale source install"
expect_output "Stale source install at ${STALE_DIR}/lib" "stale source install"
rm -rf "$STALE_DIR"

# --- Service ----------------------------------------------------------------

SERVICE_LOAD=not-found
SERVICE_ENABLED=enabled
SERVICE_ACTIVE=active
systemctl() {
  case "$1" in
    show) printf '%s\n' "$SERVICE_LOAD" ;;
    is-enabled) printf '%s\n' "$SERVICE_ENABLED" ;;
    is-active) printf '%s\n' "$SERVICE_ACTIVE" ;;
    *) return 1 ;;
  esac
}
run_section show_service_status
expect_status 0 "absent service"
[[ -z "$section_output" ]] || fail_test "absent service printed: ${section_output}"

SERVICE_LOAD=loaded
run_section show_service_status
expect_status 0 "running service"
expect_output "limine-snapper-sync.service enabled" "running service"
expect_output "limine-snapper-sync.service active" "running service"

SERVICE_ENABLED=disabled
SERVICE_ACTIVE=inactive
run_section show_service_status
expect_status 0 "stopped service"
expect_output "not enabled (disabled)" "stopped service"
expect_output "not active (inactive)" "stopped service"

# --- ESP --------------------------------------------------------------------

esp_is_mounted_vfat() { return 0; }
run_section show_esp_status
expect_status 0 "mounted ESP"
expect_output "mounted as vfat" "mounted ESP"

esp_is_mounted_vfat() { return 1; }
run_section show_esp_status
expect_status 1 "unmounted ESP"
expect_output "is not mounted as the FAT32 ESP" "unmounted ESP"

run_section without_tools show_esp_status
expect_status 0 "ESP without mount tools"
expect_output "mountpoint/findmnt unavailable" "ESP without mount tools"

# --- Limine config ----------------------------------------------------------

limine_enrollment_hooks_present() { return 0; }
limine_version() { printf '12.0.1\n'; }
write_defaults 'ENABLE_VERIFICATION=no' 'ENABLE_ENROLL_LIMINE_CONFIG=yes'
write_config 'timeout: 5' '/Omarchy' '    protocol: efi' '    path: boot():/EFI/Linux/arch.efi'
run_section show_limine_config_status true
expect_status 0 "healthy config"
expect_output "ENABLE_VERIFICATION=no" "healthy config"
expect_output "ENABLE_ENROLL_LIMINE_CONFIG=yes" "healthy config"
expect_output "Limine enrollment hooks present" "healthy config"
expect_output "Limine 12.0.1 installed" "healthy config"
expect_output "path-hash readiness passed" "healthy config"

write_defaults 'ENABLE_VERIFICATION=yes' 'ENABLE_ENROLL_LIMINE_CONFIG=yes'
run_section show_limine_config_status true
expect_status 1 "verification enabled"
expect_output "ENABLE_VERIFICATION is not one clean no (yes)" "verification enabled"

write_defaults 'ENABLE_VERIFICATION=no' 'ENABLE_ENROLL_LIMINE_CONFIG=yes'
write_config '/Linux' '    protocol: linux' '    kernel_path: boot():/vmlinuz-linux'
run_section show_limine_config_status true
expect_status 1 "unhashed path under Secure Boot"
expect_output "path-hash enforcement may block boot" "unhashed path under Secure Boot"
expect_output "kernel_path: boot():/vmlinuz-linux" "unhashed path under Secure Boot"
run_section show_limine_config_status false
expect_status 0 "unhashed path without Secure Boot"
expect_output "missing BLAKE2B hashes" "unhashed path without Secure Boot"

# A present hash is checked for every protocol: matching passes, stale fails
# under Secure Boot and warns without it, both naming the entry and the
# regenerating command.
mkdir -p "${ESP_DIR}/EFI/Linux"
printf 'UKI\n' > "${ESP_DIR}/EFI/Linux/arch.efi"
read -r good_hash _ < <(b2sum "${ESP_DIR}/EFI/Linux/arch.efi")
write_config '/Omarchy' '    protocol: efi' "    path: boot():/EFI/Linux/arch.efi#${good_hash}"
run_section show_limine_config_status true
expect_status 0 "matching path hash"
expect_output "Limine path hashes match their files" "matching path hash"
stale_hash=$(printf 'f%.0s' {1..128})
write_config '/Omarchy' '    protocol: efi' "    path: boot():/EFI/Linux/arch.efi#${stale_hash}"
run_section show_limine_config_status true
expect_status 1 "stale path hash under Secure Boot"
expect_output "Limine path hashes are stale; Limine refuses these entries with Secure Boot on" \
  "stale path hash under Secure Boot"
expect_output "path: boot():/EFI/Linux/arch.efi#${stale_hash}" "stale path hash under Secure Boot"
expect_output "Run sudo limine-mkinitcpio for the OS entry" "stale path hash under Secure Boot"
run_section show_limine_config_status false
expect_status 0 "stale path hash without Secure Boot"
expect_output "stops at a hash prompt" "stale path hash without Secure Boot"
rm -f "${ESP_DIR}/EFI/Linux/arch.efi"

write_defaults 'ENABLE_VERIFICATION=no' 'ENABLE_ENROLL_LIMINE_CONFIG=no'
run_section show_limine_config_status true
expect_status 1 "enrollment disabled"
expect_output "ENABLE_ENROLL_LIMINE_CONFIG is not one clean yes (no)" "enrollment disabled"
expect_output "path-hash enforcement inactive" "enrollment disabled"

limine_enrollment_hooks_present() { return 1; }
write_defaults 'ENABLE_VERIFICATION=no' 'ENABLE_ENROLL_LIMINE_CONFIG=yes'
write_config 'timeout: 5'
run_section show_limine_config_status true
expect_status 1 "missing enrollment hooks"
expect_output "COMMANDS_BEFORE_SAVE is missing" "missing enrollment hooks"
expect_output "COMMANDS_AFTER_SAVE is missing" "missing enrollment hooks"

write_defaults 'ENABLE_VERIFICATION=no' 'ENABLE_ENROLL_LIMINE_CONFIG=yes' \
  'COMMANDS_BEFORE_SAVE="limine-reset-enroll"' 'COMMANDS_AFTER_SAVE="limine-enroll-config"'
run_section show_limine_config_status true
expect_status 0 "deprecated fallback"
expect_output "COMMANDS_BEFORE_SAVE includes limine-reset-enroll" "deprecated fallback"
expect_output "COMMANDS_AFTER_SAVE includes limine-enroll-config" "deprecated fallback"

limine_enrollment_hooks_present() { return 0; }
run_section show_limine_config_status true
expect_status 0 "hooks with deprecated entries"
expect_output "deprecated COMMANDS_* enrollment entries remain" "hooks with deprecated entries"

rm -f "$DEFAULTS_FILE"
run_section show_limine_config_status true
expect_status 1 "missing defaults"
expect_output "not found" "missing defaults"

# --- Limine checksum --------------------------------------------------------

VERIFY_OK=true
limine_shadow_config_paths() { printf '%s\n' "${ESP_DIR}/EFI/limine/limine.conf"; }
current_limine_config_checksum() { printf 'checksum\n'; }
verify_limine_config_targets() { [[ "$1" == checksum && "$VERIFY_OK" == true ]]; }
run_section show_limine_checksum_status
expect_status 0 "enrolled checksum"
expect_output "enrolled in both boot binaries" "enrolled checksum"

VERIFY_OK=false
run_section show_limine_checksum_status
expect_status 1 "unproved checksum"
expect_output "not proved in both boot binaries" "unproved checksum"

mkdir -p "${ESP_DIR}/EFI/limine"
: > "${ESP_DIR}/EFI/limine/limine.conf"
run_section show_limine_checksum_status
expect_status 1 "shadowing config"
expect_output "Possible Limine config shadowing file" "shadowing config"
expect_no_output "not proved" "shadowing config"
rm -f "${ESP_DIR}/EFI/limine/limine.conf"

# ENABLE_LIMINE_FALLBACK=no without a fallback loader narrows the proof to
# the primary and says so; an unreadable policy value is refused.
write_defaults 'ENABLE_LIMINE_FALLBACK=no'
VERIFY_OK=true
run_section show_limine_checksum_status
expect_status 0 "primary-only checksum"
expect_output "enrolled in the primary boot binary (fallback loader not deployed, ENABLE_LIMINE_FALLBACK=no)" \
  "primary-only checksum"
write_defaults 'ENABLE_LIMINE_FALLBACK=maybe'
run_section show_limine_checksum_status
expect_status 1 "invalid fallback policy"
expect_output "ENABLE_LIMINE_FALLBACK could not be resolved" "invalid fallback policy"
write_defaults

# --- Windows ----------------------------------------------------------------

list_omarchy_direct_boot_entries() { :; }
find_windows_boot_entry() { return 1; }
list_windows_firmware_entries() { :; }
read_windows_target_state() { return 1; }
list_unmanaged_windows_chainloads() { :; }
write_config 'timeout: 5'
run_section show_windows_status
expect_status 0 "no Windows"
expect_output "No Windows Boot Manager found" "no Windows"
expect_output "No managed Windows firmware handoff configured" "no Windows"

list_windows_firmware_entries() { printf 'Boot0001* Windows Boot Manager\n'; }
run_section show_windows_status
expect_status 1 "ambiguous Windows target"
expect_output "do not resolve to one safe handoff target" "ambiguous Windows target"

find_windows_boot_entry() { printf '0001\tWindows\n'; }
list_unmanaged_windows_chainloads() { printf '12: path: boot():/EFI/Microsoft/Boot/bootmgfw.efi\n'; }
run_section show_windows_status
expect_status 0 "unmanaged chainload"
expect_output "Unique active Windows firmware handoff target" "unmanaged chainload"
expect_output "may trigger BitLocker" "unmanaged chainload"
expect_output "remove the chainload entry from limine.conf yourself" "unmanaged chainload"
list_unmanaged_windows_chainloads() { :; }

read_windows_target_state() {
  _windows_state_label="Windows"
  _windows_state_boot_number=0001
  return 0
}
windows_managed_block_state() { _windows_block_state=canonical; }
run_section show_windows_status
expect_status 0 "managed handoff"
expect_output "Durable Windows firmware target identity recorded" "managed handoff"
expect_output "Windows boot entry in limine.conf (firmware BootNext)" "managed handoff"

# A recorded target that firmware no longer resolves to is a failure, not a
# green line next to a stale record.
find_windows_boot_entry() { printf '0002\tWindows\n'; }
run_section show_windows_status
expect_status 1 "stale recorded target"
expect_output "Recorded Windows target Boot0001 is not the firmware target Boot0002" \
  "stale recorded target"
find_windows_boot_entry() { printf '0001\tWindows\n'; }

windows_managed_block_state() { _windows_block_state=absent; }
run_section show_windows_status
expect_status 1 "suppressed handoff"
expect_output "managed entry is suppressed" "suppressed handoff"

windows_managed_block_state() { return 1; }
run_section show_windows_status
expect_status 1 "malformed block"
expect_output "malformed or mismatched" "malformed block"

read_windows_target_state() { return 1; }
: > "$STATE_FILE"
chmod 644 "$STATE_FILE"
run_section show_windows_status
expect_status 1 "legacy opt-in"
expect_output "Legacy Windows opt-in marker needs explicit target migration" "legacy opt-in"

printf 'garbage\n' > "$STATE_FILE"
chmod 644 "$STATE_FILE"
run_section show_windows_status
expect_status 1 "invalid opt-in"
expect_output "Durable Windows target state is invalid or unsafe" "invalid opt-in"
rm -f "$STATE_FILE"

write_config 'timeout: 5' "$WINDOWS_ENTRY_MARKER" '/Windows' '    protocol: efi_boot_entry' "$WINDOWS_ENTRY_END_MARKER"
run_section show_windows_status
expect_status 1 "block without identity"
expect_output "Managed Windows entry has no durable target identity" "block without identity"
write_config 'timeout: 5'

# --- Tracked files ----------------------------------------------------------

control_owner_uid() { printf '%s\n' "$((EUID + 1))"; }
run_section show_tracked_files_status
expect_status 0 "unprivileged tracked files"
expect_output "Run as root for file verification" "unprivileged tracked files"
control_owner_uid() { id -u; }

ENROLLED="${ESP_DIR}/EFI/Linux/a.efi"$'\n'"${ESP_DIR}/EFI/BOOT/BOOTX64.EFI"
DISCOVERED="$ENROLLED"
STALE=""
UNSIGNED=""
list_enrolled_paths() { printf '%s\n' "$ENROLLED"; }
list_stale_sbctl_entries() { [[ -z "$STALE" ]] || printf '%s\n' "$STALE"; }
discover_efi_files() { printf '%s\n' "$DISCOVERED"; }
sbctl_file_signature_state() { [[ "$1" != "$UNSIGNED" ]]; }
run_section show_tracked_files_status
expect_status 0 "healthy tracked files"
expect_output "All tracked files signed and all discovered EFI files enrolled" "healthy tracked files"

DISCOVERED="${ENROLLED}"$'\n'"${ESP_DIR}/EFI/Linux/new.efi_sha256_abc"
run_section show_tracked_files_status
expect_status 1 "untracked snapshot"
expect_output "Untracked EFI files found (1)" "untracked snapshot"
expect_output "Snapshot UKIs exist outside sbctl's database" "untracked snapshot"
DISCOVERED="$ENROLLED"

UNSIGNED=${ESP_DIR}/EFI/Linux/a.efi
run_section show_tracked_files_status
expect_status 1 "unsigned tracked file"
expect_output "Some files failed" "unsigned tracked file"
UNSIGNED=""

STALE="${ESP_DIR}/EFI/Linux/gone.efi"$'\t'"${ESP_DIR}/EFI/Linux/gone.efi"
run_section show_tracked_files_status
expect_status 1 "stale tracking"
expect_output "Stale sbctl tracked files found" "stale tracking"
expect_output "Run sudo omasecboot cleanup" "stale tracking"
STALE=""

list_enrolled_paths() { return 1; }
run_section show_tracked_files_status
expect_status 1 "unreadable tracking"
expect_output "Could not read sbctl tracking state" "unreadable tracking"

list_enrolled_paths() { :; }
run_section show_tracked_files_status
expect_status 1 "empty database with artifacts"
expect_output "No files in sbctl database" "empty database with artifacts"
DISCOVERED=""
discover_efi_files() { :; }
run_section show_tracked_files_status
expect_status 0 "empty database without artifacts"
list_enrolled_paths() { printf '%s\n' "$ENROLLED"; }
discover_efi_files() { printf '%s\n' "$DISCOVERED"; }
DISCOVERED="$ENROLLED"

# A failed discovery is reported, never read as an empty artifact set.
discover_efi_files() { return 1; }
run_section show_tracked_files_status
expect_status 1 "failed discovery"
expect_output "Could not discover the EFI artifacts" "failed discovery"
expect_no_output "all discovered EFI files enrolled" "failed discovery"
discover_efi_files() { printf '%s\n' "$DISCOVERED"; }

# --- Display ----------------------------------------------------------------

sbctl() { [[ "$*" == "status --json" ]] && printf '%s\n' "$good_json"; }
install_hooks
esp_is_mounted_vfat() { return 0; }
write_defaults 'ENABLE_VERIFICATION=no' 'ENABLE_ENROLL_LIMINE_CONFIG=yes'
VERIFY_OK=true
run_section show_status
expect_status 0 "healthy display"
expect_output "Secure Boot Status" "healthy display"
expect_output "Tracked Files" "healthy display"

esp_is_mounted_vfat() { return 1; }
run_section show_status
expect_status 1 "display with one failing section"
expect_output "is not mounted as the FAT32 ESP" "display with one failing section"
expect_output "All tracked files signed" "display with one failing section"

printf 'status tests passed\n'
