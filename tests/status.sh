#!/bin/bash
# shellcheck disable=SC2034,SC2154,SC2329 # Stubs set the globals the sections read.
# Hermetic checks for the status sections: each section reports its own
# verdict from stubbed collaborators, and the aggregate retains failures and
# incomplete observations through its concluding verdict.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init status

# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"

REAL_LIST_ENROLLED_PATHS=$(declare -f list_enrolled_paths)
REAL_LIST_STALE_SBCTL_ENTRIES=$(declare -f list_stale_sbctl_entries)

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

DIRECT_MODE_RC=0
DIRECT_SETUP_MODE=0
DIRECT_SECURE_BOOT=1
# Mode decoding is exercised by enrollment's real efivar fixtures. This
# section must independently honor a failed read or disagreement with sbctl.
read_current_firmware_modes() {
  [[ "$DIRECT_MODE_RC" == 0 ]] || return "$DIRECT_MODE_RC"
  _setup_mode=$DIRECT_SETUP_MODE
  _secure_boot_mode=$DIRECT_SECURE_BOOT
}
good_json='{"installed":true,"setup_mode":false,"secure_boot":true,"vendors":["microsoft"]}'
run_section show_firmware_status "$good_json"
expect_status 0 "healthy firmware"
expect_output "sbctl keys installed" "healthy firmware"
expect_output "Secure Boot enabled" "healthy firmware"
expect_output "Setup Mode disabled" "healthy firmware"
expect_output "Vendor keys: microsoft" "healthy firmware"

DIRECT_SETUP_MODE=1
DIRECT_SECURE_BOOT=0
run_section show_firmware_status '{"installed":false,"setup_mode":true,"secure_boot":false}'
expect_status 1 "unprovisioned firmware"
expect_output "sbctl keys not installed" "unprovisioned firmware"
expect_output "Secure Boot disabled" "unprovisioned firmware"
expect_output "Setup Mode active" "unprovisioned firmware"
expect_no_output "status unknown" "genuine false firmware values"
DIRECT_SETUP_MODE=0
DIRECT_SECURE_BOOT=1
DIRECT_MODE_RC=1
run_section show_firmware_status "$good_json"
expect_status 1 "unreadable direct firmware modes"
expect_output "direct firmware modes could not be verified" "unreadable direct firmware modes"
expect_no_output "Secure Boot enabled" "unreadable direct firmware modes"
DIRECT_MODE_RC=0
DIRECT_SETUP_MODE=1
run_section show_firmware_status "$good_json"
expect_status 1 "sbctl default conceals a changed setup mode"
expect_output "Firmware mode observations disagree" "changed direct firmware mode"
expect_no_output "Setup Mode disabled" "changed direct firmware mode"
DIRECT_SETUP_MODE=0

sbctl() { printf 'raw sbctl status\n'; }
run_section show_firmware_status ""
expect_status 1 "unavailable firmware JSON"
expect_output "Firmware and key status unknown" "unavailable firmware JSON"
expect_no_output "raw sbctl status" "unavailable firmware JSON"

for bad_json in null '{}' '[]' true 'not JSON' \
  "${good_json}"$'\n'"${good_json}" "${good_json}"$'\n''not JSON'; do
  run_section show_firmware_status "$bad_json"
  expect_status 1 "invalid firmware JSON (${bad_json})"
  expect_output "Firmware and key status unknown" "invalid firmware JSON"
  expect_no_output "sbctl keys installed" "invalid firmware JSON"
  expect_no_output "Secure Boot enabled" "invalid firmware JSON"
  expect_no_output "Setup Mode disabled" "invalid firmware JSON"
done
for field in installed setup_mode secure_boot; do
  for bad_value in '"true"' '"false"' 0 1 null '[]' '{}'; do
    bad_json=$(jq --arg field "$field" --argjson value "$bad_value" \
      '.[$field] = $value' <<< "$good_json")
    run_section show_firmware_status "$bad_json"
    expect_status 1 "wrong-typed firmware ${field} (${bad_value})"
    expect_output "Firmware and key status unknown" "wrong-typed firmware field"
    expect_no_output "Setup Mode disabled" "wrong-typed firmware field"
  done
  bad_json=$(jq --arg field "$field" 'del(.[$field])' <<< "$good_json")
  run_section show_firmware_status "$bad_json"
  expect_status 1 "missing firmware ${field}"
done
run_section show_firmware_status "$good_json" 7
expect_status 1 "failed query with valid-looking output"
expect_output "sbctl status --json failed" "failed query with valid-looking output"
expect_no_output "Secure Boot enabled" "failed query with valid-looking output"
run_section without_tools show_firmware_status "$good_json"
expect_status 1 "unavailable JSON parser"
expect_output "Firmware and key status unknown" "unavailable JSON parser"

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
expect_status 1 "ESP without mount tools"
expect_output "mountpoint/findmnt unavailable" "ESP without mount tools"

# Test each required tool independently, retaining the real section and a
# positive mount collaborator that must not override unavailable tools.
with_missing_tool() (
  local missing="$1"
  shift
  command() {
    [[ "$*" != "-v ${missing}" ]] || return 1
    builtin command "$@"
  }
  "$@"
)
esp_is_mounted_vfat() { return 0; }
for missing_tool in mountpoint findmnt; do
  run_section with_missing_tool "$missing_tool" show_esp_status
  expect_status 1 "ESP without ${missing_tool}"
  expect_no_output "mounted as vfat" "ESP without ${missing_tool}"
done

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

# Failures are independent from empty enumerations and from Secure Boot's
# state. Partial output from a failed collaborator is never accepted either.
with_failed_path_enumeration() (
  local mode="$1" output="$2"
  shift 2
  list_limine_entry_paths() {
    [[ "$1" != "$mode" ]] || { printf '%s' "$output"; return 2; }
  }
  "$@"
)
for secure_state in true false unknown; do
  for mode in unhashed hashed; do
    for partial in '' '3: path: boot():/partial.efi'; do
      run_section with_failed_path_enumeration "$mode" "$partial" \
        show_limine_config_status "$secure_state"
      expect_status 1 "failed ${mode} enumeration (${secure_state})"
      expect_output "Could not enumerate ${mode} Limine paths" "failed path enumeration"
      expect_no_output "Limine path hashes match their files" "failed path enumeration"
      if [[ "$mode" == unhashed ]]; then
        expect_no_output "path-hash readiness passed" "failed unhashed enumeration"
      fi
    done
  done
done

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
with_failed_path_verification() (
  list_stale_limine_path_hashes() { return 2; }
  "$@"
)
for secure_state in true false unknown; do
  run_section with_failed_path_verification show_limine_config_status "$secure_state"
  expect_status 1 "unreadable path hashes (${secure_state})"
  expect_output "Could not verify Limine path hashes against their files" "unreadable path hashes"
  expect_no_output "Limine path hashes are stale" "unreadable path hashes"
  expect_no_output "Limine path hashes match" "unreadable path hashes"
done
stale_hash=$(printf 'f%.0s' {1..128})
write_config '/Omarchy' '    protocol: efi' "    path: boot():/EFI/Linux/arch.efi#${stale_hash}"
run_section show_limine_config_status true
expect_status 1 "stale path hash under Secure Boot"
expect_output "Limine path hashes are stale; Limine refuses these entries with Secure Boot on" \
  "stale path hash under Secure Boot"
expect_output "path: boot():/EFI/Linux/arch.efi#${stale_hash}" "stale path hash under Secure Boot"
expect_output "For the current OS entry, run sudo limine-mkinitcpio" "stale path hash under Secure Boot"
expect_output "A normal snapshot sync does not repair historical hashes" "historical hash remedy"
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

# Exercise the real inventory parser, selector, full-identity matcher, and
# status section. Only the inventory read and durable-record read are stubbed.
make_status_file_node() {
  local path="$1" index value length result
  local LC_ALL=C
  length=$((4 + (${#path} + 1) * 2))
  printf -v result '04 04 %02x %02x' "$((length & 255))" "$((length >> 8))"
  for ((index=0; index < ${#path}; index++)); do
    printf -v value '%02x' "'${path:$index:1}"
    result+=" ${value} 00"
  done
  printf '%s 00 00\n' "$result"
}
STATUS_HD_NODE='04 01 2a 00 01 00 00 00 00 08 00 00 00 00 00 00 00 00 10 00 00 00 00 00 33 22 11 00 55 44 77 66 88 99 aa bb cc dd ee ff 02 02'
STATUS_WINDOWS_NODE=$(make_status_file_node "$WINDOWS_LOADER_UEFI")
STATUS_LINUX_NODE=$(make_status_file_node '\EFI\Linux\omarchy.efi')
WINDOWS_INVENTORY=""
WINDOWS_INVENTORY_RC=0
efibootmgr() { fail_test "unexpected efibootmgr call in status suite: $*"; }
WINDOWS_NUMBER=0001
WINDOWS_LABEL=Windows
WINDOWS_HD_NODE="$STATUS_HD_NODE"
WINDOWS_RECORD=false
RECORDED_NUMBER=0001
RECORDED_LABEL=Windows
RECORDED_PARTUUID=00112233-4455-6677-8899-aabbccddeeff
RECORDED_LOADER="$WINDOWS_LOADER_UEFI"
windows_read_firmware_inventory() {
  if [[ "$WINDOWS_INVENTORY_RC" != 0 ]]; then
    windows_reject "Could not read EFI boot entries"
    return 1
  fi
  _windows_inventory_raw="$WINDOWS_INVENTORY"
}
set_windows_inventory() {
  if [[ "${1:-present}" == absent ]]; then
    WINDOWS_INVENTORY=$(printf 'BootOrder: 000A\nBoot000A* Omarchy\tHD/File(\\EFI\\Linux\\omarchy.efi)\n      dp: %s / %s / 7f ff 04 00\n' \
      "$STATUS_HD_NODE" "$STATUS_LINUX_NODE")
  else
    WINDOWS_INVENTORY=$(printf 'BootOrder: %s\nBoot%s* %s\tHD/File(%s)\n      dp: %s / %s / 7f ff 04 00\n' \
      "$WINDOWS_NUMBER" "$WINDOWS_NUMBER" "$WINDOWS_LABEL" "$WINDOWS_LOADER_UEFI" \
      "$WINDOWS_HD_NODE" "$STATUS_WINDOWS_NODE")
  fi
}
read_windows_target_state() {
  [[ "$WINDOWS_RECORD" == true ]] || return 1
  _windows_state_label="$RECORDED_LABEL"
  _windows_state_boot_number="$RECORDED_NUMBER"
  _windows_state_partuuid="$RECORDED_PARTUUID"
  _windows_state_loader_path="$RECORDED_LOADER"
}
set_windows_inventory absent
write_config 'timeout: 5'
run_section show_windows_status
expect_status 0 "no Windows"
expect_output "No Windows Boot Manager found" "no Windows"
expect_output "No managed Windows firmware handoff configured" "no Windows"
expect_output "Omarchy Direct Boot firmware entry enabled" "direct Linux entry"

set_windows_inventory
WINDOWS_INVENTORY+=$(printf '\nBoot0002* Other Windows\tHD/File(%s)\n      dp: %s / %s / 7f ff 04 00\n' \
  "$WINDOWS_LOADER_UEFI" "$STATUS_HD_NODE" "$STATUS_WINDOWS_NODE")
run_section show_windows_status
expect_status 1 "ambiguous Windows target"
expect_output "do not resolve to one safe handoff target" "ambiguous Windows target"
expect_no_output "No Windows Boot Manager found" "ambiguous Windows target"

# A failed or malformed inventory is unknown even when there is no opt-in.
set_windows_inventory absent
WINDOWS_INVENTORY_RC=1
run_section show_windows_status
expect_status 1 "unreadable Windows inventory without record"
expect_output "Windows firmware inventory is unverified" "unreadable Windows inventory"
expect_no_output "No Windows Boot Manager found" "unreadable Windows inventory"
WINDOWS_INVENTORY_RC=0
WINDOWS_INVENTORY='BootOrder: 0001'
run_section show_windows_status
expect_status 1 "malformed Windows inventory"
expect_output "Windows firmware inventory is unverified" "malformed Windows inventory"
expect_no_output "No Windows Boot Manager found" "malformed Windows inventory"

set_windows_inventory
write_config '/Windows' '    protocol: efi' '    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi'
run_section show_windows_status
expect_status 0 "unmanaged chainload"
expect_output "Unique active Windows firmware handoff target" "unmanaged chainload"
expect_output "may trigger BitLocker" "unmanaged chainload"
expect_output "Run sudo omasecboot windows setup" "unmanaged chainload"
expect_output "remove the chainload entry from limine.conf yourself" "unmanaged chainload"

WINDOWS_RECORD=true
windows_managed_block_state() { _windows_block_state=canonical; }
run_section show_windows_status
expect_status 0 "managed handoff"
expect_output "Durable Windows firmware target identity recorded" "managed handoff"
expect_output "Windows boot entry in limine.conf (firmware BootNext)" "managed handoff"
expect_output "Use the recorded firmware handoff" "managed handoff with native chainload"

# A recorded target that firmware no longer resolves to is a failure, not a
# green line next to a stale record. Retargeting via setup is unsupported.
WINDOWS_NUMBER=0002
set_windows_inventory
run_section show_windows_status
expect_status 1 "stale recorded target"
expect_output "Recorded Windows target identity is stale (recorded Boot0001, resolved Boot0002)" "stale recorded target"
expect_no_output "Run sudo omasecboot windows setup" "stale recorded target"
expect_no_output "run sudo omasecboot windows setup again" "stale recorded target"
WINDOWS_NUMBER=0001
WINDOWS_LABEL='Other Windows'
set_windows_inventory
run_section show_windows_status
expect_status 1 "changed Windows label"
expect_output "Recorded Windows target identity is stale" "changed Windows label"
WINDOWS_LABEL=Windows
WINDOWS_HD_NODE=${STATUS_HD_NODE/33 22 11 00/44 22 11 00}
set_windows_inventory
run_section show_windows_status
expect_status 1 "same number and label on a different PARTUUID"
expect_output "Recorded Windows target identity is stale (recorded Boot0001, resolved Boot0001)" \
  "changed Windows PARTUUID"
expect_no_output "Run sudo omasecboot windows setup" "changed Windows PARTUUID"
WINDOWS_HD_NODE="$STATUS_HD_NODE"
set_windows_inventory
RECORDED_LOADER='\EFI\Other\bootmgfw.efi'
run_section show_windows_status
expect_status 1 "changed recorded loader path"
expect_output "Recorded Windows target identity is stale" "changed recorded loader path"
RECORDED_LOADER="$WINDOWS_LOADER_UEFI"

set_windows_inventory absent
run_section show_windows_status
expect_status 1 "absent recorded Windows target"
expect_output "Recorded Windows target Boot0001 is absent from the firmware inventory" "absent recorded Windows target"
expect_no_output "Run sudo omasecboot windows setup" "absent recorded Windows target"
WINDOWS_INVENTORY_RC=1
run_section show_windows_status
expect_status 1 "unreadable inventory with recorded Windows target"
expect_output "Windows firmware inventory is unverified" "unreadable recorded Windows target"
expect_output "could not be verified against a unique firmware target" "unreadable recorded Windows target"
expect_no_output "is absent from the firmware inventory" "unreadable recorded Windows target"
WINDOWS_INVENTORY_RC=0
set_windows_inventory
write_config 'timeout: 5'
run_section show_windows_status
expect_status 0 "restored matching Windows identity"

windows_managed_block_state() { _windows_block_state=absent; }
run_section show_windows_status
expect_status 1 "suppressed handoff"
expect_output "managed entry is suppressed" "suppressed handoff"

windows_managed_block_state() { return 1; }
run_section show_windows_status
expect_status 1 "malformed block"
expect_output "malformed or mismatched" "malformed block"

WINDOWS_RECORD=false
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
expect_status 1 "unprivileged tracked files"
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

saved_enrolled=$ENROLLED
ENROLLED='/fixture/EFI/Tools/literal\new\033[31m.efi'
DISCOVERED=$ENROLLED
run_section show_tracked_files_status
expect_status 0 "literal tracked pathname"
expect_output "$ENROLLED" "literal tracked pathname"
expect_no_output $'\033' "literal tracked pathname"
ENROLLED=$saved_enrolled
DISCOVERED=$ENROLLED

with_failed_stale_tracking() (
  list_stale_sbctl_entries() { return 2; }
  "$@"
)
run_section with_failed_stale_tracking show_tracked_files_status
expect_status 1 "stale lookup failure with successful CLI list"
expect_output "Could not check stale sbctl tracking entries" "stale lookup failure"
expect_no_output "All tracked files signed" "stale lookup failure"

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

STATUS_QUERY_JSON="$good_json"
STATUS_QUERY_RC=0
STATUS_LIFECYCLE_STATE=active
STATUS_LIFECYCLE_READ_OK=true
sbctl() {
  case "$*" in
    'status --json') printf '%s\n' "$STATUS_QUERY_JSON"; return "$STATUS_QUERY_RC" ;;
    status) printf 'raw sbctl status\n' ;;
    *) return 1 ;;
  esac
}
read_lifecycle() {
  _lifecycle_state="$STATUS_LIFECYCLE_STATE"
  [[ "$STATUS_LIFECYCLE_READ_OK" == true ]]
}
# Match cmd_status's ordering with real sections, without its live dependency
# preflight. The lifecycle verdict must survive into the final summary.
status_display() {
  show_lifecycle_status || :
  show_status
}
expect_conclusion() {
  [[ "${section_output##*$'\n'}" == *"$1"* ]] \
    || fail_test "$2 ended without '$1': ${section_output}"
}
expect_incomplete_display() {
  expect_status 1 "$1"
  expect_conclusion "Status verification failed or incomplete" "$1"
  expect_no_output "Status verification passed" "$1"
}
install_hooks
esp_is_mounted_vfat() { return 0; }
write_defaults 'ENABLE_VERIFICATION=no' 'ENABLE_ENROLL_LIMINE_CONFIG=yes'
VERIFY_OK=true
run_section status_display
expect_status 0 "healthy display"
expect_output "Secure Boot Status" "healthy display"
expect_output "Tracked Files" "healthy display"
expect_conclusion "Status verification passed" "healthy display"

esp_is_mounted_vfat() { return 1; }
run_section status_display
expect_incomplete_display "display with one failing section"
expect_output "is not mounted as the FAT32 ESP" "display with one failing section"
expect_output "All tracked files signed" "display with one failing section"
esp_is_mounted_vfat() { return 0; }

for bad_json in '' null '{}' 'not JSON' \
  '{"installed":"true","setup_mode":false,"secure_boot":true}' \
  '{"installed":true,"setup_mode":"false","secure_boot":true}' \
  '{"installed":true,"setup_mode":false,"secure_boot":"true"}'; do
  STATUS_QUERY_JSON="$bad_json"
  run_section status_display
  expect_incomplete_display "display with invalid firmware JSON"
  expect_output "Firmware and key status unknown" "invalid firmware display"
  expect_output "All tracked files signed" "invalid firmware display"
  expect_no_output "Secure Boot enabled" "invalid firmware display"
  expect_no_output "Setup Mode disabled" "invalid firmware display"
done
STATUS_QUERY_JSON="$good_json"
STATUS_QUERY_RC=7
run_section status_display
expect_incomplete_display "failed query with valid JSON display"
expect_output "sbctl status --json failed" "failed firmware query display"
expect_no_output "Secure Boot enabled" "failed firmware query display"
expect_no_output "raw sbctl status" "failed firmware query display"
# Query failure must also leave the enforcement state unknown for consumers.
write_config '/Omarchy' '    protocol: efi' "    path: boot():/EFI/Linux/arch.efi#${stale_hash}"
run_section status_display
expect_incomplete_display "failed query with stale hash display"
expect_output "Secure Boot enforcement state is unknown" "failed query enforcement state"
expect_no_output "stops at a hash prompt" "failed query enforcement state"
# Valid JSON alone cannot supply a mode when direct readback failed or
# disagreed. A genuine, directly observed off state retains its own message.
STATUS_QUERY_RC=0
STATUS_QUERY_JSON=$(jq '.secure_boot = false' <<< "$good_json")
for DIRECT_MODE_RC in 1 0; do
  run_section status_display
  expect_incomplete_display "unverified direct modes (${DIRECT_MODE_RC})"
  expect_output "Secure Boot enforcement state is unknown" "unverified direct enforcement state"
  expect_no_output "stops at a hash prompt" "unverified direct enforcement state"
done
DIRECT_SECURE_BOOT=0
run_section status_display
expect_incomplete_display "directly observed Secure Boot off"
expect_output "Secure Boot disabled" "directly observed Secure Boot off"
expect_output "stops at a hash prompt" "directly observed off enforcement state"
expect_no_output "Secure Boot enforcement state is unknown" "directly observed off enforcement state"
DIRECT_SECURE_BOOT=1
write_config 'timeout: 5'
STATUS_QUERY_JSON=""
STATUS_QUERY_RC=127
run_section status_display
expect_incomplete_display "unavailable sbctl display"
expect_output "sbctl status --json failed" "unavailable sbctl display"
STATUS_QUERY_JSON="$good_json"
STATUS_QUERY_RC=0

for missing_tool in mountpoint findmnt; do
  run_section with_missing_tool "$missing_tool" status_display
  expect_incomplete_display "display without ${missing_tool}"
  expect_output "mountpoint/findmnt unavailable" "missing mount tool display"
done
for mode in unhashed hashed; do
  run_section with_failed_path_enumeration "$mode" '' status_display
  expect_incomplete_display "display with failed ${mode} enumeration"
  expect_output "Could not enumerate ${mode} Limine paths" "failed enumeration display"
done
write_config '/Omarchy' '    protocol: efi' "    path: boot():/EFI/Linux/arch.efi#${good_hash}"
run_section with_failed_path_verification status_display
expect_incomplete_display "display with failed hash verification"
expect_output "Could not verify Limine path hashes against their files" "failed hash verification display"
write_config 'timeout: 5'
run_section with_failed_stale_tracking status_display
expect_incomplete_display "display with failed stale tracking lookup"
expect_output "Could not check stale sbctl tracking entries" "failed stale tracking display"

WINDOWS_INVENTORY_RC=1
run_section status_display
expect_incomplete_display "display with unreadable Windows inventory"
expect_output "Windows firmware inventory is unverified" "unreadable Windows display"
WINDOWS_INVENTORY_RC=0
WINDOWS_RECORD=true
windows_managed_block_state() { _windows_block_state=canonical; }
WINDOWS_HD_NODE=${STATUS_HD_NODE/33 22 11 00/44 22 11 00}
set_windows_inventory
run_section status_display
expect_incomplete_display "display with changed Windows PARTUUID"
expect_output "Recorded Windows target identity is stale" "changed Windows PARTUUID display"
expect_output "All tracked files signed" "changed Windows PARTUUID display"
set_windows_inventory absent
run_section status_display
expect_incomplete_display "display with absent recorded Windows target"
expect_output "is absent from the firmware inventory" "absent Windows target display"
WINDOWS_HD_NODE="$STATUS_HD_NODE"
set_windows_inventory
run_section status_display
expect_status 0 "display with matching Windows identity"
expect_conclusion "Status verification passed" "matching Windows identity display"
WINDOWS_RECORD=false

control_owner_uid() { printf '%s\n' "$((EUID + 1))"; }
run_section status_display
expect_incomplete_display "display without file verification privileges"
expect_output "Run as root for file verification" "unprivileged display"
control_owner_uid() { id -u; }
for state in unmanaged recovery-required; do
  STATUS_LIFECYCLE_STATE="$state"
  run_section status_display
  expect_incomplete_display "display with lifecycle ${state}"
  expect_output "All tracked files signed" "unhealthy lifecycle display"
done
STATUS_LIFECYCLE_STATE=active
STATUS_LIFECYCLE_READ_OK=false
run_section status_display
expect_incomplete_display "display with unreadable lifecycle"
expect_output "Lifecycle state is invalid or unsafe" "unreadable lifecycle display"
STATUS_LIFECYCLE_READ_OK=true
run_section status_display
expect_status 0 "restored healthy display"
expect_conclusion "Status verification passed" "restored healthy display"

# Keep the real CLI/database readers, merger and stale enumerator. A valid
# CLI subset must not conceal a failed complete database observation.
with_real_tracking_observation() (
  local scenario="$1" data_dir fixture_db image missing cli_json
  shift
  data_dir="${TEST_DIR}/tracking-${scenario}/data"
  fixture_db="${data_dir}/files.json"
  image="${ESP_DIR}/EFI/Linux/observed.efi"
  missing="${ESP_DIR}/EFI/Linux/missing.efi"
  mkdir -p "$data_dir" "$(dirname "$image")"
  # Replace the inherited harness trap only in this fixture subshell.
  trap 'chmod 700 -- "$data_dir" 2>/dev/null || :' EXIT
  printf 'fixture image\n' > "$image"
  jq -cn --arg file "$image" '{($file): {file: $file, output_file: $file}}' > "$fixture_db"
  cli_json=$(jq -cn --arg file "$image" '[{file: $file, output_file: $file, is_signed: true}]')
  eval "$REAL_LIST_ENROLLED_PATHS"
  eval "$REAL_LIST_STALE_SBCTL_ENTRIES"
  resolve_sbctl_files_db_path() { printf '%s\n' "$fixture_db"; }
  sbctl() {
    case "$*" in
      'list-files --json') printf '%s\n' "$cli_json" ;;
      'status --json') printf '%s\n' "$STATUS_QUERY_JSON"; return "$STATUS_QUERY_RC" ;;
      *) fail_test "unexpected sbctl call in tracking observation: $*" ;;
    esac
  }
  discover_efi_files() { printf '%s\n' "$image"; }
  case "$scenario" in
    valid) ;;
    mismatched-row|stale-row)
      local stored_file="$missing"
      [[ "$scenario" != mismatched-row ]] || stored_file="${missing}.different"
      jq --arg key "$missing" --arg file "$stored_file" \
        '. + {($key): {file: $file, output_file: $key}}' "$fixture_db" > "${fixture_db}.new"
      mv "${fixture_db}.new" "$fixture_db"
      ;;
    malformed) printf '{\n' > "$fixture_db" ;;
    unreadable) chmod 000 "$fixture_db" ;;
    absent|absent-parent)
      rm "$fixture_db"
      [[ "$scenario" != absent-parent ]] || rmdir "$data_dir"
      discover_efi_files() { :; }
      ;;
    unsearchable-parent) chmod 000 "$data_dir" ;;
    *) fail_test "unknown tracking scenario: ${scenario}" ;;
  esac
  "$@"
)
run_section with_real_tracking_observation valid status_display
expect_status 0 "complete real tracking observation"
expect_conclusion "Status verification passed" "complete real tracking observation"
for scenario in mismatched-row malformed unreadable unsearchable-parent; do
  run_section with_real_tracking_observation "$scenario" status_display
  expect_incomplete_display "failed database observation (${scenario})"
  expect_output "Could not check stale sbctl tracking entries" "failed real database observation"
  expect_no_output "All tracked files signed" "failed real database observation"
done
run_section with_real_tracking_observation stale-row status_display
expect_incomplete_display "missing output omitted from CLI"
expect_output "Stale sbctl tracked files found" "complete database stale observation"
for scenario in absent absent-parent; do
  run_section with_real_tracking_observation "$scenario" show_tracked_files_status
  expect_status 0 "observed absent tracking store (${scenario})"
  expect_output "No files in sbctl database" "observed absent tracking store"
  expect_no_output "Could not check stale sbctl tracking entries" "observed absent tracking store"
done
run_section with_real_tracking_observation mismatched-row list_stale_sbctl_entries
expect_status 0 "cleanup retains its optional database fallback"

printf 'status tests passed\n'
