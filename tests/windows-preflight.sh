#!/bin/bash
# shellcheck disable=SC2034,SC2154,SC2329 # Tests inspect and set sourced globals.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init windows-preflight
BIN_DIR="${TEST_DIR}/bin"
EFI_FIXTURE="${TEST_DIR}/efibootmgr.out"
EFI_ERROR_FIXTURE="${TEST_DIR}/efibootmgr.err"
LSBLK_FIXTURE="${TEST_DIR}/lsblk.json"
FINDMNT_INVENTORY="${TEST_DIR}/findmnt.json"
DEVICE_MAP="${TEST_DIR}/devices"
BITLOCKER_DEVICES="${TEST_DIR}/bitlocker-devices"
VFAT_DEVICES="${TEST_DIR}/vfat-devices"
BLKID_UNKNOWN_DEVICES="${TEST_DIR}/blkid-unknown-devices"
PARTITION_DEVICES="${TEST_DIR}/partition-devices"
BLKID_ODD_DEVICES="${TEST_DIR}/blkid-odd-devices"
LOADER_DEVICES="${TEST_DIR}/loader-devices"
BAD_LOADER_DEVICES="${TEST_DIR}/bad-loader-devices"
UNREADABLE_DEVICES="${TEST_DIR}/unreadable-devices"
LOOKUP_UNKNOWN_SUFFIX=""
MOUNT_FAIL_DEVICES="${TEST_DIR}/mount-fail-devices"
MOUNT_SIGNAL_DEVICES="${TEST_DIR}/mount-signal-devices"
LOADER_SOURCE="${TEST_DIR}/bootmgfw.efi"
CALL_LOG="${TEST_DIR}/calls.log"
TEST_FAILURE_LOGS=("$CALL_LOG")
GUM_LOG="${TEST_DIR}/gum.log"
ORIGINAL_PATH=$PATH

mkdir -p "$BIN_DIR" "${TEST_DIR}/tmp"
export TMPDIR="${TEST_DIR}/tmp"
TEST_MOUNT_ID=$(/usr/bin/findmnt -n -T "$TEST_DIR" -o ID)
[[ "$TEST_MOUNT_ID" =~ ^[1-9][0-9]*$ ]] \
  || fail_test "could not determine test mount ID"
{
  printf 'MZ'
  /usr/bin/dd if=/dev/zero bs=1 count=126 status=none
} > "$LOADER_SOURCE"
TEST_MAJ_MIN=$(stat -Lc '%Hd:%Ld' "$LOADER_SOURCE")

cat > "${BIN_DIR}/efibootmgr" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $# -eq 1 && "$1" == -v ]] || exit 2
[[ ! -s "$EFI_ERROR_FIXTURE" ]] || /usr/bin/cat "$EFI_ERROR_FIXTURE" >&2
/usr/bin/cat "$EFI_FIXTURE"
exit "$EFI_RC"
EOF

cat > "${BIN_DIR}/lsblk" <<'EOF'
#!/bin/bash
set -euo pipefail
expected='--json --paths --list --output PATH,MAJ:MIN,TYPE,PARTTYPE,RM,TRAN,SUBSYSTEMS'
[[ "$*" == "$expected" ]] || {
  printf 'unexpected lsblk arguments: %s\n' "$*" >&2
  exit 2
}
[[ "$LSBLK_RC" == 0 ]] || exit "$LSBLK_RC"
/usr/bin/cat "$LSBLK_FIXTURE"
EOF

cat > "${BIN_DIR}/blkid" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $# -eq 9 && "$1" == --probe && "$2" == --match-types \
  && "$4" == --output && "$5" == value && "$6" == --match-tag \
  && "$7" == TYPE && "$8" == -- ]] || {
  printf 'unexpected blkid arguments: %s\n' "$*" >&2
  exit 4
}
expected=$3
path=$9
printf 'blkid:%s:%s\n' "$expected" "$path" >> "$CALL_LOG"
if /usr/bin/grep -Fxq "$path" "$BLKID_UNKNOWN_DEVICES"; then
  exit 8
fi
if /usr/bin/grep -Fxq "$path" "$BLKID_ODD_DEVICES"; then
  printf 'ntfs\n'
  exit 0
fi
# A GPT partition without the filtered type still yields its partition entry,
# so real blkid exits 0 with nothing to print; an image file exits 2.
absent() {
  if /usr/bin/grep -Fxq "$path" "$PARTITION_DEVICES"; then
    exit 0
  fi
  exit 2
}
case "$expected" in
  BitLocker)
    /usr/bin/grep -Fxq "$path" "$BITLOCKER_DEVICES" || absent
    printf 'BitLocker\n'
    ;;
  vfat)
    /usr/bin/grep -Fxq "$path" "$VFAT_DEVICES" || absent
    printf 'vfat\n'
    ;;
  *) exit 4 ;;
esac
EOF

cat > "${BIN_DIR}/findmnt" <<'EOF'
#!/bin/bash
set -euo pipefail
target="" previous="" columns=""
for argument in "$@"; do
  if [[ "$previous" == --mountpoint ]]; then
    target="$argument"
  elif [[ "$previous" == --output ]]; then
    columns="$argument"
  fi
  previous="$argument"
done
if [[ -n "$target" ]]; then
  [[ -f "${target}/.mounted" || -f "${target}/.reusable" ]] || exit 1
  if [[ "$columns" == 'TARGET,MAJ:MIN,FSTYPE,FSROOT' ]]; then
    jq -cn --arg target "$target" --arg maj "$(< "${target}/.maj")" '{
      filesystems: [{target: $target, "maj:min": $maj, fstype: "vfat", fsroot: "/"}]
    }'
  elif [[ -z "$columns" ]]; then
    printf '%s\n' "$target"
  else
    exit 2
  fi
  exit 0
fi
[[ "$columns" == 'TARGET,MAJ:MIN,FSTYPE,FSROOT' ]] || exit 2
/usr/bin/cat "$FINDMNT_INVENTORY"
EOF

cat > "${BIN_DIR}/mount" <<'EOF'
#!/bin/bash
set -euo pipefail
device=${@: -2:1}
target=${@: -1}
maj=$(/usr/bin/grep -F "${device}"$'\t' "$DEVICE_MAP" | /usr/bin/cut -f2)
[[ -n "$maj" ]] || exit 2
printf 'mount:%s:%s:%s\n' "$device" "$target" "$*" >> "$CALL_LOG"
/usr/bin/grep -Fxq "$device" "$MOUNT_FAIL_DEVICES" && exit 1
mkdir -p "$target"
printf '%s\n' "$maj" > "${target}/.maj"
printf '%s\n' "$device" > "${target}/.device"
: > "${target}/.mounted"
if /usr/bin/grep -Fxq "$device" "$LOADER_DEVICES"; then
  mkdir -p "${target}/EFI/Microsoft/Boot"
  if /usr/bin/grep -Fxq "$device" "$BAD_LOADER_DEVICES"; then
    printf 'MZ' > "${target}/EFI/Microsoft/Boot/bootmgfw.efi"
  else
    cp "$LOADER_SOURCE" "${target}/EFI/Microsoft/Boot/bootmgfw.efi"
  fi
fi
if /usr/bin/grep -Fxq "$device" "$MOUNT_SIGNAL_DEVICES"; then
  kill -TERM "$PPID"
fi
EOF

cat > "${BIN_DIR}/umount" <<'EOF'
#!/bin/bash
set -euo pipefail
target=${!#}
printf 'umount:%s\n' "$target" >> "$CALL_LOG"
rm -rf "${target}/EFI"
rm -f "${target}/.maj" "${target}/.device" "${target}/.mounted"
chmod 700 "$target"
EOF

cat > "${BIN_DIR}/dd" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'dd:%s\n' "$*" >> "$CALL_LOG"
[[ " $* " == *' iflag=fullblock,noatime '* ]] || exit 97
/usr/bin/dd "$@"
EOF

cat > "${BIN_DIR}/gum" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$GUM_LOG"
case "${1:-}" in
  choose)
    if [[ "$*" == *'Windows edition'* ]]; then
      printf '%s\n' "$GUM_EDITION"
    elif [[ "$*" == *'Windows management'* ]]; then
      printf '%s\n' "$GUM_MANAGEMENT"
    else
      exit 2
    fi
    ;;
  confirm)
    case "$*" in
      *administrator*) [[ "$GUM_ADMIN_APPROVED" == true ]] ;;
      *recovery\ key*) [[ "$GUM_RECOVERY_APPROVED" == true ]] ;;
      *Device\ Encryption*) [[ "$GUM_PREPARATION_APPROVED" == true ]] ;;
      *BitLocker\ protection*) [[ "$GUM_PREPARATION_APPROVED" == true ]] ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
EOF

chmod +x "${BIN_DIR}/efibootmgr" "${BIN_DIR}/lsblk" "${BIN_DIR}/blkid" \
  "${BIN_DIR}/findmnt" "${BIN_DIR}/mount" "${BIN_DIR}/umount" \
  "${BIN_DIR}/dd" "${BIN_DIR}/gum"

export EFI_FIXTURE EFI_ERROR_FIXTURE LSBLK_FIXTURE FINDMNT_INVENTORY DEVICE_MAP
export BITLOCKER_DEVICES VFAT_DEVICES BLKID_UNKNOWN_DEVICES LOADER_DEVICES
export PARTITION_DEVICES BLKID_ODD_DEVICES
export BAD_LOADER_DEVICES MOUNT_FAIL_DEVICES MOUNT_SIGNAL_DEVICES
export LOADER_SOURCE CALL_LOG GUM_LOG TEST_MOUNT_ID
export EFI_RC=0 LSBLK_RC=0
export GUM_EDITION=Home GUM_MANAGEMENT='Personal device'
export GUM_ADMIN_APPROVED=true GUM_RECOVERY_APPROVED=true
export GUM_PREPARATION_APPROVED=true
PATH="${BIN_DIR}:${ORIGINAL_PATH}"
export PATH

# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"

control_owner_uid() {
  id -u
}

windows_efibootmgr_executable_path() {
  printf '%s/efibootmgr\n' "$BIN_DIR"
}

check_root() {
  :
}

windows_runtime_dir_path() {
  printf '%s/run/omasecboot\n' "$TEST_DIR"
}

windows_block_device_matches() {
  local path="$1" maj="$2"
  /usr/bin/grep -Fxq "${path}"$'\t'"${maj}" "$DEVICE_MAP"
}

windows_preflight_device_reads() {
  ! /usr/bin/grep -Fxq "$1" "$UNREADABLE_DEVICES"
}

eval "original_$(declare -f windows_path_lookup_state)"
windows_path_lookup_state() {
  if [[ -n "$LOOKUP_UNKNOWN_SUFFIX" && "$1" == *"$LOOKUP_UNKNOWN_SUFFIX" ]]; then
    printf 'unknown\n'
    return 0
  fi
  original_windows_path_lookup_state "$1"
}

windows_preflight_gum_path() {
  [[ "$GUM_AVAILABLE" == true ]] || return 1
  printf '%s/gum\n' "$BIN_DIR"
}

LOCK_FAIL_LIMINE=false
LOCK_FAIL_REPAIR=false
with_limine_lock() {
  [[ "$LOCK_FAIL_LIMINE" == false ]] || return 1
  _OMASECBOOT_LIMINE_LOCK_OWNED=local
}

with_repair_lock() {
  [[ "$LOCK_FAIL_REPAIR" == false ]] || return 1
  _OMASECBOOT_REPAIR_LOCK_OWNED=true
}

release_limine_lock() {
  _OMASECBOOT_LIMINE_LOCK_OWNED=false
}

release_repair_lock() {
  _OMASECBOOT_REPAIR_LOCK_OWNED=false
}

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

HD_NODE='04 01 2a 00 01 00 00 00 00 08 00 00 00 00 00 00 00 00 10 00 00 00 00 00 33 22 11 00 55 44 77 66 88 99 aa bb cc dd ee ff 02 02'
END_NODE='7f ff 04 00'
WINDOWS_FILE_NODE=$(make_file_node '\EFI\Microsoft\Boot\bootmgfw.efi')
LINUX_FILE_NODE=$(make_file_node '\EFI\Linux\omarchy.efi')
WINDOWS_DP="${HD_NODE} / ${WINDOWS_FILE_NODE} / ${END_NODE}"
LINUX_DP="${HD_NODE} / ${LINUX_FILE_NODE} / ${END_NODE}"

write_firmware_absent() {
  {
    printf 'BootOrder: 0001\n'
    printf 'Boot0001* Linux\tformatted-path\n'
    printf '      dp: %s\n' "$LINUX_DP"
  } > "$EFI_FIXTURE"
}

write_firmware_present() {
  {
    printf 'BootOrder: 0007\n'
    printf 'Boot0007* Windows Boot Manager\tformatted-path\n'
    printf '      dp: %s\n' "$WINDOWS_DP"
  } > "$EFI_FIXTURE"
}

write_inventory() {
  local esp_path="${1:-/dev/linux-esp}" esp_maj="${2:-$TEST_MAJ_MIN}"
  local removable="${3:-false}" transport="${4:-nvme}"
  local subsystems="${5:-block:nvme:pci}"
  jq -n --arg esp "$esp_path" --arg maj "$esp_maj" \
    --arg transport "$transport" --arg subsystems "$subsystems" \
    --argjson removable "$removable" '{
    blockdevices: [
      {
        path: $esp,
        "maj:min": $maj,
        type: "part",
        parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
        rm: $removable,
        tran: $transport,
        subsystems: $subsystems
      },
      {
        path: "/dev/windows-os",
        "maj:min": "259:6",
        type: "part",
        parttype: "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7",
        rm: false,
        tran: "nvme",
        subsystems: "block:nvme:pci"
      }
    ]
  }' > "$LSBLK_FIXTURE"
  {
    printf '%s\t%s\n' "$esp_path" "$esp_maj"
    printf '/dev/windows-os\t259:6\n'
  } > "$DEVICE_MAP"
}

write_two_esp_inventory() {
  local first_maj="$1" second_maj="$2"
  jq -n --arg first "$first_maj" --arg second "$second_maj" '{
    blockdevices: [
      {
        path: "/dev/esp-a", "maj:min": $first, type: "part",
        parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
        rm: false, tran: "nvme", subsystems: "block:nvme:pci"
      },
      {
        path: "/dev/esp-b", "maj:min": $second, type: "part",
        parttype: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
        rm: false, tran: "nvme", subsystems: "block:nvme:pci"
      }
    ]
  }' > "$LSBLK_FIXTURE"
  {
    printf '/dev/esp-a\t%s\n' "$first_maj"
    printf '/dev/esp-b\t%s\n' "$second_maj"
  } > "$DEVICE_MAP"
}

write_reusable_mount() {
  local target="$1"
  mkdir -m 700 "$target"
  mkdir -p "${target}/EFI/Microsoft/Boot"
  cp "$LOADER_SOURCE" "${target}/EFI/Microsoft/Boot/bootmgfw.efi"
  printf '%s\n' "$TEST_MAJ_MIN" > "${target}/.maj"
  : > "${target}/.reusable"
  jq -n --arg target "$target" --arg maj "$TEST_MAJ_MIN" '{
    filesystems: [{target: $target, "maj:min": $maj, fstype: "vfat", fsroot: "/"}]
  }' > "$FINDMNT_INVENTORY"
}

reset_case() {
  rm -rf "${TEST_DIR}/run" "${TEST_DIR}/reusable-esp"
  mkdir -m 700 "${TEST_DIR}/run"
  : > "$EFI_ERROR_FIXTURE"
  : > "$BITLOCKER_DEVICES"
  : > "$BLKID_UNKNOWN_DEVICES"
  : > "$PARTITION_DEVICES"
  : > "$BLKID_ODD_DEVICES"
  : > "$LOADER_DEVICES"
  : > "$BAD_LOADER_DEVICES"
  : > "$UNREADABLE_DEVICES"
  LOOKUP_UNKNOWN_SUFFIX=""
  : > "$MOUNT_FAIL_DEVICES"
  : > "$MOUNT_SIGNAL_DEVICES"
  : > "$CALL_LOG"
  : > "$GUM_LOG"
  printf '{"filesystems":[]}\n' > "$FINDMNT_INVENTORY"
  printf '/dev/linux-esp\n' > "$VFAT_DEVICES"
  write_firmware_absent
  write_inventory
  EFI_RC=0
  LSBLK_RC=0
  GUM_EDITION=Home
  GUM_MANAGEMENT='Personal device'
  GUM_ADMIN_APPROVED=true
  GUM_RECOVERY_APPROVED=true
  GUM_PREPARATION_APPROVED=true
  GUM_AVAILABLE=true
  LOCK_FAIL_LIMINE=false
  LOCK_FAIL_REPAIR=false
  _OMASECBOOT_LIMINE_LOCK_OWNED=false
  _OMASECBOOT_REPAIR_LOCK_OWNED=false
  QUIET=false
  export EFI_RC LSBLK_RC GUM_EDITION GUM_MANAGEMENT
  export GUM_ADMIN_APPROVED GUM_RECOVERY_APPROVED GUM_PREPARATION_APPROVED
  export GUM_AVAILABLE LOCK_FAIL_LIMINE LOCK_FAIL_REPAIR
}

run_gate() {
  local output="$1"
  GATE_RC=0
  windows_encryption_gate > "$output" 2>&1 || GATE_RC=$?
  if /usr/bin/grep -Fq 'command not found' "$output"; then
    fail_test "preflight called an undefined function"
  fi
  if /usr/bin/grep -Eqi 'ntfs-3g|hivex|mount:[^:]*windows-os|mount:.*ntfs' \
    "$CALL_LOG"; then
    fail_test "preflight invoked a forbidden Windows-volume operation"
  fi
  if /usr/bin/grep -Eqi 'enter Setup Mode|clear (the )?firmware keys|sbctl (enroll|reset)|enable Secure Boot' \
    "$output"; then
    fail_test "preflight printed a firmware mutation instruction"
  fi
}

assert_no_runtime_artifacts() {
  local runtime="${TEST_DIR}/run/omasecboot"
  if [[ -d "$runtime" ]] \
    && compgen -G "${runtime}/windows-preflight-*/.mounted" >/dev/null; then
    fail_test "owned ESP mount was not cleaned"
  fi
}

case_output="${TEST_DIR}/case.out"
TEST_FAILURE_LOGS=("$case_output" "$CALL_LOG")

reset_case
run_gate "$case_output"
if [[ $GATE_RC -ne 0 || $_windows_preflight_result != negative ]]; then
  fail_test "complete negative scan did not return the negative result"
fi
[[ ! -s "$GUM_LOG" ]] || fail_test "negative scan invoked interactive prompts"
/usr/bin/grep -Fq 'does not prove Windows is absent' "$case_output" \
  || fail_test "negative scan omitted its detection boundary"
/usr/bin/grep -Fq 'can still trigger BitLocker recovery' "$case_output" \
  || fail_test "negative scan omitted the bounded recovery warning"

reset_case
write_firmware_present
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "firmware-only signal did not trigger and pass the gate"
/usr/bin/grep -Fq 'backed up every available recovery key' "$GUM_LOG" \
  || fail_test "firmware-only signal skipped recovery-key preparation"
/usr/bin/grep -Fq 'Windows Home' "$case_output" \
  || fail_test "Home guidance was not printed"
if /usr/bin/grep -Eq 'Suspend-BitLocker|Resume-BitLocker' "$case_output"; then
  fail_test "interactive Home guidance offered BitLocker suspension"
fi

reset_case
printf '/dev/windows-os\n' > "$BITLOCKER_DEVICES"
GUM_EDITION=Pro
export GUM_EDITION
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "BitLocker-only signal did not trigger and pass the gate"
/usr/bin/grep -Fq "Suspend-BitLocker -MountPoint \$env:SystemDrive -RebootCount 0" \
  "$case_output" || fail_test "Pro guidance omitted documented suspension"
/usr/bin/grep -Fq "Resume-BitLocker -MountPoint \$env:SystemDrive" "$case_output" \
  || fail_test "Pro guidance omitted explicit resume"
if /usr/bin/grep -Fq 'mount:/dev/windows-os:' "$CALL_LOG"; then
  fail_test "BitLocker volume was mounted"
fi

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
GUM_EDITION=Education
export GUM_EDITION
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "ESP-loader-only signal did not trigger and pass the gate"
/usr/bin/grep -Fq 'Boot manager: /dev/linux-esp' "$case_output" \
  || fail_test "ESP loader was not reported"
/usr/bin/grep -Fq 'iflag=fullblock,noatime' "$CALL_LOG" \
  || fail_test "loader read omitted O_NOATIME"
assert_no_runtime_artifacts

reset_case
write_reusable_mount "${TEST_DIR}/reusable-esp"
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "reusable ESP mount did not pass the gate"
/usr/bin/grep -Fq 'Boot manager: /dev/linux-esp' "$case_output" \
  || fail_test "reusable ESP loader was not inspected"
if /usr/bin/grep -Fq 'mount:/dev/linux-esp:' "$CALL_LOG"; then
  fail_test "reusable ESP was mounted again"
fi
/usr/bin/grep -Fq 'iflag=fullblock,noatime' "$CALL_LOG" \
  || fail_test "reusable ESP read omitted O_NOATIME"
assert_no_runtime_artifacts

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
printf '/dev/linux-esp\n' > "$BAD_LOADER_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "unsafe loader did not leave a technical blocker"
/usr/bin/grep -Fq 'failed safely on ESP /dev/linux-esp' "$case_output" \
  || fail_test "unsafe loader omitted its device-specific blocker"
assert_no_runtime_artifacts

# A probe that cannot open its device is not a negative observation.
reset_case
printf '/dev/windows-os\n' > "$UNREADABLE_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "unreadable Windows volume passed as a BitLocker negative"
/usr/bin/grep -Fq 'BitLocker signature probing is inconclusive for /dev/windows-os' \
  "$case_output" || fail_test "unreadable volume omitted its device-specific blocker"

reset_case
printf '/dev/linux-esp\n' > "$UNREADABLE_DEVICES"
: > "$VFAT_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "unreadable ESP passed as a negative"
/usr/bin/grep -Fq 'BitLocker signature probing is inconclusive for /dev/linux-esp' \
  "$case_output" || fail_test "unreadable ESP omitted its BitLocker blocker"
/usr/bin/grep -Fq 'FAT signature probing is inconclusive for ESP /dev/linux-esp' \
  "$case_output" || fail_test "unreadable ESP omitted its FAT blocker"

# On a GPT partition blkid's low-level probe answers 0 with empty output when
# the filtered type is absent, because it still reports the partition entry;
# that is a negative once the device reads, not an unreadable device.
reset_case
printf '/dev/windows-os\n/dev/linux-esp\n' > "$PARTITION_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == negative ]] \
  || fail_test "partition-style blkid answers were not a complete negative"
if /usr/bin/grep -Fq 'inconclusive' "$case_output"; then
  fail_test "partition-style blkid answers were reported as inconclusive"
fi

reset_case
printf '/dev/windows-os\n/dev/linux-esp\n' > "$PARTITION_DEVICES"
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "partition-style ESP with a loader did not pass the gate"
/usr/bin/grep -Fq 'Boot manager: /dev/linux-esp' "$case_output" \
  || fail_test "partition-style ESP loader was not reported"
assert_no_runtime_artifacts

reset_case
printf '/dev/windows-os\n' > "$PARTITION_DEVICES"
printf '/dev/windows-os\n' > "$UNREADABLE_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "partition-style answer on an unreadable device passed as a negative"
/usr/bin/grep -Fq 'BitLocker signature probing is inconclusive for /dev/windows-os' \
  "$case_output" || fail_test "unreadable partition-style device omitted its blocker"

# A type value other than the filtered one is not a negative either.
reset_case
printf '/dev/windows-os\n' > "$BLKID_ODD_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "an unexpected blkid type value passed as a negative"
/usr/bin/grep -Fq 'BitLocker signature probing is inconclusive for /dev/windows-os' \
  "$case_output" || fail_test "unexpected blkid type value omitted its blocker"

# A loader path whose lookup fails for any reason other than absence stays
# unknown.
reset_case
LOOKUP_UNKNOWN_SUFFIX=$WINDOWS_LOADER_POSIX
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "unobservable loader path passed as a loader negative"
/usr/bin/grep -Fq 'failed safely on ESP /dev/linux-esp' "$case_output" \
  || fail_test "unobservable loader omitted its device-specific blocker"
assert_no_runtime_artifacts

reset_case
printf 'firmware warning\n' > "$EFI_ERROR_FIXTURE"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "firmware detector error did not become technical unknown"
/usr/bin/grep -Fq 'Windows Home' "$case_output" \
  || fail_test "firmware uncertainty suppressed preparation guidance"
/usr/bin/grep -Fq 'efibootmgr reported incomplete' "$case_output" \
  || fail_test "firmware uncertainty omitted its exact reason"

reset_case
printf '/dev/windows-os\n' > "$BLKID_UNKNOWN_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "ambiguous BitLocker probe did not become technical unknown"
/usr/bin/grep -Fq 'BitLocker signature probing is inconclusive' "$case_output" \
  || fail_test "ambiguous BitLocker probe omitted its device reason"

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
LOCK_FAIL_LIMINE=true
export LOCK_FAIL_LIMINE
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "shared ESP lock failure did not leave a technical blocker"
[[ $_OMASECBOOT_LIMINE_LOCK_OWNED == false \
  && $_OMASECBOOT_REPAIR_LOCK_OWNED == false ]] \
  || fail_test "shared ESP lock failure changed prior lock ownership"
/usr/bin/grep -Fq 'Could not acquire the shared ESP lock' "$case_output" \
  || fail_test "shared ESP lock failure omitted retry guidance"

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
LOCK_FAIL_REPAIR=true
export LOCK_FAIL_REPAIR
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "repair lock failure did not leave a technical blocker"
[[ $_OMASECBOOT_LIMINE_LOCK_OWNED == false \
  && $_OMASECBOOT_REPAIR_LOCK_OWNED == false ]] \
  || fail_test "repair lock failure did not restore prior lock ownership"
/usr/bin/grep -Fq 'Could not acquire the repair lock' "$case_output" \
  || fail_test "repair lock failure omitted retry guidance"

reset_case
write_inventory /dev/external-esp 8:1 false usb block:scsi:usb:pci
printf '/dev/external-esp\n' > "$VFAT_DEVICES"
printf '/dev/external-esp\n' > "$LOADER_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "external ESP did not become a technical blocker"
if /usr/bin/grep -Fq 'mount:/dev/external-esp:' "$CALL_LOG"; then
  fail_test "external ESP was mounted"
fi
/usr/bin/grep -Fq 'disconnect external boot media' "$case_output" \
  || fail_test "external ESP omitted retry guidance"

reset_case
write_firmware_present
GUM_AVAILABLE=false
export GUM_AVAILABLE
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "missing gum did not leave a technical blocker"
/usr/bin/grep -Fq 'Windows Home' "$case_output" \
  || fail_test "missing gum omitted Home-only workflow"
/usr/bin/grep -Fq 'Windows Pro, Enterprise, or Education' "$case_output" \
  || fail_test "missing gum omitted Pro+ workflow"
/usr/bin/grep -Fq 'use this workflow only' "$case_output" \
  || fail_test "missing gum did not keep suspension out of the Home workflow"

reset_case
write_firmware_present
QUIET=true
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "quiet mode changed the gate result"
/usr/bin/grep -Fq 'Windows Home' "$case_output" \
  || fail_test "quiet mode suppressed the safety checklist"

reset_case
write_firmware_present
GUM_RECOVERY_APPROVED=false
export GUM_RECOVERY_APPROVED
run_gate "$case_output"
[[ $GATE_RC -eq 1 && $_windows_preflight_result == declined ]] \
  || fail_test "firmware-only recovery-key decline did not block the gate"

reset_case
write_firmware_present
GUM_MANAGEMENT='Managed by an organization'
GUM_ADMIN_APPROVED=false
export GUM_MANAGEMENT GUM_ADMIN_APPROVED
run_gate "$case_output"
[[ $GATE_RC -eq 1 && $_windows_preflight_result == declined ]] \
  || fail_test "managed-device decline did not block the gate"
/usr/bin/grep -Fq 'Administrator approval is required' "$case_output" \
  || fail_test "managed-device decline omitted its blocker"

reset_case
printf '/dev/windows-os\n' > "$BITLOCKER_DEVICES"
GUM_EDITION=Pro
GUM_RECOVERY_APPROVED=false
export GUM_EDITION GUM_RECOVERY_APPROVED
run_gate "$case_output"
[[ $GATE_RC -eq 1 && $_windows_preflight_result == declined ]] \
  || fail_test "recovery-key decline did not block the gate"

reset_case
printf '/dev/windows-os\n' > "$BITLOCKER_DEVICES"
GUM_PREPARATION_APPROVED=false
export GUM_PREPARATION_APPROVED
run_gate "$case_output"
[[ $GATE_RC -eq 1 && $_windows_preflight_result == declined ]] \
  || fail_test "Home decryption decline did not block the gate"
if /usr/bin/grep -Eq 'Suspend-BitLocker|Resume-BitLocker' "$case_output"; then
  fail_test "declined Home path exposed suspension commands"
fi

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
_OMASECBOOT_LIMINE_LOCK_OWNED=inherited
_OMASECBOOT_REPAIR_LOCK_OWNED=true
run_gate "$case_output"
[[ $_OMASECBOOT_LIMINE_LOCK_OWNED == inherited \
  && $_OMASECBOOT_REPAIR_LOCK_OWNED == true ]] \
  || fail_test "preflight changed inherited lock ownership"

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
_OMASECBOOT_LIMINE_LOCK_OWNED=local
_OMASECBOOT_REPAIR_LOCK_OWNED=true
run_gate "$case_output"
[[ $_OMASECBOOT_LIMINE_LOCK_OWNED == local \
  && $_OMASECBOOT_REPAIR_LOCK_OWNED == true ]] \
  || fail_test "preflight changed local lock ownership"

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
printf '/dev/linux-esp\n' > "$MOUNT_SIGNAL_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 143 && $_windows_preflight_result == declined ]] \
  || fail_test "handled mount signal did not propagate safely"
[[ $_OMASECBOOT_LIMINE_LOCK_OWNED == false \
  && $_OMASECBOOT_REPAIR_LOCK_OWNED == false ]] \
  || fail_test "handled mount signal did not release acquired locks"
assert_no_runtime_artifacts

reset_case
write_two_esp_inventory "$TEST_MAJ_MIN" 999:2
printf '/dev/esp-a\n/dev/esp-b\n' > "$VFAT_DEVICES"
printf '/dev/esp-a\n/dev/esp-b\n' > "$LOADER_DEVICES"
printf '/dev/esp-b\n' > "$MOUNT_FAIL_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "second-ESP failure did not leave a technical blocker"
/usr/bin/grep -Fq 'Boot manager: /dev/esp-a' "$case_output" \
  || fail_test "first ESP result was lost when the second ESP failed"
/usr/bin/grep -Fq 'failed safely on ESP /dev/esp-b' "$case_output" \
  || fail_test "second ESP failure omitted its device-specific blocker"
assert_no_runtime_artifacts

# Quattro's normal dual-boot shape: the Windows ESP carries the loader and the
# Linux ESP does not; only the Windows one is reported and the scan is complete.
reset_case
write_two_esp_inventory "$TEST_MAJ_MIN" 999:2
printf '/dev/esp-a\n/dev/esp-b\n' > "$VFAT_DEVICES"
printf '/dev/esp-a\n' > "$LOADER_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "loader-bearing plus loader-free ESP pair did not pass the gate"
/usr/bin/grep -Fq 'Boot manager: /dev/esp-a' "$case_output" \
  || fail_test "the loader-bearing ESP of the pair was not reported"
if /usr/bin/grep -Fq 'Boot manager: /dev/esp-b' "$case_output"; then
  fail_test "the loader-free ESP of the pair was reported as a boot manager"
fi
/usr/bin/grep -Fq 'mount:/dev/esp-b:' "$CALL_LOG" \
  || fail_test "the loader-free ESP was not inspected"
assert_no_runtime_artifacts

# A SATA-attached internal disk is not external media.
reset_case
write_inventory /dev/sata-esp "$TEST_MAJ_MIN" false sata block:scsi:pci
printf '/dev/sata-esp\n' > "$VFAT_DEVICES"
printf '/dev/sata-esp\n' > "$LOADER_DEVICES"
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "SATA internal ESP was not scanned as internal media"
/usr/bin/grep -Fq 'Boot manager: /dev/sata-esp' "$case_output" \
  || fail_test "SATA internal ESP loader was not reported"
assert_no_runtime_artifacts

reset_case
write_two_esp_inventory 8:1 8:2
printf '/dev/esp-a\n/dev/esp-b\n' > "$VFAT_DEVICES"
runtime="${TEST_DIR}/run/omasecboot"
stale_a="${runtime}/windows-preflight-8-1"
mkdir -m 700 "$runtime"
mkdir -m 700 "$stale_a"
printf '8:1\n' > "${stale_a}/.maj"
printf '/dev/esp-a\n' > "${stale_a}/.device"
: > "${stale_a}/.mounted"
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == negative ]] \
  || fail_test "stale ESP A mount blocked the multi-ESP negative scan"
/usr/bin/grep -Fq "umount:${stale_a}" "$CALL_LOG" \
  || fail_test "matching stale ESP mount was not reconciled"
assert_no_runtime_artifacts

reset_case
windows_preflight_read_block_inventory() {
  return 1
}
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "internal inventory failure did not fail closed"
/usr/bin/grep -Fq 'Block-device inventory processing failed safely' "$case_output" \
  || fail_test "internal inventory failure omitted the BitLocker blocker"
/usr/bin/grep -Fq 'ESP inventory processing failed safely' "$case_output" \
  || fail_test "internal inventory failure omitted the loader blocker"

reset_case
windows_preflight_scan_esps() {
  return 1
}
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "internal ESP scan failure did not fail closed"
/usr/bin/grep -Fq 'Windows preflight collection failed safely' "$case_output" \
  || fail_test "internal ESP scan failure omitted its blocker"
/usr/bin/grep -Fq 'Windows Home' "$case_output" \
  || fail_test "internal ESP scan failure omitted preparation guidance"

printf 'windows preflight tests passed\n'
