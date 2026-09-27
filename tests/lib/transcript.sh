#!/bin/bash
# What the acceptance recorder takes out of everything it writes down, and its
# verdict on whether a record counts, kept here so the records suite can test
# them: the filter guards privacy as much as looks, the verdict the evidence.

# Terminal control out of a transcript: operating system commands, which sudo
# and systemd use for session marks that name the host and the machine-id,
# then control sequences (parameter bytes, intermediate bytes, a final byte),
# then the carriage return at a line's end. The byte ranges only hold in the C
# locale.
strip_terminal_control() {
  LC_ALL=C sed 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g; s/\x1b\[[0-?]*[ -\/]*[@-~]//g; s/\r$//' "$@"
}

# efibootmgr -v prints each entry's device path a second time as raw bytes
# ("dp:"), and its optional data twice: as hex behind the path and as bytes
# ("data:"). They can repeat a partition's UUID, and a legacy entry's optional
# data holds the disk's model and serial number, in forms no later filter
# would recognise.
strip_boot_entry_bytes() {
  grep -v -E '^ *(dp|data): ' | sed -E 's/(\)|\.efi)[0-9a-fA-F]{8,}$/\1 (optional data left out)/I; s/MAC\([^)]*\)/MAC(redacted)/g; s/NVMe\([^)]*\)/NVMe(redacted)/g'
}

# evidence_verdict ROOT: whether a record made from the checkout at ROOT
# counts (release-checklist.md): a clean git checkout of its own, and, while
# the package is installed, installed files equal to it, as the recorder's
# compare_installed_files lists them. Prints "counts" or "does not count" with
# the reason. The comparison is read whole: a reader that stops at the first
# difference would end it by SIGPIPE, which pipefail reads as no difference.
evidence_verdict() {
  local root=$1 top porcelain differences
  if ! top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || [[ $(realpath -- "$top") != "$(realpath -- "$root")" ]] ||
    ! porcelain=$(git -C "$root" status --porcelain 2>/dev/null) || [[ -n $porcelain ]]; then
    printf 'does not count: the checkout is modified or is no git checkout of its own\n'
    return
  fi
  if pacman -Q omasecboot >/dev/null 2>&1; then
    differences=$(compare_installed_files | grep -v '^match: ')
    if [[ -n $differences ]]; then
      printf 'does not count: an installed file differs from the checkout or is missing\n'
      return
    fi
  fi
  printf 'counts\n'
}
