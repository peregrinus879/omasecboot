#!/bin/bash
# shellcheck disable=SC2016 # bash -c snippets and Markdown backticks are single-quoted on purpose.
# The recorder for the hardware rows of docs/release-checklist.md.
#
#   sudo bash tests/acceptance-record.sh <row> [-- command [args...]]
#
# Records the machine's state, runs the command with a full terminal
# transcript (prompts included), records the state again, and writes one
# Markdown file per run under ${OMASECBOOT_ACCEPTANCE_DIR:-$PWD/acceptance-records}.
# Without a command it records the state only, for rows that are steps in the
# firmware's menus.
#
# Never recorded: DMI serial numbers and UUIDs, MAC and NVMe device-path
# nodes, recovery keys, firmware backup payloads (listed by name and size).
# Partition identifiers and the tool's small state files are recorded, because
# the review needs them.
set -uo pipefail

usage() {
  printf 'usage: sudo bash %s <row> [-- command [args...]]\n' "${BASH_SOURCE[0]##*/}" >&2
  exit 2
}

(( $# >= 1 )) || usage
row=$1
shift
[[ $row =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || usage
command_args=()
if (( $# > 0 )); then
  { [[ $1 == -- ]] && (( $# > 1 )); } || usage
  shift
  command_args=("$@")
fi
(( EUID == 0 )) || {
  printf 'Run this with sudo: it reads the ESP and root-only state\n' >&2
  exit 2
}
command -v script >/dev/null 2>&1 || {
  printf 'script from util-linux is required\n' >&2
  exit 2
}

root_dir=$(realpath "${BASH_SOURCE[0]%/*}/..")
records_dir=${OMASECBOOT_ACCEPTANCE_DIR:-$PWD/acceptance-records}
mkdir -p "$records_dir" || exit 2
stamp=$(date -u +%Y%m%dT%H%M%SZ)
record=${records_dir}/${stamp}-${row}.md
transcript=${records_dir}/.${stamp}-${row}.transcript
state_dir=/var/lib/omasecboot
# Omarchy mounts the ESP at /boot; another mount point is given in the environment.
export esp=${OMASECBOOT_ESP:-/boot}

# shellcheck source=tests/lib/transcript.sh
source "$root_dir/tests/lib/transcript.sh"

section() { printf '\n## %s\n\n' "$1" >>"$record"; }

# block TITLE COMMAND...: the command line and everything it printed.
block() {
  local title=$1
  shift
  {
    printf '\n### %s\n\n```text\n$ %s\n' "$title" "$*"
    "$@" 2>&1 | strip_terminal_control
    printf '```\n'
  } >>"$record"
}

# file_block TITLE PATH
file_block() {
  {
    printf '\n### %s\n\n' "$1"
    if [[ -f $2 ]]; then
      printf '```text\n'
      strip_terminal_control "$2"
      printf '```\n'
    else
      printf '_absent_\n'
    fi
  } >>"$record"
}

# Version strings repeat across candidates, so the installed files are compared
# byte for byte with the checkout the recorder runs from. The hook and the
# units are installed with the command's directory filled in.
compare_installed_files() {
  local source installed
  local -A installed_as=([bin/omasecboot]=/usr/bin/omasecboot
    [limine/90-omasecboot-sign]=/etc/boot/hooks/post.d/90-omasecboot-sign
    ["systemd/omasecboot-watch@.path"]=/usr/lib/systemd/system/omasecboot-watch@.path
    ["systemd/omasecboot-watch@.service"]=/usr/lib/systemd/system/omasecboot-watch@.service)
  for source in "$root_dir"/lib/*.sh; do
    installed_as[lib/${source##*/}]=/usr/lib/omasecboot/${source##*/}
  done
  for source in "${!installed_as[@]}"; do
    installed=${installed_as[$source]}
    if [[ -e $installed ]] && sed 's|@BINDIR@|/usr/bin|g' "$root_dir/$source" | cmp -s - "$installed"; then
      printf 'match: %s\n' "$installed"
    else
      printf 'DIFFERENT OR MISSING: %s\n' "$installed"
    fi
  done | LC_ALL=C sort
  for installed in /usr/lib/omasecboot/*.sh; do
    [[ ! -e $installed || -e $root_dir/lib/${installed##*/} ]] || printf 'NOT IN THE CHECKOUT: %s\n' "$installed"
  done
}

boot_entries() { efibootmgr -v 2>&1 | strip_boot_entry_bytes; }

record_state() {
  section "State $1"
  block "Time (UTC)" date -u +%Y-%m-%dT%H:%M:%SZ
  block "Kernel" uname -r
  block "Firmware and machine model" bash -c 'for f in sys_vendor product_name product_family bios_vendor bios_version bios_date; do printf "%s=%s\n" "$f" "$(cat /sys/class/dmi/id/$f 2>/dev/null)"; done'
  block "Omarchy version" bash -c 'pacman -Q omarchy omarchy-settings 2>&1; cat /usr/share/omarchy/version 2>/dev/null'
  block "Related packages" pacman -Q omasecboot limine limine-mkinitcpio-hook limine-snapper-sync sbctl efibootmgr snapper systemd jq gum
  block "Checkout revision and uncommitted changes" bash -c "git -C '$root_dir' rev-parse HEAD 2>&1; git -C '$root_dir' status --porcelain 2>&1 | sed 's/^/changed: /'"
  block "Installed files versus the checkout" compare_installed_files
  block "Leftovers of an install made without pacman" bash -c 'ls -la /usr/local/bin/omasecboot /usr/local/lib/omasecboot /etc/pacman.d/hooks/*omasecboot* /etc/boot/hooks/post.d/zzz-omasecboot-sign 2>&1'
  block "Limine hook directories" bash -c 'ls -la /etc/boot/hooks/pre.d /etc/boot/hooks/post.d 2>&1'
  block "pacman hooks that name Limine or this tool" bash -c 'grep -l -i -E "limine|omasecboot" /etc/pacman.d/hooks/*.hook /usr/share/libalpm/hooks/*.hook 2>/dev/null | while IFS= read -r hook; do printf "%s (%s)\n" "$hook" "$(pacman -Qqo "$hook" 2>/dev/null || echo "owned by no package")"; grep -E "^(Operation|Target|When|Exec) *=" "$hook" | sed "s/^/    /"; done'
  block "Secure Boot variables" bash -c 'for v in SecureBoot SetupMode AuditMode DeployedMode; do p=$(ls /sys/firmware/efi/efivars/${v}-* 2>/dev/null | head -1); if [[ -n $p ]]; then printf "%s=%s\n" "$v" "$(od -An -tu1 -j4 -N1 "$p" | tr -d " ")"; else printf "%s=absent\n" "$v"; fi; done'
  block "sbctl status" sbctl status
  block "sbctl list-files" sbctl list-files
  block "sbctl verify" sbctl verify
  block "omasecboot status" bash -c 'if command -v omasecboot >/dev/null; then omasecboot status; printf "exit status: %s\n" "$?"; else echo "omasecboot is not installed"; fi'
  block "omasecboot windows status" bash -c 'if command -v omasecboot >/dev/null; then omasecboot windows status 2>&1; else echo "omasecboot is not installed"; fi'
  block "BootNext" bash -c 'p=$(ls /sys/firmware/efi/efivars/BootNext-* 2>/dev/null | head -1); if [[ -n $p ]]; then od -An -tx1 -j4 "$p"; else echo absent; fi'
  block "Watchers" bash -c 'systemctl list-units --all --no-pager "omasecboot-watch@*" 2>&1; systemctl list-unit-files --no-pager "omasecboot-watch@*" 2>&1'
  block "Boot entries (MAC and NVMe nodes redacted, raw bytes left out)" boot_entries
  block "ESP mount, free space and partitions" bash -c 'findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS $esp 2>&1; df -h $esp 2>&1; lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINTS 2>&1'
  block "EFI files" bash -c 'find $esp/EFI -type f \( -iname "*.efi" -o -name "*.efi_*" \) -exec sha256sum {} + 2>/dev/null | sort -k2'
  block "Snapshot images kept by limine-snapper-sync" bash -c 'find $esp -path "*/limine_history/*" -type f -exec sha256sum {} + 2>/dev/null | sort -k2'
  block "Snapshot list kept by limine-snapper-sync (first 60 lines)" bash -c 'find $esp -path "*/limine_history/snapshots.json" -exec head -n 60 {} + 2>&1'
  block "Snapshots" bash -c 'snapper -c root list 2>&1'
  block "Limine loader directories" bash -c 'ls -la $esp/EFI/limine $esp/EFI/BOOT 2>&1'
  block "Limine path hashes versus files" bash -c 'grep -o "boot():/[^#[:space:]]*#[0-9A-Fa-f]\{128\}" $esp/limine.conf 2>/dev/null | sort -u | while IFS= read -r uri; do file="$esp/${uri#boot():/}"; file="${file%#*}"; hash="${uri##*#}"; if [ -f "$file" ]; then actual=$(b2sum "$file" | cut -d" " -f1); [ "$actual" = "$hash" ] && printf "match  %s\n" "$uri" || printf "STALE  %s\n" "$uri"; else printf "absent %s\n" "$uri"; fi; done; true'
  block "Config checksum in each loader (first 16 hex digits)" bash -c 'for f in $esp/EFI/limine/limine_x64.efi $esp/EFI/BOOT/BOOTX64.EFI; do h=$(grep -a -o "++CONFIG_B2SUM_SIGNATURE++[0-9a-f]\{128\}" "$f" 2>/dev/null | head -1 | cut -c27-42); printf "%s: %s\n" "$f" "${h:-absent}"; done; printf "limine.conf b2sum: "; b2sum $esp/limine.conf | cut -c1-16'
  block "Limine config layers (owner, mode, links)" bash -c 'stat -c "%U:%G %a %h %n" /etc/default/limine /etc/limine-entry-tool.conf /etc/limine-entry-tool.d/*.conf /usr/share/limine-entry-tool.d/*.conf 2>&1'
  block "Limine drop-in settings" bash -c 'grep -H -v "^[[:space:]]*#" /etc/limine-entry-tool.d/*.conf /usr/share/limine-entry-tool.d/*.conf 2>&1 | grep -v ":$"'
  file_block "/etc/default/limine" /etc/default/limine
  file_block "limine.conf" "$esp/limine.conf"
  block "State directory" bash -c "ls -laR $state_dir 2>&1 | grep -v '^\$'"
  block "Firmware backups (names and sizes only)" bash -c "find $state_dir/firmware-backup -type f -printf '%s %p\n' 2>/dev/null | sort -k2"
  file_block "settings-originals" "$state_dir/settings-originals"
  file_block "needs-attention" "$state_dir/needs-attention"
  block "This boot's journal for omasecboot, limine, sbctl (last 200 lines)" bash -c "journalctl -b --no-pager -o short-iso 2>/dev/null | grep -i -E 'omasecboot|limine|sbctl|efibootmgr' | tail -200"
}

{
  printf '# Acceptance record %s\n\n' "$row"
  printf -- '- Row: `%s`\n- Recorded: %s\n- Command: `%s`\n' "$row" "$stamp" "${command_args[*]:-(state only)}"
} >"$record"

record_state before

status=none
if (( ${#command_args[@]} > 0 )); then
  section "Command transcript"
  printf 'Running: `%s`\n\n' "${command_args[*]}" >>"$record"
  printf '=== omasecboot acceptance %s: %s ===\n' "$row" "${command_args[*]}"
  script -q -e -c "$(printf '%q ' "${command_args[@]}")" "$transcript"
  status=$?
  {
    printf '```text\n'
    strip_terminal_control "$transcript"
    printf '```\n\nExit status: `%s`\n' "$status"
  } >>"$record"
  rm -f -- "$transcript"
  record_state after
fi

[[ -z ${SUDO_USER:-} ]] || chown "$SUDO_USER" "$records_dir" "$record" 2>/dev/null
printf '\nRecord written: %s (exit status %s)\n' "$record" "$status"
