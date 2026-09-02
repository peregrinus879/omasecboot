#!/bin/bash
# shellcheck disable=SC2034,SC2154,SC2329 # Sourced modules consume dynamic fixtures.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-enrollment.XXXXXX")

cleanup() {
  release_boot_repair_lock 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/discover.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/sign.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/enroll.sh"

pacman_database_lock_path() {
  printf '%s/pacman-db.lck\n' "$TEST_DIR"
}

test_sbctl_boundary_implementation() (
  local boundary_config="${TEST_DIR}/boundary.conf"
  local boundary_package="sbctl 0.18-2"
  local boundary_executable="/usr/bin/sbctl"
  local boundary_owner="sbctl"
  local boundary_hash
  boundary_hash=$(printf boundary | sha256sum | cut -d' ' -f1)

  printf '# canonical defaults\n' > "$boundary_config"

  sbctl_config_path() {
    printf '%s\n' "$boundary_config"
  }

  pacman() {
    case "$1" in
      -Q)
        [[ "$2" == sbctl ]] || return 1
        printf '%s\n' "$boundary_package"
        ;;
      -Qqo)
        [[ "$2" == /usr/bin/sbctl ]] || return 1
        printf '%s\n' "$boundary_owner"
        ;;
      *) return 1 ;;
    esac
  }

  command() {
    [[ $# -eq 2 && $1 == -v && $2 == sbctl ]] || return 1
    printf '/fixture/bin/sbctl\n'
  }

  readlink() {
    [[ $# -eq 2 && $1 == -f && $2 == /fixture/bin/sbctl ]] || return 1
    printf '%s\n' "$boundary_executable"
  }

  validate_control_file() {
    [[ "$1" == /usr/bin/sbctl || "$1" == /var/lib/sbctl/GUID \
      || "$1" == "$boundary_config" ]]
  }

  validate_control_directory() {
    return 0
  }

  path_has_no_symlink_components() {
    [[ "$1" == /var/lib/sbctl/keys || "$1" == /var/lib/sbctl/GUID ]]
  }

  sha256_file() {
    [[ "$1" == /usr/bin/sbctl || "$1" == "$boundary_config" ]] || return 1
    printf '%s\n' "$boundary_hash"
  }

  validate_sbctl_enrollment_boundary \
    || fail_test "canonical sbctl enrollment boundary was rejected"
  [[ "$_sbctl_package_identity" == "sbctl 0.18-2" \
    && "$_sbctl_executable" == /usr/bin/sbctl \
    && "$_sbctl_executable_hash" == "$boundary_hash" \
    && "$_sbctl_config_state" == present \
    && "$_sbctl_config_hash" == "$boundary_hash" \
    && "$_sbctl_keydir" == /var/lib/sbctl/keys \
    && "$_sbctl_guid_path" == /var/lib/sbctl/GUID ]] \
    || fail_test "canonical sbctl enrollment boundary was not captured"

  boundary_package="sbctl 0.19-1"
  if validate_sbctl_enrollment_boundary; then
    fail_test "unsupported sbctl package version was accepted"
  fi

  boundary_package="sbctl 0.18-2"
  boundary_executable="/usr/local/bin/sbctl"
  if validate_sbctl_enrollment_boundary; then
    fail_test "noncanonical sbctl executable was accepted"
  fi

  boundary_executable="/usr/bin/sbctl"
  boundary_owner="foreign-package"
  if validate_sbctl_enrollment_boundary; then
    fail_test "foreign-owned sbctl executable was accepted"
  fi

  boundary_owner="sbctl"
  printf 'keydir: /tmp/keys\n' > "$boundary_config"
  if validate_sbctl_enrollment_boundary; then
    fail_test "noncanonical sbctl key directory was accepted"
  fi
)

test_run_sbctl_enrollment_uses_validated_executable() (
  local executable="${TEST_DIR}/pinned-sbctl" log="${TEST_DIR}/pinned-sbctl.log"
  # shellcheck disable=SC2016 # Expand these variables when the fixture executes.
  printf '%s\n' '#!/bin/sh' \
    'printf "%s\n" "$*" > "$SBCTL_EXEC_LOG"' \
    'exit "${SBCTL_EXEC_RC:-0}"' > "$executable"
  chmod 700 "$executable"
  export SBCTL_EXEC_LOG="$log" SBCTL_EXEC_RC=0
  _sbctl_executable="$executable"

  sbctl() {
    return 97
  }

  run_sbctl_enrollment enroll-keys -m -f --partial db \
    || fail_test "validated sbctl executable was not invoked"
  [[ "$(<"$log")" == "enroll-keys -m -f --partial db" ]] \
    || fail_test "validated sbctl executable received the wrong arguments"

  SBCTL_EXEC_RC=23
  export SBCTL_EXEC_RC
  if run_sbctl_enrollment create-keys; then
    fail_test "validated sbctl executable failure was ignored"
  fi

  _sbctl_executable=""
  if run_sbctl_enrollment create-keys; then
    fail_test "empty validated sbctl executable was accepted"
  fi
)

test_sbctl_boundary_implementation \
  || fail_test "production sbctl boundary test failed"
test_run_sbctl_enrollment_uses_validated_executable \
  || fail_test "production sbctl runner test failed"

QUIET=true

CERT_KEY="${TEST_DIR}/fixture.key"
CERT_PEM="${TEST_DIR}/fixture.pem"
CERT_DER="${TEST_DIR}/fixture.der"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
  -subj /CN=OmaSecBoot-Test -keyout "$CERT_KEY" -out "$CERT_PEM" \
  >/dev/null 2>&1
openssl x509 -in "$CERT_PEM" -outform DER -out "$CERT_DER"

CASE_DIR=""
EFIVARS_DIR=""
DMI_DIR=""
PLAN_SOURCE=""
SBCTL_ROOT=""
SBCTL_LOG=""
ARTIFACT_LOG=""
WINDOWS_RC=0
ALLOW_SETUP=true
ALLOW_ENROLL=false
SBCTL_FAIL_PHASE=""
SBCTL_MISMATCH_PHASE=""
SBCTL_BAD_KEY=false
ENROLLMENT_MUTATION_POINT=""
ENROLLMENT_MUTATION_USED=false

state_dir_path() {
  printf '%s/state\n' "$CASE_DIR"
}

limine_lock_path() {
  printf '%s/boot-partition.lock\n' "$CASE_DIR"
}

snapshot_restore_lock_path() {
  printf '%s/limine-snapper-restore.lock\n' "$CASE_DIR"
}

firmware_variables_path() {
  printf '%s\n' "$EFIVARS_DIR"
}

firmware_runtime_dir_path() {
  printf '%s/runtime/firmware\n' "$CASE_DIR"
}

firmware_dmi_root_path() {
  printf '%s\n' "$DMI_DIR"
}

sbctl_config_path() {
  printf '%s/sbctl.conf\n' "$CASE_DIR"
}

control_owner_uid() {
  id -u
}

require_control_root() {
  :
}

durable_sync() {
  :
}

validate_efivarfs_mount() {
  [[ -d "$EFIVARS_DIR" && ! -L "$EFIVARS_DIR" ]]
}

capture_service_state() {
  printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"not-found","active_state":"inactive","unit_file_state":"not-found"}}'
}

state_aware_setup_is_available() {
  [[ "$ALLOW_SETUP" == true ]]
}

firmware_enrollment_is_available() {
  [[ "$ALLOW_ENROLL" == true ]]
}

secure_boot_windows_gate() {
  return "$WINDOWS_RC"
}

validate_sbctl_enrollment_boundary() {
  _sbctl_package_identity="sbctl 0.18-2"
  _sbctl_executable="${CASE_DIR}/bin/sbctl"
  _sbctl_executable_hash=$(sha256_file "$_sbctl_executable") || return 1
  _sbctl_config_state=absent
  _sbctl_config_hash=""
  _sbctl_keydir="${SBCTL_ROOT}/keys"
  _sbctl_guid_path="${SBCTL_ROOT}/GUID"
}

artifact_repair_preflight() {
  _repair_config_checksum=$(printf fixture | b2sum | cut -d' ' -f1)
  printf 'artifact-preflight\n' >> "$ARTIFACT_LOG"
}

repair_boot_artifacts() {
  transaction_phase_start "backup-artifacts" || return 1
  printf 'artifact-repair\n' >> "$ARTIFACT_LOG"
  transaction_phase_complete "backup-artifacts"
}

verify_all_efi_artifacts() {
  [[ "$1" == "$_repair_config_checksum" ]] || return 1
  printf 'artifact-proof\n' >> "$ARTIFACT_LOG"
}

append_hex() {
  local file="$1" hex="$2" escaped="" index
  [[ "$hex" =~ ^([0-9a-f]{2})+$ ]] || return 1
  for ((index = 0; index < ${#hex}; index += 2)); do
    escaped+="\\x${hex:index:2}"
  done
  printf '%b' "$escaped" >> "$file"
}

append_le32() {
  local file="$1" value="$2" hex
  printf -v hex '%02x%02x%02x%02x' \
    "$((value & 255))" "$(((value >> 8) & 255))" \
    "$(((value >> 16) & 255))" "$(((value >> 24) & 255))"
  append_hex "$file" "$hex"
}

append_byte() {
  local file="$1" value="$2" hex
  printf -v hex '%02x' "$value"
  append_hex "$file" "$hex"
}

append_x509_list() {
  local file="$1" owner="$2" cert="$3" cert_size signature_size list_size
  cert_size=$(stat -Lc '%s' "$cert")
  signature_size=$((16 + cert_size))
  list_size=$((28 + signature_size))
  append_hex "$file" "$EFI_SIGNATURE_X509_BYTES"
  append_le32 "$file" "$list_size"
  append_le32 "$file" 0
  append_le32 "$file" "$signature_size"
  append_hex "$file" "$owner"
  command cat "$cert" >> "$file"
}

append_sha256_list() {
  local file="$1" owner="$2" data="$3"
  append_hex "$file" "$EFI_SIGNATURE_SHA256_BYTES"
  append_le32 "$file" 76
  append_le32 "$file" 0
  append_le32 "$file" 48
  append_hex "$file" "$owner"
  append_hex "$file" "$data"
}

write_raw_database() {
  local name="$1" esl="$2" path
  path=$(firmware_variable_path "$name")
  : > "$path"
  append_le32 "$path" "$EFI_ACTIVE_AUTH_ATTRIBUTES"
  command cat "$esl" >> "$path"
  chmod 600 "$path"
}

write_state_variable() {
  local name="$1" value="$2" path
  path=$(firmware_variable_path "$name")
  : > "$path"
  append_le32 "$path" "$EFI_STATE_ATTRIBUTES"
  append_byte "$path" "$value"
  chmod 600 "$path"
}

create_key_fixture() {
  local path
  mkdir -p "$SBCTL_ROOT/keys/PK" "$SBCTL_ROOT/keys/KEK" "$SBCTL_ROOT/keys/db"
  chmod 700 "$SBCTL_ROOT" "$SBCTL_ROOT/keys" "$SBCTL_ROOT/keys/PK" \
    "$SBCTL_ROOT/keys/KEK" "$SBCTL_ROOT/keys/db"
  printf '12345678-1234-4234-8234-123456789abc\n' > "$SBCTL_ROOT/GUID"
  for path in PK KEK db; do
    cp "$CERT_KEY" "$SBCTL_ROOT/keys/$path/$path.key"
    cp "$CERT_PEM" "$SBCTL_ROOT/keys/$path/$path.pem"
    chmod 600 "$SBCTL_ROOT/keys/$path/$path.key" \
      "$SBCTL_ROOT/keys/$path/$path.pem"
  done
  if [[ "$SBCTL_BAD_KEY" == true ]]; then
    printf 'not-a-private-key\n' > "$SBCTL_ROOT/keys/KEK/KEK.key"
    chmod 600 "$SBCTL_ROOT/keys/KEK/KEK.key"
  fi
  chmod 600 "$SBCTL_ROOT/GUID"
}

sbctl() {
  printf '%s\n' "$*" >> "$SBCTL_LOG"
  case "$*" in
    create-keys)
      create_key_fixture
      ;;
    'enroll-keys -m -f --export esl')
      cp "$PLAN_SOURCE/PK.esl" "$PLAN_SOURCE/KEK.esl" "$PLAN_SOURCE/db.esl" .
      chmod 600 PK.esl KEK.esl db.esl
      ;;
    'enroll-keys -m -f --partial db')
      [[ "$SBCTL_FAIL_PHASE" != before-db ]] || return 31
      if [[ "$SBCTL_MISMATCH_PHASE" == db ]]; then
        write_raw_database db "$PLAN_SOURCE/mismatch.esl"
      else
        write_raw_database db "$PLAN_SOURCE/db.esl"
      fi
      [[ "$SBCTL_FAIL_PHASE" != after-db ]] || return 32
      ;;
    'enroll-keys -m -f --partial KEK')
      [[ "$SBCTL_FAIL_PHASE" != before-KEK ]] || return 33
      write_raw_database KEK "$PLAN_SOURCE/KEK.esl"
      [[ "$SBCTL_FAIL_PHASE" != after-KEK ]] || return 34
      ;;
    'enroll-keys -m -f --partial PK')
      [[ "$SBCTL_FAIL_PHASE" != before-PK ]] || return 35
      write_raw_database PK "$PLAN_SOURCE/PK.esl"
      write_state_variable SetupMode 0
      [[ "$SBCTL_FAIL_PHASE" != after-PK ]] || return 36
      ;;
    *)
      return 97
      ;;
  esac
}

run_sbctl_enrollment() {
  sbctl "$@"
}

enrollment_failpoint() {
  local point="$1"
  [[ -n "$ENROLLMENT_MUTATION_POINT" \
    && "$point" == "$ENROLLMENT_MUTATION_POINT" \
    && "$ENROLLMENT_MUTATION_USED" == false ]] || return 0
  ENROLLMENT_MUTATION_USED=true
  case "$point" in
    after-firmware-snapshot)
      write_raw_database db "$PLAN_SOURCE/mismatch.esl"
      ;;
    after-enrollment-artifact-repair)
      write_raw_database dbx "$PLAN_SOURCE/mismatch.esl"
      ;;
    before-db-write)
      ALLOW_ENROLL=false
      ;;
    before-activation-artifact-repair)
      ALLOW_SETUP=false
      ;;
    *) return 1 ;;
  esac
}

setup_fixture() {
  local name="$1" owner
  release_boot_repair_lock 2>/dev/null || true
  CASE_DIR="${TEST_DIR}/${name}"
  EFIVARS_DIR="${CASE_DIR}/efivars"
  DMI_DIR="${CASE_DIR}/dmi"
  PLAN_SOURCE="${CASE_DIR}/planned"
  SBCTL_ROOT="${CASE_DIR}/sbctl-state"
  SBCTL_LOG="${CASE_DIR}/sbctl.log"
  ARTIFACT_LOG="${CASE_DIR}/artifact.log"
  mkdir -p "$CASE_DIR" "$EFIVARS_DIR" "$DMI_DIR" "$PLAN_SOURCE" \
    "${CASE_DIR}/bin" "$SBCTL_ROOT"
  chmod 700 "$CASE_DIR" "$EFIVARS_DIR" "$DMI_DIR" "$PLAN_SOURCE" \
    "${CASE_DIR}/bin" "$SBCTL_ROOT"
  : > "$SBCTL_LOG"
  : > "$ARTIFACT_LOG"
  printf '#!/bin/sh\nexit 97\n' > "${CASE_DIR}/bin/sbctl"
  chmod 700 "${CASE_DIR}/bin/sbctl"
  printf '12345678-1234-4234-8234-123456789abc\n' > "$DMI_DIR/product_uuid"
  for name in sys_vendor product_name product_version board_vendor board_name \
    board_version board_serial bios_vendor bios_version; do
    printf 'fixture-%s\n' "$name" > "$DMI_DIR/$name"
  done

  owner=11111111111111111111111111111111
  : > "$PLAN_SOURCE/current-PK.esl"
  append_x509_list "$PLAN_SOURCE/current-PK.esl" "$owner" "$CERT_DER"
  : > "$PLAN_SOURCE/PK.esl"
  append_x509_list "$PLAN_SOURCE/PK.esl" 22222222222222222222222222222222 "$CERT_DER"
  : > "$PLAN_SOURCE/current-KEK.esl"
  append_x509_list "$PLAN_SOURCE/current-KEK.esl" 33333333333333333333333333333333 "$CERT_DER"
  : > "$PLAN_SOURCE/KEK.esl"
  append_x509_list "$PLAN_SOURCE/KEK.esl" 33333333333333333333333333333333 "$CERT_DER"
  append_x509_list "$PLAN_SOURCE/KEK.esl" 44444444444444444444444444444444 "$CERT_DER"
  : > "$PLAN_SOURCE/current-db.esl"
  append_x509_list "$PLAN_SOURCE/current-db.esl" 55555555555555555555555555555555 "$CERT_DER"
  : > "$PLAN_SOURCE/db.esl"
  append_x509_list "$PLAN_SOURCE/db.esl" 55555555555555555555555555555555 "$CERT_DER"
  append_x509_list "$PLAN_SOURCE/db.esl" 66666666666666666666666666666666 "$CERT_DER"
  : > "$PLAN_SOURCE/dbx.esl"
  append_sha256_list "$PLAN_SOURCE/dbx.esl" 77777777777777777777777777777777 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$PLAN_SOURCE/mismatch.esl"
  append_x509_list "$PLAN_SOURCE/mismatch.esl" 99999999999999999999999999999999 "$CERT_DER"
  chmod 600 "$PLAN_SOURCE"/*.esl

  write_raw_database PK "$PLAN_SOURCE/current-PK.esl"
  write_raw_database KEK "$PLAN_SOURCE/current-KEK.esl"
  write_raw_database db "$PLAN_SOURCE/current-db.esl"
  write_raw_database dbx "$PLAN_SOURCE/dbx.esl"
  write_state_variable SetupMode 0
  write_state_variable AuditMode 0
  write_state_variable DeployedMode 0
  write_state_variable SecureBoot 0
  WINDOWS_RC=0
  ALLOW_SETUP=true
  ALLOW_ENROLL=false
  SBCTL_FAIL_PHASE=""
  SBCTL_MISMATCH_PHASE=""
  SBCTL_BAD_KEY=false
  ENROLLMENT_MUTATION_POINT=""
  ENROLLMENT_MUTATION_USED=false
  _transaction_active=false
  _transaction_id=""
  _transaction_token=""
  _transaction_operation=""
  _transaction_target_state=""
}

prepare_and_activate() {
  local state_file backup_id
  prepare_state_aware_setup true || fail_test "dormant setup preparation failed"
  state_file=$(lifecycle_file_path)
  backup_id=$(jq -r '.last_transaction.id' "$state_file")
  validate_firmware_backup "$backup_id" || fail_test "firmware backup validation failed"
  validate_enrollment_plan "$backup_id" false || fail_test "unconfirmed plan validation failed"
  activate_confirmed_enrollment_plan "$backup_id" true true true \
    || fail_test "plan confirmation and artifact proof failed"
  validate_enrollment_plan "$backup_id" true || fail_test "confirmed plan validation failed"
  printf '%s\n' "$backup_id"
}

enter_setup_mode() {
  rm -f "$(firmware_variable_path PK)"
  write_state_variable SetupMode 1
}

test_esl_parser() {
  local output truncated unknown trailing_certificate trailing_esl
  setup_fixture parser
  output="${CASE_DIR}/canonical"
  canonicalize_esl "$PLAN_SOURCE/db.esl" "$output" \
    || fail_test "valid X.509 ESL was rejected"
  [[ $(wc -l < "$output") -eq 2 ]] || fail_test "ESL entries were not canonicalized"
  truncated="${CASE_DIR}/truncated.esl"
  dd if="$PLAN_SOURCE/db.esl" of="$truncated" bs=1 \
    count=$(($(stat -Lc '%s' "$PLAN_SOURCE/db.esl") - 1)) status=none
  chmod 600 "$truncated"
  if canonicalize_esl "$truncated" "${CASE_DIR}/truncated.entries"; then
    fail_test "truncated ESL was accepted"
  fi
  unknown="${CASE_DIR}/unknown.esl"
  : > "$unknown"
  append_hex "$unknown" 00000000000000000000000000000000
  append_le32 "$unknown" 76
  append_le32 "$unknown" 0
  append_le32 "$unknown" 48
  append_hex "$unknown" 11111111111111111111111111111111
  append_hex "$unknown" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  chmod 600 "$unknown"
  if canonicalize_esl "$unknown" "${CASE_DIR}/unknown.entries"; then
    fail_test "unsupported ESL type was accepted"
  fi
  canonicalize_esl "$PLAN_SOURCE/dbx.esl" "${CASE_DIR}/dbx.entries" \
    || fail_test "valid SHA-256 ESL was rejected"
  trailing_certificate="${CASE_DIR}/trailing.der"
  cp "$CERT_DER" "$trailing_certificate"
  append_byte "$trailing_certificate" 0
  trailing_esl="${CASE_DIR}/trailing.esl"
  : > "$trailing_esl"
  append_x509_list "$trailing_esl" 88888888888888888888888888888888 \
    "$trailing_certificate"
  chmod 600 "$trailing_certificate" "$trailing_esl"
  if canonicalize_esl "$trailing_esl" "${CASE_DIR}/trailing.entries"; then
    fail_test "X.509 ESL with trailing DER data was accepted"
  fi
}

test_setup_classifier() {
  [[ $(classify_setup_state none absent 0 0) == 1 ]] || fail_test "state 1 mismatch"
  [[ $(classify_setup_state none absent 0 1) == 1 ]] \
    || fail_test "Secure Boot-on state 1 mismatch"
  [[ $(classify_setup_state complete partial 1 0) == 2 ]] || fail_test "state 2 mismatch"
  [[ $(classify_setup_state complete absent 0 0) == 3 ]] || fail_test "state 3 mismatch"
  [[ $(classify_setup_state complete partial 0 1) == 3 ]] \
    || fail_test "Secure Boot-on state 3 mismatch"
  [[ $(classify_setup_state complete exact 0 0) == 4 ]] || fail_test "state 4 mismatch"
  [[ $(classify_setup_state complete exact 0 1) == 5 ]] || fail_test "state 5 mismatch"
  if classify_setup_state partial partial 0 0 >/dev/null; then
    fail_test "partial local keys were classified"
  fi
  if classify_setup_state complete partial 1 1 >/dev/null; then
    fail_test "Setup Mode plus Secure Boot was classified"
  fi
  if classify_setup_state none exact 0 0 >/dev/null; then
    fail_test "trust without local keys was classified"
  fi
}

test_pk_mode_contradictions() {
  setup_fixture pk-mode-contradictions
  rm -f "$(firmware_variable_path PK)"
  if observe_setup_state >/dev/null; then
    fail_test "User Mode without PK was classified"
  fi
  write_raw_database PK "$PLAN_SOURCE/current-PK.esl"
  write_state_variable SetupMode 1
  if observe_setup_state >/dev/null; then
    fail_test "Setup Mode with PK present was classified"
  fi
}

test_config_boundary_parser() {
  local config
  setup_fixture config-parser
  config="${CASE_DIR}/config.yml"
  printf '%s\n' \
    'landlock: true' \
    'keydir: /var/lib/sbctl/keys' \
    'guid: /var/lib/sbctl/GUID' \
    'files_db: /var/lib/sbctl/files.json' \
    'bundles_db: /var/lib/sbctl/bundles.json' \
    'db_additions: []' \
    'files: []' > "$config"
  chmod 600 "$config"
  sbctl_config_enrollment_values "$config" \
    || fail_test "audited plain sbctl config was rejected"
  [[ "$_sbctl_keydir" == /var/lib/sbctl/keys \
    && "$_sbctl_guid_path" == /var/lib/sbctl/GUID ]] \
    || fail_test "sbctl config paths were parsed incorrectly"
  printf '%s\n' 'db_additions:' '  - custom' > "$config"
  chmod 600 "$config"
  if sbctl_config_enrollment_values "$config"; then
    fail_test "nonempty db additions were accepted"
  fi
  printf '%s\n' 'keys:' '  pk:' '    type: tpm' > "$config"
  chmod 600 "$config"
  if sbctl_config_enrollment_values "$config"; then
    fail_test "custom key backend was accepted"
  fi
}

test_preparation_consent() {
  setup_fixture preparation-consent
  if prepare_state_aware_setup false; then
    fail_test "declined preparation consent succeeded"
  fi
  [[ ! -e "$(lifecycle_file_path)" ]] \
    || fail_test "declined preparation published lifecycle state"
  [[ ! -e "$SBCTL_ROOT/keys" && ! -e "$(firmware_backup_root_path)" ]] \
    || fail_test "declined preparation retained state"
}

test_incoherent_snapshot_blocks() {
  local manifest
  setup_fixture incoherent-snapshot
  ENROLLMENT_MUTATION_POINT=after-firmware-snapshot
  if prepare_state_aware_setup true; then
    fail_test "changing firmware snapshot was accepted"
  fi
  read_lifecycle || fail_test "snapshot failure lifecycle is unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "snapshot race did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.firmware_backup.status == "pending" and
    .firmware_backup.manifest_sha256 == null' "$manifest" >/dev/null \
    || fail_test "pending firmware attachment was not retained"
  [[ ! -e "$(firmware_backup_path "$_lifecycle_transaction_id")" ]] \
    || fail_test "incoherent firmware backup was published"
}

test_bad_key_rolls_back() {
  local manifest
  setup_fixture bad-key
  SBCTL_BAD_KEY=true
  if prepare_state_aware_setup true; then
    fail_test "mismatched local key hierarchy was accepted"
  fi
  read_lifecycle || fail_test "bad-key lifecycle is unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "bad-key failure did not require recovery"
  classify_local_sbctl_keys || fail_test "rolled-back key state is unreadable"
  [[ "$_local_key_state" == none ]] || fail_test "failed key creation retained key files"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.rollback.status == "completed" and
    ([.backups[] | select(.kind == "absent-file")] | length) == 7' \
    "$manifest" >/dev/null || fail_test "key rollback coverage is incomplete"
}

test_confirmation_requires_acknowledgments() {
  local state_file backup_id generation
  setup_fixture confirmation-acknowledgments
  prepare_state_aware_setup true || fail_test "confirmation fixture preparation failed"
  state_file=$(lifecycle_file_path)
  backup_id=$(jq -r '.last_transaction.id' "$state_file")
  read_lifecycle || fail_test "confirmation fixture lifecycle unreadable"
  generation=$_lifecycle_generation
  if activate_confirmed_enrollment_plan "$backup_id" true false true; then
    fail_test "missing PK-only capability acknowledgment was accepted"
  fi
  read_lifecycle || fail_test "declined confirmation damaged lifecycle"
  [[ "$_lifecycle_state" == disabled && $_lifecycle_generation -eq generation ]] \
    || fail_test "declined confirmation published a transaction"
  jq -e '.confirmation == null' "$(firmware_plan_path "$backup_id")/manifest.json" \
    >/dev/null || fail_test "declined confirmation changed the plan"
  [[ ! -s "$ARTIFACT_LOG" ]] || fail_test "declined confirmation repaired artifacts"
}

test_activation_artifact_guard() {
  local state_file backup_id manifest
  setup_fixture activation-artifact-guard
  prepare_state_aware_setup true || fail_test "activation-guard preparation failed"
  state_file=$(lifecycle_file_path)
  backup_id=$(jq -r '.last_transaction.id' "$state_file")
  ENROLLMENT_MUTATION_POINT=before-activation-artifact-repair
  if activate_confirmed_enrollment_plan "$backup_id" true true true; then
    fail_test "false activation guard allowed artifact repair"
  fi
  if grep -Fq artifact-repair "$ARTIFACT_LOG"; then
    fail_test "false activation guard reached artifact mutation"
  fi
  read_lifecycle || fail_test "activation-guard lifecycle unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "post-publication activation guard did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.enrollment_plan != null and .rollback.status == "completed"' \
    "$manifest" >/dev/null || fail_test "activation guard outcome was not durable"
  jq -e '.confirmation == null' "$(firmware_plan_path "$backup_id")/manifest.json" \
    >/dev/null || fail_test "activation guard did not roll back confirmation"
}

test_preparation_and_backup() {
  local backup_id original_uuid
  setup_fixture preparation
  backup_id=$(prepare_and_activate)
  read_lifecycle || fail_test "prepared lifecycle is unreadable"
  [[ "$_lifecycle_state" == active ]] || fail_test "activation did not commit active"
  jq -e '
    .variables.PK.present == true and
    .variables.KEK.present == true and
    .variables.db.present == true and
    .variables.dbx.present == true and
    .variables.SetupMode.value == 0 and
    .variables.AuditMode.value == 0 and
    .variables.DeployedMode.value == 0 and
    .variables.SecureBoot.value == 0
  ' "$(firmware_backup_path "$backup_id")/manifest.json" >/dev/null \
    || fail_test "firmware backup manifest is incomplete"
  jq -e --arg id "$backup_id" '
    .status == "completed" and
    .firmware_backup.id == $id and
    .firmware_backup.status == "complete" and
    (.firmware_backup.manifest_sha256 | test("^[0-9a-f]{64}$")) and
    ([.backups[] | select(.kind == "absent-file")] | length) == 7
  ' "$(lifecycle_manifest_path "$backup_id")" >/dev/null \
    || fail_test "firmware backup and key rollback metadata are incomplete"
  jq -e '
    .confirmation.accepted == true and
    .confirmation.pk_replacement_confirmed == true and
    .confirmation.pk_only_capability_confirmed == true and
    .confirmation.retained_artifacts_acknowledged == true and
    (.confirmation.current_pk_sha256 | test("^[0-9a-f]{64}$")) and
    (.confirmation.planned_pk_sha256 | test("^[0-9a-f]{64}$"))
  ' "$(firmware_plan_path "$backup_id")/manifest.json" >/dev/null \
    || fail_test "explicit plan confirmation is incomplete"
  grep -Fxq 'create-keys' "$SBCTL_LOG" || fail_test "local keys were not created"
  [[ $(grep -Fxc 'enroll-keys -m -f --export esl' "$SBCTL_LOG") -ge 3 ]] \
    || fail_test "plan was not regenerated across preparation and activation"
  grep -Fxq artifact-repair "$ARTIFACT_LOG" || fail_test "artifacts were not repaired"
  original_uuid=$(<"$DMI_DIR/product_uuid")
  printf 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\n' > "$DMI_DIR/product_uuid"
  if validate_firmware_backup "$backup_id"; then
    fail_test "foreign-machine firmware backup was accepted"
  fi
  printf '%s\n' "$original_uuid" > "$DMI_DIR/product_uuid"
  validate_firmware_backup "$backup_id" || fail_test "same-machine backup did not recover"
}

test_absent_dbx_record() {
  local state_file backup_id
  setup_fixture absent-dbx
  rm -f "$(firmware_variable_path dbx)"
  prepare_state_aware_setup true || fail_test "absent dbx preparation failed"
  state_file=$(lifecycle_file_path)
  backup_id=$(jq -r '.last_transaction.id' "$state_file")
  jq -e '.variables.dbx == {
    present: false,
    raw_file: null,
    attributes: null,
    raw_sha256: null,
    payload_sha256: null,
    payload_size: null,
    value: null
  }' "$(firmware_backup_path "$backup_id")/manifest.json" >/dev/null \
    || fail_test "dbx absence was not explicit"
}

test_missing_current_entry_blocks() {
  setup_fixture missing-entry
  cp "$PLAN_SOURCE/mismatch.esl" "$PLAN_SOURCE/db.esl"
  if prepare_state_aware_setup true >/dev/null 2>&1; then
    fail_test "plan losing a current db entry succeeded"
  fi
  read_lifecycle || fail_test "failed preservation lifecycle is unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "failed post-key plan did not require recovery"
  classify_local_sbctl_keys || fail_test "failed preservation key state is unreadable"
  [[ "$_local_key_state" == none ]] \
    || fail_test "failed trust plan retained generated key files"
}

test_enrollment_guard_and_success() {
  local backup_id manifest
  setup_fixture enrollment-success
  [[ "$(observe_setup_state)" == 1 ]] || fail_test "observed state 1 mismatch"
  backup_id=$(prepare_and_activate)
  [[ "$(observe_setup_state "$backup_id")" == 3 ]] \
    || fail_test "observed state 3 mismatch"
  enter_setup_mode
  [[ "$(observe_setup_state "$backup_id")" == 2 ]] \
    || fail_test "observed state 2 mismatch"
  : > "$SBCTL_LOG"
  if run_dormant_enrollment "$backup_id"; then
    fail_test "false production guard allowed enrollment"
  fi
  [[ ! -s "$SBCTL_LOG" ]] || fail_test "false guard reached sbctl"
  ALLOW_ENROLL=true
  run_dormant_enrollment "$backup_id" || fail_test "dormant enrollment failed"
  mapfile -t partial_calls < <(grep -- '--partial' "$SBCTL_LOG")
  [[ "${partial_calls[*]}" == \
    'enroll-keys -m -f --partial db enroll-keys -m -f --partial KEK enroll-keys -m -f --partial PK' ]] \
    || fail_test "firmware enrollment order changed"
  read_current_firmware_modes || fail_test "post-enrollment modes are invalid"
  [[ "$_setup_mode" == 0 && "$_secure_boot_mode" == 0 ]] \
    || fail_test "PK enrollment did not return to User Mode"
  compare_current_database_to_plan "$backup_id" PK \
    || fail_test "enrolled PK differs from plan"
  current_firmware_variable_matches_backup "$backup_id" dbx \
    || fail_test "dbx changed during enrollment"
  read_lifecycle || fail_test "enrollment lifecycle is unreadable"
  [[ "$_lifecycle_state" == active ]] || fail_test "enrollment did not commit active"
  [[ "$(observe_setup_state "$backup_id")" == 4 ]] \
    || fail_test "observed state 4 mismatch"
  manifest=$(lifecycle_manifest_path "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
  jq -e --arg backup_id "$backup_id" '
    .file_rollback_policy == "preserve" and
    .firmware_backup.id == $backup_id and
    .firmware_backup.status == "complete" and
    .enrollment_plan.backup_id == $backup_id and
    (.enrollment_plan.manifest_sha256 | test("^[0-9a-f]{64}$")) and
    [.firmware_writes[].hierarchy] == ["db","KEK","PK"] and
    all(.firmware_writes[];
      .command_exit_code == 0 and .readback_status == "verified") and
    (.completed_phases | index("enroll-db") != null) and
    (.completed_phases | index("enroll-kek") != null) and
    (.completed_phases | index("enroll-pk") != null) and
    (.completed_phases | index("prove-enrolled-trust") != null)
  ' "$manifest" >/dev/null || fail_test "enrollment phases are incomplete"
  grep -Fxq artifact-proof "$ARTIFACT_LOG" || fail_test "post-enrollment artifact proof missing"
  write_state_variable SecureBoot 1
  [[ "$(observe_setup_state "$backup_id")" == 5 ]] \
    || fail_test "observed state 5 mismatch"
}

test_dbx_drift_blocks_cleanly() {
  local backup_id generation
  setup_fixture dbx-drift
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  write_raw_database dbx "$PLAN_SOURCE/mismatch.esl"
  ALLOW_ENROLL=true
  read_lifecycle || fail_test "drift fixture lifecycle unreadable"
  generation=$_lifecycle_generation
  : > "$SBCTL_LOG"
  if run_dormant_enrollment "$backup_id"; then
    fail_test "changed dbx passed enrollment preflight"
  fi
  read_lifecycle || fail_test "dbx refusal damaged lifecycle"
  [[ "$_lifecycle_state" == active && $_lifecycle_generation -eq generation ]] \
    || fail_test "preflight dbx refusal published a transaction"
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "dbx refusal reached a firmware write"
  fi
}

test_partial_readback_failure() {
  local backup_id manifest
  setup_fixture partial-readback
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ALLOW_ENROLL=true
  SBCTL_MISMATCH_PHASE=db
  : > "$SBCTL_LOG"
  if run_dormant_enrollment "$backup_id"; then
    fail_test "incorrect db readback reported success"
  fi
  read_lifecycle || fail_test "partial readback lifecycle unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "partial firmware write did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.failure.phase == "enroll-db" and
    .file_rollback_policy == "preserve" and
    .rollback.status == "preserved" and
    (.firmware_writes | length) == 1 and
    .firmware_writes[0].hierarchy == "db" and
    .firmware_writes[0].command_exit_code == 0 and
    .firmware_writes[0].readback_status == "failed"' "$manifest" >/dev/null \
    || fail_test "partial firmware failure phase was not recorded"
  if grep -Fq -- '--partial KEK' "$SBCTL_LOG" \
    || grep -Fq -- '--partial PK' "$SBCTL_LOG"; then
    fail_test "enrollment continued after db mismatch"
  fi
  current_pk_is_absent || fail_test "partial failure enrolled PK"
}

test_db_command_failure_after_effect() {
  local backup_id manifest
  setup_fixture db-command-failure
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ALLOW_ENROLL=true
  SBCTL_FAIL_PHASE=after-db
  : > "$SBCTL_LOG"
  if run_dormant_enrollment "$backup_id"; then
    fail_test "post-db command failure reported success"
  fi
  read_lifecycle || fail_test "post-db command failure lifecycle unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "post-db command failure did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.failure.phase == "enroll-db" and
    .rollback.status == "preserved" and
    (.firmware_writes | length) == 1 and
    .firmware_writes[0].command_exit_code == 32 and
    .firmware_writes[0].readback_status == "verified"' "$manifest" >/dev/null \
    || fail_test "post-db side effect was not recorded"
  compare_current_database_to_plan "$backup_id" db \
    || fail_test "post-db side effect was not observed"
  current_pk_is_absent || fail_test "post-db failure enrolled PK"
  if grep -Fq -- '--partial KEK' "$SBCTL_LOG" \
    || grep -Fq -- '--partial PK' "$SBCTL_LOG"; then
    fail_test "enrollment continued after post-db command failure"
  fi
}

test_pk_command_failure_after_effect() {
  local backup_id manifest
  setup_fixture pk-command-failure
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ALLOW_ENROLL=true
  SBCTL_FAIL_PHASE=after-PK
  : > "$SBCTL_LOG"
  : > "$ARTIFACT_LOG"
  if run_dormant_enrollment "$backup_id"; then
    fail_test "post-PK command failure reported success"
  fi
  read_lifecycle || fail_test "post-PK command failure lifecycle unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "post-PK command failure did not require recovery"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.failure.phase == "enroll-pk" and
    .rollback.status == "preserved" and
    [.firmware_writes[].hierarchy] == ["db","KEK","PK"] and
    .firmware_writes[2].command_exit_code == 36 and
    .firmware_writes[2].readback_status == "verified"' "$manifest" >/dev/null \
    || fail_test "post-PK side effect was not recorded"
  compare_current_database_to_plan "$backup_id" PK \
    || fail_test "post-PK side effect was not observed"
  if grep -Fq artifact-proof "$ARTIFACT_LOG"; then
    fail_test "post-PK command failure reached final artifact proof"
  fi
}

test_artifact_repair_drift_blocks_write() {
  local backup_id manifest
  setup_fixture artifact-drift
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ALLOW_ENROLL=true
  ENROLLMENT_MUTATION_POINT=after-enrollment-artifact-repair
  : > "$SBCTL_LOG"
  if run_dormant_enrollment "$backup_id"; then
    fail_test "post-repair firmware drift allowed enrollment"
  fi
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "post-repair firmware drift reached a firmware write"
  fi
  read_lifecycle || fail_test "post-repair drift lifecycle unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.failure.phase == "enroll-db" and
    .file_rollback_policy == "restore" and
    .rollback.status == "completed" and
    .firmware_writes == []' "$manifest" >/dev/null \
    || fail_test "pre-write drift rollback policy is incorrect"
}

test_guard_flip_blocks_write() {
  local backup_id manifest
  setup_fixture guard-flip
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ALLOW_ENROLL=true
  ENROLLMENT_MUTATION_POINT=before-db-write
  : > "$SBCTL_LOG"
  if run_dormant_enrollment "$backup_id"; then
    fail_test "false phase guard allowed a firmware write"
  fi
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "false phase guard reached sbctl partial enrollment"
  fi
  read_lifecycle || fail_test "phase-guard lifecycle unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '.rollback.status == "preserved" and
    (.firmware_writes | length) == 1 and
    .firmware_writes[0].hierarchy == "db" and
    .firmware_writes[0].command_exit_code == null and
    .firmware_writes[0].readback_status == "pending"' "$manifest" >/dev/null \
    || fail_test "blocked write attempt was not durable"
}

test_plan_manifest_tamper_blocks() {
  local state_file backup_id manifest temporary generation
  setup_fixture plan-tamper
  prepare_state_aware_setup true || fail_test "plan-tamper preparation failed"
  state_file=$(lifecycle_file_path)
  backup_id=$(jq -r '.last_transaction.id' "$state_file")
  manifest="$(firmware_plan_path "$backup_id")/manifest.json"
  temporary="${CASE_DIR}/tampered-plan.json"
  jq '.sbctl.key_sha256 = {}' "$manifest" > "$temporary"
  atomic_write_control_file "$manifest" 600 < "$temporary"
  read_lifecycle || fail_test "plan-tamper lifecycle unreadable"
  generation=$_lifecycle_generation
  if activate_confirmed_enrollment_plan "$backup_id" true true true; then
    fail_test "empty key binding was accepted"
  fi
  read_lifecycle || fail_test "plan-tamper refusal damaged lifecycle"
  [[ "$_lifecycle_state" == disabled && $_lifecycle_generation -eq generation ]] \
    || fail_test "plan-tamper refusal published a transaction"
  [[ ! -s "$ARTIFACT_LOG" ]] || fail_test "plan-tamper refusal repaired artifacts"
}

test_windows_gate_blocks_preparation() {
  setup_fixture windows-gate
  WINDOWS_RC=2
  if prepare_state_aware_setup true; then
    fail_test "technical Windows uncertainty allowed preparation"
  fi
  [[ ! -e "$(lifecycle_file_path)" ]] \
    || fail_test "Windows preflight refusal published lifecycle state"
  [[ ! -e "$SBCTL_ROOT/keys" ]] || fail_test "Windows refusal created local keys"
}

run_case() {
  local name="$1" function="$2"
  (
    trap - EXIT
    "$function"
  ) || fail_test "case failed: ${name}"
}

run_case parser test_esl_parser
run_case classifier test_setup_classifier
run_case pk-mode-contradictions test_pk_mode_contradictions
run_case config-parser test_config_boundary_parser
run_case preparation-consent test_preparation_consent
run_case incoherent-snapshot test_incoherent_snapshot_blocks
run_case bad-key test_bad_key_rolls_back
run_case confirmation-acknowledgments test_confirmation_requires_acknowledgments
run_case activation-artifact-guard test_activation_artifact_guard
run_case preparation test_preparation_and_backup
run_case absent-dbx test_absent_dbx_record
run_case missing-entry test_missing_current_entry_blocks
run_case enrollment-success test_enrollment_guard_and_success
run_case dbx-drift test_dbx_drift_blocks_cleanly
run_case partial-readback test_partial_readback_failure
run_case db-command-failure test_db_command_failure_after_effect
run_case pk-command-failure test_pk_command_failure_after_effect
run_case artifact-drift test_artifact_repair_drift_blocks_write
run_case guard-flip test_guard_flip_blocks_write
run_case plan-tamper test_plan_manifest_tamper_blocks
run_case windows-gate test_windows_gate_blocks_preparation

printf 'enrollment tests passed\n'
