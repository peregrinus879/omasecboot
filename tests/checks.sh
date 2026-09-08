#!/bin/bash
# shellcheck disable=SC2329 # Overrides are invoked indirectly by the code under test.
# Hermetic checks for lib/checks.sh: each environment check dies with its
# message when its precondition is missing and is silent otherwise. Every
# case runs in a subshell with only the shims on PATH.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-checks.XXXXXX")
BIN_DIR="${TEST_DIR}/bin"
mkdir -p "$BIN_DIR" "${TEST_DIR}/esp/EFI" "${TEST_DIR}/firmware/efi/efivars"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/checks.sh"

esp_path() { printf '%s/esp\n' "$TEST_DIR"; }
efivars_path() { printf '%s/firmware/efi/efivars\n' "$TEST_DIR"; }

shim() {
  local name="$1" body="${2:-exit 0}"
  printf '#!/bin/bash\n%s\n' "$body" > "${BIN_DIR}/${name}"
  chmod 755 "${BIN_DIR}/${name}"
}

# Runs one check with only the shims on PATH; prints its status then its output.
run_check() {
  local rc=0 output
  output=$(PATH="$BIN_DIR" "$@" 2>&1) || rc=$?
  printf '%s\n%s\n' "$rc" "$output"
}

expect_pass() {
  local description="$1" result
  shift
  result=$(run_check "$@")
  [[ "${result%%$'\n'*}" == 0 ]] || fail_test "${description}: ${result#*$'\n'}"
}

expect_die() {
  local description="$1" message="$2" result
  shift 2
  result=$(run_check "$@")
  [[ "${result%%$'\n'*}" == 1 ]] || fail_test "${description} did not die"
  [[ "${result#*$'\n'}" == *"$message"* ]] \
    || fail_test "${description} died without its message: ${result#*$'\n'}"
}

for tool in sbctl jq limine b2sum openssl gum flock sha256sum stat mountpoint; do
  shim "$tool"
done
shim findmnt 'printf "vfat\n"'

[[ $EUID -ne 0 ]] || fail_test "run the checks suite as an unprivileged user"
expect_die "check_root as an unprivileged user" "Root required" check_root setup

expect_pass "core dependencies present" check_core_deps
rm -f "${BIN_DIR}/sbctl"
expect_die "check_core_deps without sbctl" "sbctl not installed" check_core_deps
shim sbctl
rm -f "${BIN_DIR}/jq"
expect_die "check_core_deps without jq" "jq not installed" check_core_deps
shim jq

expect_pass "recovery dependencies present" check_recovery_deps
rm -f "${BIN_DIR}/flock"
expect_die "check_recovery_deps without flock" "Recovery dependency not installed: flock" \
  check_recovery_deps
shim flock

expect_pass "mutation dependencies and ESP present" check_deps
for tool in limine b2sum openssl; do
  rm -f "${BIN_DIR}/${tool}"
  expect_die "check_deps without ${tool}" "${tool} not installed" check_deps
  shim "$tool"
done

expect_pass "ESP mounted as vfat" check_esp_mount
shim findmnt 'printf "ext4\n"'
expect_die "check_esp_mount on a non-FAT mount" "is not mounted as the FAT32 ESP" check_esp_mount
shim findmnt 'printf "vfat\n"'
shim mountpoint 'exit 1'
expect_die "check_esp_mount on a plain directory" "is not mounted as the FAT32 ESP" check_esp_mount
shim mountpoint
rmdir "${TEST_DIR}/esp/EFI"
expect_die "check_esp_mount without an EFI directory" "EFI not found" check_esp_mount
mkdir "${TEST_DIR}/esp/EFI"
rm -f "${BIN_DIR}/findmnt"
expect_die "check_esp_mount without findmnt" "util-linux" check_esp_mount
shim findmnt 'printf "vfat\n"'

expect_pass "UEFI firmware directory present" check_efi_mode
rm -rf "${TEST_DIR}/firmware"
expect_die "check_efi_mode without firmware" "did not boot in UEFI mode" check_efi_mode
mkdir -p "${TEST_DIR}/firmware/efi/efivars"

expect_pass "gum present" require_gum
rm -f "${BIN_DIR}/gum"
expect_die "require_gum without gum" "gum not installed" require_gum

printf 'checks tests passed\n'
