#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154,SC2329 # Fixtures source and override checkout functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init artifacts

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=../lib/records.sh
source "${ROOT_DIR}/lib/records.sh"
# shellcheck source=../lib/software.sh
source "${ROOT_DIR}/lib/software.sh"
# shellcheck source=../lib/discover.sh
source "${ROOT_DIR}/lib/discover.sh"
# shellcheck source=../lib/sign.sh
source "${ROOT_DIR}/lib/sign.sh"

QUIET=true

state_dir_path() {
  printf '%s/state\n' "$CASE_DIR"
}

limine_lock_path() {
  printf '%s/boot-partition.lock\n' "$CASE_DIR"
}

snapshot_restore_lock_path() {
  printf '%s/limine-snapper-restore.lock\n' "$CASE_DIR"
}

pacman_database_lock_path() {
  printf '%s/pacman-db.lck\n' "$CASE_DIR"
}

esp_path() {
  printf '%s/boot\n' "$CASE_DIR"
}

limine_config_path() {
  printf '%s/boot/limine.conf\n' "$CASE_DIR"
}

limine_default_config_path() {
  printf '%s/limine-defaults\n' "$CASE_DIR"
}

# Only the fixture's defaults file and its optional drop-in count as
# limine-entry-tool configuration; the host's layers never leak in.
limine_entry_tool_config_files() {
  [[ ! -e "${CASE_DIR}/limine-dropin.conf" ]] \
    || printf '%s\n' "${CASE_DIR}/limine-dropin.conf"
  printf '%s\n' "$(limine_default_config_path)"
}

sbctl_config_path() {
  printf '%s\n' "$SBCTL_CONFIG"
}

sbctl_database_candidate_paths() {
  printf '%s\n%s\n' "$SBCTL_FILES_DB" "$SBCTL_ALTERNATE_DB"
}

limine_unsigned_binary_path() {
  printf '%s/BOOTX64.EFI\n' "$CASE_DIR"
}

control_owner_uid() {
  id -u
}

control_file_identity() {
  local path="$1"
  if [[ -n "$IDENTITY_ALIAS_PATH" && "$path" == "$IDENTITY_ALIAS_PATH" ]]; then
    path="$IDENTITY_ALIAS_TARGET"
  fi
  stat -Lc '%d:%i' "$path" 2>/dev/null
}

require_control_root() {
  :
}

durable_sync() {
  local path="$1"
  [[ -z "$SYNC_FAIL_PATH" || "$path" != "$SYNC_FAIL_PATH" ]]
}

limine_enrollment_hooks_present() {
  :
}

mountpoint() {
  [[ "$MOUNTPOINT_OK" == true && "$1" == -q && "$2" == "$(esp_path)" ]]
}

findmnt() {
  [[ "$1" == -n && "$2" == -T && "$3" == "$(esp_path)" && "$4" == -o \
    && "$5" == FSTYPE ]] || return 2
  printf 'vfat\n'
}

write_binary() {
  local path="$1" checksum="$2" signature="${3:-}"
  {
    printf 'FAKE_EFI\n%s%s\n' "$LIMINE_CONFIG_MARKER" "$checksum"
    [[ -z "$signature" ]] || printf '%s\n' "$signature"
  } > "$path"
}

update_tracking_db() {
  local file="$1" tmp
  tmp="${SBCTL_FILES_DB}.tmp"
  [[ -s "$SBCTL_FILES_DB" ]] || printf '{}\n' > "$SBCTL_FILES_DB"
  jq --arg file "$file" '.[$file] = {file: $file, output: $file}' \
    "$SBCTL_FILES_DB" > "$tmp" || return 1
  mv "$tmp" "$SBCTL_FILES_DB"
}

# Activation's entry regeneration: the pinned tools are dispatched to these
# stubs with the same lock handoff the real runner performs. The mkinitcpio
# stub rebuilds the OS UKI and removes its hash under ENABLE_VERIFICATION=no.
# The snapshot stub deliberately rewrites a hash to test final enrollment
# ordering; native 1.31.0 retains historical hashes (docs/maintenance.md), so
# this fixture is not evidence of historical migration.
MKINITCPIO_FAIL=false
limine-mkinitcpio() {
  printf 'mkinitcpio\n' >> "$ARTIFACT_LOG"
  [[ "$MKINITCPIO_FAIL" == false ]] || return 1
  printf 'UKI_REBUILT\nLOCAL_SIGNATURE\n' > "$OS_UKI"
  sed -i 's|\(path: boot():/EFI/Linux/omarchy_linux.efi\)#[0-9A-Fa-f]\{128\}|\1|' \
    "$(limine_config_path)"
}

limine-snapper-sync() {
  local hash remainder
  [[ "$*" == --no-force-save ]] || return 2
  printf 'snapper-sync\n' >> "$ARTIFACT_LOG"
  read -r hash remainder < <(b2sum "$HISTORY")
  sed -i "s|\(path: boot():/EFI/Linux/history.efi_sha256_abc\)#[0-9A-Fa-f]\{128\}|\1#${hash}|" \
    "$(limine_config_path)"
}

run_bound_limine_tool() {
  local key="$1" handoff="$2" command
  shift 3
  case "$key" in
    mkinitcpio) command=limine-mkinitcpio ;;
    snapper-sync) command=limine-snapper-sync ;;
    *) return 1 ;;
  esac
  if [[ "$handoff" == true ]]; then
    with_limine_lock_handoff "$command" "$@"
  else
    "$command" "$@"
  fi
}

activation_repair_transaction() {
  repair_boot_artifacts activation
}

run_activation_repair() {
  _activation_limine_tools_json='{"mkinitcpio": {}, "snapper-sync": {}}'
  run_lifecycle_transaction_with_preflight "$1" "active" "active" \
    artifact_repair_preflight activation_repair_transaction
}

# A stock config as limine-entry-tool writes it under ENABLE_VERIFICATION=yes:
# an OS entry and a snapshot entry, each hashing its unsigned file.
write_hashed_limine_config() {
  local os_hash history_hash remainder
  printf 'UKI\n' > "$OS_UKI"
  printf 'SNAPSHOT\n' > "$HISTORY"
  read -r os_hash remainder < <(b2sum "$OS_UKI")
  read -r history_hash remainder < <(b2sum "$HISTORY")
  printf '%s\n' \
    'timeout: 5' \
    'hash_mismatch_panic: no' \
    '/+Omarchy' \
    '    protocol: efi' \
    "    path: boot():/EFI/Linux/omarchy_linux.efi#${os_hash}" \
    '    //Snapshots' \
    '    ///5' \
    '    ////linux' \
    '    protocol: efi' \
    "    path: boot():/EFI/Linux/history.efi_sha256_abc#${history_hash}" \
    > "$(limine_config_path)"
}

limine() {
  local binary checksum
  [[ "$1" == enroll-config ]] || return 2
  shift
  if [[ "${1:-}" == --quiet ]]; then
    shift
  fi
  [[ $# -eq 2 ]] || return 2
  binary="$1"
  checksum="$2"
  printf 'enroll:%s\n' "$binary" >> "$ARTIFACT_LOG"
  if [[ -n "$LIMINE_FAIL_TARGET" \
    && ( "$binary" == "$LIMINE_FAIL_TARGET" \
      || "$(dirname "$binary")" == "$(dirname "$LIMINE_FAIL_TARGET")" ) ]]; then
    return 42
  fi
  if grep -aFxq 'LOCAL_SIGNATURE' "$binary"; then
    return 43
  fi
  if [[ -n "$LIMINE_BAD_TARGET" \
    && ( "$binary" == "$LIMINE_BAD_TARGET" \
      || "$(dirname "$binary")" == "$(dirname "$LIMINE_BAD_TARGET")" ) ]]; then
    checksum=$(printf 'f%.0s' {1..128})
  fi
  write_binary "$binary" "$checksum"
}

sbctl() {
  local file save=false valid=true
  case "$1" in
    list-files)
      [[ "${2:-}" == --json ]] || return 2
      case "$SBCTL_LIST_MODE" in
        fail) return 45 ;;
        empty) return 0 ;;
        json)
          # The CLI prints an array of entries; the database is the keyed
          # object it reads (sbctl 0.18 cmd/sbctl/list-files.go).
          if [[ -n "$SBCTL_LIST_RAW" ]]; then
            printf '%s\n' "$SBCTL_LIST_RAW"
          elif [[ ! -f "$SBCTL_FILES_DB" ]]; then
            printf '[]\n'
          elif [[ -n "$SBCTL_OMIT_LIST_PATH" ]]; then
            jq --arg path "$SBCTL_OMIT_LIST_PATH" \
              '[del(.[$path]) | to_entries[] | .value + {is_signed: true}]' \
              "$SBCTL_FILES_DB"
          else
            jq '[to_entries[] | .value + {is_signed: true}]' "$SBCTL_FILES_DB"
          fi
          ;;
        *) return 2 ;;
      esac
      ;;
    verify)
      [[ "${2:-}" == --json && $# -eq 3 ]] || return 2
      file="$3"
      grep -aFxq 'LOCAL_SIGNATURE' "$file" || valid=false
      jq -cn --arg path "$file" --argjson valid "$valid" \
        '[{file_name: $path, is_signed: (if $valid then 1 else 0 end)}]'
      ;;
    sign)
      shift
      if [[ "${1:-}" == -s ]]; then
        save=true
        shift
      fi
      [[ $# -eq 1 ]] || return 2
      file="$1"
      printf 'sign:%s\n' "$file" >> "$ARTIFACT_LOG"
      [[ "$file" != "$SBCTL_FAIL_TARGET" ]] || return 46
      printf 'LOCAL_SIGNATURE\n' >> "$file"
      if [[ "$save" == true ]]; then
        update_tracking_db "$file" || return 1
        if [[ -n "$SBCTL_INJECT_MAPPING_TARGET" ]]; then
          jq --arg source "${CASE_DIR}/external.efi" \
            --arg output "$SBCTL_INJECT_MAPPING_TARGET" \
            '.[$source] = {file: $source, output_file: $output}' \
            "$SBCTL_FILES_DB" > "${SBCTL_FILES_DB}.tmp" || return 1
          mv "${SBCTL_FILES_DB}.tmp" "$SBCTL_FILES_DB" || return 1
        fi
      fi
      ;;
    remove-file)
      [[ $# -eq 2 ]] || return 2
      file="$2"
      jq --arg file "$file" 'del(.[$file])' "$SBCTL_FILES_DB" \
        > "${SBCTL_FILES_DB}.tmp" || return 1
      mv "${SBCTL_FILES_DB}.tmp" "$SBCTL_FILES_DB"
      ;;
    *)
      return 2
      ;;
  esac
}

setup_fixture() {
  local name="$1" stale_path microsoft_path old_checksum
  CASE_DIR="${TEST_DIR}/${name}"
  PRIMARY="${CASE_DIR}/boot/EFI/limine/limine_x64.efi"
  FALLBACK="${CASE_DIR}/boot/EFI/BOOT/BOOTX64.EFI"
  SNAPSHOT="${CASE_DIR}/boot/EFI/Linux/snapshot.efi_sha256_deadbeef"
  OS_UKI="${CASE_DIR}/boot/EFI/Linux/omarchy_linux.efi"
  HISTORY="${CASE_DIR}/boot/EFI/Linux/history.efi_sha256_abc"
  MIXED="${CASE_DIR}/boot/EFI/Tools/Mixed.EfI"
  MICROSOFT="${CASE_DIR}/boot/EFI/Microsoft/Boot/bootmgfw.efi"
  IA32="${CASE_DIR}/boot/EFI/BOOT/BOOTIA32.EFI"
  BACKUP="${CASE_DIR}/boot/EFI/Linux/old.efi.bak"
  SBCTL_FILES_DB="${CASE_DIR}/files.json"
  SBCTL_ALTERNATE_DB="${CASE_DIR}/files.db"
  SBCTL_CONFIG="${CASE_DIR}/sbctl.conf"
  ARTIFACT_LOG="${CASE_DIR}/artifact.log"
  MOUNTPOINT_OK=true
  SBCTL_LIST_MODE=json
  SBCTL_OMIT_LIST_PATH=""
  SBCTL_LIST_RAW=""
  SBCTL_FAIL_TARGET=""
  SBCTL_INJECT_MAPPING_TARGET=""
  IDENTITY_ALIAS_PATH=""
  IDENTITY_ALIAS_TARGET=""
  SYNC_FAIL_PATH=""
  LIMINE_FAIL_TARGET=""
  LIMINE_BAD_TARGET=""
  MKINITCPIO_FAIL=false

  mkdir -p "${CASE_DIR}/boot/EFI/limine" "${CASE_DIR}/boot/EFI/BOOT" \
    "${CASE_DIR}/boot/EFI/Linux" "${CASE_DIR}/boot/EFI/Tools" \
    "${CASE_DIR}/boot/EFI/Microsoft/Boot"
  printf 'TIMEOUT=5\n' > "$(limine_config_path)"
  printf '%s\n' \
    'ENABLE_VERIFICATION=yes' \
    'ENABLE_ENROLL_LIMINE_CONFIG=no' \
    'COMMANDS_BEFORE_SAVE="other limine-reset-enroll"' \
    'COMMANDS_AFTER_SAVE="limine-enroll-config other"' \
    > "$(limine_default_config_path)"
  old_checksum=$(printf '0%.0s' {1..128})
  write_binary "$(limine_unsigned_binary_path)" "$old_checksum"
  write_binary "$PRIMARY" "$old_checksum"
  write_binary "$FALLBACK" "$old_checksum"
  printf 'SNAPSHOT\nLOCAL_SIGNATURE\n' > "$SNAPSHOT"
  printf 'TOOL\n' > "$MIXED"
  printf 'MICROSOFT\n' > "$MICROSOFT"
  printf 'IA32\n' > "$IA32"
  printf 'BACKUP\n' > "$BACKUP"

  stale_path="${CASE_DIR}/boot/EFI/Linux/missing.efi"
  microsoft_path="$MICROSOFT"
  jq -cn --arg stale "$stale_path" --arg microsoft "$microsoft_path" '{
    ($stale): {file: $stale, output: $stale},
    ($microsoft): {file: $microsoft, output: $microsoft}
  }' > "$SBCTL_FILES_DB"
  printf 'files_db: %s\n' "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  : > "$ARTIFACT_LOG"

  # Originals match the managed values unless a case overrides one.
  adopt_lifecycle : "yes" "${FIXTURE_ORIGINAL_VERIFICATION:-no}" "no" "yes" \
    "present" "absent" "present" "absent" \
    || fail_test "${name}: active fixture adoption failed"
}

assert_hash() {
  local expected="$1" path="$2" message="$3"
  [[ "$(sha256_file "$path")" == "$expected" ]] || fail_test "$message"
}

assert_recovery_rollback() {
  local phase="$1"
  read_lifecycle || fail_test "failure lifecycle became unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "artifact failure did not require recovery"
  if ! jq -e --arg phase "$phase" '
    .status == "failed" and
    .failure.phase == $phase and
    .rollback.status == "completed" and
    (.rollback.failures | length) == 0
  ' "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null; then
    jq -c '{status, failure, rollback}' \
      "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >&2 || true
    fail_test "artifact rollback result was not durable for ${phase}"
  fi
}

test_discovery_and_tracking_sources() {
  local discovered tracked suffix
  for suffix in sha1_a b3_b blake3_c xxh_d xxhash_e; do
    printf 'SNAPSHOT\n' > "${CASE_DIR}/boot/EFI/Linux/history.efi_${suffix}"
  done
  printf 'NOT\n' > "${CASE_DIR}/boot/EFI/Linux/history.efi_md5_f"
  discovered=$(discover_efi_files) || fail_test "EFI discovery failed"
  for suffix in sha1_a b3_b blake3_c xxh_d xxhash_e; do
    grep -Fxq "${CASE_DIR}/boot/EFI/Linux/history.efi_${suffix}" <<< "$discovered" \
      || fail_test "snapshot suffix efi_${suffix} was not discovered"
  done
  if grep -Fq "history.efi_md5_f" <<< "$discovered"; then
    fail_test "an unsupported hash suffix was discovered as an EFI artifact"
  fi
  rm -f "${CASE_DIR}"/boot/EFI/Linux/history.efi_*
  grep -Fxq "$PRIMARY" <<< "$discovered" || fail_test "primary Limine binary was not discovered"
  grep -Fxq "$FALLBACK" <<< "$discovered" || fail_test "fallback Limine binary was not discovered"
  grep -Fxq "$SNAPSHOT" <<< "$discovered" || fail_test "snapshot UKI suffix was not discovered"
  grep -Fxq "$MIXED" <<< "$discovered" || fail_test "case-insensitive EFI suffix was not discovered"
  if grep -Fxq "$MICROSOFT" <<< "$discovered" \
    || grep -Fxq "$IA32" <<< "$discovered" \
    || grep -Fxq "$BACKUP" <<< "$discovered"; then
    fail_test "excluded EFI artifact was discovered"
  fi

  SBCTL_LIST_MODE=empty
  tracked=$(list_enrolled_paths) || fail_test "successful empty sbctl list failed"
  [[ -z "$tracked" ]] || fail_test "successful empty sbctl list fell back to the database"
  SBCTL_LIST_MODE=fail
  tracked=$(list_enrolled_paths) || fail_test "sbctl database fallback failed"
  grep -Fq 'missing.efi' <<< "$tracked" || fail_test "failed sbctl list did not use the database fallback"

  # Each reader accepts exactly its source's shape and fails closed on
  # anything else instead of inventing a source. The database is an object
  # keyed by source path whose file equals the key.
  jq -cn --arg source "$PRIMARY" '{($source): {output_file: $source}}' > "$SBCTL_FILES_DB"
  if list_enrolled_paths >/dev/null 2>&1; then
    fail_test "database fallback synthesized a source for an entry without a file"
  fi
  jq -cn --arg source "$PRIMARY" --arg other "${CASE_DIR}/other.efi" '{
    ($other): {file: $source, output_file: $source}
  }' > "$SBCTL_FILES_DB"
  if list_enrolled_paths >/dev/null 2>&1; then
    fail_test "database fallback accepted an entry whose file differs from its key"
  fi
  # The CLI prints an array of entries. An unsupported CLI answer fails closed
  # even while the database is readable: an entry without a file, or the
  # database object itself in place of the array.
  SBCTL_LIST_MODE=json
  jq -cn --arg source "$PRIMARY" '{($source): {file: $source, output_file: $source}}' \
    > "$SBCTL_FILES_DB"
  SBCTL_LIST_RAW=$(jq -cn --arg source "$PRIMARY" '[{output_file: $source, is_signed: true}]')
  if list_enrolled_paths >/dev/null 2>&1; then
    fail_test "sbctl list output with an entry without a file fell back to the database"
  fi
  SBCTL_LIST_RAW=$(jq -c . "$SBCTL_FILES_DB")
  if list_enrolled_paths >/dev/null 2>&1; then
    fail_test "sbctl list output shaped as the database object fell back to the database"
  fi
  SBCTL_LIST_RAW=""
  tracked=$(list_enrolled_paths) || fail_test "sbctl list array output failed"
  grep -Fxq "$PRIMARY" <<< "$tracked" || fail_test "sbctl list array output lost the tracked path"
}

test_sbctl_config_resolution() {
  local resolved
  printf 'files_db: "%s" # fixture\n' "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  resolved=$(resolve_sbctl_files_db_path) || fail_test "quoted sbctl files_db value was rejected"
  [[ "$resolved" == "$SBCTL_FILES_DB" ]] \
    || fail_test "sbctl files_db resolved to the wrong path"

  printf 'files_db: %s # fixture\n' "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  resolved=$(resolve_sbctl_files_db_path) \
    || fail_test "plain sbctl files_db with a separated comment was rejected"
  [[ "$resolved" == "$SBCTL_FILES_DB" ]] \
    || fail_test "plain sbctl files_db with a comment resolved incorrectly"

  printf 'files_db: %s#suffix\n' "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "adjacent hash in plain files_db was truncated as a comment"
  fi

  printf 'files_db: "%s"#comment\n' "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "unseparated comment after quoted files_db was accepted"
  fi

  printf 'metadata:\n  files_db: /var/lib/decoy/files.json\nfiles_db: %s\n' \
    "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  resolved=$(resolve_sbctl_files_db_path) \
    || fail_test "explicit top-level files_db was rejected"
  [[ "$resolved" == "$SBCTL_FILES_DB" ]] \
    || fail_test "nested files_db overrode the top-level path"

  printf '{"files_db": "%s"}\n' "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "unsupported sbctl YAML syntax did not fail closed"
  fi

  printf 'metadata:\n  files_db: /var/lib/decoy/files.json\n' > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "nested files_db was mistaken for the active top-level path"
  fi

  printf 'files_db: %s\n"files\\u005fdb": /var/lib/decoy/files.json\n' \
    "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "encoded duplicate files_db key did not fail closed"
  fi

  printf 'files_db: %s\nfiles_db: /var/lib/decoy/files.json\n' \
    "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "duplicate files_db key did not fail closed"
  fi

  printf '%s\n---\nmetadata: fixture\n' "files_db: $SBCTL_FILES_DB" \
    > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "multiple sbctl config documents did not fail closed"
  fi

  printf 'files_db: %s\n  continuation\n' "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "multiline files_db value did not fail closed"
  fi

  printf 'defaults: &defaults\n  files_db: %s\n<<: *defaults\n' \
    "$SBCTL_FILES_DB" > "$SBCTL_CONFIG"
  if resolve_sbctl_files_db_path >/dev/null 2>&1; then
    fail_test "merged files_db key did not fail closed"
  fi
}

test_preflight_validation() {
  local old_checksum shadow
  old_checksum=$(printf '0%.0s' {1..128})
  printf 'NO_MARKER\n' > "$PRIMARY"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted a Limine binary without a checksum marker"
  fi

  write_binary "$PRIMARY" "$old_checksum"
  {
    printf 'FAKE_EFI\n%s%s\n' "$LIMINE_CONFIG_MARKER" "$old_checksum"
    printf '%s%s\n' "$LIMINE_CONFIG_MARKER" "$old_checksum"
  } > "$FALLBACK"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted duplicate Limine checksum markers"
  fi

  write_binary "$FALLBACK" "$old_checksum"
  : > "$SBCTL_FILES_DB"
  artifact_repair_preflight \
    || fail_test "preflight rejected an empty sbctl tracking database"

  printf '{}\n' > "$SBCTL_FILES_DB"
  shadow="$(esp_path)/EFI/limine/limine.conf"
  printf 'SHADOW\n' > "$shadow"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted a possible shadow Limine config"
  fi
  rm -f "$shadow"

  printf 'not-json\n' > "$SBCTL_FILES_DB"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted a malformed sbctl tracking database"
  fi
}

test_mapping_validation() {
  local external_source
  jq -cn --arg source "$SNAPSHOT" --arg output "$MIXED" '{
    ($source): {file: $source, output_file: $output}
  }' > "$SBCTL_FILES_DB"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted a discovered sbctl source with a different output"
  fi

  external_source="${CASE_DIR}/external.efi"
  printf 'EXTERNAL\n' > "$external_source"
  jq -cn --arg source "$external_source" --arg output "$MIXED" '{
    ($source): {file: $source, output_file: $output}
  }' > "$SBCTL_FILES_DB"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted an external source mapped onto a discovered EFI artifact"
  fi

  IDENTITY_ALIAS_PATH=${FALLBACK,,}
  IDENTITY_ALIAS_TARGET=$FALLBACK
  jq -cn --arg source "$external_source" --arg output "$IDENTITY_ALIAS_PATH" '{
    ($source): {file: $source, output_file: $output}
  }' > "$SBCTL_FILES_DB"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted a VFAT alias mapped onto a discovered EFI artifact"
  fi

  # Nothing is synthesized for a malformed entry on a proof path: the CLI
  # array refuses an entry without a file, and the database fallback refuses
  # an entry whose file differs from its key.
  jq -cn --arg source "$PRIMARY" '{($source): {output_file: $source}}' > "$SBCTL_FILES_DB"
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight synthesized a source for an entry without a file"
  fi
  jq -cn --arg source "$PRIMARY" --arg other "${CASE_DIR}/other.efi" '{
    ($other): {file: $source, output_file: $source}
  }' > "$SBCTL_FILES_DB"
  SBCTL_LIST_MODE=fail
  if artifact_repair_preflight >/dev/null 2>&1; then
    fail_test "preflight accepted a tracking entry whose file differs from its key"
  fi
  SBCTL_LIST_MODE=json
}

test_managed_setting_drift_repair() {
  # The fixture recorded ENABLE_VERIFICATION=yes as the original; repair manages no.
  run_artifact_repair "artifact-drift-baseline" || fail_test "baseline repair failed"
  # A value that drifted back to its recorded original is repaired, not refused.
  set_limine_default_value ENABLE_VERIFICATION yes || fail_test "drift fixture failed"
  run_artifact_repair "artifact-drift-original" \
    || fail_test "repair refused a managed setting that drifted to its recorded original"
  [[ $(grep -Fxc 'ENABLE_VERIFICATION=no' "$(limine_default_config_path)") -eq 1 ]] \
    || fail_test "drift repair did not re-apply the managed value"
  # A value outside {managed, original} is a conflict and is refused.
  replace_limine_default_entry ENABLE_VERIFICATION 'ENABLE_VERIFICATION=maybe' \
    || fail_test "conflict fixture failed"
  if run_artifact_repair "artifact-drift-conflict" >/dev/null 2>&1; then
    fail_test "repair accepted a managed setting outside its recorded values"
  fi
  set_limine_default_value ENABLE_VERIFICATION no || fail_test "conflict cleanup failed"
  read_lifecycle || fail_test "drift repair damaged lifecycle readability"
  [[ "$_lifecycle_state" == active ]] || fail_test "drift conflict left lifecycle ${_lifecycle_state}"
}

test_staged_limine_install() {
  local checksum database_hash
  checksum=$(current_limine_config_checksum) || fail_test "staging checksum failed"
  database_hash=$(sha256_file "$SBCTL_FILES_DB")
  install_enrolled_limine_binary "$PRIMARY" "$checksum" \
    || fail_test "staged Limine enrollment failed"
  verify_limine_embedded_checksum "$PRIMARY" "$checksum" \
    || fail_test "staged Limine target has the wrong checksum"
  sbctl_file_signature_state "$PRIMARY" \
    || fail_test "staged Limine target was installed unsigned"
  assert_hash "$database_hash" "$SBCTL_FILES_DB" \
    "staging-only signing changed sbctl tracking state"
  if compgen -G "$(dirname "$PRIMARY")/.omasecboot-limine.*" >/dev/null; then
    fail_test "staged Limine enrollment retained a temporary file"
  fi
}

test_successful_repair() {
  local checksum manifest last_enroll first_sign artifact proof
  run_artifact_repair "artifact-success" \
    || fail_test "artifact repair failed"
  checksum=$(current_limine_config_checksum) || fail_test "config checksum failed"
  verify_limine_embedded_checksum "$PRIMARY" "$checksum" \
    || fail_test "primary Limine checksum was not proved"
  verify_limine_embedded_checksum "$FALLBACK" "$checksum" \
    || fail_test "fallback Limine checksum was not proved"
  verify_all_efi_artifacts "$checksum" || fail_test "final EFI proof failed after repair"

  [[ $(grep -Fxc 'ENABLE_VERIFICATION=no' "$(limine_default_config_path)") -eq 1 ]] \
    || fail_test "Limine verification setting was not normalized"
  [[ $(grep -Fxc 'ENABLE_ENROLL_LIMINE_CONFIG=yes' "$(limine_default_config_path)") -eq 1 ]] \
    || fail_test "Limine enrollment setting was not normalized"
  if grep -Eq 'limine-(reset-enroll|enroll-config)' "$(limine_default_config_path)"; then
    fail_test "obsolete Limine enrollment hooks were retained"
  fi

  jq -e --arg snapshot "$SNAPSHOT" --arg primary "$PRIMARY" --arg fallback "$FALLBACK" '
    .[$snapshot].file == $snapshot and
    .[$primary].file == $primary and
    .[$fallback].file == $fallback and
    (to_entries | all(.key | contains("missing.efi") | not)) and
    (to_entries | all(.key | contains("/Microsoft/") | not))
  ' "$SBCTL_FILES_DB" >/dev/null || fail_test "sbctl tracking cleanup or registration was incomplete"
  if grep -Fxq "sign:${SNAPSHOT}" "$ARTIFACT_LOG"; then
    fail_test "already-signed snapshot was signed instead of registered"
  fi

  last_enroll=$(awk -F: '/^enroll:/{line=NR} END{print line+0}' "$ARTIFACT_LOG")
  first_sign=$(awk -v target="sign:${MIXED}" '$0 == target {print NR; exit}' "$ARTIFACT_LOG")
  [[ "$last_enroll" -gt 0 && "$first_sign" -gt "$last_enroll" ]] \
    || fail_test "EFI signing did not follow both config enrollments"

  manifest=""
  for artifact in "$(state_dir_path)"/transactions/*/manifest.json; do
    if [[ $(jq -r '.operation' "$artifact") == artifact-success ]]; then
      manifest="$artifact"
    fi
  done
  [[ -n "$manifest" ]] || fail_test "repair transaction manifest was not found"
  jq -e '.completed_phases == [
    "backup-artifacts",
    "configure-limine",
    "enroll-config",
    "verify-config",
    "clean-tracking",
    "sign-efi",
    "prove-artifacts"
  ] and .status == "completed"' "$manifest" >/dev/null \
    || fail_test "repair phases were not committed in the required order"
  proof=$(jq -r '.domain_records.final_proof.path' "$manifest")
  jq -e --arg path "$SNAPSHOT" --argjson schema "$FINAL_PROOF_SCHEMA_VERSION" '
    .schema_version == $schema and any(.artifacts[]; .path == $path)
  ' "$proof" >/dev/null || fail_test "final proof omitted the snapshot artifact"

  : > "$ARTIFACT_LOG"
  run_artifact_repair "artifact-current-config" \
    || fail_test "current config enrollment repair failed"
  [[ $(grep -Fc 'enroll:' "$ARTIFACT_LOG") -eq 2 ]] \
    || fail_test "current config was not enrolled into both Limine binaries"
}

test_empty_database_repair() {
  : > "$SBCTL_FILES_DB"
  run_artifact_repair "artifact-empty-database" \
    || fail_test "artifact repair rejected an empty tracking database"
  jq -e --arg primary "$PRIMARY" --arg fallback "$FALLBACK" '
    .[$primary].file == $primary and .[$fallback].file == $fallback
  ' "$SBCTL_FILES_DB" >/dev/null \
    || fail_test "empty tracking database was not populated"
}

test_enrollment_failure_rollback() {
  local primary_hash fallback_hash defaults_hash db_hash
  primary_hash=$(sha256_file "$PRIMARY")
  fallback_hash=$(sha256_file "$FALLBACK")
  defaults_hash=$(sha256_file "$(limine_default_config_path)")
  db_hash=$(sha256_file "$SBCTL_FILES_DB")
  LIMINE_FAIL_TARGET="$FALLBACK"

  if run_artifact_repair "artifact-enroll-failure" >/dev/null 2>&1; then
    fail_test "one-target enrollment failure reported success"
  fi
  assert_hash "$primary_hash" "$PRIMARY" "primary Limine binary was not rolled back"
  assert_hash "$fallback_hash" "$FALLBACK" "fallback Limine binary changed after failed enrollment"
  assert_hash "$defaults_hash" "$(limine_default_config_path)" "Limine defaults were not rolled back"
  assert_hash "$db_hash" "$SBCTL_FILES_DB" "sbctl database changed before signing"
  assert_recovery_rollback "enroll-config"
}

test_readback_failure_rollback() {
  local primary_hash fallback_hash defaults_hash
  primary_hash=$(sha256_file "$PRIMARY")
  fallback_hash=$(sha256_file "$FALLBACK")
  defaults_hash=$(sha256_file "$(limine_default_config_path)")
  LIMINE_BAD_TARGET="$FALLBACK"

  if run_artifact_repair "artifact-readback-failure" >/dev/null 2>&1; then
    fail_test "incorrect embedded checksum reported success"
  fi
  assert_hash "$primary_hash" "$PRIMARY" "primary binary was not restored after read-back failure"
  assert_hash "$fallback_hash" "$FALLBACK" "fallback binary was not restored after read-back failure"
  assert_hash "$defaults_hash" "$(limine_default_config_path)" "defaults were not restored after read-back failure"
  assert_recovery_rollback "enroll-config"
}

test_final_proof_failure_rollback() {
  local primary_hash fallback_hash snapshot_hash mixed_hash defaults_hash
  primary_hash=$(sha256_file "$PRIMARY")
  fallback_hash=$(sha256_file "$FALLBACK")
  snapshot_hash=$(sha256_file "$SNAPSHOT")
  mixed_hash=$(sha256_file "$MIXED")
  defaults_hash=$(sha256_file "$(limine_default_config_path)")
  rm -f "$SBCTL_FILES_DB" "$SBCTL_ALTERNATE_DB"
  SBCTL_OMIT_LIST_PATH="$PRIMARY"

  if run_artifact_repair "artifact-proof-failure" >/dev/null 2>&1; then
    fail_test "incomplete final tracking proof reported success"
  fi
  assert_hash "$primary_hash" "$PRIMARY" "primary binary was not restored after proof failure"
  assert_hash "$fallback_hash" "$FALLBACK" "fallback binary was not restored after proof failure"
  assert_hash "$snapshot_hash" "$SNAPSHOT" "snapshot was not restored after proof failure"
  assert_hash "$mixed_hash" "$MIXED" "EFI tool was not restored after proof failure"
  assert_hash "$defaults_hash" "$(limine_default_config_path)" "defaults were not restored after proof failure"
  [[ ! -e "$SBCTL_FILES_DB" && ! -e "$SBCTL_ALTERNATE_DB" ]] \
    || fail_test "transaction-created sbctl tracking state survived rollback"
  assert_recovery_rollback "prove-artifacts"
}

test_final_proof_drift_rollback() {
  local mixed_hash persist_definition
  mixed_hash=$(sha256_file "$MIXED")
  persist_definition=$(declare -f persist_final_artifact_proof)
  persist_definition=${persist_definition/persist_final_artifact_proof/real_persist_final_artifact_proof}
  eval "$persist_definition"
  persist_final_artifact_proof() {
    printf 'DRIFT\n' >> "$MIXED"
    real_persist_final_artifact_proof "$@"
  }

  if run_artifact_repair "artifact-proof-drift" >/dev/null 2>&1; then
    fail_test "artifact drift during final-proof persistence reported success"
  fi
  assert_hash "$mixed_hash" "$MIXED" \
    "artifact drift during final-proof persistence was not rolled back"
  assert_recovery_rollback "prove-artifacts"
}

test_signing_failure_rollback() {
  local primary_hash fallback_hash mixed_hash defaults_hash db_hash
  primary_hash=$(sha256_file "$PRIMARY")
  fallback_hash=$(sha256_file "$FALLBACK")
  mixed_hash=$(sha256_file "$MIXED")
  defaults_hash=$(sha256_file "$(limine_default_config_path)")
  db_hash=$(sha256_file "$SBCTL_FILES_DB")
  SBCTL_FAIL_TARGET="$MIXED"

  if run_artifact_repair "artifact-sign-failure" >/dev/null 2>&1; then
    fail_test "EFI signing failure reported success"
  fi
  assert_hash "$primary_hash" "$PRIMARY" "primary changed after signing failure"
  assert_hash "$fallback_hash" "$FALLBACK" "fallback changed after signing failure"
  assert_hash "$mixed_hash" "$MIXED" "partially signed EFI file was not restored"
  assert_hash "$defaults_hash" "$(limine_default_config_path)" \
    "defaults changed after signing failure"
  assert_hash "$db_hash" "$SBCTL_FILES_DB" "tracking database changed after signing failure"
  assert_recovery_rollback "sign-efi"
}

test_sign_sync_failure_rollback() {
  local mixed_hash
  mixed_hash=$(sha256_file "$MIXED")
  SYNC_FAIL_PATH="$MIXED"
  if run_artifact_repair "artifact-sign-sync-failure" >/dev/null 2>&1; then
    fail_test "EFI durability failure reported success"
  fi
  SYNC_FAIL_PATH=""
  assert_hash "$mixed_hash" "$MIXED" "EFI file was not restored after durability failure"
  assert_recovery_rollback "sign-efi"
}

# Snapshot churn creates and deletes hash-suffixed UKIs for as long as the
# machine lives; ownership follows the files that exist instead of growing
# toward the record limit.
test_ownership_retirement() {
  local index churn_dir record live
  churn_dir="${CASE_DIR}/boot/EFI/Linux"
  for ((index=0; index < 40; index++)); do
    printf 'CHURN %s\n' "$index" \
      > "${churn_dir}/churn-${index}.efi_sha256_$(printf '%08x' "$index")"
  done
  run_artifact_repair "artifact-churn-seed" || fail_test "churn seed repair failed"
  read_lifecycle || fail_test "churn seed lifecycle unreadable"
  record=$(read_control_document \
    "$(jq -r '.tracking_ownership.path' <<< "$_lifecycle_json")") \
    || fail_test "churn seed ownership record unreadable"
  [[ $(jq '[.paths[] | select(contains("/churn-"))] | length' <<< "$record") -eq 40 ]] \
    || fail_test "churn seed did not record ownership of the snapshot UKIs"

  rm -f "${churn_dir}"/churn-*
  live="${churn_dir}/churn-live.efi_sha256_ffffffff"
  printf 'LIVE\n' > "$live"
  run_artifact_repair "artifact-churn-retire" || fail_test "repair after snapshot churn failed"
  read_lifecycle || fail_test "churn retire lifecycle unreadable"
  record=$(read_control_document \
    "$(jq -r '.tracking_ownership.path' <<< "$_lifecycle_json")") \
    || fail_test "churn retire ownership record unreadable"
  [[ $(jq '[.paths[] | select(contains("/churn-"))] | length' <<< "$record") -eq 1 ]] \
    || fail_test "retired snapshot UKIs stayed in the ownership record"
  jq -e --arg path "$live" '.paths | index($path) != null' <<< "$record" >/dev/null \
    || fail_test "the live snapshot UKI was not owned"
  [[ $(jq '[to_entries[] | select(.key | contains("/churn-"))] | length' "$SBCTL_FILES_DB") -eq 1 ]] \
    || fail_test "retired snapshot UKIs stayed tracked"
}

test_final_mapping_failure_rollback() {
  local db_hash
  db_hash=$(sha256_file "$SBCTL_FILES_DB")
  SBCTL_INJECT_MAPPING_TARGET="$PRIMARY"
  if run_artifact_repair "artifact-final-mapping-failure" >/dev/null 2>&1; then
    fail_test "ambiguous mapping introduced during signing reported success"
  fi
  assert_hash "$db_hash" "$SBCTL_FILES_DB" \
    "tracking database was not restored after final mapping failure"
  assert_recovery_rollback "prove-artifacts"
}

# ENABLE_LIMINE_FALLBACK=no with no fallback loader on the ESP (Omarchy 4.0.3
# on the Vivobook TP3402VA, 2026-09-10): the primary is the whole managed
# set, the defaults file outranks the drop-in, and a quoted value parses.
test_fallback_not_deployed() {
  local checksum manifest artifact
  printf 'ENABLE_LIMINE_FALLBACK=yes\n' > "${CASE_DIR}/limine-dropin.conf"
  printf 'ENABLE_LIMINE_FALLBACK="no"\n' >> "$(limine_default_config_path)"
  rm -f "$FALLBACK"
  [[ "$(limine_fallback_policy)" == no ]] \
    || fail_test "the defaults file did not override the drop-in"
  if limine_fallback_is_managed; then
    fail_test "an absent fallback under policy no was managed"
  fi
  run_artifact_repair "artifact-no-fallback" > "${CASE_DIR}/no-fallback.out" 2>&1 \
    || fail_test "repair without a fallback loader failed: $(<"${CASE_DIR}/no-fallback.out")"
  grep -Fq 'Limine fallback loader is not deployed (ENABLE_LIMINE_FALLBACK=no)' \
    "${CASE_DIR}/no-fallback.out" || fail_test "the repair did not say the fallback is not deployed"
  checksum=$(current_limine_config_checksum) || fail_test "config checksum failed"
  verify_limine_embedded_checksum "$PRIMARY" "$checksum" \
    || fail_test "primary Limine checksum was not proved"
  [[ ! -e "$FALLBACK" ]] || fail_test "repair created a fallback loader"
  verify_all_efi_artifacts "$checksum" || fail_test "final EFI proof failed without a fallback"
  [[ $(grep -Fc 'enroll:' "$ARTIFACT_LOG") -eq 1 ]] \
    || fail_test "enrollment did not stop at the primary"
  jq -e --arg fallback "$FALLBACK" 'has($fallback) | not' "$SBCTL_FILES_DB" >/dev/null \
    || fail_test "tracking registered an absent fallback"
  manifest=""
  for artifact in "$(state_dir_path)"/transactions/*/manifest.json; do
    [[ $(jq -r '.operation' "$artifact") != artifact-no-fallback ]] || manifest="$artifact"
  done
  [[ -n "$manifest" ]] || fail_test "no-fallback repair manifest was not found"
  jq -e --arg fallback "$FALLBACK" \
    '.status == "completed" and ([.backups[] | select(.target == $fallback)] | length) == 0' \
    "$manifest" >/dev/null || fail_test "the transaction recorded an absent fallback"
}

# A policy that deploys the fallback (unset, an empty value, or yes) with the
# loader missing is refused before any transaction, naming the loader and
# the remedy; an unreadable value is refused as such.
test_fallback_missing_is_refused() {
  local generation
  rm -f "$FALLBACK"
  read_lifecycle || fail_test "missing-fallback fixture lifecycle is unreadable"
  generation=$_lifecycle_generation
  if run_artifact_repair "artifact-missing-fallback" > "${CASE_DIR}/missing.out" 2>&1; then
    fail_test "a missing fallback under an unset policy was accepted"
  fi
  grep -Fq "Limine fallback loader is missing at ${FALLBACK} while ENABLE_LIMINE_FALLBACK is unset; run limine-install to deploy it" \
    "${CASE_DIR}/missing.out" || fail_test "the missing fallback refusal did not name the loader: $(<"${CASE_DIR}/missing.out")"
  grep -Fq 'preflight failed; no transaction was started' "${CASE_DIR}/missing.out" \
    || fail_test "the missing fallback refusal started a transaction"
  printf 'ENABLE_LIMINE_FALLBACK=no\nENABLE_LIMINE_FALLBACK=""\n' >> "$(limine_default_config_path)"
  [[ "$(limine_fallback_policy)" == unset ]] || fail_test "an empty last value did not read as unset"
  printf 'ENABLE_LIMINE_FALLBACK=yes\n' > "${CASE_DIR}/limine-dropin.conf"
  [[ "$(limine_fallback_policy)" == unset ]] \
    || fail_test "a drop-in outranked the defaults file"
  printf 'ENABLE_LIMINE_FALLBACK=yes\n' >> "$(limine_default_config_path)"
  if run_artifact_repair "artifact-missing-fallback-yes" > "${CASE_DIR}/missing-yes.out" 2>&1; then
    fail_test "a missing fallback under policy yes was accepted"
  fi
  grep -Fq 'while ENABLE_LIMINE_FALLBACK is yes' "${CASE_DIR}/missing-yes.out" \
    || fail_test "the refusal did not report policy yes"
  printf 'ENABLE_LIMINE_FALLBACK=maybe\n' >> "$(limine_default_config_path)"
  if run_artifact_repair "artifact-bad-policy" > "${CASE_DIR}/bad-policy.out" 2>&1; then
    fail_test "an unreadable fallback policy was accepted"
  fi
  grep -Fq 'ENABLE_LIMINE_FALLBACK could not be resolved' "${CASE_DIR}/bad-policy.out" \
    || fail_test "the unreadable policy was not named"
  read_lifecycle || fail_test "refusals damaged the lifecycle"
  [[ "$_lifecycle_state" == active && $_lifecycle_generation -eq generation ]] \
    || fail_test "a refused preflight published a transaction"
}

# A fallback loader that exists stays in the managed set whatever the policy
# says, so it never boots with a stale config checksum.
test_fallback_present_under_no() {
  local checksum
  printf 'ENABLE_LIMINE_FALLBACK=no\n' >> "$(limine_default_config_path)"
  limine_fallback_is_managed || fail_test "an existing fallback under policy no was not managed"
  run_artifact_repair "artifact-fallback-kept" || fail_test "repair with a kept fallback failed"
  checksum=$(current_limine_config_checksum) || fail_test "config checksum failed"
  verify_limine_embedded_checksum "$FALLBACK" "$checksum" \
    || fail_test "the kept fallback was not enrolled"
  [[ $(grep -Fc 'enroll:' "$ARTIFACT_LOG") -eq 2 ]] \
    || fail_test "the kept fallback was not enrolled alongside the primary"
}

# Activation ordering with a deliberately rewriting snapshot fixture: the OS
# entry changes before signing, the snapshot entry changes afterwards, and
# the last enrolled checksum must describe all final producer edits.
test_activation_regenerates_entries() {
  local checksum manifest artifact history_hash remainder mkinitcpio_line
  local first_sign snapper_line first_enroll
  write_hashed_limine_config
  [[ -z "$(list_stale_limine_path_hashes)" ]] || fail_test "the fixture's hashes did not match"
  run_activation_repair "artifact-activation" > "${CASE_DIR}/activation.out" 2>&1 \
    || fail_test "activation repair failed: $(<"${CASE_DIR}/activation.out")"
  # The enroll phase signs its staged loaders too, so the order proved here is
  # mkinitcpio, the artifact signing, snapper-sync, then the first enrollment.
  mkinitcpio_line=$(grep -n -m1 '^mkinitcpio$' "$ARTIFACT_LOG" | cut -d: -f1)
  first_sign=$(grep -n -m1 '^sign:' "$ARTIFACT_LOG" | cut -d: -f1)
  snapper_line=$(grep -n -m1 '^snapper-sync$' "$ARTIFACT_LOG" | cut -d: -f1)
  first_enroll=$(grep -n -m1 '^enroll:' "$ARTIFACT_LOG" | cut -d: -f1)
  [[ -n "$mkinitcpio_line" && -n "$first_sign" && -n "$snapper_line" && -n "$first_enroll" ]] \
    || fail_test "activation did not run every regeneration and signing step: $(<"$ARTIFACT_LOG")"
  [[ "$mkinitcpio_line" -lt "$first_sign" && "$first_sign" -lt "$snapper_line" \
    && "$snapper_line" -lt "$first_enroll" ]] \
    || fail_test "activation order was not mkinitcpio, sign, snapper-sync, enroll: $(<"$ARTIFACT_LOG")"
  grep -Fxq "sign:${HISTORY}" "$ARTIFACT_LOG" || fail_test "the snapshot UKI was not signed in the sign phase"
  [[ $(grep -n -Fx "sign:${HISTORY}" "$ARTIFACT_LOG" | cut -d: -f1) -lt "$snapper_line" ]] \
    || fail_test "the snapshot entry was regenerated before its file was signed"
  grep -Fxq '    path: boot():/EFI/Linux/omarchy_linux.efi' "$(limine_config_path)" \
    || fail_test "the regenerated OS entry still carries a hash"
  read -r history_hash remainder < <(b2sum "$HISTORY")
  grep -Fxq "    path: boot():/EFI/Linux/history.efi_sha256_abc#${history_hash}" \
    "$(limine_config_path)" || fail_test "the snapshot entry does not hash the signed file"
  grep -aFxq 'LOCAL_SIGNATURE' "$HISTORY" || fail_test "the snapshot UKI was not signed"
  grep -aFxq 'UKI_REBUILT' "$OS_UKI" || fail_test "the OS UKI was not rebuilt"
  [[ -z "$(list_stale_limine_path_hashes)" ]] || fail_test "a stale hash survived activation"
  checksum=$(current_limine_config_checksum) || fail_test "config checksum failed"
  verify_limine_embedded_checksum "$PRIMARY" "$checksum" \
    || fail_test "the enrolled checksum does not describe the final config"
  verify_all_efi_artifacts "$checksum" || fail_test "final EFI proof failed after activation"
  manifest=""
  for artifact in "$(state_dir_path)"/transactions/*/manifest.json; do
    [[ $(jq -r '.operation' "$artifact") != artifact-activation ]] || manifest="$artifact"
  done
  [[ -n "$manifest" ]] || fail_test "activation manifest was not found"
  jq -e --arg config "$(limine_config_path)" --arg uki "$OS_UKI" '.completed_phases == [
    "backup-artifacts",
    "configure-limine",
    "regenerate-entries",
    "clean-tracking",
    "sign-efi",
    "regenerate-snapshot-entries",
    "enroll-config",
    "verify-config",
    "prove-artifacts"
  ] and .status == "completed" and
    ([.backups[] | select(.target == $config)] | length) == 1 and
    ([.backups[] | select(.target == $uki)] | length) == 1' "$manifest" >/dev/null \
    || fail_test "activation phases or backups were not recorded as required"
}

# A regeneration failure rolls the config and the UKI back to their recorded
# state and leaves recovery pending, like every other repair phase.
test_activation_regeneration_failure_rolls_back() {
  local config_hash uki_hash
  write_hashed_limine_config
  config_hash=$(sha256_file "$(limine_config_path)")
  uki_hash=$(sha256_file "$OS_UKI")
  MKINITCPIO_FAIL=true
  if run_activation_repair "artifact-activation-failure" >/dev/null 2>&1; then
    fail_test "a failed limine-mkinitcpio did not fail activation"
  fi
  assert_recovery_rollback "regenerate-entries"
  assert_hash "$config_hash" "$(limine_config_path)" "limine.conf was not restored after the regeneration failure"
  assert_hash "$uki_hash" "$OS_UKI" "the OS UKI was not restored after the regeneration failure"
}

# Without hashed paths activation regenerates nothing and runs the phases as
# recorded.
test_activation_without_hashes_skips_regeneration() {
  printf 'UKI\n' > "$OS_UKI"
  printf '%s\n' 'timeout: 5' '/+Omarchy' '    protocol: efi' \
    '    path: boot():/EFI/Linux/omarchy_linux.efi' > "$(limine_config_path)"
  run_activation_repair "artifact-activation-plain" \
    || fail_test "activation without hashed paths failed"
  if grep -Eq '^(mkinitcpio|snapper-sync)$' "$ARTIFACT_LOG"; then
    fail_test "activation regenerated entries that carried no hash"
  fi
  grep -aFxq 'LOCAL_SIGNATURE' "$OS_UKI" || fail_test "the OS UKI was not signed"
}

test_path_hash_proof_boundaries() {
  local config path checksum result invalid producer_calls regenerator
  config=$(limine_config_path)
  path="$(esp_path)/EFI/Linux/path with spaces.efi"
  printf 'fixture image\n' > "$path"
  checksum=$(b2sum < "$path")
  checksum=${checksum%% *}
  printf '%s\n' '/Omarchy' 'protocol: efi' \
    "path: boot():/EFI/Linux/path with spaces.efi#${checksum^^}" > "$config"
  result=$(list_stale_limine_path_hashes) || fail_test "valid spaced path could not be verified"
  [[ -z "$result" ]] || fail_test "valid spaced path or uppercase hash was rejected"
  b2sum() {
    printf '%s  -\n' "$checksum"
    return 7
  }
  result=$(list_stale_limine_path_hashes) || fail_test "failed checksum could not be reported"
  [[ -n "$result" ]] || fail_test "plausible checksum output hid the hash command failure"
  unset -f b2sum
  for invalid in broken '' "${checksum}0" "${checksum} trailing"; do
    printf '%s\n' '/Omarchy' 'protocol: efi' \
      "path: boot():/EFI/Linux/path with spaces.efi#${invalid}" > "$config"
    result=$(list_stale_limine_path_hashes) || fail_test "malformed hash enumeration failed"
    [[ -n "$result" ]] || fail_test "malformed EFI URI hash was waived: ${invalid}"
  done
  printf '%s\n' "global_dtb: boot():/tree.dtb#broken" > "$config"
  [[ -n "$(list_stale_limine_path_hashes)" ]] \
    || fail_test "malformed global DTB hash was waived"
  printf 'outside fixture\n' > "${CASE_DIR}/outside.efi"
  checksum=$(b2sum < "${CASE_DIR}/outside.efi")
  checksum=${checksum%% *}
  printf '%s\n' '/Omarchy' 'protocol: efi' \
    "path: boot():/../outside.efi#${checksum}" > "$config"
  [[ -n "$(list_stale_limine_path_hashes)" ]] \
    || fail_test "boot-relative path escaped the ESP during proof"
  rm "$config"
  if list_stale_limine_path_hashes; then
    fail_test "missing configuration was treated as a proved empty path set"
  fi
  list_limine_entry_paths() {
    printf '3: path: boot():/EFI/Linux/image.efi#broken\n'
    return 7
  }
  if list_stale_limine_path_hashes; then
    fail_test "partial failed enumeration was accepted as path-hash proof"
  fi
  producer_calls="${CASE_DIR}/unexpected-regeneration.log"
  _activation_limine_tools_json='{}'
  run_bound_limine_tool() {
    printf '%s\n' "$1" >> "$producer_calls"
    return 0
  }
  durable_sync() { return 0; }
  for regenerator in regenerate_limine_os_entry regenerate_limine_snapshot_entries; do
    : > "$producer_calls"
    if "$regenerator"; then
      fail_test "${regenerator} accepted failed path enumeration"
    fi
    [[ ! -s "$producer_calls" ]] \
      || fail_test "${regenerator} invoked a producer after failed path enumeration"
  done
}

run_case() {
  local name="$1" test_function="$2"
  case "${ARTIFACT_TEST_CASE:-all}" in
    all) ;;
    path-hash-proof) [[ "$name" == path-hash-proof ]] || return 0 ;;
    *) fail_test "unknown ARTIFACT_TEST_CASE: ${ARTIFACT_TEST_CASE}" ;;
  esac
  (
    setup_fixture "$name"
    "$test_function"
  )
}

run_case discovery test_discovery_and_tracking_sources
run_case path-hash-proof test_path_hash_proof_boundaries
run_case sbctl-config test_sbctl_config_resolution
run_case preflight test_preflight_validation
run_case mappings test_mapping_validation
run_case staged-install test_staged_limine_install
run_case success test_successful_repair
run_case empty-database test_empty_database_repair
run_case enrollment-failure test_enrollment_failure_rollback
run_case readback-failure test_readback_failure_rollback
run_case signing-failure test_signing_failure_rollback
run_case sign-sync-failure test_sign_sync_failure_rollback
run_case final-mapping-failure test_final_mapping_failure_rollback
run_case ownership-retirement test_ownership_retirement
run_case proof-failure test_final_proof_failure_rollback
run_case proof-drift test_final_proof_drift_rollback
run_case fallback-not-deployed test_fallback_not_deployed
run_case fallback-missing test_fallback_missing_is_refused
run_case fallback-kept test_fallback_present_under_no
run_case activation-regenerates test_activation_regenerates_entries
run_case activation-regeneration-failure test_activation_regeneration_failure_rolls_back
run_case activation-plain test_activation_without_hashes_skips_regeneration
FIXTURE_ORIGINAL_VERIFICATION=yes run_case setting-drift test_managed_setting_drift_repair

printf 'artifact tests passed\n'
