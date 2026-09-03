#!/bin/bash
# shellcheck disable=SC2034,SC2154,SC2329 # Tests inspect and set sourced globals.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-windows-preflight.XXXXXX")
BIN_DIR="${TEST_DIR}/bin"
EFI_FIXTURE="${TEST_DIR}/efibootmgr.out"
EFI_ERROR_FIXTURE="${TEST_DIR}/efibootmgr.err"
LSBLK_FIXTURE="${TEST_DIR}/lsblk.json"
FINDMNT_INVENTORY="${TEST_DIR}/findmnt.json"
DEVICE_MAP="${TEST_DIR}/devices"
BITLOCKER_DEVICES="${TEST_DIR}/bitlocker-devices"
VFAT_DEVICES="${TEST_DIR}/vfat-devices"
BLKID_UNKNOWN_DEVICES="${TEST_DIR}/blkid-unknown-devices"
LOADER_DEVICES="${TEST_DIR}/loader-devices"
BAD_LOADER_DEVICES="${TEST_DIR}/bad-loader-devices"
MOUNT_FAIL_DEVICES="${TEST_DIR}/mount-fail-devices"
MOUNT_SIGNAL_DEVICES="${TEST_DIR}/mount-signal-devices"
LOADER_SOURCE="${TEST_DIR}/bootmgfw.efi"
CALL_LOG="${TEST_DIR}/calls.log"
GUM_LOG="${TEST_DIR}/gum.log"
ORIGINAL_PATH=$PATH

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  if [[ -n "${case_output:-}" && -f "$case_output" ]]; then
    /usr/bin/cat "$case_output" >&2
  fi
  if [[ -f "${CALL_LOG:-/nonexistent}" ]]; then
    /usr/bin/cat "$CALL_LOG" >&2
  fi
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

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
case "$expected" in
  BitLocker)
    /usr/bin/grep -Fxq "$path" "$BITLOCKER_DEVICES" || exit 2
    printf 'BitLocker\n'
    ;;
  vfat)
    /usr/bin/grep -Fxq "$path" "$VFAT_DEVICES" || exit 2
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
    [[ "$columns" == 'TARGET,ID,MAJ:MIN,FSTYPE,FSROOT,VFS-OPTIONS' ]] || exit 2
    access=ro
    mount_id=$TEST_MOUNT_ID
    if [[ -f "${target}/.reusable" ]]; then
      access=$(< "${target}/.access")
      mount_id=$(< "${target}/.id")
    fi
    jq -cn --arg target "$target" --arg maj "$(< "${target}/.maj")" \
      --argjson id "$mount_id" --arg options "${access},nosuid,nodev,noexec,noatime" '{
      filesystems: [{
        target: $target,
        id: $id,
        "maj:min": $maj,
        fstype: "vfat",
        fsroot: "/",
        "vfs-options": $options
      }]
    }'
  fi
  exit 0
fi
[[ "$columns" == 'TARGET,ID,MAJ:MIN,FSTYPE,FSROOT,VFS-OPTIONS' ]] || exit 2
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

cat > "${BIN_DIR}/setpriv" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'setpriv:%s\n' "$*" >> "$CALL_LOG"
joined=" $* "
for required in '--reuid=nobody' '--regid=nobody' '--clear-groups' \
  '--inh-caps=-all' '--ambient-caps=-all' '--bounding-set=-all' \
  '--no-new-privs' '--reset-env'; do
  [[ "$joined" == *" ${required} "* ]] || exit 96
done
while [[ $# -gt 0 && "$1" != -- ]]; do
  shift
done
[[ $# -gt 0 ]] || exit 95
shift
exec "$@"
EOF

cat > "${BIN_DIR}/sbverify" <<'EOF'
#!/bin/bash
set -euo pipefail
script_dir=$(/usr/bin/dirname "$0")
test_dir=$(/usr/bin/dirname "$script_dir")
SIGNER_MODE=$(< "${script_dir}/signer-mode")
printf 'sbverify:%s\n' "$*" >> "${test_dir}/calls.log"
[[ $# -eq 2 && "$1" == --list && "$2" == /proc/self/fd/3 ]] || exit 94
[[ $(/usr/bin/od -An -N2 -tx1 "$2" | /usr/bin/tr -d '[:space:]') == 4d5a ]] || exit 93
case "$SIGNER_MODE" in
  2011)
    printf '%s\n' \
      'signature 1' \
      'image signature issuers:' \
      ' - /C=US/O=Microsoft Corporation/CN=Microsoft Windows Production PCA 2011' \
      'image signature certificates:'
    ;;
  2023)
    printf '%s\n' \
      'signature 1' \
      'image signature issuers:' \
      ' - /C=US/O=Microsoft Corporation/CN=Windows UEFI CA 2023' \
      'image signature certificates:'
    ;;
  both)
    printf '%s\n' \
      'signature 1' \
      'image signature issuers:' \
      ' - /C=US/O=Microsoft Corporation/CN=Microsoft Windows Production PCA 2011' \
      'image signature certificates:' \
      'signature 2' \
      'image signature issuers:' \
      ' - /C=US/O=Microsoft Corporation/CN=Windows UEFI CA 2023' \
      'image signature certificates:'
    ;;
  unknown)
    printf '%s\n' \
      'signature 1' \
      'image signature issuers:' \
      ' - /C=US/O=Example Corp/CN=Future Windows Signing CA 2040' \
      'image signature certificates:'
    ;;
  malformed) printf 'signature 1\n' ;;
  whitespace)
    printf '%s\n' \
      'signature 1' \
      '  image signature issuers:' \
      '   - /C=US/O=Microsoft Corporation/CN=Windows UEFI CA 2023' \
      '  image signature certificates:'
    ;;
  fail) exit 1 ;;
  *) exit 2 ;;
esac
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
  "${BIN_DIR}/dd" "${BIN_DIR}/setpriv" "${BIN_DIR}/sbverify" "${BIN_DIR}/gum"

export EFI_FIXTURE EFI_ERROR_FIXTURE LSBLK_FIXTURE FINDMNT_INVENTORY DEVICE_MAP
export BITLOCKER_DEVICES VFAT_DEVICES BLKID_UNKNOWN_DEVICES LOADER_DEVICES
export BAD_LOADER_DEVICES MOUNT_FAIL_DEVICES MOUNT_SIGNAL_DEVICES
export LOADER_SOURCE CALL_LOG GUM_LOG TEST_MOUNT_ID
export EFI_RC=0 LSBLK_RC=0 SIGNER_MODE=2023
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

windows_preflight_setpriv_path() {
  printf '%s/setpriv\n' "$BIN_DIR"
}

windows_preflight_sbverify_path() {
  if [[ "$SBVERIFY_AVAILABLE" != true ]]; then
    printf '%s/missing-sbverify\n' "$BIN_DIR"
    return 0
  fi
  printf '%s/sbverify\n' "$BIN_DIR"
}

windows_preflight_prepare_inspection_owner() {
  chmod 400 "$1"
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
  local target="$1" access="$2"
  mkdir -m 700 "$target"
  mkdir -p "${target}/EFI/Microsoft/Boot"
  cp "$LOADER_SOURCE" "${target}/EFI/Microsoft/Boot/bootmgfw.efi"
  printf '%s\n' "$TEST_MAJ_MIN" > "${target}/.maj"
  printf '%s\n' "$TEST_MOUNT_ID" > "${target}/.id"
  printf '%s\n' "$access" > "${target}/.access"
  : > "${target}/.reusable"
  jq -n --arg target "$target" --arg maj "$TEST_MAJ_MIN" \
    --arg access "$access" --argjson id "$TEST_MOUNT_ID" '{
    filesystems: [{
      target: $target,
      id: $id,
      "maj:min": $maj,
      fstype: "vfat",
      fsroot: "/",
      "vfs-options": ($access + ",nosuid,nodev,noexec,noatime")
    }]
  }' > "$FINDMNT_INVENTORY"
}

reset_case() {
  rm -rf "${TEST_DIR}/run" "${TEST_DIR}/reusable-esp" \
    "${TEST_DIR}/uncontrolled-esp"
  mkdir -m 700 "${TEST_DIR}/run"
  : > "$EFI_ERROR_FIXTURE"
  : > "$BITLOCKER_DEVICES"
  : > "$BLKID_UNKNOWN_DEVICES"
  : > "$LOADER_DEVICES"
  : > "$BAD_LOADER_DEVICES"
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
  SIGNER_MODE=2023
  GUM_EDITION=Home
  GUM_MANAGEMENT='Personal device'
  GUM_ADMIN_APPROVED=true
  GUM_RECOVERY_APPROVED=true
  GUM_PREPARATION_APPROVED=true
  GUM_AVAILABLE=true
  SBVERIFY_AVAILABLE=true
  LOCK_FAIL_LIMINE=false
  LOCK_FAIL_REPAIR=false
  _OMASECBOOT_LIMINE_LOCK_OWNED=false
  _OMASECBOOT_REPAIR_LOCK_OWNED=false
  QUIET=false
  export EFI_RC LSBLK_RC SIGNER_MODE GUM_EDITION GUM_MANAGEMENT
  export GUM_ADMIN_APPROVED GUM_RECOVERY_APPROVED GUM_PREPARATION_APPROVED
  export GUM_AVAILABLE LOCK_FAIL_LIMINE LOCK_FAIL_REPAIR
  export SBVERIFY_AVAILABLE
}

run_gate() {
  local output="$1"
  printf '%s\n' "$SIGNER_MODE" > "${BIN_DIR}/signer-mode"
  GATE_RC=0
  windows_encryption_gate > "$output" 2>&1 || GATE_RC=$?
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
    && compgen -G "${runtime}/bootmgfw.*" >/dev/null; then
    fail_test "private boot-manager copy was not cleaned"
  fi
  if [[ -d "$runtime" ]] \
    && compgen -G "${runtime}/windows-preflight-*/.mounted" >/dev/null; then
    fail_test "owned ESP mount was not cleaned"
  fi
}

case_output="${TEST_DIR}/case.out"

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
SIGNER_MODE=both
export GUM_EDITION SIGNER_MODE
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "ESP-loader-only signal did not trigger and pass the gate"
/usr/bin/grep -Fq '(known-both)' "$case_output" \
  || fail_test "multi-signature loader was not fully classified"
/usr/bin/grep -Fq 'Microsoft Windows Production PCA 2011' "$case_output" \
  || fail_test "2011 issuer metadata was not reported"
/usr/bin/grep -Fq 'Windows UEFI CA 2023' "$case_output" \
  || fail_test "2023 issuer metadata was not reported"
/usr/bin/grep -Fq 'iflag=fullblock,noatime' "$CALL_LOG" \
  || fail_test "full loader copy omitted O_NOATIME"
/usr/bin/grep -Fq -- '--reuid=nobody --regid=nobody --clear-groups' "$CALL_LOG" \
  || fail_test "signer inspection omitted real/effective identity drop"
/usr/bin/grep -Fq -- '--inh-caps=-all --ambient-caps=-all --bounding-set=-all' \
  "$CALL_LOG" || fail_test "signer inspection did not clear capabilities"
/usr/bin/grep -Fq 'sbverify:--list /proc/self/fd/3' "$CALL_LOG" \
  || fail_test "sbverify received an ESP or private-copy pathname"
assert_no_runtime_artifacts

reset_case
write_reusable_mount "${TEST_DIR}/reusable-esp" rw
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "controlled reusable ESP did not pass the gate"
/usr/bin/grep -Fq 'Boot manager: /dev/linux-esp (known-2023)' "$case_output" \
  || fail_test "controlled reusable ESP loader was not inspected"
if /usr/bin/grep -Fq 'mount:/dev/linux-esp:' "$CALL_LOG"; then
  fail_test "controlled reusable ESP was mounted again"
fi
/usr/bin/grep -Fq 'iflag=fullblock,noatime' "$CALL_LOG" \
  || fail_test "reusable writable ESP copy omitted O_NOATIME"
assert_no_runtime_artifacts

reset_case
write_reusable_mount "${TEST_DIR}/uncontrolled-esp" rw
chmod 777 "${TEST_DIR}/uncontrolled-esp"
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "uncontrolled writable ESP did not fail closed"
if /usr/bin/grep -Fq 'mount:/dev/linux-esp:' "$CALL_LOG"; then
  fail_test "uncontrolled writable ESP reached the owned-mount fallback"
fi
assert_no_runtime_artifacts

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
SIGNER_MODE=whitespace
export SIGNER_MODE
run_gate "$case_output"
[[ $GATE_RC -eq 0 && $_windows_preflight_result == prepared ]] \
  || fail_test "whitespace-tolerant signer fixture did not pass"
/usr/bin/grep -Fq '(known-2023)' "$case_output" \
  || fail_test "indented signer metadata was not classified"
assert_no_runtime_artifacts

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
SIGNER_MODE=unknown
export SIGNER_MODE
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "unknown signer metadata did not leave a technical blocker"
/usr/bin/grep -Fq 'Future Windows Signing CA 2040' "$case_output" \
  || fail_test "unknown sanitized issuer metadata was not reportable"
/usr/bin/grep -Fq 'maintainer review is required' "$case_output" \
  || fail_test "unknown issuer omitted maintainer disposition"
assert_no_runtime_artifacts

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
SIGNER_MODE=malformed
export SIGNER_MODE
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "malformed signer output did not leave a technical blocker"
/usr/bin/grep -Fq 'signer metadata could not be inspected' "$case_output" \
  || fail_test "malformed signer output omitted its disposition"
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

reset_case
printf '/dev/linux-esp\n' > "$LOADER_DEVICES"
SBVERIFY_AVAILABLE=false
export SBVERIFY_AVAILABLE
run_gate "$case_output"
[[ $GATE_RC -eq 2 && $_windows_preflight_result == technical-unknown ]] \
  || fail_test "missing sbverify did not leave a technical blocker"
/usr/bin/grep -Fq 'requires sbsigntools (/usr/bin/sbverify)' "$case_output" \
  || fail_test "missing sbverify omitted its prerequisite"
if /usr/bin/grep -Fq 'dd:' "$CALL_LOG"; then
  fail_test "missing sbverify still copied the boot manager"
fi
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
/usr/bin/grep -Fq 'Boot manager: /dev/esp-a (known-2023)' "$case_output" \
  || fail_test "first ESP result was lost when the second ESP failed"
/usr/bin/grep -Fq 'failed safely on ESP /dev/esp-b' "$case_output" \
  || fail_test "second ESP failure omitted its device-specific blocker"
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
