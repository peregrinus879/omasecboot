#!/bin/bash
# shellcheck disable=SC2154,SC2329 # Tests inspect globals and sourced overrides.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-windows.XXXXXX")
BIN_DIR="${TEST_DIR}/bin"
EFI_FIXTURE="${TEST_DIR}/efibootmgr.out"
EFI_ERROR_FIXTURE="${TEST_DIR}/efibootmgr.err"
LSBLK_FIXTURE="${TEST_DIR}/lsblk.json"
FINDMNT_FIXTURE="${TEST_DIR}/findmnt.json"
FINDMNT_REPLACEMENT_FIXTURE="${TEST_DIR}/findmnt-replacement.json"
FINDMNT_CALL_COUNT="${TEST_DIR}/findmnt-calls"
CALL_LOG="${TEST_DIR}/calls.log"
MOUNT_MARKER="${TEST_DIR}/owned-mounted"
LOADER_SOURCE="${TEST_DIR}/bootmgfw.efi"
EXISTING_ESP="${TEST_DIR}/existing-esp"
RUNTIME_PARENT="${TEST_DIR}/run"
ORIGINAL_PATH=$PATH

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$BIN_DIR" "${EXISTING_ESP}/EFI/Microsoft/Boot" "$RUNTIME_PARENT"
TEST_MOUNT_ID=$(/usr/bin/findmnt -n -T "$TEST_DIR" -o ID)
[[ "$TEST_MOUNT_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail_test "could not determine the test filesystem mount ID"
: > "$CALL_LOG"
{
  printf 'MZ'
  dd if=/dev/zero bs=1 count=62 status=none
} > "$LOADER_SOURCE"
cp "$LOADER_SOURCE" "${EXISTING_ESP}/EFI/Microsoft/Boot/bootmgfw.efi"
TEST_MAJ_MIN=$(stat -Lc '%Hd:%Ld' "$LOADER_SOURCE")
: > "$FINDMNT_CALL_COUNT"
: > "$EFI_ERROR_FIXTURE"

cat > "${BIN_DIR}/efibootmgr" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $# -eq 1 && "$1" == -v ]] || {
  printf 'forbidden:efibootmgr:%s\n' "$*" >> "$CALL_LOG"
  exit 2
}
[[ ! -s "$EFI_ERROR_FIXTURE" ]] || cat "$EFI_ERROR_FIXTURE" >&2
cat "$EFI_FIXTURE"
EOF

cat > "${BIN_DIR}/lsblk" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$*" == '--json --bytes --paths --list --output PATH,MAJ:MIN,TYPE,PARTN,PARTUUID,PARTTYPE,START,SIZE,LOG-SEC,FSTYPE' ]] || {
  printf 'unexpected lsblk arguments: %s\n' "$*" >&2
  exit 2
}
cat "$LSBLK_FIXTURE"
EOF

cat > "${BIN_DIR}/findmnt" <<'EOF'
#!/bin/bash
set -euo pipefail
target="" query="" previous="" columns="" fixture="" result="" calls=""
for argument in "$@"; do
  if [[ "$previous" == --mountpoint ]]; then
    target="$argument"
    query=mountpoint
  elif [[ "$previous" == --target ]]; then
    target="$argument"
    query=target
  elif [[ "$previous" == --output ]]; then
    columns="$argument"
  fi
  previous="$argument"
done
if [[ "$query" == target ]]; then
  printf 'forbidden:findmnt-target:%s\n' "$target" >> "$CALL_LOG"
  exit 2
fi
if [[ "$query" == mountpoint ]]; then
  calls=$(< "$FINDMNT_CALL_COUNT")
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$FINDMNT_CALL_COUNT"
  if [[ -e "$MOUNT_MARKER" ]]; then
    [[ -z "$columns" || "$columns" == 'TARGET,MAJ:MIN,FSTYPE,FSROOT' ]] || exit 2
    jq -cn --arg target "$target" --arg maj "$MOUNT_MARKER_MAJ_MIN" '{
      filesystems: [{target: $target, "maj:min": $maj, fstype: "vfat", fsroot: "/"}]
    }'
    exit 0
  fi
  fixture="$FINDMNT_FIXTURE"
  if (( FINDMNT_REPLACE_AT > 0 && calls >= FINDMNT_REPLACE_AT )) \
    && [[ -f "$FINDMNT_REPLACEMENT_FIXTURE" ]]; then
    fixture="$FINDMNT_REPLACEMENT_FIXTURE"
  fi
  result=$(jq -c --arg target "$target" \
    '{filesystems: [.filesystems[] | select(.target == $target)]}' "$fixture")
  jq -e '.filesystems | length == 1' <<< "$result" >/dev/null || exit 1
  if [[ "$columns" == TARGET ]]; then
    jq -c '{filesystems: [.filesystems[] | {target}]}' <<< "$result"
  else
    [[ -z "$columns" || "$columns" == 'TARGET,MAJ:MIN,FSTYPE,FSROOT' ]] || exit 2
    printf '%s\n' "$result"
  fi
  exit 0
fi
[[ "$columns" == 'TARGET,MAJ:MIN,FSTYPE,FSROOT' ]] || exit 2
cat "$FINDMNT_FIXTURE"
EOF

cat > "${BIN_DIR}/mount" <<'EOF'
#!/bin/bash
set -euo pipefail
target=${!#}
printf 'mount:%s\n' "$*" >> "$CALL_LOG"
mkdir -p "${target}/EFI/Microsoft/Boot"
cp "$LOADER_SOURCE" "${target}/EFI/Microsoft/Boot/bootmgfw.efi"
: > "$MOUNT_MARKER"
if [[ "$MOUNT_SIGNAL" == true ]]; then
  kill -TERM "$PPID"
fi
EOF

cat > "${BIN_DIR}/umount" <<'EOF'
#!/bin/bash
set -euo pipefail
target=${!#}
printf 'umount:%s\n' "$*" >> "$CALL_LOG"
rm -rf "${target}/EFI"
rm -f "$MOUNT_MARKER"
chmod 700 "$target"
EOF

cat > "${BIN_DIR}/gum" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "${BIN_DIR}/efibootmgr" "${BIN_DIR}/lsblk" \
  "${BIN_DIR}/findmnt" "${BIN_DIR}/mount" "${BIN_DIR}/umount" \
  "${BIN_DIR}/gum"
export EFI_FIXTURE EFI_ERROR_FIXTURE LSBLK_FIXTURE FINDMNT_FIXTURE
export FINDMNT_REPLACEMENT_FIXTURE
export FINDMNT_CALL_COUNT CALL_LOG MOUNT_MARKER LOADER_SOURCE TEST_MAJ_MIN
export TEST_MOUNT_ID
export FINDMNT_REPLACE_AT=0
export MOUNT_SIGNAL=false
export MOUNT_MARKER_MAJ_MIN="$TEST_MAJ_MIN"
export RUNTIME_PARENT EXISTING_ESP
PATH="${BIN_DIR}:${ORIGINAL_PATH}"
export PATH

# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"

# The efibootmgr boundary binds the open executable and records the installed
# package; anything below the supported floor or owned by another package is
# refused. The package facts are stubbed so the case never depends on the host.
test_efibootmgr_boundary() (
  local executable
  executable=$(windows_efibootmgr_executable_path)
  producer_file_owner_package() {
    [[ "$1" == "$executable" ]] || return 1
    printf 'efibootmgr\n'
  }
  (
    producer_package_version() { printf '17-1\n'; }
    if validate_windows_efibootmgr_boundary >/dev/null 2>&1; then
      fail_test "the efibootmgr boundary accepted a version below the floor"
    fi
  ) || exit 1
  (
    producer_package_version() { printf '18-4\n'; }
    producer_file_owner_package() { printf 'not-efibootmgr\n'; }
    if validate_windows_efibootmgr_boundary >/dev/null 2>&1; then
      fail_test "the efibootmgr boundary accepted a foreign-owned executable"
    fi
  ) || exit 1
  producer_package_version() { printf '18-4\n'; }
  validate_windows_efibootmgr_boundary \
    || fail_test "could not validate the supported efibootmgr executable"
  [[ "$_windows_efibootmgr_package" == "efibootmgr 18-4" ]] \
    || fail_test "the boundary recorded the wrong efibootmgr package"
  [[ $(hash_bound_windows_efibootmgr) == "$(sha256_file "$executable")" ]] \
    || fail_test "the open efibootmgr executable hash changed"
  run_windows_efibootmgr --version >/dev/null \
    || fail_test "could not execute the bound efibootmgr inode"
  close_windows_efibootmgr_boundary
)

test_efibootmgr_boundary

if windows_block_device_matches "$LOADER_SOURCE" "$TEST_MAJ_MIN"; then
  fail_test "regular file was accepted as the mapped ESP block device"
fi
ln -s "$LOADER_SOURCE" "${TEST_DIR}/device-link"
if windows_block_device_matches "${TEST_DIR}/device-link" "$TEST_MAJ_MIN"; then
  fail_test "symlink was accepted as the mapped ESP block device"
fi

control_owner_uid() {
  id -u
}

state_dir_path() {
  printf '%s/state\n' "$TEST_DIR"
}
mkdir -p "$(state_dir_path)"
chmod 755 "$(state_dir_path)"

write_windows_target_state_fixture() {
  local boot_number="${1:-0007}"
  jq -cn --arg version "$OMASECBOOT_VERSION" --arg boot_number "$boot_number" \
    --arg loader "$WINDOWS_LOADER_UEFI" '{
      schema_version: 1, writer_version: $version, enabled: true,
      boot_number: $boot_number, label: "Windows Boot Manager",
      partuuid: "00112233-4455-6677-8899-aabbccddeeff", loader_path: $loader
    }' > "$(windows_target_state_path)"
  chmod 644 "$(windows_target_state_path)"
}

windows_efibootmgr_executable_path() {
  printf '%s/efibootmgr\n' "$BIN_DIR"
}

windows_runtime_dir_path() {
  printf '%s/omasecboot\n' "$RUNTIME_PARENT"
}

windows_block_device_matches() {
  [[ "$WINDOWS_BLOCK_DEVICE_MATCH" == true \
    && "$1" == /dev/windows-esp && "$2" == "$TEST_MAJ_MIN" ]]
}

durable_sync() {
  :
}

_OMASECBOOT_LIMINE_LOCK_OWNED=local
_OMASECBOOT_REPAIR_LOCK_OWNED=true
WINDOWS_BLOCK_DEVICE_MATCH=true

make_file_node() {
  local path="$1" index character value low high length result
  local LC_ALL=C
  length=$((4 + (${#path} + 1) * 2))
  printf -v low '%02x' "$((length & 255))"
  printf -v high '%02x' "$((length >> 8))"
  result="04 04 ${low} ${high}"
  for ((index=0; index < ${#path}; index++)); do
    character=${path:$index:1}
    printf -v value '%02x' "'$character"
    result+=" ${value} 00"
  done
  result+=' 00 00'
  printf '%s\n' "$result"
}

make_odd_file_node() {
  local node="${1% ??}" length low high
  local -a bytes=()
  read -r -a bytes <<< "$node"
  length=${#bytes[@]}
  printf -v low '%02x' "$((length & 255))"
  printf -v high '%02x' "$((length >> 8))"
  bytes[2]="$low"
  bytes[3]="$high"
  printf '%s\n' "${bytes[*]}"
}

HD_NODE='04 01 2a 00 01 00 00 00 00 08 00 00 00 00 00 00 00 00 10 00 00 00 00 00 33 22 11 00 55 44 77 66 88 99 aa bb cc dd ee ff 02 02'
END_NODE='7f ff 04 00'
END_INSTANCE_NODE='7f 01 04 00'
WINDOWS_FILE_NODE=$(make_file_node '\EFI\Microsoft\Boot\bootmgfw.efi')
LINUX_FILE_NODE=$(make_file_node '\EFI\Linux\omarchy.efi')
TOOLS_FILE_NODE=$(make_file_node '\EFI\Tools\shell.efi')
EMBEDDED_NUL_FILE_NODE=${WINDOWS_FILE_NODE/5c 00/00 00}
MISSING_TERMINATOR_FILE_NODE="${WINDOWS_FILE_NODE% 00 00} 41 00"
ODD_FILE_NODE=$(make_odd_file_node "$WINDOWS_FILE_NODE")
WINDOWS_DP="${HD_NODE} / ${WINDOWS_FILE_NODE} / ${END_NODE}"
LINUX_DP="${HD_NODE} / ${LINUX_FILE_NODE} / ${END_NODE}"
TOOLS_DP="${HD_NODE} / ${TOOLS_FILE_NODE} / ${END_NODE}"
NVME_NODE='03 17 10 00 01 00 00 00 11 22 33 44 55 66 77 88'
PCI_NODE='01 01 06 00 03 14'
ACPI_NODE='02 01 0c 00 d0 41 03 0a 00 00 00 00'

begin_inventory() {
  printf 'BootOrder: %s\n' "$1" > "$EFI_FIXTURE"
}

add_entry() {
  local number="$1" active="$2" label="$3" device_path="$4"
  printf 'Boot%s%s %s\tformatted-path\n' "$number" "$active" "$label" \
    >> "$EFI_FIXTURE"
  printf '      dp: %s\n' "$device_path" >> "$EFI_FIXTURE"
}

write_good_inventory() {
  begin_inventory '0001,0007,0002'
  add_entry 0001 '*' Linux "$LINUX_DP"
  add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
  printf '    data: 42 43 44 4f 42 4a 45 43 54\n' >> "$EFI_FIXTURE"
  add_entry 0002 '*' 'UEFI Shell' "$TOOLS_DP"
}

write_good_lsblk() {
  jq -n --arg maj "$TEST_MAJ_MIN" '{
    blockdevices: [
      {
        path: "/dev/windows-disk",
        "maj:min": "259:0",
        type: "disk",
        partn: null,
        partuuid: null,
        parttype: null,
        start: 0,
        size: 1073741824,
        "log-sec": 512,
        fstype: null
      },
      {
        path: "/dev/windows-esp",
        "maj:min": $maj,
        type: "part",
        partn: 1,
        partuuid: "00112233-4455-6677-8899-aabbccddeeff",
        parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
        start: 2048,
        size: 536870912,
        "log-sec": 512,
        fstype: "vfat"
      },
      {
        path: "/dev/linux-esp",
        "maj:min": "259:2",
        type: "part",
        partn: 2,
        partuuid: "aaaabbbb-cccc-4ddd-8eee-ffff00001111",
        parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
        start: 1050624,
        size: 536870912,
        "log-sec": 512,
        fstype: "vfat"
      }
    ]
  }' > "$LSBLK_FIXTURE"
}

write_existing_mount() {
  local options="${1:-ro,relatime}" target="${2:-$EXISTING_ESP}"
  local maj_min="${3:-$TEST_MAJ_MIN}" destination="${4:-$FINDMNT_FIXTURE}"
  local mount_id="${5:-$TEST_MOUNT_ID}"
  jq -n --arg target "$target" --arg maj "$maj_min" --arg options "$options" \
    --argjson id "$mount_id" '{
    filesystems: [{
      target: $target,
      id: $id,
      "maj:min": $maj,
      fstype: "vfat",
      fsroot: "/",
      "vfs-options": $options
    }]
  }' > "$destination"
}

write_empty_mounts() {
  printf '{"filesystems":[]}\n' > "$FINDMNT_FIXTURE"
}

reset_findmnt_calls() {
  printf '0\n' > "$FINDMNT_CALL_COUNT"
  FINDMNT_REPLACE_AT=0
  export FINDMNT_REPLACE_AT
  rm -f "$FINDMNT_REPLACEMENT_FIXTURE"
}

expect_inventory_failure() {
  local description="$1"
  if find_windows_boot_entry > "${TEST_DIR}/unexpected.out" 2>&1; then
    fail_test "$description"
  fi
}

write_good_inventory
write_good_lsblk
write_existing_mount
reset_findmnt_calls

if cmd_windows available > "${TEST_DIR}/no-optin.out" 2>&1; then
  fail_test "available succeeded without the durable Windows opt-in"
fi
[[ ! -s "${TEST_DIR}/no-optin.out" ]] \
  || fail_test "available without the opt-in produced output"
write_windows_target_state_fixture 0001
if cmd_windows available > "${TEST_DIR}/stale-optin.out" 2>&1; then
  fail_test "available succeeded with an opt-in that no longer matches firmware"
fi
[[ ! -s "${TEST_DIR}/stale-optin.out" ]] \
  || fail_test "available with a stale opt-in produced output"
write_windows_target_state_fixture
available_output=$(cmd_windows available) || fail_test "available rejected the recorded structural target"
[[ -z "$available_output" ]] || fail_test "available produced output"
[[ $(find_windows_boot_entry) == $'0007\tWindows Boot Manager' ]] \
  || fail_test "structural target identity was parsed incorrectly"

had_tmpdir=false
if [[ -v TMPDIR ]]; then
  had_tmpdir=true
  saved_tmpdir=$TMPDIR
fi
TMPDIR="${TEST_DIR}/missing-tmpdir"
if cmd_windows available > "${TEST_DIR}/unavailable.out" 2>&1; then
  fail_test "available succeeded without a diagnostics directory"
fi
if [[ "$had_tmpdir" == true ]]; then
  TMPDIR=$saved_tmpdir
else
  unset TMPDIR
fi
[[ ! -s "${TEST_DIR}/unavailable.out" ]] \
  || fail_test "unavailable probe emitted command diagnostics"
rm -f "$(windows_target_state_path)"

begin_inventory '0001,0007,0002,0003,0004'
add_entry 0001 '*' Linux "$LINUX_DP"
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
add_entry 0002 '*' 'UEFI Shell' "$TOOLS_DP"
add_entry 0003 ' ' 'Description Only' ''
add_entry 0004 '*' 'End Only' "$END_NODE"
[[ $(find_windows_boot_entry) == $'0007\tWindows Boot Manager' ]] \
  || fail_test "legal non-target empty device paths poisoned target discovery"

begin_inventory '0001,0007,0002,0003'
add_entry 0001 '*' Linux "$LINUX_DP"
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
add_entry 0002 '*' 'UEFI Shell' "$TOOLS_DP"
add_entry 0003 '*' 'Multi Instance' \
  "${LINUX_DP% / *} / ${END_INSTANCE_NODE} / ${TOOLS_DP}"
[[ $(find_windows_boot_entry) == $'0007\tWindows Boot Manager' ]] \
  || fail_test "legal non-target multi-instance path poisoned target discovery"

begin_inventory '0007,0003'
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
add_entry 0003 '*' 'Multi Instance Windows' \
  "${WINDOWS_DP% / *} / ${END_INSTANCE_NODE} / ${TOOLS_DP}"
expect_inventory_failure "multi-instance Windows loader path was accepted as a target"

begin_inventory '0003'
add_entry 0003 '*' 'Windows Boot Manager' \
  "${WINDOWS_DP% / *} / ${END_INSTANCE_NODE} / ${TOOLS_DP}"
expect_inventory_failure "sole multi-instance Windows loader candidate was accepted"

begin_inventory '0007,0003'
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
add_entry 0003 '*' 'Truncated Instance' "$END_INSTANCE_NODE"
expect_inventory_failure "terminal End This Instance node was accepted"

printf 'warning: skipped unreadable firmware variable\n' > "$EFI_ERROR_FIXTURE"
expect_inventory_failure "efibootmgr diagnostics were ignored"
: > "$EFI_ERROR_FIXTURE"

begin_inventory '000A'
add_entry 000a '*' 'Windows Boot Manager' "$WINDOWS_DP"
expect_inventory_failure "lowercase Boot variable name was accepted"

write_good_inventory
windows_parse_firmware_inventory || fail_test "valid raw inventory did not parse"
windows_select_firmware_target || fail_test "valid target was not selected"
[[ "$_windows_partuuid" == 00112233-4455-6677-8899-aabbccddeeff ]] \
  || fail_test "EFI GUID byte order was decoded incorrectly"
[[ "$_windows_hd_start" == 2048 && "$_windows_hd_size" == 1048576 ]] \
  || fail_test "HD geometry was decoded incorrectly"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' "${NVME_NODE} / ${WINDOWS_DP}"
find_windows_boot_entry >/dev/null \
  || fail_test "allowed NVMe prefix was rejected"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' \
  "${ACPI_NODE} / ${PCI_NODE} / ${NVME_NODE} / ${WINDOWS_DP}"
find_windows_boot_entry >/dev/null \
  || fail_test "structurally valid local prefix was rejected"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' "01 01 06 00 03 / ${WINDOWS_DP}"
expect_inventory_failure "prefix node with a wrong declared length was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' "${WINDOWS_DP/04 01 2a 00/04 01 29 00}"
expect_inventory_failure "malformed HD node length was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' \
  "${HD_NODE} / ${EMBEDDED_NUL_FILE_NODE} / ${END_NODE}"
expect_inventory_failure "File node with an embedded NUL was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' \
  "${HD_NODE} / ${MISSING_TERMINATOR_FILE_NODE} / ${END_NODE}"
expect_inventory_failure "File node without a terminal NUL was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' \
  "${HD_NODE} / ${ODD_FILE_NODE} / ${END_NODE}"
expect_inventory_failure "File node with an odd payload length was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' \
  "${HD_NODE} / ${WINDOWS_FILE_NODE} / ${LINUX_FILE_NODE} / ${END_NODE}"
expect_inventory_failure "Windows target with a second File node was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' "${WINDOWS_DP% / *}"
expect_inventory_failure "Windows target without End Entire was accepted"

begin_inventory '0007'
{
  printf 'Boot0007* Windows Boot Manager\tformatted-path\n'
  printf 'BootCurrent: 0007\n'
  printf '      dp: %s\n' "$WINDOWS_DP"
} >> "$EFI_FIXTURE"
expect_inventory_failure "raw device path separated from its Boot record was accepted"

begin_inventory '0007'
add_entry 0007 ' ' 'Windows Boot Manager' "$WINDOWS_DP"
expect_inventory_failure "inactive Windows target was accepted"

begin_inventory '0001,0007'
add_entry 0001 ' ' 'windows boot manager' "$LINUX_DP"
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
expect_inventory_failure "Limine duplicate-label target was accepted"

begin_inventory '0001'
add_entry 0001 '*' Linux "$LINUX_DP"
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
expect_inventory_failure "Windows target outside BootOrder was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
add_entry 0008 ' ' 'Windows Recovery' "$WINDOWS_DP"
expect_inventory_failure "second exact Windows loader outside BootOrder was accepted"

begin_inventory '0007,0008'
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
expect_inventory_failure "missing BootOrder record was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows/Boot' "$WINDOWS_DP"
expect_inventory_failure "unsafe firmware label was accepted"

begin_inventory '0007'
printf '      dp: %s\n' "$WINDOWS_DP" >> "$EFI_FIXTURE"
expect_inventory_failure "orphan raw device path was accepted"

begin_inventory '0007'
add_entry 0007 '*' 'Windows Boot Manager' "$WINDOWS_DP"
printf '      dp: %s\n' "$WINDOWS_DP" >> "$EFI_FIXTURE"
expect_inventory_failure "duplicate raw device path was accepted"

order=""
for number in $(seq 0 128); do
  printf -v hex '%04X' "$number"
  [[ -z "$order" ]] || order+=,
  order+="$hex"
done
begin_inventory "$order"
expect_inventory_failure "BootOrder above Limine's 128-entry limit was accepted"

write_good_inventory
windows_parse_firmware_inventory || fail_test "mapping fixture inventory did not parse"
windows_select_firmware_target || fail_test "mapping fixture target was not selected"
windows_map_target_esp || fail_test "valid Windows ESP mapping failed"
[[ "$_windows_device_path" == /dev/windows-esp \
  && "$_windows_maj_min" == "$TEST_MAJ_MIN" ]] \
  || fail_test "Windows ESP mapping returned the wrong device beside the Linux ESP"
WINDOWS_BLOCK_DEVICE_MATCH=false
if windows_map_target_esp >/dev/null 2>&1; then
  fail_test "ESP mapping ignored a changed block-device identity"
fi
WINDOWS_BLOCK_DEVICE_MATCH=true

jq '(.blockdevices[1].start) = 16384 |
    (.blockdevices[1].size) = 4294967296 |
    (.blockdevices[1]."log-sec") = 4096' \
  "$LSBLK_FIXTURE" > "${TEST_DIR}/4kn.json"
cp "${TEST_DIR}/4kn.json" "$LSBLK_FIXTURE"
windows_map_target_esp || fail_test "valid 4Kn Windows ESP geometry was rejected"

write_good_lsblk
jq '(.blockdevices[0].unexpected) = true' "$LSBLK_FIXTURE" \
  > "${TEST_DIR}/extra-key.json"
cp "${TEST_DIR}/extra-key.json" "$LSBLK_FIXTURE"
if windows_map_target_esp >/dev/null 2>&1; then
  fail_test "block inventory with an unrequested key was accepted"
fi

write_good_lsblk
jq '.blockdevices += [.blockdevices[1] | .path = "/dev/duplicate-esp" | ."maj:min" = "259:2"]' \
  "$LSBLK_FIXTURE" > "${TEST_DIR}/duplicate.json"
cp "${TEST_DIR}/duplicate.json" "$LSBLK_FIXTURE"
if windows_map_target_esp >/dev/null 2>&1; then
  fail_test "duplicate PARTUUID mapping was accepted"
fi

write_good_lsblk
jq '(.blockdevices[1].size) = 536870400' "$LSBLK_FIXTURE" \
  > "${TEST_DIR}/bad-size.json"
cp "${TEST_DIR}/bad-size.json" "$LSBLK_FIXTURE"
if windows_map_target_esp >/dev/null 2>&1; then
  fail_test "mismatched HD size was accepted"
fi

write_good_lsblk
jq '(.blockdevices[1]."log-sec") = null' "$LSBLK_FIXTURE" \
  > "${TEST_DIR}/null-sector.json"
cp "${TEST_DIR}/null-sector.json" "$LSBLK_FIXTURE"
if windows_map_target_esp >/dev/null 2>&1; then
  fail_test "incomplete ESP geometry was accepted"
fi

write_good_lsblk
jq '(.blockdevices[1].start) = 9007199254740992' "$LSBLK_FIXTURE" \
  > "${TEST_DIR}/inexact-integer.json"
cp "${TEST_DIR}/inexact-integer.json" "$LSBLK_FIXTURE"
if windows_map_target_esp >/dev/null 2>&1; then
  fail_test "block geometry outside jq's exact integer range was accepted"
fi

write_good_inventory
write_good_lsblk
write_existing_mount
reset_findmnt_calls
: > "$CALL_LOG"
missing_tool_bin="${TEST_DIR}/missing-tool-bin"
mkdir -p "$missing_tool_bin"
for dependency in dd dirname efibootmgr findmnt install jq lsblk mktemp mount od \
  readlink rm rmdir stat umount; do
  dependency_path=$(type -P "$dependency") \
    || fail_test "could not resolve dependency fixture: ${dependency}"
  ln -s "$dependency_path" "${missing_tool_bin}/${dependency}"
done
saved_path=$PATH
PATH=$missing_tool_bin
dependency_result=0
_windows_boot_number='dependency-sentinel'
resolve_windows_target >/dev/null 2>&1 || dependency_result=$?
PATH=$saved_path
[[ $dependency_result -ne 0 \
  && "$_windows_error" == 'Required Windows target tool is unavailable: tr' \
  && "$_windows_boot_number" == dependency-sentinel ]] \
  || fail_test "target resolution did not reject its missing runtime dependency first"

_OMASECBOOT_LIMINE_LOCK_OWNED=false
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "Windows target proof ran without the Limine lock"
fi
_OMASECBOOT_LIMINE_LOCK_OWNED=local
_OMASECBOOT_REPAIR_LOCK_OWNED=false
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "Windows target proof ran without the repair lock"
fi
_OMASECBOOT_REPAIR_LOCK_OWNED=true
[[ ! -s "$CALL_LOG" ]] || fail_test "unlocked Windows target proof mutated mounts"
resolve_windows_target || fail_test "full proof rejected an existing read-only ESP mount"
[[ ! -s "$CALL_LOG" ]] || fail_test "existing-mount proof invoked mount mutation"

write_existing_mount 'rw,relatime'
reset_findmnt_calls
: > "$CALL_LOG"
loader_path="${EXISTING_ESP}/EFI/Microsoft/Boot/bootmgfw.efi"
atime_control="${TEST_DIR}/atime-control"
cp "$loader_path" "$atime_control"
touch -a -d '@946684800' "$atime_control"
atime_control_before=$(stat -Lc '%X' "$atime_control")
command dd bs=2 count=1 iflag=fullblock status=none \
  < "$atime_control" >/dev/null 2>&1
atime_control_after=$(stat -Lc '%X' "$atime_control")
atime_updates=false
[[ "$atime_control_before" == "$atime_control_after" ]] || atime_updates=true

DD_NOATIME_MARKER="${TEST_DIR}/dd-noatime"
DD_NOATIME_FAIL=false
dd() {
  local argument noatime=false
  for argument in "$@"; do
    if [[ ",$argument," == ,iflag=*,noatime,* ]]; then
      noatime=true
    fi
  done
  [[ "$noatime" == true ]] || return 97
  [[ "$DD_NOATIME_FAIL" != true ]] || return 98
  : > "$DD_NOATIME_MARKER"
  command dd "$@"
}
touch -a -d '@946684800' "$loader_path"
loader_atime_before=$(stat -Lc '%X' "$loader_path")
resolve_windows_target \
  || fail_test "controlled writable Windows ESP mount was not reused without atime"
loader_atime_after=$(stat -Lc '%X' "$loader_path")
[[ ! -s "$CALL_LOG" ]] \
  || fail_test "controlled writable-mount proof invoked mount mutation"
[[ -e "$DD_NOATIME_MARKER" ]] \
  || fail_test "controlled writable-mount proof omitted the noatime read flag"
if [[ "$atime_updates" == true \
  && "$loader_atime_before" != "$loader_atime_after" ]]; then
  fail_test "controlled writable-mount proof updated loader access time"
fi
DD_NOATIME_FAIL=true
reset_findmnt_calls
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "controlled writable-mount proof ignored a noatime flag failure"
fi
DD_NOATIME_FAIL=false
unset -f dd

write_existing_mount
reset_findmnt_calls
write_existing_mount 'ro,relatime' "$EXISTING_ESP" '9:9' \
  "$FINDMNT_REPLACEMENT_FIXTURE"
FINDMNT_REPLACE_AT=2
export FINDMNT_REPLACE_AT
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "reusable Windows ESP source change after loader read was accepted"
fi

write_existing_mount
reset_findmnt_calls
windows_parse_firmware_inventory || fail_test "loader fixture inventory did not parse"
windows_select_firmware_target || fail_test "loader fixture target was not selected"
windows_map_target_esp || fail_test "loader fixture mapping failed"
_windows_maj_min=9:9
if windows_verify_loader_file "$EXISTING_ESP" >/dev/null 2>&1; then
  fail_test "loader from a different filesystem was accepted"
fi

printf 'ZZ' | dd of="${EXISTING_ESP}/EFI/Microsoft/Boot/bootmgfw.efi" \
  bs=1 conv=notrunc status=none
write_existing_mount
reset_findmnt_calls
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "non-MZ Windows loader was accepted"
fi
cp "$LOADER_SOURCE" "${EXISTING_ESP}/EFI/Microsoft/Boot/bootmgfw.efi"

write_existing_mount
jq --arg second "${TEST_DIR}/second-esp" \
  --arg maj "$TEST_MAJ_MIN" \
  '.filesystems += [{target: $second, id: 601, "maj:min": $maj, fstype: "vfat", fsroot: "/", "vfs-options": "ro"}]' \
  "$FINDMNT_FIXTURE" > "${TEST_DIR}/ambiguous-mounts.json"
mkdir -p "${TEST_DIR}/second-esp"
cp "${TEST_DIR}/ambiguous-mounts.json" "$FINDMNT_FIXTURE"
reset_findmnt_calls
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "ambiguous Windows ESP mounts were accepted"
fi

write_empty_mounts
reset_findmnt_calls
: > "$CALL_LOG"
mkdir -p "$(windows_runtime_dir_path)"
chmod 755 "$(windows_runtime_dir_path)"
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "unsafe Windows runtime directory was repaired automatically"
fi
chmod 700 "$(windows_runtime_dir_path)"
[[ ! -s "$CALL_LOG" ]] || fail_test "unsafe runtime-directory refusal mutated mounts"
resolve_windows_target || fail_test "owned read-only Windows ESP mount proof failed"
/usr/bin/grep -Fq 'mount:-t vfat -o ro,nosuid,nodev,noexec,noatime,dmask=0077,fmask=0177 -- /dev/windows-esp' \
  "$CALL_LOG" || fail_test "owned mount omitted restrictive options"
/usr/bin/grep -Fq "umount:-- $(windows_runtime_mount_path)" "$CALL_LOG" \
  || fail_test "owned Windows ESP mount was not cleaned up"
[[ ! -e "$MOUNT_MARKER" && ! -e "$(windows_runtime_mount_path)" ]] \
  || fail_test "owned Windows ESP mount residue remained"

MOUNT_SIGNAL=true
export MOUNT_SIGNAL
reset_findmnt_calls
: > "$CALL_LOG"
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "interrupted Windows ESP proof reported success"
fi
MOUNT_SIGNAL=false
export MOUNT_SIGNAL
/usr/bin/grep -Fq "umount:-- $(windows_runtime_mount_path)" "$CALL_LOG" \
  || fail_test "interrupted Windows ESP proof did not unmount"
[[ ! -e "$MOUNT_MARKER" && ! -e "$(windows_runtime_mount_path)" ]] \
  || fail_test "interrupted Windows ESP proof left mount residue"

mkdir -p "$(windows_runtime_dir_path)" "$(windows_runtime_mount_path)"
chmod 700 "$(windows_runtime_dir_path)" "$(windows_runtime_mount_path)"
: > "$MOUNT_MARKER"
chmod 755 "$(windows_runtime_mount_path)"
MOUNT_MARKER_MAJ_MIN=9:9
write_existing_mount
reset_findmnt_calls
: > "$CALL_LOG"
if resolve_windows_target >/dev/null 2>&1; then
  fail_test "stale owned mount from another device was unmounted"
fi
if /usr/bin/grep -Eq '^umount:' "$CALL_LOG"; then
  fail_test "stale mount reconciliation unmounted another device"
fi
rm -f "$MOUNT_MARKER"
chmod 700 "$(windows_runtime_mount_path)"
rmdir "$(windows_runtime_mount_path)"
MOUNT_MARKER_MAJ_MIN="$TEST_MAJ_MIN"

mkdir -p "$(windows_runtime_mount_path)"
chmod 755 "$(windows_runtime_mount_path)"
: > "$MOUNT_MARKER"
write_existing_mount
reset_findmnt_calls
: > "$CALL_LOG"
resolve_windows_target || fail_test "stale owned mount was not reconciled"
/usr/bin/grep -Fq "umount:-- $(windows_runtime_mount_path)" "$CALL_LOG" \
  || fail_test "stale owned mount was not removed before reuse scanning"
if /usr/bin/grep -Eq '^mount:' "$CALL_LOG"; then
  fail_test "stale reconciliation remounted despite a reusable ESP mount"
fi

: > "$CALL_LOG"
real_check_root=$(declare -f check_root)
check_root() { die "Injected root boundary"; }
for mutation in setup suppress bootnext; do
  if (cmd_windows "$mutation") > "${TEST_DIR}/${mutation}.out" 2>&1; then
    fail_test "unsafe Windows ${mutation} mutation succeeded"
  fi
done
eval "$real_check_root"
[[ ! -s "$CALL_LOG" ]] || fail_test "unprivileged Windows command reached a mutation tool"
for mutation in setup suppress bootnext; do
  /usr/bin/grep -Fq 'Injected root boundary' "${TEST_DIR}/${mutation}.out" \
    || fail_test "Windows ${mutation} omitted its root safety boundary"
done

if /usr/bin/grep -RE 'efibootmgr[[:space:]].*(-n|--bootnext|-o|--bootorder|-B|--delete-bootnum|-c|--create)' \
  "${ROOT_DIR}/bin" "${ROOT_DIR}/lib/common.sh" "${ROOT_DIR}/lib/lifecycle.sh" \
  "${ROOT_DIR}/lib/checks.sh" "${ROOT_DIR}/lib/discover.sh" "${ROOT_DIR}/lib/sign.sh" \
  "${ROOT_DIR}/lib/enroll.sh" "${ROOT_DIR}/lib/producers.sh" \
  "${ROOT_DIR}/lib/status.sh" >/dev/null; then
  fail_test "code outside the guarded Windows boundary retained a firmware mutation command"
fi
[[ $(/usr/bin/grep -Ec \
  'efibootmgr[[:space:]].*(-n|--bootnext|-o|--bootorder|-B|--delete-bootnum|-c|--create)' \
  "${ROOT_DIR}/lib/windows.sh") -eq 2 ]] \
  || fail_test "guarded Windows code does not contain the two bounded BootNext writes"
/usr/bin/grep -Fxq "  run_windows_efibootmgr -n \"\$target_number\" || command_rc=\$?" \
  "${ROOT_DIR}/lib/windows.sh" \
  || fail_test "guarded Windows code bypassed its validated efibootmgr wrapper"
if /usr/bin/grep -Eq 'run_windows_efibootmgr[[:space:]]+-N' \
  "${ROOT_DIR}/lib/windows.sh"; then
  fail_test "Windows recovery retained efibootmgr's unreliable BootNext deletion path"
fi
/usr/bin/grep -Fq "remove_windows_bootnext_variable \"\$(windows_bootnext_variable_path)\"" \
  "${ROOT_DIR}/lib/windows.sh" \
  || fail_test "Windows recovery does not use its bounded direct deletion wrapper"
/usr/bin/grep -Fq "owner=\$(producer_file_owner_package \"\$path\")" \
  "${ROOT_DIR}/lib/windows.sh" \
  || fail_test "guarded Windows code does not verify efibootmgr package ownership"
/usr/bin/grep -Fq "\"/proc/self/fd/\${_windows_efibootmgr_fd}\" \"\$@\"" \
  "${ROOT_DIR}/lib/windows.sh" \
  || fail_test "guarded Windows code does not execute the validated efibootmgr inode"
/usr/bin/grep -Fxq "  rm -f -- \"\$1\"" "${ROOT_DIR}/lib/windows.sh" \
  || fail_test "Windows recovery does not remove BootNext through its bounded wrapper"
if /usr/bin/grep -RE 'systemctl[[:space:]]+reboot' \
  "${ROOT_DIR}/lib" "${ROOT_DIR}/bin" >/dev/null; then
  fail_test "production code retained a direct reboot command"
fi
for source in "${ROOT_DIR}/bin/omasecboot" "${ROOT_DIR}"/lib/*.sh; do
  [[ "$source" == "${ROOT_DIR}/lib/windows.sh" ]] && continue
  if /usr/bin/grep -Eq \
      'record_and_set_windows_bootnext|windows_recovery_transaction|execute_windows_recovery_action|remove_windows_bootnext_variable' \
      "$source"; then
    fail_test "production path outside windows.sh can invoke a guarded Windows mutation"
  fi
done

if cmd_windows > "${TEST_DIR}/windows-help.out" 2>&1; then
  fail_test "bare windows command succeeded"
fi
/usr/bin/grep -Fq 'windows <command>' "${TEST_DIR}/windows-help.out" \
  || fail_test "bare windows command did not show focused help"

if cmd_windows unknown > "${TEST_DIR}/windows-unknown.out" 2>&1; then
  fail_test "unknown windows command succeeded"
fi
/usr/bin/grep -Fq 'Unknown Windows command: unknown' "${TEST_DIR}/windows-unknown.out" \
  || fail_test "unknown windows command was not reported"

menu_file="${ROOT_DIR}/omarchy/omarchy-menu.jsonc"
jq -e '."system.windows"' "$menu_file" >/dev/null \
  || fail_test "Quattro menu fragment is invalid"
[[ $(jq -r '."system.windows".action' "$menu_file") == \
  "omarchy-launch-floating-terminal-with-presentation 'sudo omasecboot windows bootnext && omarchy system reboot'" ]] \
  || fail_test "Quattro menu action does not use BootNext plus graceful reboot"
/usr/bin/grep -Fq 'omasecboot windows available' "$menu_file" \
  || fail_test "Quattro menu entry lacks its availability guard"

write_good_inventory
write_windows_target_state_fixture
cmd_windows available \
  || fail_test "Quattro menu guard failed with the recorded Windows handoff"
rm -f "$(windows_target_state_path)"

printf 'windows tests passed\n'
