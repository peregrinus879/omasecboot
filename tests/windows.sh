#!/bin/bash
# shellcheck disable=SC2329 # Test overrides are called through the sourced dispatcher.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-windows.XXXXXX")
BIN_DIR="${TEST_DIR}/bin"
CALL_LOG="${TEST_DIR}/calls.log"
ORIGINAL_PATH=$PATH

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$BIN_DIR"
: > "$CALL_LOG"

cat > "${BIN_DIR}/efibootmgr" <<'EOF'
#!/bin/bash
set -euo pipefail

case "${1:-}" in
  -v)
    if [[ "${EFI_AVAILABLE:-true}" == true ]]; then
      printf 'Boot0007* Windows Boot Manager\tHD(1,GPT,11111111-2222-3333-4444-555555555555,0x800,0x100000)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)\n'
    fi
    ;;
  -n)
    printf 'bootnext:%s\n' "$2" >> "$CALL_LOG"
    ;;
  "")
    if [[ "${EFI_AVAILABLE:-true}" == true ]]; then
      printf 'Boot0007* Windows Boot Manager\n'
    fi
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat > "${BIN_DIR}/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'systemctl:%s\n' "$*" >> "$CALL_LOG"
EOF

cat > "${BIN_DIR}/gum" <<'EOF'
#!/bin/bash
set -euo pipefail
printf 'gum:%s\n' "$*" >> "$CALL_LOG"
EOF

chmod +x "${BIN_DIR}/efibootmgr" "${BIN_DIR}/systemctl" "${BIN_DIR}/gum"
export CALL_LOG EFI_AVAILABLE=true
PATH="${BIN_DIR}:${ORIGINAL_PATH}"
export PATH

# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"

available_output=$(cmd_windows available) || fail_test "available did not find Windows"
[[ -z "$available_output" ]] || fail_test "available produced output"

EFI_AVAILABLE=false
export EFI_AVAILABLE
if cmd_windows available > "${TEST_DIR}/available.out" 2>&1; then
  fail_test "available succeeded without a Windows firmware entry"
fi
[[ ! -s "${TEST_DIR}/available.out" ]] || fail_test "unavailable probe produced output"
EFI_AVAILABLE=true
export EFI_AVAILABLE

: > "$CALL_LOG"
set_windows_bootnext > "${TEST_DIR}/bootnext.out"
grep -Fxq 'bootnext:0007' "$CALL_LOG" || fail_test "BootNext used the wrong firmware entry"
grep -Fq 'next boot still enters Windows once' "${TEST_DIR}/bootnext.out" \
  || fail_test "BootNext residue was not disclosed"
if grep -Fq 'systemctl:' "$CALL_LOG"; then
  fail_test "BootNext-only path rebooted"
fi

: > "$CALL_LOG"
reboot_to_windows > /dev/null
grep -Fxq 'bootnext:0007' "$CALL_LOG" || fail_test "reboot path did not set BootNext"
grep -Fxq 'systemctl:reboot' "$CALL_LOG" || fail_test "reboot path did not reboot"

check_root() {
  printf 'forbidden:root:%s\n' "$1" >> "$CALL_LOG"
}
check_deps() {
  printf 'forbidden:deps\n' >> "$CALL_LOG"
  return 1
}
require_gum() {
  printf 'forbidden:gum\n' >> "$CALL_LOG"
  return 1
}
add_windows_boot_entry() {
  printf 'forbidden:add\n' >> "$CALL_LOG"
  return 1
}

: > "$CALL_LOG"
for mutation in setup bootnext reboot; do
  if cmd_windows "$mutation" > "${TEST_DIR}/${mutation}.out" 2>&1; then
    fail_test "unsafe Windows ${mutation} mutation succeeded"
  fi
done
if grep -Fq 'forbidden:' "$CALL_LOG"; then
  fail_test "blocked Windows command reached a legacy mutation path"
fi
grep -Fq 'firmware target identity can be proven' "${TEST_DIR}/setup.out" \
  || fail_test "blocked Windows setup omitted its safety reason"
grep -Fq 'persisted Windows firmware target can be revalidated' \
  "${TEST_DIR}/bootnext.out" \
  || fail_test "blocked BootNext omitted its safety reason"

if cmd_windows > "${TEST_DIR}/windows-help.out" 2>&1; then
  fail_test "bare windows command succeeded"
fi
grep -Fq 'windows <command>' "${TEST_DIR}/windows-help.out" \
  || fail_test "bare windows command did not show focused help"

if cmd_windows unknown > "${TEST_DIR}/windows-unknown.out" 2>&1; then
  fail_test "unknown windows command succeeded"
fi
grep -Fq 'Unknown Windows command: unknown' "${TEST_DIR}/windows-unknown.out" \
  || fail_test "unknown windows command was not reported"

menu_file="${ROOT_DIR}/omarchy/omarchy-menu.jsonc"
jq -e '."system.windows"' "$menu_file" >/dev/null \
  || fail_test "Quattro menu fragment is invalid"
[[ $(jq -r '."system.windows".action' "$menu_file") == \
  "omarchy-launch-floating-terminal-with-presentation 'sudo omasecboot windows bootnext && omarchy system reboot'" ]] \
  || fail_test "Quattro menu action does not use BootNext plus graceful reboot"
grep -Fq 'omasecboot windows available' "$menu_file" \
  || fail_test "Quattro menu entry lacks its availability guard"

PATH="${ROOT_DIR}/bin:${BIN_DIR}:${ORIGINAL_PATH}" \
  bash -c 'command -v omasecboot >/dev/null && omasecboot windows available' \
  || fail_test "Quattro menu guard failed with Windows available"

printf 'windows tests passed\n'
