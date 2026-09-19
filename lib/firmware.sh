#!/bin/bash
# OmaSecBoot: what the firmware says, read from efivarfs directly. sbctl's
# status output hides read errors of these variables (upstream-contracts C4).

readonly EFI_GLOBAL_GUID="8be4df61-93ca-11d2-aa0d-00e098032b8c"

# A mode variable is four attribute bytes and one value byte. Prints 0 or 1;
# an absent variable, any other content or a read error fails instead of
# guessing, so no caller can mistake "unknown" for "off".
read_mode_variable() {
  local path dump
  local -a bytes=()
  path="$(efivars_dir)/$1-${EFI_GLOBAL_GUID}"
  dump=$(od -An -v -tu1 -- "$path" 2>/dev/null) || return 1
  read -r -a bytes <<<"$dump"
  [[ ${#bytes[@]} == 5 && ${bytes[4]} =~ ^[01]$ ]] || return 1
  printf '%s\n' "${bytes[4]}"
}
