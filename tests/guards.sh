#!/bin/bash
# shellcheck disable=SC2154 # Assertions read globals set by lifecycle functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

removal_hook="${ROOT_DIR}/pacman-hooks/00-omasecboot-removal-guard.hook"
guard_hook="${ROOT_DIR}/pacman-hooks/00-omasecboot-transition-guard.hook"
cleanup_hook="${ROOT_DIR}/pacman-hooks/zz-omasecboot-cleanup.hook"
repair_hook="${ROOT_DIR}/pacman-hooks/zzz-omasecboot.hook"
grep -Fxq 'When = PreTransaction' "$guard_hook" \
  || fail_test "package guard is not a pre-transaction hook"
grep -Fxq 'AbortOnFail' "$guard_hook" \
  || fail_test "package guard cannot abort a transaction"
grep -Fxq 'Exec = @BINDIR@/omasecboot --quiet guard transaction' "$guard_hook" \
  || fail_test "package guard does not call the canonical transition check"
grep -Fxq 'Target = boot/*' "$guard_hook" \
  || fail_test "package guard does not cover boot artifacts"
grep -Fxq 'Target = efi/*' "$guard_hook" \
  || fail_test "package guard does not cover ESP artifacts"
collect_hook_targets() {
  local line
  while IFS= read -r line; do
    [[ "$line" == 'Target = '* ]] || continue
    printf '%s\n' "${line#Target = }"
  done < "$1"
}
expected_removal_targets=$(sort <<'EOF'
b3sum
bash
btrfs-progs
coreutils
efibootmgr
findutils
gawk
grep
inotify-tools
jq
libnotify
limine
limine-mkinitcpio-hook
limine-snapper-sync
mkinitcpio
omarchy
omarchy-settings
omasecboot
openssl
pacman
sbctl
snapper
systemd
tar
util-linux
xxhash
EOF
)
[[ $(collect_hook_targets "$removal_hook" | sort) == "$expected_removal_targets" ]] \
  || fail_test "recovery-dependency removal registry drifted"
printf '%s\n' "${removal_hook##*/}" "${guard_hook##*/}" | LC_ALL=C sort -C \
  || fail_test "removal guard no longer sorts before the producer guard"
grep -Fxq 'Type = Package' "$removal_hook" \
  || fail_test "removal guard does not use package targets"
[[ $(grep -Fxc 'Operation = Remove' "$removal_hook") -eq 1 ]] \
  || fail_test "removal guard does not exclusively cover package removal"
grep -Fxq 'When = PreTransaction' "$removal_hook" \
  || fail_test "removal guard is not a pre-transaction hook"
grep -Fxq 'AbortOnFail' "$removal_hook" \
  || fail_test "removal guard cannot abort dependency removal"
grep -Fxq 'Exec = @BINDIR@/omasecboot --quiet guard removal' "$removal_hook" \
  || fail_test "removal guard does not call the canonical lifecycle check"
if grep -Eq '^(Depends =|NeedsTargets$)' "$removal_hook"; then
  fail_test "removal guard can be skipped or consume the producer target stream"
fi
expected_targets=$(sort <<'EOF'
boot/*
coreutils
efi/*
efibootmgr
linux*
limine*
mkinitcpio*
omarchy
omarchy-settings
sbctl
snapper*
usr/bin/cryptsetup
usr/bin/lvm
usr/lib/**/efi/*.efi*
usr/lib/firmware/*
usr/lib/initcpio/*
usr/lib/modules/*/extramodules/
usr/lib/modules/*/extramodules/*
usr/lib/modules/*/modules.builtin
usr/lib/modules/*/vmlinuz
usr/lib/systemd/systemd
usr/share/**/*.efi*
usr/src/*/dkms.conf
EOF
)
for hook in "$guard_hook" "$cleanup_hook" "$repair_hook"; do
  actual_targets=$(collect_hook_targets "$hook" | sort)
  [[ "$actual_targets" == "$expected_targets" ]] \
    || fail_test "hook target registry drifted: ${hook##*/}"
  grep -Fxq 'Operation = Remove' "$hook" \
    || fail_test "hook does not cover removal: ${hook##*/}"
  grep -Fxq 'Target = boot/*' "$hook" \
    || fail_test "hook does not cover boot artifacts: ${hook##*/}"
  for producer in 'linux*' 'limine*' 'snapper*' 'mkinitcpio*'; do
    grep -Fxq "Target = ${producer}" "$hook" \
      || fail_test "hook does not cover producer ${producer}: ${hook##*/}"
  done
  if grep -Fq 'Depends =' "$hook"; then
    fail_test "hook can be skipped when a dependency is unavailable: ${hook##*/}"
  fi
done
[[ $(grep -Fxc NeedsTargets "$guard_hook") -eq 1 ]] \
  || fail_test "package pre-hook does not own exactly one NeedsTargets stream"
for hook in "$cleanup_hook" "$repair_hook"; do
  if grep -Fxq NeedsTargets "$hook"; then
    fail_test "package post-hook requested an unauthoritative target stream: ${hook##*/}"
  fi
done

printf 'guard tests passed\n'
