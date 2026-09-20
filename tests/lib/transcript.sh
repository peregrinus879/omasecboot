#!/bin/bash
# What the acceptance recorder takes out of everything it writes down, kept
# here so the records suite can test it: it is a privacy filter as much as a
# cosmetic one.

# Terminal control out of a transcript: operating system commands, which sudo
# and systemd use for session marks that name the host and the machine-id,
# then control sequences (parameter bytes, intermediate bytes, a final byte),
# then the carriage return at a line's end. The byte ranges only hold in the C
# locale.
strip_terminal_control() {
  LC_ALL=C sed 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g; s/\x1b\[[0-?]*[ -\/]*[@-~]//g; s/\r$//' "$@"
}

# efibootmgr -v prints each entry's device path a second time as raw bytes,
# and the optional data after the file path as hex. Both can repeat a
# partition's UUID in a form no later filter would recognise.
strip_boot_entry_bytes() {
  grep -v '^ *dp: ' | sed -E 's/(\.efi)[0-9a-fA-F]{16,}$/\1 (optional data left out)/I; s/MAC\([^)]*\)/MAC(redacted)/g; s/NVMe\([^)]*\)/NVMe(redacted)/g'
}
