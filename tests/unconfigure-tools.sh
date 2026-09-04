#!/bin/bash
# shellcheck disable=SC1091,SC2218 # Tests source modules and override dependency probes.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-unconfigure-tools.XXXXXX")

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=../lib/discover.sh
source "${ROOT_DIR}/lib/discover.sh"
# shellcheck source=../lib/sign.sh
source "${ROOT_DIR}/lib/sign.sh"
# shellcheck source=../lib/producers.sh
source "${ROOT_DIR}/lib/producers.sh"

[[ $(limine_install_path) == /usr/bin/limine-install \
  && $(limine_mkinitcpio_path) == /usr/bin/limine-mkinitcpio \
  && $(limine_reset_enroll_path) == /usr/bin/limine-reset-enroll ]] \
  || fail_test "production Limine tool paths are not pinned"

INSTALL="${TEST_DIR}/limine-install"
MKINITCPIO="${TEST_DIR}/limine-mkinitcpio"
RESET="${TEST_DIR}/limine-reset-enroll"
cp /bin/true "$INSTALL"
cp /bin/true "$MKINITCPIO"
cp /bin/true "$RESET"
PIN_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"
PIN_OWNER=limine-mkinitcpio-hook

limine_install_path() { printf '%s\n' "$INSTALL"; }
limine_mkinitcpio_path() { printf '%s\n' "$MKINITCPIO"; }
limine_reset_enroll_path() { printf '%s\n' "$RESET"; }
validate_control_file() { [[ -f "$1" ]]; }
producer_package_version() { printf '%s\n' "$PIN_VERSION"; }
producer_file_owner_package() { printf '%s\n' "$PIN_OWNER"; }

unconfigure_limine_tools_are_pinned \
  || fail_test "supported package-owned Limine tools were rejected"
PIN_OWNER=unrelated-package
if unconfigure_limine_tools_are_pinned; then
  fail_test "Limine tool owned by another package was accepted"
fi
PIN_OWNER=limine-mkinitcpio-hook
PIN_VERSION=1.37.1-1
if unconfigure_limine_tools_are_pinned; then
  fail_test "unsupported Limine tool package version was accepted"
fi
PIN_VERSION="$SUPPORTED_LIMINE_MKINITCPIO_VERSION"

_unconfigure_limine_tools_json=$(capture_unconfigure_limine_tools) \
  || fail_test "could not capture Limine tool evidence"
run_bound_unconfigure_limine_tool install false \
  || fail_test "bound Limine tool inode was not executable"
printf 'tampered\n' > "$INSTALL"
chmod 755 "$INSTALL"
if unconfigure_limine_tools_match_intent; then
  fail_test "byte-replaced Limine tool matched immutable evidence"
fi
cp /bin/true "${TEST_DIR}/replacement"
mv -f "${TEST_DIR}/replacement" "$INSTALL"
if unconfigure_limine_tools_match_intent; then
  fail_test "path-replaced Limine tool matched immutable identity"
fi

printf 'unconfigure tool tests passed\n'
