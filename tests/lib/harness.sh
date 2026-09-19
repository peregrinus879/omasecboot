#!/bin/bash
# Shared harness for the hermetic suites: a fixture machine under one scratch
# directory, stub tools first on PATH, and the library with its locations
# pointed at the fixture. A suite sets ROOT_DIR, sources this file, calls
# test_harness_init, then runs cases with run_case.
#
# Rule for stubs: every behaviour a stub models cites the section of
# docs/upstream-contracts.md (C1 to C7) that records it. Anything a stub does
# without such a record is marked ASSUMPTION, because tests that share an
# unchecked assumption with the code prove nothing about real machines.
# shellcheck disable=SC2329 # Overrides and case functions are called indirectly.

test_harness_init() {
  TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-${1}.XXXXXX")
  SUITE_NAME=$1
  CASES_RUN=0
  trap 'rm -rf "$TEST_DIR"' EXIT
}

fail_test() {
  printf 'FAIL: %s/%s: %s\n' "$SUITE_NAME" "${CASE_NAME:-}" "$*" >&2
  exit 1
}

# Each case gets its own fixture machine and runs in a subshell, so overrides
# and shell state never leak between cases.
run_case() {
  CASE_NAME=$1
  (
    fixture_machine "$TEST_DIR/$1"
    "$2"
  ) || fail_test "case failed"
  printf 'PASS: %s/%s\n' "$SUITE_NAME" "$1"
  CASES_RUN=$((CASES_RUN + 1))
}

finish_suite() { printf '%s tests passed (%s cases)\n' "$SUITE_NAME" "$CASES_RUN"; }

# shellcheck source=tests/lib/esl.sh
source "$ROOT_DIR/tests/lib/esl.sh"

# --- The fixture machine ---------------------------------------------------------

readonly FIXTURE_MARKER='++CONFIG_B2SUM_SIGNATURE++'
readonly FIXTURE_SIGNATURE='SIGNED-BY-FIXTURE-KEY'

# A Limine executable is modelled as some bytes, Limine's marker and a
# 128-digit checksum slot, zero until enrolled (C1).
write_raw_loader() {
  { printf 'LIMINE-%s\n%s' "${2:-12.8.0}" "$FIXTURE_MARKER"; printf '0%.0s' {1..128}; printf '\ntail\n'; } >"$1"
}

# limine-install keeps the executable it deployed as a one-member tar beside
# the primary (C2).
write_loader_backup() {
  tar -cf "$FIX/esp/EFI/limine/limine_x64.bak" -C "$FIX/esp/EFI/limine" limine_x64.efi
}

write_uki() { printf 'UKI %s\n' "$2" >"$1"; }

fixture_machine() {
  FIX=$1
  mkdir -p "$FIX"/{esp/EFI/limine,esp/EFI/Linux,esp/EFI/BOOT,etc/layers,state,efivars,share,run,bin,sbctl,systemd}
  write_raw_loader "$FIX/share/BOOTX64.EFI"
  cp "$FIX/share/BOOTX64.EFI" "$FIX/esp/EFI/limine/limine_x64.efi"
  cp "$FIX/share/BOOTX64.EFI" "$FIX/esp/EFI/BOOT/BOOTX64.EFI"
  write_loader_backup
  write_uki "$FIX/esp/EFI/Linux/omarchy_linux.efi" unsigned
  # Stock Omarchy: UKIs on, verification on by upstream default, an
  # /etc/default/limine with only ESP_PATH and the command line (C3, C7).
  printf 'ENABLE_VERIFICATION=yes\nENABLE_UKI=no\n' >"$FIX/etc/layers/10-upstream.conf"
  printf 'ENABLE_UKI=yes\nENABLE_LIMINE_FALLBACK=yes\n' >"$FIX/etc/layers/20-omarchy.conf"
  printf 'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="quiet splash"\n' >"$FIX/etc/default-limine"
  write_limine_conf hashed
  # Factory keys, SetupMode 0 and SecureBoot 0.
  write_key_variable PK "$(x509_list "$OEM_OWNER" 'OEM platform key' | base64 -w0)"
  write_key_variable KEK "$({ x509_list "$OEM_OWNER" 'OEM KEK'; x509_list "$MICROSOFT_OWNER" 'Microsoft KEK'; } | base64 -w0)"
  write_key_variable db "$({ x509_list "$MICROSOFT_OWNER" 'Microsoft Windows CA'; x509_list "$MICROSOFT_OWNER" 'Microsoft UEFI CA'; x509_list "$OEM_OWNER" 'OEM db'; } | base64 -w0)"
  write_key_variable dbx "$(sha256_list "$MICROSOFT_OWNER" "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})" | base64 -w0)"
  set_mode_variable SetupMode 0
  set_mode_variable SecureBoot 0
  install_stubs
  export FIX ROOT_DIR PATH="$FIX/bin:$PATH"
  load_library
}

# limine.conf as limine-entry-tool writes it: indented sub-entries, a path
# hash on the OS entry only while verification is on (C2).
write_limine_conf() {
  local hash=''
  [[ $1 != hashed ]] || hash="#$(b2sum <"$FIX/esp/EFI/Linux/omarchy_linux.efi" | cut -d' ' -f1)"
  cat >"$FIX/esp/limine.conf" <<EOF
timeout: 3
hash_mismatch_panic: no

/+Omarchy
  //linux
    protocol: efi
    path: boot():/EFI/Linux/omarchy_linux.efi${hash}
    cmdline: quiet splash
EOF
}

set_mode_variable() { printf '%b' "\\x06\\x00\\x00\\x00\\x0$2" >"$FIX/efivars/$1-8be4df61-93ca-11d2-aa0d-00e098032b8c"; }

readonly OEM_OWNER=11111111111111111111111111111111
readonly MICROSOFT_OWNER=bd9afa775903324dbd6028f4e78f784b

key_variable_path() {
  case $1 in
    db | dbx) printf '%s/efivars/%s-d719b2cb-3d3a-4596-a3bc-dad00e67656f\n' "$FIX" "$1" ;;
    *) printf '%s/efivars/%s-8be4df61-93ca-11d2-aa0d-00e098032b8c\n' "$FIX" "$1" ;;
  esac
}

# write_key_variable NAME BASE64-OF-THE-LISTS: efivarfs puts four attribute
# bytes before the data. The lists travel as base64 because they hold NULs.
write_key_variable() {
  { printf '\x27\x00\x00\x00'; base64 -d <<<"$2"; } >"$(key_variable_path "$1")"
}

# What the firmware's key menu does on the reference machine: only the PK
# goes, and the firmware enters Setup Mode (C6).
delete_platform_key() {
  rm "$(key_variable_path PK)"
  set_mode_variable SetupMode 1
}

# Rows as the library prints them, computed here from the known fixture
# content, so an assertion never depends on the reader under test.
x509_row() { printf '%s %s %s\n' "$ESL_X509_TYPE" "$1" "$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"; }

file_is_fixture_signed() { [[ $(tail -c ${#FIXTURE_SIGNATURE} "$1") == "$FIXTURE_SIGNATURE" ]]; }

# Independent of the library's own proof: the checksum slot of the file equals
# the BLAKE2B of the fixture's limine.conf, and the file carries the signature.
loader_is_sealed_and_signed() {
  local content slot
  content=$(tr -d '\0' <"$1")
  [[ $content == *"$FIXTURE_MARKER"* ]] || return 1
  slot=${content#*"$FIXTURE_MARKER"}
  [[ ${slot:0:128} == "$(b2sum <"$FIX/esp/limine.conf" | cut -d' ' -f1)" ]] && file_is_fixture_signed "$1"
}

# Sources the modules the way the dispatcher does and points every location at
# the fixture.
load_library() {
  local module
  for module in common checks files firmware limine sign status; do
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/${module}.sh"
  done
  fixture_overrides
  : >"$FIX/bin/limine-hook" && chmod 755 "$FIX/bin/limine-hook"
}

# Runs the dispatcher as a process of its own with the same overrides, so
# errexit and every exit path behave as installed: inside a suite's "||" lists
# bash ignores errexit, which would hide an abort on an unguarded failure.
run_cli() {
  ROOT_DIR=$ROOT_DIR CONFIRM_ANSWER=${CONFIRM_ANSWER:-yes} bash -c '
    source "$ROOT_DIR/tests/lib/harness.sh"
    source "$ROOT_DIR/bin/omasecboot"
    fixture_overrides
    main "$@"' omasecboot "$@" >"$FIX/run/output" 2>&1
}

fixture_overrides() {
  state_dir() { printf '%s/state\n' "$FIX"; }
  efivars_dir() { printf '%s/efivars\n' "$FIX"; }
  limine_default_config() { printf '%s/etc/default-limine\n' "$FIX"; }
  restore_marker_path() { printf '%s/run/restore.lock\n' "$FIX"; }
  boot_lock_path() { printf '%s/run/boot-partition.lock\n' "$FIX"; }
  boot_lock_wait() { printf '1\n'; }
  hook_lock_wait() { printf '1\n'; }
  owner_uid() { printf '%s\n' "$EUID"; }
  limine_config_layers() {
    local file
    for file in "$FIX"/etc/layers/*.conf "$FIX/etc/default-limine"; do
      [[ ! -f $file ]] || printf '%s\n' "$file"
    done
  }
  esp_path() { printf '%s/esp\n' "$FIX"; }
  esp_is_mounted_vfat() { [[ ! -e $FIX/run/esp-unmounted ]]; }
  package_loader_path() { printf '%s/share/BOOTX64.EFI\n' "$FIX"; }
  limine_hook_path() { printf '%s/bin/limine-hook\n' "$FIX"; }
  leftover_candidates() { printf '%s\n' "$FIX/old/omasecboot" "$FIX"/old/hooks/*omasecboot*; }
  durable_sync() { :; }
  check_root() { :; }
  check_architecture() { :; }
  check_uefi() { :; }
  require_terminal() { :; }
  confirm() {
    printf 'QUESTION: %s\n' "$2"
    [[ ${CONFIRM_ANSWER:-yes} == yes ]]
  }
}

# --- Stub tools --------------------------------------------------------------------

install_stubs() {
  # sbctl 0.18 enroll-keys (C4): every entry sbctl writes is owned by the GUID
  # its status reports; --append adds the local certificate to what each
  # variable holds, again on every run (run/sbctl-append-is-idempotent models
  # a later sbctl that stops doing that); --microsoft and
  # --firmware-builtin build from the local certificate, Microsoft's and the
  # firmware's dbDefault and KEKDefault instead, and the PK is always the local
  # certificate alone in that form; --export esl writes db.esl, KEK.esl and
  # PK.esl into the current directory and touches nothing; a write goes db,
  # KEK, PK or to the one --partial names, stops at the first error without
  # rolling back (run/sbctl-enroll-fails-at-NAME), and is refused without
  # --ignore-immutable because the kernel marks the variables immutable.
  # Firmware that reports success and keeps the old value is
  # run/firmware-ignores-writes. The export works with a PK in place and
  # outside Setup Mode, and nothing works without keys (C4). ASSUMPTIONS:
  # outside Setup Mode the firmware rejects the write, because nothing it
  # trusts signed it; and --firmware-builtin fails on firmware without
  # dbDefault or KEKDefault.
  #
  # sbctl 0.18 (C4): status reports whether keys exist; create-keys makes
  # them; verify exits 0 and answers with an array of one entry whose
  # is_signed is 1, 0 or -1, or with null for a file it may not read, which
  # is any file outside the ESP that ESP_PATH names (or run/sbctl-cannot-read);
  # sign works in place and leaves an already signed
  # file alone; list-files is an array of entries with "file" that leaves out
  # rows whose file is gone; remove-file drops one row.
  cat >"$FIX/bin/sbctl" <<'EOF'
#!/bin/bash
sig='SIGNED-BY-FIXTURE-KEY'
signed() { [[ $(tail -c ${#sig} "$1" 2>/dev/null) == "$sig" ]]; }
printf '%s\n' "sbctl $*" >>"$FIX/run/calls"
case $1 in
  status)
    if [[ -e $FIX/sbctl/keys ]]; then
      guid=01020304-0506-0708-090a-0b0c0d0e0f10
      [[ ! -e $FIX/run/sbctl-owner-changed ]] || guid=ffffffff-0506-0708-090a-0b0c0d0e0f10
      [[ ! -e $FIX/run/sbctl-owner-malformed ]] || guid='.*020304-0506-0708-090a-0b0c0d0e0f10'
      printf '{"installed":true,"guid":"%s"}\n' "$guid"
    else
      printf '{"installed":false}\n'
    fi
    ;;
  enroll-keys)
    source "$ROOT_DIR/tests/lib/esl.sh"
    [[ -e $FIX/sbctl/keys && ! -e $FIX/run/sbctl-enroll-keys-fails ]] || { printf 'stub: enroll-keys failed\n' >&2; exit 1; }
    shift
    append=false microsoft=false builtin=false export=false immutable_ok=false targets=(db KEK PK)
    while (( $# > 0 )); do
      case $1 in
        --append) append=true ;;
        --microsoft) microsoft=true ;;
        --firmware-builtin) builtin=true ;;
        --ignore-immutable) immutable_ok=true ;;
        --export) [[ $2 == esl ]] || exit 64; export=true; shift ;;
        --partial) targets=("$2"); shift ;;
        *) exit 64 ;;
      esac
      shift
    done
    variable() {
      case $1 in
        db | dbx) printf '%s/efivars/%s-d719b2cb-3d3a-4596-a3bc-dad00e67656f\n' "$FIX" "$1" ;;
        *) printf '%s/efivars/%s-8be4df61-93ca-11d2-aa0d-00e098032b8c\n' "$FIX" "$1" ;;
      esac
    }
    planned() {
      local name=$1
      if [[ $append == true ]]; then
        [[ ! -e $(variable "$name") ]] || tail -c +5 "$(variable "$name")"
        [[ -e $FIX/run/sbctl-append-is-idempotent && -e $(variable "$name") ]] &&
          grep -aqF "local ${name} certificate" "$(variable "$name")" ||
          x509_list 0403020106050807090a0b0c0d0e0f10 "local ${name} certificate"
        [[ ! -e $FIX/run/sbctl-plans-a-stowaway ]] || x509_list 11111111111111111111111111111111 'stowaway'
      else
        x509_list 0403020106050807090a0b0c0d0e0f10 "local ${name} certificate"
        [[ ! -e $FIX/run/sbctl-plans-a-stowaway || $export == false ]] || x509_list 11111111111111111111111111111111 'stowaway'
        [[ $name != PK ]] || return 0
        [[ $microsoft == false ]] || x509_list bd9afa775903324dbd6028f4e78f784b "Microsoft ${name} as sbctl ships it"
        if [[ $builtin == true ]]; then
          [[ -e $(variable "${name}Default") ]] || exit 1
          tail -c +5 "$(variable "${name}Default")"
        fi
      fi
    }
    if [[ $export == true ]]; then
      for name in db KEK PK; do planned "$name" >"${name}.esl" || exit 1; done
      exit 0
    fi
    [[ $immutable_ok == true ]] || exit 1
    [[ $(od -An -tu1 -j4 -N1 "$(variable SetupMode)" | tr -d ' ') == 1 ]] || exit 1
    for name in "${targets[@]}"; do
      [[ ! -e $FIX/run/sbctl-enroll-fails-at-${name} ]] || exit 1
      [[ -e $FIX/run/firmware-ignores-writes ]] || { printf '\x27\x00\x00\x00'; planned "$name"; } >"$FIX/run/variable.new"
      [[ -e $FIX/run/firmware-ignores-writes ]] || mv "$FIX/run/variable.new" "$(variable "$name")"
    done
    ;;
  create-keys) : >"$FIX/sbctl/keys" ;;
  verify)
    if [[ -e $FIX/run/sbctl-cannot-read || -z ${ESP_PATH:-} || $3 != "$ESP_PATH/"* ]]; then
      printf 'null\n'
      exit 0
    fi
    if [[ ! -e $3 ]]; then state=-1; elif signed "$3"; then state=1; else state=0; fi
    jq -cn --arg f "$3" --argjson s "$state" '[{file_name:$f,is_signed:$s}]'
    ;;
  sign)
    [[ -e $FIX/sbctl/keys && ! -e $FIX/run/sbctl-sign-fails ]] || exit 1
    signed "$2" || printf '%s' "$sig" >>"$2"
    ;;
  list-files)
    [[ ! -e $FIX/run/sbctl-list-fails ]] || exit 1
    while IFS= read -r file; do [[ ! -e $file ]] || printf '%s\n' "$file"; done <"$FIX/sbctl/files" |
      jq -Rn '[inputs | {file: ., output_file: .}]'
    ;;
  remove-file) grep -vxF -- "$2" "$FIX/sbctl/files" >"$FIX/sbctl/files.new"; mv "$FIX/sbctl/files.new" "$FIX/sbctl/files" ;;
  *) exit 64 ;;
esac
EOF
  : >"$FIX/sbctl/files"

  # limine enroll-config writes the checksum into the slot after the marker,
  # --reset zeroes it (C1). Changing a signed executable invalidates its
  # signature (C4, sbctl issue 408), modelled by dropping the fixture signature.
  cat >"$FIX/bin/limine" <<'EOF'
#!/bin/bash
marker='++CONFIG_B2SUM_SIGNATURE++' sig='SIGNED-BY-FIXTURE-KEY'
printf '%s\n' "limine $*" >>"$FIX/run/calls"
[[ $1 == enroll-config ]] || exit 64
shift
if [[ $1 == --reset ]]; then file=$2 sum=$(printf '0%.0s' {1..128}); else file=$1 sum=$2; fi
[[ ! -e $FIX/run/limine-enroll-fails ]] || exit 1
# An editor saves limine.conf while the loader is being rebuilt, once.
if [[ -e $FIX/run/config-changes-during-enroll ]]; then
  rm "$FIX/run/config-changes-during-enroll"
  printf 'timeout: 9\n' >>"$FIX/esp/limine.conf"
fi
content=$(<"$file")
content=${content%"$sig"}
prefix=${content%%"$marker"*}
rest=${content#*"$marker"}
printf '%s%s%s%s' "$prefix" "$marker" "$sum" "${rest:128}" >"$file"
printf '\n' >>"$file"
EOF

  # The Limine tools (C2). Each takes the boot lock, which here must be free:
  # a caller that still held it would make the real tool wait and then carry
  # on unlocked. The pre-hook restores the primary from limine-install's
  # backup. limine-mkinitcpio rebuilds the UKI, signed at build when keys
  # exist, and rewrites the OS entry with a hash only while verification is on,
  # or reports success without doing either (run/uki-build-fails-silently).
  # limine-install deploys the package's executable to the primary, its backup
  # and an existing fallback unless it holds a new major back
  # (run/upstream-holds-back). Then upstream's enroll hook seals and signs the
  # primary when enrollment is on, hiding its own failure
  # (run/upstream-hook-fails). limine-reset-enroll is the pre-hook alone.
  cat >"$FIX/bin/limine-tool" <<'EOF'
#!/bin/bash
name=${0##*/}
printf '%s\n' "$name $*" >>"$FIX/run/calls"
[[ ! -e $FIX/run/${name}-fails ]] || exit 1
setting() { grep -h "^$1=" "$FIX"/etc/layers/*.conf "$FIX/etc/default-limine" | tail -n 1 | cut -d= -f2 | tr -d '"'; }
limine_dir=$FIX/esp/EFI/limine
primary=$limine_dir/limine_x64.efi
if [[ $name != limine-reset-enroll ]]; then
  exec 200>>"$FIX/run/boot-partition.lock"
  flock -n 200 || {
    printf '%s: the boot lock is held by the caller\n' "$name" >&2
    exit 1
  }
fi
tar -xf "$limine_dir/limine_x64.bak" -C "$limine_dir" limine_x64.efi
case $name in
  limine-mkinitcpio)
    if [[ ! -e $FIX/run/uki-build-fails-silently ]]; then
      printf 'UKI rebuilt %s\n' "$RANDOM" >"$FIX/esp/EFI/Linux/omarchy_linux.efi"
      [[ ! -e $FIX/sbctl/keys || -e $FIX/run/uki-arrives-unsigned ]] || sbctl sign "$FIX/esp/EFI/Linux/omarchy_linux.efi"
      hash=''
      [[ $(setting ENABLE_VERIFICATION) == no ]] || hash="#$(b2sum <"$FIX/esp/EFI/Linux/omarchy_linux.efi" | cut -d' ' -f1)"
      sed -i "s|^\(    path: boot():/EFI/Linux/omarchy_linux.efi\).*|\1${hash}|" "$FIX/esp/limine.conf"
    fi
    ;;
  limine-install)
    if [[ ! -e $FIX/run/upstream-holds-back ]]; then
      cp "$FIX/share/BOOTX64.EFI" "$primary"
      tar -cf "$limine_dir/limine_x64.bak" -C "$limine_dir" limine_x64.efi
      [[ ! -e $FIX/esp/EFI/BOOT/BOOTX64.EFI ]] || cp "$FIX/share/BOOTX64.EFI" "$FIX/esp/EFI/BOOT/BOOTX64.EFI"
    fi
    ;;
  limine-reset-enroll) exit 0 ;;
esac
if [[ ! -e $FIX/run/upstream-hook-fails ]]; then
  [[ $(grep -h '^ENABLE_ENROLL_LIMINE_CONFIG=' "$FIX/etc/default-limine" | tail -n 1 | cut -d= -f2) != yes ]] ||
    limine enroll-config "$primary" "$(b2sum <"$FIX/esp/limine.conf" | cut -d' ' -f1)"
  [[ ! -e $FIX/sbctl/keys ]] || sbctl sign "$primary"
fi
exit 0
EOF
  local tool
  for tool in limine-mkinitcpio limine-install limine-reset-enroll; do
    ln -s limine-tool "$FIX/bin/$tool"
  done

  # systemctl and pacman record what they were asked; ASSUMPTION: a unit that
  # was enabled with --now reads as enabled and active.
  cat >"$FIX/bin/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "systemctl $*" >>"$FIX/run/calls"
unit=${*: -1}
case $1 in
  enable) : >"$FIX/systemd/$unit" ;;
  disable) rm -f "$FIX/systemd/$unit" ;;
  is-enabled | is-active) [[ -e $FIX/systemd/$unit ]] ;;
esac
EOF
  cat >"$FIX/bin/pacman" <<'EOF'
#!/bin/bash
printf '%s\n' "pacman $*" >>"$FIX/run/calls"
EOF
  chmod 755 "$FIX"/bin/*
  : >"$FIX/run/calls"
}
