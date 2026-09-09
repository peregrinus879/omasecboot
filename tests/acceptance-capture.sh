#!/bin/bash
# shellcheck disable=SC2016 # Single-quoted bash -c snippets and Markdown backticks are intentional.
# Acceptance capture for docs/release-checklist.md rows.
#
# Usage (as root, from a terminal):
#   sudo bash tests/acceptance-capture.sh <row> [-- command [args...]]
#
# Records the machine and package state before the row, runs the command with
# a full terminal transcript (interactive prompts included), records the state
# again, and writes one self-contained Markdown file per run under
# ${OMASECBOOT_ACCEPTANCE_DIR:-$PWD/acceptance-records}. Without a command it
# records a state checkpoint only, for rows that are firmware-menu steps.
#
# It never records DMI serial numbers or UUIDs, MAC or NVMe device-path nodes,
# recovery keys, or raw firmware backup payloads (that directory is listed by
# name and size). It does record partition identifiers, boot IDs, and the
# lifecycle records, which the review needs.
set -uo pipefail

usage() {
  printf 'usage: sudo bash %s <row> [-- command [args...]]\n' "${BASH_SOURCE[0]##*/}" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
row="$1"
shift
[[ "$row" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || usage
command_args=()
if [[ $# -gt 0 ]]; then
  [[ "$1" == -- ]] || usage
  shift
  [[ $# -gt 0 ]] || usage
  command_args=("$@")
fi
[[ $EUID -eq 0 ]] || { printf 'run this with sudo; it reads root-only lifecycle state\n' >&2; exit 2; }
command -v script >/dev/null 2>&1 || { printf 'util-linux script is required\n' >&2; exit 2; }

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out_dir="${OMASECBOOT_ACCEPTANCE_DIR:-$PWD/acceptance-records}"
mkdir -p "$out_dir" || exit 2
stamp=$(date -u +%Y%m%dT%H%M%SZ)
out="${out_dir}/${stamp}-${row}.md"
transcript="${out_dir}/.${stamp}-${row}.transcript"
state_dir=/var/lib/omasecboot

section() {
  printf '\n## %s\n\n' "$1" >> "$out"
}

block() { # title, then command...
  local title="$1"
  shift
  {
    printf '\n### %s\n\n```text\n$ %s\n' "$title" "$*"
    "$@" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true
    printf '```\n'
  } >> "$out"
}

# Version strings repeat across candidates, so the record compares the
# installed payload byte for byte with the checkout the recorder runs from.
compare_installed_payload() {
  local installed source mismatches=0
  for installed in /usr/bin/omasecboot /usr/lib/omasecboot/*.sh; do
    case "$installed" in
      /usr/bin/omasecboot) source="${root_dir}/bin/omasecboot" ;;
      *) source="${root_dir}/lib/${installed##*/}" ;;
    esac
    if [[ ! -e "$installed" ]]; then
      printf 'missing: %s\n' "$installed"
      mismatches=$((mismatches + 1))
    elif cmp -s "$installed" "$source"; then
      printf 'match: %s\n' "$installed"
    else
      printf 'MISMATCH: %s differs from %s\n' "$installed" "$source"
      mismatches=$((mismatches + 1))
    fi
  done
  for source in "${root_dir}"/lib/*.sh; do
    [[ -e "/usr/lib/omasecboot/${source##*/}" ]] || {
      printf 'not installed: %s\n' "$source"
      mismatches=$((mismatches + 1))
    }
  done
  if [[ $mismatches -eq 0 ]]; then
    printf 'installed payload matches checkout: yes\n'
  else
    printf 'installed payload matches checkout: no (%s)\n' "$mismatches"
  fi
}

file_block() { # title path
  local title="$1" path="$2"
  {
    printf '\n### %s\n\n' "$title"
    if [[ -f "$path" ]]; then
      printf '```text\n'
      sed 's/\x1b\[[0-9;]*m//g' "$path"
      printf '```\n'
    else
      printf '_absent_\n'
    fi
  } >> "$out"
}

capture_state() {
  local phase="$1" manifest incident
  section "State ${phase}"
  block "Time (UTC)" date -u +%Y-%m-%dT%H:%M:%SZ
  block "Kernel" uname -r
  block "Firmware and machine model" bash -c 'for f in sys_vendor product_name product_family bios_vendor bios_version bios_date; do printf "%s=%s\n" "$f" "$(cat /sys/class/dmi/id/$f 2>/dev/null)"; done'
  block "Omarchy version" bash -c 'pacman -Q omarchy omarchy-settings 2>&1; cat /usr/share/omarchy/version 2>/dev/null'
  block "Pinned and related packages" pacman -Q omasecboot limine-mkinitcpio-hook limine-snapper-sync sbctl efibootmgr coreutils limine util-linux jq gum openssl
  block "Checkout revision and dirty state" bash -c "git -C '${root_dir}' rev-parse HEAD 2>&1; git -C '${root_dir}' status --porcelain 2>&1 | sed 's/^/dirty: /'"
  block "Installed payload hashes" bash -c 'sha256sum /usr/bin/omasecboot /usr/lib/omasecboot/*.sh 2>&1'
  block "Installed payload versus checkout" compare_installed_payload
  block "Secure Boot variables" bash -c 'for v in SecureBoot SetupMode AuditMode DeployedMode; do p=$(ls /sys/firmware/efi/efivars/${v}-* 2>/dev/null | head -1); if [[ -n $p ]]; then printf "%s=%s\n" "$v" "$(od -An -tu1 -j4 -N1 "$p" | tr -d " ")"; else printf "%s=absent\n" "$v"; fi; done'
  block "sbctl status" sbctl status
  block "sbctl list-files" sbctl list-files
  block "sbctl verify" sbctl verify
  block "omasecboot status" bash -c 'if command -v omasecboot >/dev/null; then omasecboot status; printf "exit status: %s\n" "$?"; else echo "omasecboot is not installed"; fi'
  block "omasecboot version" bash -c 'command -v omasecboot >/dev/null && omasecboot version || echo "omasecboot is not installed"'
  block "Boot entries (MAC and NVMe nodes redacted)" bash -c 'efibootmgr -v 2>&1 | sed -E "s/MAC\([^)]*\)/MAC(redacted)/g; s/NVMe\([^)]*\)/NVMe(redacted)/g"'
  block "ESP mount" findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /boot
  block "Installed hooks" bash -c 'ls -la /usr/share/libalpm/hooks/*omasecboot* /etc/pacman.d/hooks/*omasecboot* /etc/boot/hooks/pre.d/*omasecboot* /etc/boot/hooks/post.d/*omasecboot* 2>&1; sha256sum /usr/share/libalpm/hooks/*omasecboot* /etc/boot/hooks/*/*omasecboot* 2>/dev/null'
  block "Stale source install" bash -c 'ls -la /usr/local/bin/omasecboot /usr/local/lib/omasecboot 2>&1'
  block "EFI artifacts" bash -c 'find /boot/EFI -type f \( -iname "*.efi" -o -name "*.efi_*" \) -exec sha256sum {} + 2>/dev/null | sort -k2'
  block "Limine checksum enrollment (first 16 hex digits)" bash -c 'for f in /boot/EFI/limine/limine_x64.efi /boot/EFI/BOOT/BOOTX64.EFI; do h=$(grep -a -o "++CONFIG_B2SUM_SIGNATURE++[0-9a-f]\{128\}" "$f" 2>/dev/null | head -1 | cut -c27-42); printf "%s: %s\n" "$f" "${h:-absent}"; done; printf "limine.conf b2sum: "; b2sum /boot/limine.conf | cut -c1-16'
  file_block "/etc/default/limine" /etc/default/limine
  file_block "/boot/limine.conf" /boot/limine.conf
  block "Lifecycle directory" bash -c "ls -laR ${state_dir} 2>&1 | grep -v -E '^\s*$'"
  block "Firmware backup listing (names and sizes only)" bash -c "find ${state_dir}/firmware-backup -type f -printf '%s %p\n' 2>/dev/null | sort -k2"
  file_block "lifecycle.json" "${state_dir}/lifecycle.json"
  file_block "windows-enabled" "${state_dir}/windows-enabled"
  manifest=$(find "${state_dir}/transactions" -mindepth 2 -maxdepth 2 -name manifest.json -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  if [[ -n "$manifest" ]]; then
    file_block "Newest transaction manifest (${manifest})" "$manifest"
    incident="${manifest%/manifest.json}/incident.json"
    file_block "Incident seal for that transaction" "$incident"
  else
    printf '\n### Newest transaction manifest\n\n_none_\n' >> "$out"
  fi
  block "Boot journal for omasecboot, limine, sbctl (last 200 lines)" bash -c "journalctl -b --no-pager -o short-iso 2>/dev/null | grep -i -E 'omasecboot|limine|sbctl|efibootmgr' | tail -200"
}

{
  printf '# Acceptance record %s\n\n' "$row"
  printf -- '- Row: `%s`\n- Captured: %s\n- Command: `%s`\n' "$row" "$stamp" "${command_args[*]:-(state checkpoint only)}"
} > "$out"

capture_state before

rc="n/a"
if [[ ${#command_args[@]} -gt 0 ]]; then
  section "Command transcript"
  printf 'Running: `%s`\n\n' "${command_args[*]}" >> "$out"
  printf '=== omasecboot acceptance %s: %s ===\n' "$row" "${command_args[*]}"
  script -q -e -c "$(printf '%q ' "${command_args[@]}")" "$transcript"
  rc=$?
  {
    printf '```text\n'
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r$//' "$transcript"
    printf '```\n\nExit status: `%s`\n' "$rc"
  } >> "$out"
  rm -f "$transcript"
  capture_state after
fi

if [[ -n "${SUDO_USER:-}" ]]; then
  chown "$SUDO_USER" "$out_dir" "$out" 2>/dev/null || true
fi
printf '\nRecord written: %s (exit status %s)\n' "$out" "$rc"
