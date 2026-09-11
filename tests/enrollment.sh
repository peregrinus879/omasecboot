#!/bin/bash
# shellcheck disable=SC2034,SC2154,SC2329 # Sourced modules consume dynamic fixtures.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init enrollment

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/records.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/software.sh"
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

  producer_package_version() {
    [[ "$1" == sbctl ]] || return 1
    printf '%s\n' "${boundary_package#sbctl }"
  }

  producer_file_owner_package() {
    [[ "$1" == /usr/bin/sbctl ]] || return 1
    printf '%s\n' "$boundary_owner"
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

  run_sbctl_enrollment enroll-keys -m -f --ignore-immutable --partial db \
    || fail_test "validated sbctl executable was not invoked"
  [[ "$(<"$log")" == "enroll-keys -m -f --ignore-immutable --partial db" ]] \
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
SBCTL_FAIL_PHASE=""
SBCTL_MISMATCH_PHASE=""
SBCTL_PK_SETUP_MODE=0
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

efivars_path() {
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

lifecycle_activation_environment_is_ready() {
  [[ "$ACTIVATION_READY" == true ]]
}

capture_activation_limine_tools() {
  printf '{"mkinitcpio": {}, "snapper-sync": {}}\n'
}

# The instruction boundary reads limine.conf for path hashes; the fixture
# owns that path and the ESP root, never the host's.
limine_config_path() { printf '%s/limine.conf\n' "${CASE_DIR:-$TEST_DIR}"; }
esp_path() { printf '%s/boot\n' "${CASE_DIR:-$TEST_DIR}"; }

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

persist_fixture_final_proof() {
  local transaction_dir proof_path timestamp digest document reference
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  proof_path="${transaction_dir}/final-proof.json"
  timestamp=$(utc_timestamp) || return 1
  digest=$(sha256_text fixture) || return 1
  document=$(jq -cn \
    --argjson schema "$FINAL_PROOF_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg timestamp "$timestamp" \
    --arg checksum "$_repair_config_checksum" \
    --arg config "${CASE_DIR}/limine.conf" \
    --arg artifact "${CASE_DIR}/boot.efi" \
    --arg digest "$digest" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      proved_at: $timestamp,
      config: {path: $config, checksum: $checksum, sha256: $digest, identity: "1:1"},
      artifacts: [{
        identity: "1:1",
        path: $artifact,
        sha256: $digest,
        signature: "local",
        tracking: "tracked"
      }]
    }') || return 1
  validate_final_proof_json "$_transaction_id" "$document" || return 1
  printf '%s\n' "$document" | atomic_create_control_file "$proof_path" 600 || return 1
  reference=$(transaction_artifact_reference "$proof_path" "$FINAL_PROOF_SCHEMA_VERSION") \
    || return 1
  transaction_set_domain_record final_proof "$reference"
}

repair_boot_artifacts() {
  transaction_phase_start "backup-artifacts" || return 1
  printf 'artifact-repair\n' >> "$ARTIFACT_LOG"
  persist_fixture_final_proof || return 1
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

# The files sbctl 0.18 create-keys writes: directories through MkdirAll with
# os.ModePerm (755 under the root umask, existing directories untouched), the
# GUID 0644, every key and certificate 0400 (util.go, guid.go,
# backend/backend.go at tag 0.18).
create_key_fixture() {
  local path
  for path in "$SBCTL_ROOT" "$SBCTL_ROOT/keys" "$SBCTL_ROOT/keys/PK" \
    "$SBCTL_ROOT/keys/KEK" "$SBCTL_ROOT/keys/db"; do
    [[ -d "$path" ]] || { mkdir "$path" && chmod 755 "$path"; }
  done
  printf '12345678-1234-4234-8234-123456789abc\n' > "$SBCTL_ROOT/GUID"
  chmod 644 "$SBCTL_ROOT/GUID"
  for path in PK KEK db; do
    cp "$CERT_KEY" "$SBCTL_ROOT/keys/$path/$path.key"
    cp "$CERT_PEM" "$SBCTL_ROOT/keys/$path/$path.pem"
    chmod 400 "$SBCTL_ROOT/keys/$path/$path.key" \
      "$SBCTL_ROOT/keys/$path/$path.pem"
  done
  if [[ "$SBCTL_BAD_KEY" == true ]]; then
    chmod 600 "$SBCTL_ROOT/keys/KEK/KEK.key"
    printf 'not-a-private-key\n' > "$SBCTL_ROOT/keys/KEK/KEK.key"
    chmod 400 "$SBCTL_ROOT/keys/KEK/KEK.key"
  fi
}

sbctl() {
  local path
  printf '%s\n' "$*" >> "$SBCTL_LOG"
  case "$*" in
    create-keys)
      # cmd/sbctl/create-keys.go at tag 0.18: CreateDirectory for the key
      # directory and the GUID's directory (MkdirAll, 755 under the root
      # umask), CreateGUID (0644, only when absent), then keys only while
      # CheckIfKeysInitialized finds one of keys/PK, keys/KEK, and keys/db
      # missing; with all three present it writes nothing and exits 0.
      for path in "$SBCTL_ROOT" "$SBCTL_ROOT/keys"; do
        [[ -d "$path" ]] || { mkdir "$path" && chmod 755 "$path"; }
      done
      if [[ ! -e "$SBCTL_ROOT/GUID" ]]; then
        printf '12345678-1234-4234-8234-123456789abc\n' > "$SBCTL_ROOT/GUID"
        chmod 644 "$SBCTL_ROOT/GUID"
      fi
      printf 'Created Owner UUID 12345678-1234-4234-8234-123456789abc\n'
      if [[ -e "$SBCTL_ROOT/keys/PK" && -e "$SBCTL_ROOT/keys/KEK" \
        && -e "$SBCTL_ROOT/keys/db" ]]; then
        printf 'Secure boot keys have already been created!\n'
        return 0
      fi
      create_key_fixture
      printf 'Secure boot keys created!\n'
      ;;
    'enroll-keys -m -f --export esl')
      cp "$PLAN_SOURCE/PK.esl" "$PLAN_SOURCE/KEK.esl" "$PLAN_SOURCE/db.esl" .
      chmod 600 PK.esl KEK.esl db.esl
      ;;
    'enroll-keys -m -f --partial '*)
      # cmd/sbctl/enroll-keys.go at tag 0.18 without --ignore-immutable:
      # CheckImmutable refuses before any write while PK, KEK, or db exists,
      # because efivarfs marks them immutable (fs/efivarfs/vars.c removable
      # list; probed on 2026-09-10, ledger).
      for path in PK KEK db; do
        [[ ! -e "$(firmware_variable_path "$path")" ]] \
          || printf 'File is immutable: %s\n' "$(firmware_variable_path "$path")"
      done
      printf 'You need to chattr -i files in efivarfs\n'
      return 1
      ;;
    'enroll-keys -m -f --ignore-immutable --partial db')
      [[ "$SBCTL_FAIL_PHASE" != before-db ]] || return 31
      if [[ "$SBCTL_MISMATCH_PHASE" == db ]]; then
        write_raw_database db "$PLAN_SOURCE/mismatch.esl"
      else
        write_raw_database db "$PLAN_SOURCE/db.esl"
      fi
      [[ "$SBCTL_FAIL_PHASE" != after-db ]] || return 32
      ;;
    'enroll-keys -m -f --ignore-immutable --partial KEK')
      [[ "$SBCTL_FAIL_PHASE" != before-KEK ]] || return 33
      write_raw_database KEK "$PLAN_SOURCE/KEK.esl"
      [[ "$SBCTL_FAIL_PHASE" != after-KEK ]] || return 34
      ;;
    'enroll-keys -m -f --ignore-immutable --partial PK')
      [[ "$SBCTL_FAIL_PHASE" != before-PK ]] || return 35
      write_raw_database PK "$PLAN_SOURCE/PK.esl"
      write_state_variable SetupMode "$SBCTL_PK_SETUP_MODE"
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
    "${CASE_DIR}/bin"
  # sbctl's state directory as list-files or verify leave it on a keyless
  # machine: mode 755 with zero-length databases (util.go ReadOrCreateFile at
  # tag 0.18); the acceptance recorder runs both before setup.
  chmod 755 "$SBCTL_ROOT"
  : > "$SBCTL_ROOT/files.json"
  : > "$SBCTL_ROOT/bundles.json"
  chmod 644 "$SBCTL_ROOT/files.json" "$SBCTL_ROOT/bundles.json"
  : > "$SBCTL_LOG"
  : > "$ARTIFACT_LOG"
  printf '%s\n' '/Omarchy' 'protocol: efi' \
    'path: boot():/EFI/Linux/omarchy_linux.efi' > "$(limine_config_path)"
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
  ACTIVATION_READY=true
  SBCTL_FAIL_PHASE=""
  SBCTL_MISMATCH_PHASE=""
  SBCTL_PK_SETUP_MODE=0
  SBCTL_BAD_KEY=false
  ENROLLMENT_MUTATION_POINT=""
  ENROLLMENT_MUTATION_USED=false
  _transaction_active=false
  _transaction_id=""
  _transaction_token=""
  _transaction_operation=""
  _transaction_target_state=""
}

# Callers capture the printed backup id, so the preparation's own output,
# which carries sbctl's create-keys lines, goes to stderr.
prepare_and_activate() {
  local state_file backup_id
  prepare_state_aware_setup true >&2 || fail_test "setup preparation failed"
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

recover_firmware_incident() {
  local rc=0
  with_boot_repair_lock || return 1
  run_firmware_recovery_locked || rc=$?
  release_boot_repair_lock
  return "$rc"
}

fail_before_enrollment_binding() {
  return 44
}

record_intervening_cleanup() {
  transaction_phase_start clean-tracking || return 1
  transaction_phase_complete clean-tracking
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
  parse_sbctl_config "$config" true \
    || fail_test "audited plain sbctl config was rejected"
  [[ "$_sbctl_keydir" == /var/lib/sbctl/keys \
    && "$_sbctl_guid_path" == /var/lib/sbctl/GUID ]] \
    || fail_test "sbctl config paths were parsed incorrectly"
  printf '%s\n' 'db_additions:' '  - custom' > "$config"
  chmod 600 "$config"
  if parse_sbctl_config "$config" true; then
    fail_test "nonempty db additions were accepted"
  fi
  printf '%s\n' 'keys:' '  pk:' '    type: tpm' > "$config"
  chmod 600 "$config"
  if parse_sbctl_config "$config" true; then
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
  jq -e --arg keys "$SBCTL_ROOT/keys" --arg guid "$SBCTL_ROOT/GUID" '
    .rollback.status == "completed" and
    ([.backups[] | select(.kind == "absent-directory")] | map(.target)) == [$keys] and
    ([.backups[] | select(.kind == "absent-file")] | map(.target)) == [$guid]' \
    "$manifest" >/dev/null || fail_test "key rollback coverage is incomplete"
  # Rollback removed the directories sbctl created, not only the files, so
  # sbctl does not report the keys as already created on the next attempt
  # (the third Vivobook run of 2026-09-09); its own database files remain.
  [[ ! -e "$SBCTL_ROOT/keys" && ! -e "$SBCTL_ROOT/GUID" ]] \
    || fail_test "key rollback left sbctl's directories or GUID behind"
  [[ -e "$SBCTL_ROOT/files.json" && $(stat -c %a "$SBCTL_ROOT") == 755 ]] \
    || fail_test "key rollback removed state that predates the transaction"
  SBCTL_BAD_KEY=false
  sbctl create-keys > "${CASE_DIR}/second-create.out" || fail_test "second create-keys failed"
  grep -Fq 'Secure boot keys created!' "${CASE_DIR}/second-create.out" \
    || fail_test "sbctl still treated the rolled-back layout as created keys"
  classify_local_sbctl_keys || fail_test "keys after the second create-keys are unreadable"
  [[ "$_local_key_state" == complete ]] || fail_test "second create-keys did not create keys"
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

test_activation_environment_guard() {
  local state_file backup_id generation
  setup_fixture activation-environment-guard
  prepare_state_aware_setup true || fail_test "activation-environment preparation failed"
  state_file=$(lifecycle_file_path)
  backup_id=$(jq -r '.last_transaction.id' "$state_file")
  read_lifecycle || fail_test "activation-environment lifecycle unreadable"
  generation=$_lifecycle_generation
  ACTIVATION_READY=false
  if activate_confirmed_enrollment_plan "$backup_id" true true true; then
    fail_test "incomplete activation environment was accepted"
  fi
  read_lifecycle || fail_test "activation-environment refusal damaged lifecycle"
  [[ "$_lifecycle_state" == disabled && $_lifecycle_generation -eq generation ]] \
    || fail_test "activation-environment refusal published a transaction"
  jq -e '.confirmation == null' "$(firmware_plan_path "$backup_id")/manifest.json" \
    >/dev/null || fail_test "activation-environment refusal changed the plan"
  [[ ! -s "$ARTIFACT_LOG" ]] \
    || fail_test "activation-environment refusal repaired artifacts"
}

test_preparation_and_backup() {
  local backup_id original_uuid name
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
    ([.backups[] | select(.kind == "absent-directory")] | length) == 1 and
    ([.backups[] | select(.kind == "absent-file")] | length) == 1
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
  for name in PK KEK db; do
    [[ ! -e "$(firmware_plan_path "$backup_id")/current-${name}.entries" \
      && ! -L "$(firmware_plan_path "$backup_id")/current-${name}.entries" ]] \
      || fail_test "plan retained unsealed current-${name} evidence"
  done
  validate_enrollment_plan "$backup_id" true \
    || fail_test "plan did not re-derive its backup-preservation proof"
  [[ "$_validated_current_pk_hash" == \
    "$(jq -r '.confirmation.current_pk_sha256' \
      "$(firmware_plan_path "$backup_id")/manifest.json")" ]] \
    || fail_test "re-derived current PK did not match the confirmation"
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

test_firmware_frontier_classifier() {
  local backup_id output
  setup_fixture firmware-frontiers
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == F0 ]] \
    || fail_test "initial enrollment state was not F0"
  if sbctl 'enroll-keys -m -f --partial db' > "${CASE_DIR}/immutable.out"; then
    fail_test "a partial write without --ignore-immutable was accepted"
  fi
  grep -Fq "File is immutable: $(firmware_variable_path db)" "${CASE_DIR}/immutable.out" \
    || fail_test "the immutable refusal did not name the variable"
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == F0 ]] \
    || fail_test "the immutable refusal changed the firmware"
  sbctl 'enroll-keys -m -f --ignore-immutable --partial db' \
    || fail_test "frontier fixture db write failed"
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == F1 ]] \
    || fail_test "db enrollment state was not F1"
  sbctl 'enroll-keys -m -f --ignore-immutable --partial KEK' \
    || fail_test "frontier fixture KEK write failed"
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == F2 ]] \
    || fail_test "KEK enrollment state was not F2"
  sbctl 'enroll-keys -m -f --ignore-immutable --partial PK' \
    || fail_test "frontier fixture PK write failed"
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == F3 ]] \
    || fail_test "PK enrollment state was not F3"

  write_state_variable AuditMode 1
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == invalid ]] \
    || fail_test "mode drift was not classified invalid"
  write_state_variable AuditMode 0
  rm -f "$(firmware_variable_path DeployedMode)"
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == invalid ]] \
    || fail_test "a mode variable disappearing after the backup was not classified invalid"
  write_state_variable DeployedMode 0
  rm -f "$(firmware_variable_path SetupMode)"
  output=""
  if output=$(classify_firmware_enrollment_frontier "$backup_id"); then
    fail_test "unreadable firmware state was classified"
  fi
  [[ -z "$output" ]] || fail_test "unreadable firmware state returned a frontier"
}

# Firmware that predates UEFI 2.5 has neither AuditMode nor DeployedMode; the
# whole path accepts that, records it, and treats a later appearance as drift.
test_absent_mode_variables() {
  local backup_id transaction_id manifest firmware_proof proof_document
  local before_id tampered manifest_path
  setup_fixture absent-modes
  rm -f "$(firmware_variable_path AuditMode)" "$(firmware_variable_path DeployedMode)"
  read_current_firmware_modes \
    || fail_test "firmware without AuditMode and DeployedMode was unreadable"
  [[ "$_audit_mode" == absent && "$_deployed_mode" == absent ]] \
    || fail_test "absent mode variables were not observed as absent"
  [[ "$(observe_setup_state)" == 1 ]] || fail_test "absent-mode state 1 mismatch"
  backup_id=$(prepare_and_activate)
  jq -e '.variables.AuditMode.present == false and
    .variables.DeployedMode.present == false and
    .variables.SetupMode.value == 0' \
    "$(firmware_backup_path "$backup_id")/manifest.json" >/dev/null \
    || fail_test "mode variable absence was not recorded in the backup"
  [[ "$(observe_setup_state "$backup_id")" == 3 ]] \
    || fail_test "absent-mode state 3 mismatch"
  validate_setup_instruction_boundary "$backup_id" 3 \
    || fail_test "absent-mode state 3 boundary was rejected"
  write_state_variable DeployedMode 0
  if validate_setup_instruction_boundary "$backup_id" 3; then
    fail_test "a mode variable appearing after the backup was accepted"
  fi
  if observe_setup_state "$backup_id" >/dev/null; then
    fail_test "a mode variable appearing after the backup was classified"
  fi
  rm -f "$(firmware_variable_path DeployedMode)"
  enter_setup_mode
  [[ "$(observe_setup_state "$backup_id")" == 2 ]] \
    || fail_test "absent-mode state 2 mismatch"
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == F0 ]] \
    || fail_test "absent-mode enrollment did not start from F0"
  write_state_variable AuditMode 0
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == invalid ]] \
    || fail_test "a mode variable appearing in Setup Mode was not classified invalid"
  before_id=$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")
  if run_enrollment "$backup_id" > "${CASE_DIR}/drift-enroll.out" 2>&1; then
    fail_test "enrollment accepted a mode variable that appeared in Setup Mode"
  fi
  grep -Fq 'Operation enroll-secure-boot preflight failed; no transaction was started' \
    "${CASE_DIR}/drift-enroll.out" || fail_test "drift refusal gave no reason"
  [[ $(jq -r '.last_transaction.id' "$(lifecycle_file_path)") == "$before_id" ]] \
    || fail_test "refused enrollment published a transaction"
  rm -f "$(firmware_variable_path AuditMode)"
  run_enrollment "$backup_id" || fail_test "absent-mode enrollment failed"
  read_lifecycle || fail_test "absent-mode enrollment lifecycle is unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "absent-mode enrollment did not commit active"
  [[ "$(observe_setup_state "$backup_id")" == 4 ]] \
    || fail_test "absent-mode state 4 mismatch"
  transaction_id=$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")
  manifest=$(lifecycle_manifest_path "$transaction_id")
  firmware_proof=$(jq -r '.domain_records.firmware.path' "$manifest")
  proof_document=$(read_control_document "$firmware_proof") \
    || fail_test "absent-mode firmware proof is unreadable"
  jq -e '.modes == {SetupMode: 0, AuditMode: null, DeployedMode: null, SecureBoot: 0}' \
    <<< "$proof_document" >/dev/null \
    || fail_test "absent modes were not recorded as null in the firmware proof"
  read_transaction_manifest "$transaction_id" \
    || fail_test "absent-mode enrollment manifest failed validation"
  validate_firmware_proof_json "$transaction_id" "$proof_document" "$_manifest_json" \
    || fail_test "absent-mode firmware proof did not validate"
  tampered=$(jq -c '.modes.AuditMode = 1' <<< "$proof_document")
  if validate_firmware_proof_json "$transaction_id" "$tampered" "$_manifest_json"; then
    fail_test "firmware proof accepted a non-zero optional mode"
  fi
  # Only the two optional variables may be recorded absent. The raw file is
  # removed too, so only the optional-name guard can reject the record.
  manifest_path="$(firmware_backup_path "$backup_id")/manifest.json"
  validate_firmware_backup "$backup_id" || fail_test "absent-mode backup stopped validating"
  tampered=$(jq -c '.variables.SetupMode = .variables.AuditMode' "$manifest_path")
  printf '%s\n' "$tampered" > "$manifest_path"
  rm -f "$(firmware_backup_path "$backup_id")/SetupMode.efivar"
  if validate_firmware_backup "$backup_id"; then
    fail_test "backup validation accepted an absent SetupMode record"
  fi
}

# When a predicate refuses, the operator sees each trust variable against the
# backup and the plan: a KEK cleared with the PK, and a db serviced after
# enrollment, are named rather than hidden behind a bare status.
test_observation_explanation() {
  local backup_id output
  setup_fixture observation-explanation
  output=$(explain_setup_observation 2>&1)
  grep -Fq 'Observed: SetupMode=0 SecureBoot=0 AuditMode=0 DeployedMode=0' <<< "$output" \
    || fail_test "explanation without a backup omitted the mode variables"
  if grep -Fq 'versus' <<< "$output"; then
    fail_test "explanation without a backup compared against one"
  fi
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  rm -f "$(firmware_variable_path KEK)"
  output=$(explain_setup_observation "$backup_id" 2>&1)
  grep -Fq 'Observed: SetupMode=1 SecureBoot=0 AuditMode=0 DeployedMode=0' <<< "$output" \
    || fail_test "explanation omitted the mode variables"
  grep -Fq 'KEK: absent, versus backup: different, versus plan: different' <<< "$output" \
    || fail_test "explanation did not name the cleared KEK"
  grep -Fq 'db: present, versus backup: exact, versus plan: different' <<< "$output" \
    || fail_test "explanation did not show the untouched db"
  grep -Fq 'Local sbctl keys: complete' <<< "$output" \
    || fail_test "explanation omitted the local key state"
  if run_enrollment "$backup_id" > "${CASE_DIR}/cleared-kek.out" 2>&1; then
    fail_test "enrollment accepted a KEK cleared with the PK"
  fi
  grep -Fq 'Operation enroll-secure-boot preflight failed; no transaction was started' \
    "${CASE_DIR}/cleared-kek.out" || fail_test "cleared KEK refusal gave no reason"
  [[ -z "$(ls -A "$(firmware_runtime_dir_path)" 2>/dev/null)" ]] \
    || fail_test "the explanation left runtime files behind"
  write_raw_database KEK "$PLAN_SOURCE/current-KEK.esl"
  # A transaction that fails after its first firmware write leaves recovery
  # pending; the explanation says so instead of claiming nothing changed.
  SBCTL_FAIL_PHASE=after-db
  if run_enrollment "$backup_id" >/dev/null 2>&1; then
    fail_test "post-db failure fixture reported success"
  fi
  SBCTL_FAIL_PHASE=""
  output=$(explain_setup_observation "$backup_id" 2>&1)
  grep -Fq 'Lifecycle: recovery-required; run sudo omasecboot repair and do not intervene manually' \
    <<< "$output" || fail_test "explanation omitted the pending recovery"
  if grep -Fqi 'nothing was changed' <<< "$output"; then
    fail_test "explanation claimed nothing changed after a firmware write"
  fi
  grep -Fq 'db: present, versus backup: different, versus plan: exact' <<< "$output" \
    || fail_test "explanation did not show the written db"
  recover_firmware_incident || fail_test "recovery after the post-db failure did not complete"
  read_lifecycle || fail_test "recovered lifecycle is unreadable"
  [[ "$_lifecycle_state" == active ]] || fail_test "recovery did not return to active"
  [[ "$(observe_setup_state "$backup_id")" == 4 ]] \
    || fail_test "recovered enrollment was not observed as state 4"
  # A damaged plan reads as unknown, never as a firmware difference.
  mv "$(firmware_plan_path "$backup_id")/db.entries" "${CASE_DIR}/db.entries.aside"
  output=$(explain_setup_observation "$backup_id" 2>&1)
  grep -Fq "Enrollment plan ${backup_id}: failed validation" <<< "$output" \
    || fail_test "explanation did not report the damaged plan"
  grep -Fq 'db: present, versus backup: different, versus plan: unknown' <<< "$output" \
    || fail_test "a damaged plan was reported as a firmware difference"
  mv "${CASE_DIR}/db.entries.aside" "$(firmware_plan_path "$backup_id")/db.entries"
  write_raw_database db "$PLAN_SOURCE/mismatch.esl"
  [[ "$(observe_setup_state "$backup_id")" == 3 ]] \
    || fail_test "a db serviced after enrollment was not observed as state 3"
  if validate_setup_instruction_boundary "$backup_id" 3; then
    fail_test "a db serviced after enrollment passed the state 3 boundary"
  fi
  output=$(explain_setup_observation "$backup_id" 2>&1)
  grep -Fq 'db: present, versus backup: different, versus plan: different' <<< "$output" \
    || fail_test "explanation did not name the serviced db"
  grep -Fq 'PK: present, versus backup: different, versus plan: exact' <<< "$output" \
    || fail_test "explanation did not show the enrolled PK"
  grep -Fq 'Lifecycle: active' <<< "$output" \
    || fail_test "explanation omitted the lifecycle state"
}

# sbctl's own state directory (755 with zero-length databases) is accepted,
# and the keys it writes at 0400 classify as complete.
test_sbctl_state_directory_accepted() {
  setup_fixture sbctl-state-accepted
  [[ $(stat -c %a "$SBCTL_ROOT") == 755 && -e "$SBCTL_ROOT/files.json" \
    && ! -s "$SBCTL_ROOT/files.json" ]] \
    || fail_test "fixture did not reproduce sbctl's state directory"
  prepare_state_aware_setup true \
    || fail_test "preparation refused sbctl's own state directory"
  read_lifecycle || fail_test "prepared lifecycle is unreadable"
  [[ "$_lifecycle_state" == disabled ]] || fail_test "preparation did not publish disabled"
  [[ $(stat -c %a "$SBCTL_ROOT/keys/PK/PK.key") == 400 \
    && $(stat -c %a "$SBCTL_ROOT/GUID") == 644 ]] \
    || fail_test "fixture did not create sbctl's file modes"
  classify_local_sbctl_keys || fail_test "sbctl's file modes were not classifiable"
  [[ "$_local_key_state" == complete ]] || fail_test "sbctl's file modes were not complete"
}

# Without any state directory sbctl creates its own (755) and the tool
# records that one directory, which covers the GUID and the keys below it.
test_sbctl_state_directory_absent() {
  local manifest
  setup_fixture sbctl-state-absent
  rm -rf "$SBCTL_ROOT"
  prepare_state_aware_setup true \
    || fail_test "preparation refused an absent state directory"
  [[ $(stat -c %a "$SBCTL_ROOT") == 755 ]] \
    || fail_test "the state directory does not carry sbctl's mode"
  classify_local_sbctl_keys || fail_test "keys under sbctl's directory were not classifiable"
  [[ "$_local_key_state" == complete ]] || fail_test "keys under sbctl's directory were not complete"
  manifest=$(lifecycle_manifest_path "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
  jq -e --arg root "$SBCTL_ROOT" '
    ([.backups[] | select(.kind == "absent-directory")] | map(.target)) == [$root] and
    ([.backups[] | select(.kind == "absent-file")] | length) == 0' \
    "$manifest" >/dev/null || fail_test "the absent state directory was not the only record"
}

# A failure after key creation removes the whole state directory sbctl made.
test_sbctl_state_directory_absent_rollback() {
  setup_fixture sbctl-state-absent-rollback
  rm -rf "$SBCTL_ROOT"
  SBCTL_BAD_KEY=true
  if prepare_state_aware_setup true; then
    fail_test "mismatched keys under a new state directory were accepted"
  fi
  read_lifecycle || fail_test "rollback lifecycle is unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "the failed creation did not require recovery"
  jq -e '.rollback.status == "completed"' \
    "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
    || fail_test "rollback of the new state directory did not complete"
  [[ ! -e "$SBCTL_ROOT" ]] || fail_test "rollback left sbctl's new state directory behind"
}

# Hierarchy directories without keys, as an interrupted run leaves them, are
# refused before any transaction, by name, because sbctl create-keys would
# report them as created keys and write nothing.
test_sbctl_leftover_key_directories_refused() {
  local generation
  setup_fixture sbctl-leftover-directories
  mkdir -p "$SBCTL_ROOT/keys/PK" "$SBCTL_ROOT/keys/KEK" "$SBCTL_ROOT/keys/db"
  chmod 755 "$SBCTL_ROOT/keys" "$SBCTL_ROOT/keys/PK" "$SBCTL_ROOT/keys/KEK" \
    "$SBCTL_ROOT/keys/db"
  read_lifecycle || fail_test "leftover fixture lifecycle is unreadable"
  generation=$_lifecycle_generation
  classify_local_sbctl_keys || fail_test "leftover directories were not classifiable"
  [[ "$_local_key_state" == none ]] || fail_test "empty directories counted as keys"
  if prepare_state_aware_setup true > "${CASE_DIR}/leftover.out" 2>&1; then
    fail_test "leftover key directories were accepted"
  fi
  grep -Fq "Local sbctl key directories exist without keys: ${SBCTL_ROOT}/keys/PK ${SBCTL_ROOT}/keys/KEK ${SBCTL_ROOT}/keys/db" \
    "${CASE_DIR}/leftover.out" || fail_test "the leftover refusal did not name the directories"
  grep -Fq 'remove them if they hold nothing you need' "${CASE_DIR}/leftover.out" \
    || fail_test "the leftover refusal gave no remedy"
  read_lifecycle || fail_test "leftover refusal damaged the lifecycle"
  [[ $_lifecycle_generation -eq generation ]] \
    || fail_test "leftover directories were refused inside a transaction"
  [[ ! -e "$SBCTL_ROOT/GUID" ]] || fail_test "the refusal ran create-keys"
  rm -rf "$SBCTL_ROOT/keys/KEK" "$SBCTL_ROOT/keys/db"
  if prepare_state_aware_setup true > "${CASE_DIR}/leftover-one.out" 2>&1; then
    fail_test "a single leftover key directory was accepted"
  fi
  grep -Fq "Local sbctl key directories exist without keys: ${SBCTL_ROOT}/keys/PK" \
    "${CASE_DIR}/leftover-one.out" || fail_test "a single leftover directory was not named"
  explain_setup_observation > "${CASE_DIR}/leftover-explain.out" 2>&1
  grep -Fq "Local sbctl key directories without keys: ${SBCTL_ROOT}/keys/PK" \
    "${CASE_DIR}/leftover-explain.out" \
    || fail_test "the observation did not name the leftover directory"
}

# A stale or unresolvable Limine path hash refuses the firmware instruction
# with the regenerating command as the remedy, and clears once it is gone.
test_stale_path_hash_refuses_instruction() {
  local backup_id
  setup_fixture stale-path-hash
  backup_id=$(prepare_and_activate)
  mkdir -p "$(dirname "$(limine_config_path)")" "$(esp_path)"
  printf '%s\n' '/Linux' '    protocol: efi' \
    "    path: hdd(1):/EFI/Linux/arch.efi#$(printf 'f%.0s' {1..128})" \
    > "$(limine_config_path)"
  if validate_setup_instruction_boundary "$backup_id" 3 > "${CASE_DIR}/stale.out" 2>&1; then
    fail_test "a stale path hash did not refuse the instruction"
  fi
  grep -Fq 'Limine path hashes are stale; Limine refuses these entries once Secure Boot is on' \
    "${CASE_DIR}/stale.out" || fail_test "the stale hash refusal gave no reason"
  grep -Fq 'path: hdd(1):/EFI/Linux/arch.efi#' "${CASE_DIR}/stale.out" \
    || fail_test "the stale hash refusal did not name the entry"
  grep -Fq 'For the current OS entry, run sudo limine-mkinitcpio' "${CASE_DIR}/stale.out" \
    || fail_test "the stale hash refusal gave no remedy"
  rm -f "$(limine_config_path)"
  if validate_setup_instruction_boundary "$backup_id" 3 >/dev/null 2>&1; then
    fail_test "a missing configuration authorized a firmware instruction"
  fi
  printf '%s\n' '/Linux' 'protocol: efi' \
    'path: boot():/EFI/Linux/arch.efi' > "$(limine_config_path)"
  validate_setup_instruction_boundary "$backup_id" 3 \
    || fail_test "the instruction stayed refused after the stale hash was gone"
  printf '%s\n' '/Linux' 'protocol: linux' \
    'kernel_path: boot():/vmlinuz' > "$(limine_config_path)"
  if validate_setup_instruction_boundary "$backup_id" 3 > "${CASE_DIR}/unhashed.out" 2>&1; then
    fail_test "an unhashed non-EFI resource authorized a firmware instruction"
  fi
  grep -Fq 'Limine requires BLAKE2B hashes' "${CASE_DIR}/unhashed.out" \
    || fail_test "the missing required hash refusal gave no reason"
}

# The README remedy leaves the key directory itself (700 from an earlier
# tool version) with the hierarchy directories removed: each of the three is
# recorded and the GUID is recorded as an absent file.
test_sbctl_key_directory_present() {
  local manifest
  setup_fixture sbctl-key-directory-present
  mkdir "$SBCTL_ROOT/keys"
  chmod 700 "$SBCTL_ROOT/keys"
  prepare_state_aware_setup true \
    || fail_test "preparation refused an empty key directory"
  classify_local_sbctl_keys || fail_test "keys under the existing directory were not classifiable"
  [[ "$_local_key_state" == complete ]] || fail_test "keys under the existing directory were not complete"
  [[ $(stat -c %a "$SBCTL_ROOT/keys") == 700 && $(stat -c %a "$SBCTL_ROOT/keys/PK") == 755 ]] \
    || fail_test "sbctl's creation changed the existing directory or its own modes"
  manifest=$(lifecycle_manifest_path "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
  jq -e --arg keys "$SBCTL_ROOT/keys" --arg guid "$SBCTL_ROOT/GUID" '
    ([.backups[] | select(.kind == "absent-directory")] | map(.target)) ==
      [$keys + "/PK", $keys + "/KEK", $keys + "/db"] and
    ([.backups[] | select(.kind == "absent-file")] | map(.target)) == [$guid]' \
    "$manifest" >/dev/null || fail_test "the hierarchy directories were not the recorded set"
}

# A failure after that creation removes the three directories and the GUID
# and leaves the key directory and sbctl's databases as they were.
test_sbctl_key_directory_present_rollback() {
  setup_fixture sbctl-key-directory-present-rollback
  mkdir "$SBCTL_ROOT/keys"
  chmod 700 "$SBCTL_ROOT/keys"
  SBCTL_BAD_KEY=true
  if prepare_state_aware_setup true; then
    fail_test "mismatched keys under an existing key directory were accepted"
  fi
  read_lifecycle || fail_test "rollback lifecycle is unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "the failed creation did not require recovery"
  jq -e '.rollback.status == "completed"' \
    "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
    || fail_test "rollback under an existing key directory did not complete"
  [[ ! -e "$SBCTL_ROOT/keys/PK" && ! -e "$SBCTL_ROOT/keys/KEK" && ! -e "$SBCTL_ROOT/keys/db" \
    && ! -e "$SBCTL_ROOT/GUID" ]] || fail_test "rollback left sbctl's creations behind"
  [[ -d "$SBCTL_ROOT/keys" && $(stat -c %a "$SBCTL_ROOT/keys") == 700 \
    && -e "$SBCTL_ROOT/files.json" ]] \
    || fail_test "rollback removed state that predates the transaction"
  classify_local_sbctl_keys || fail_test "rolled-back key state is unreadable"
  [[ "$_local_key_state" == none ]] || fail_test "rollback left key files behind"
  local_sbctl_key_directories_are_clear \
    || fail_test "rollback left hierarchy directories that the next setup would refuse"
}

# A state directory that group or others can write is refused with its reason.
test_sbctl_state_directory_writable() {
  setup_fixture sbctl-state-writable
  chmod 775 "$SBCTL_ROOT"
  if prepare_state_aware_setup true > "${CASE_DIR}/writable.out" 2>&1; then
    fail_test "a group-writable state directory was accepted"
  fi
  grep -Fq "${SBCTL_ROOT} must be owned by the control user and not writable by group or others" \
    "${CASE_DIR}/writable.out" \
    || fail_test "the writable state directory refusal gave no reason"
  [[ ! -e "$SBCTL_ROOT/keys" ]] || fail_test "a refused state directory received keys"
}

# A refused setup preflight names its reason and starts no transaction.
test_preflight_reasons() {
  setup_fixture preflight-reasons
  enter_setup_mode
  if prepare_state_aware_setup true > "${CASE_DIR}/setup-mode.out" 2>&1; then
    fail_test "Setup Mode without a backup was accepted"
  fi
  grep -Fq 'already in Setup Mode without a validated backup' \
    "${CASE_DIR}/setup-mode.out" || fail_test "Setup Mode refusal gave no reason"
  write_raw_database PK "$PLAN_SOURCE/current-PK.esl"
  write_state_variable SetupMode 0
  write_state_variable AuditMode 1
  if prepare_state_aware_setup true > "${CASE_DIR}/audit-mode.out" 2>&1; then
    fail_test "non-zero AuditMode was accepted"
  fi
  grep -Fq 'AuditMode and DeployedMode must both be absent or both read zero' \
    "${CASE_DIR}/audit-mode.out" || fail_test "non-zero AuditMode refusal gave no reason"
  grep -Fq 'Operation prepare-secure-boot preflight failed; no transaction was started' \
    "${CASE_DIR}/audit-mode.out" \
    || fail_test "preflight refusal did not say that no transaction started"
  write_state_variable AuditMode 0
  write_state_variable DeployedMode 1
  if prepare_state_aware_setup true > "${CASE_DIR}/deployed-mode.out" 2>&1; then
    fail_test "non-zero DeployedMode was accepted"
  fi
  grep -Fq 'must both be absent or both read zero' "${CASE_DIR}/deployed-mode.out" \
    || fail_test "non-zero DeployedMode refusal gave no reason"
  write_state_variable DeployedMode 0
  rm -f "$(firmware_variable_path AuditMode)"
  if prepare_state_aware_setup true > "${CASE_DIR}/mixed-modes.out" 2>&1; then
    fail_test "one optional mode variable without the other was accepted"
  fi
  grep -Fq 'must both be absent or both read zero' "${CASE_DIR}/mixed-modes.out" \
    || fail_test "mixed mode presence refusal gave no reason"
  [[ ! -e "$(lifecycle_file_path)" ]] \
    || fail_test "preflight refusal published lifecycle state"
}

firmware_ledger_writer_callback() {
  local backup_id="$1" timestamp combined tampered retry_output
  transaction_phase_start "bind-enrollment-plan" || return 1
  bind_enrollment_transaction "$backup_id" || return 1
  transaction_phase_complete "bind-enrollment-plan" || return 1
  preserve_transaction_files_on_failure || return 1
  preserve_transaction_files_on_failure || return 1

  read_transaction_manifest "$_transaction_id" || return 1
  timestamp=$(utc_timestamp) || return 1
  combined=$(jq -c --arg timestamp "$timestamp" '
    .firmware_writes += [{
      hierarchy: "db",
      started_at: $timestamp,
      command_exit_code: 0,
      readback_status: "pending",
      completed_at: null
    }]
  ' <<< "$_manifest_json") || return 1
  if write_transaction_manifest_json "$combined"; then
    return 71
  fi

  record_firmware_write_start db || return 1
  record_firmware_write_result db unchanged || return 1
  record_firmware_write_start db || return 1
  record_firmware_write_command_result db 31 || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  jq -e '.firmware_writes[0].command_exit_code == null and
    .firmware_writes[0].readback_status == "unchanged" and
    .firmware_writes[1].command_exit_code == 31 and
    .firmware_writes[1].readback_status == "pending"' \
    <<< "$_manifest_json" >/dev/null || return 72
  tampered=$(jq -c '.firmware_writes[0].command_exit_code = 0' \
    <<< "$_manifest_json") || return 1
  if write_transaction_manifest_json "$tampered"; then
    return 73
  fi
  record_firmware_write_result db unchanged || return 1
  if retry_output=$(record_firmware_write_start db 2>&1); then
    return 74
  fi
  printf '%s\n' "$retry_output" > "${CASE_DIR}/retry-limit.out"
  [[ "$retry_output" == *"firmware write retry limit reached for db"* ]] || return 75
  printf 'passed\n' > "${CASE_DIR}/ledger-writer-pass"
  return 42
}

test_live_firmware_ledger_writer() {
  local backup_id callback_rc manifest
  setup_fixture live-ledger-writer
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  if run_lifecycle_transaction_with_preflight "enroll-secure-boot" "active" "active" \
    enrollment_preflight firmware_ledger_writer_callback "$backup_id"; then
    fail_test "ledger writer fixture reported success"
  else
    callback_rc=$?
  fi
  [[ $callback_rc -eq 42 && -f "${CASE_DIR}/ledger-writer-pass" ]] \
    || fail_test "live ledger writer rejected a legal evidence transition"
  grep -Fq 'firmware write retry limit reached for db' "${CASE_DIR}/retry-limit.out" \
    || fail_test "third firmware attempt lacked its fixed diagnostic"
  read_lifecycle || fail_test "live ledger writer lifecycle unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "live ledger writer failure did not retain its incident"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '(.firmware_writes | length) == 2 and
    all(.firmware_writes[]; .hierarchy == "db" and
      .readback_status == "unchanged") and
    .firmware_writes[0].command_exit_code == null and
    .firmware_writes[1].command_exit_code == 31 and
    .rollback.status == "preserved"' "$manifest" >/dev/null \
    || fail_test "live ledger writer did not preserve exact evidence"
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "ledger writer evidence test reached a firmware command"
  fi
}

test_enrollment_guard_and_success() {
  local backup_id manifest transaction_id firmware_proof proof_document tampered
  setup_fixture enrollment-success
  [[ "$(observe_setup_state)" == 1 ]] || fail_test "observed state 1 mismatch"
  backup_id=$(prepare_and_activate)
  [[ "$(observe_setup_state "$backup_id")" == 3 ]] \
    || fail_test "observed state 3 mismatch"
  validate_setup_instruction_boundary "$backup_id" 3 \
    || fail_test "proved state 3 instruction boundary was rejected"
  WINDOWS_RC=2
  if validate_setup_instruction_boundary "$backup_id" 3; then
    fail_test "uncertain Windows state admitted a Setup Mode instruction"
  fi
  WINDOWS_RC=0
  enter_setup_mode
  [[ "$(observe_setup_state "$backup_id")" == 2 ]] \
    || fail_test "observed state 2 mismatch"
  [[ "$(classify_firmware_enrollment_frontier "$backup_id")" == F0 ]] \
    || fail_test "enrollment did not start from F0"
  run_enrollment "$backup_id" || fail_test "enrollment failed"
  mapfile -t partial_calls < <(grep -- '--partial' "$SBCTL_LOG")
  [[ "${partial_calls[*]}" == \
    'enroll-keys -m -f --ignore-immutable --partial db enroll-keys -m -f --ignore-immutable --partial KEK enroll-keys -m -f --ignore-immutable --partial PK' ]] \
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
  validate_setup_instruction_boundary "$backup_id" 4 \
    || fail_test "proved state 4 instruction boundary was rejected"
  transaction_id=$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")
  manifest=$(lifecycle_manifest_path "$transaction_id")
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
    (.completed_phases | index("prove-enrolled-trust") != null) and
    .domain_records.final_proof.schema_version == 2 and
    .domain_records.firmware.schema_version == 1
  ' "$manifest" >/dev/null || fail_test "enrollment phases are incomplete"
  read_transaction_manifest "$transaction_id" \
    || fail_test "completed enrollment manifest failed validation"
  firmware_proof=$(jq -r '.domain_records.firmware.path' "$manifest")
  proof_document=$(read_control_document "$firmware_proof") \
    || fail_test "firmware proof is unreadable"
  validate_firmware_proof_json "$transaction_id" "$proof_document" "$_manifest_json" \
    || fail_test "firmware proof did not validate"
  tampered=$(jq -c '.firmware_writes_sha256 =
    "0000000000000000000000000000000000000000000000000000000000000000"' \
    <<< "$proof_document")
  if validate_firmware_proof_json "$transaction_id" "$tampered" "$_manifest_json"; then
    fail_test "firmware proof accepted a changed ledger hash"
  fi
  tampered=$(jq -c '.domain_records.firmware = null' "$manifest")
  if validate_transaction_manifest_json "$transaction_id" "$tampered"; then
    fail_test "completed enrollment accepted a missing firmware proof"
  fi
  grep -Fxq artifact-proof "$ARTIFACT_LOG" || fail_test "post-enrollment artifact proof missing"
  write_state_variable SecureBoot 1
  [[ "$(observe_setup_state "$backup_id")" == 5 ]] \
    || fail_test "observed state 5 mismatch"
}

test_partial_plan_refusal() {
  local backup_id rc
  setup_fixture partial-plan
  # A backup that already equals the planned KEK has no F0 frontier; the plan
  # is refused with its guidance before it is recorded.
  write_raw_database KEK "$PLAN_SOURCE/KEK.esl"
  if prepare_state_aware_setup true > "${CASE_DIR}/build.out" 2>&1; then
    fail_test "preparation built a plan the firmware already partly holds"
  fi
  grep -Fq 'already holds part of the planned trust set' "${CASE_DIR}/build.out" \
    || fail_test "partial plan refusal at plan build lacked its guidance"

  # A backup that already holds the whole plan is an enrolled firmware: the
  # plan is built, the machine is observed as state 4, and nothing is written.
  setup_fixture whole-plan
  write_raw_database PK "$PLAN_SOURCE/PK.esl"
  write_raw_database KEK "$PLAN_SOURCE/KEK.esl"
  write_raw_database db "$PLAN_SOURCE/db.esl"
  backup_id=$(prepare_and_activate) \
    || fail_test "preparation refused a plan the firmware already holds in full"
  [[ "$(observe_setup_state "$backup_id")" == 4 ]] \
    || fail_test "a fully enrolled firmware was not observed as state 4"
  validate_setup_instruction_boundary "$backup_id" 4 >/dev/null 2>&1 \
    || fail_test "state 4 instruction boundary refused a fully enrolled firmware"
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "a fully enrolled firmware reached a firmware command"
  fi

  # A plan recorded before the frontier check exists: the firmware already
  # holds the planned KEK and the instruction boundaries refuse it.
  setup_fixture partial-plan-boundary
  write_raw_database KEK "$PLAN_SOURCE/KEK.esl"
  planned_trust_backup_match_is_whole() { return 0; }
  backup_id=$(prepare_and_activate)
  [[ "$(observe_setup_state "$backup_id")" == 3 ]] \
    || fail_test "partially enrolled plan was not observed as state 3"
  if validate_setup_instruction_boundary "$backup_id" 3 \
    > "${CASE_DIR}/boundary.out" 2>&1; then
    fail_test "state 3 instruction boundary admitted a partially enrolled plan"
  fi
  grep -Fq 'already holds part of the planned trust set' "${CASE_DIR}/boundary.out" \
    || fail_test "partial plan refusal lacked its guidance"
  # A database that cannot be read is reported as unreadable, not as a match.
  rc=0
  (
    current_database_plan_status() { return 1; }
    validate_setup_instruction_boundary "$backup_id" 3 > "${CASE_DIR}/unreadable.out" 2>&1
  ) || rc=$?
  [[ $rc -ne 0 ]] || fail_test "state 3 instruction boundary admitted an unreadable database"
  grep -Fq "Could not read the firmware's PK database" "${CASE_DIR}/unreadable.out" \
    || fail_test "unreadable database was not reported as such"
  if grep -Fq 'already holds part of the planned trust set' "${CASE_DIR}/unreadable.out"; then
    fail_test "unreadable database was reported as a partial match"
  fi
  enter_setup_mode
  [[ "$(observe_setup_state "$backup_id")" == 2 ]] \
    || fail_test "partially enrolled plan in Setup Mode was not state 2"
  if run_enrollment "$backup_id" > "${CASE_DIR}/enroll.out" 2>&1; then
    fail_test "enrollment started from a partially enrolled plan"
  fi
  grep -Fq 'already holds part of the planned trust set' "${CASE_DIR}/enroll.out" \
    || fail_test "enrollment refusal lacked its guidance"
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "partial plan refusal reached a firmware command"
  fi
  read_lifecycle || fail_test "partial plan refusal left the lifecycle unreadable"
  [[ "$_lifecycle_state" == active ]] \
    || fail_test "partial plan refusal changed the lifecycle state"
}

test_firmware_command_evidence_boundaries() {
  local backup_id manifest
  setup_fixture unknown-command-result
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ENROLLMENT_MUTATION_POINT=after-db-command
  if run_enrollment "$backup_id"; then
    fail_test "post-command failpoint reported success"
  fi
  read_lifecycle || fail_test "post-command lifecycle unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '(.firmware_writes | length) == 1 and
    .firmware_writes[0].hierarchy == "db" and
    .firmware_writes[0].command_exit_code == null and
    .firmware_writes[0].readback_status == "pending" and
    .rollback.status == "preserved"' "$manifest" >/dev/null \
    || fail_test "unknown command result was not retained as pending"

  setup_fixture pending-readback
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ENROLLMENT_MUTATION_POINT=after-db-command-result
  if run_enrollment "$backup_id"; then
    fail_test "post-command-result failpoint reported success"
  fi
  read_lifecycle || fail_test "pending-readback lifecycle unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '(.firmware_writes | length) == 1 and
    .firmware_writes[0].hierarchy == "db" and
    .firmware_writes[0].command_exit_code == 0 and
    .firmware_writes[0].readback_status == "pending" and
    .rollback.status == "preserved"' "$manifest" >/dev/null \
    || fail_test "known command result with pending readback was not durable"

  setup_fixture unchanged-readback
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  SBCTL_FAIL_PHASE=before-db
  if run_enrollment "$backup_id"; then
    fail_test "no-effect db command reported success"
  fi
  read_lifecycle || fail_test "unchanged-readback lifecycle unreadable"
  manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
  jq -e '(.firmware_writes | length) == 1 and
    .firmware_writes[0].hierarchy == "db" and
    .firmware_writes[0].command_exit_code == 31 and
    .firmware_writes[0].readback_status == "unchanged" and
    .rollback.status == "preserved"' "$manifest" >/dev/null \
    || fail_test "exact pre-frontier readback was not recorded unchanged"
}

test_dbx_drift_blocks_cleanly() {
  local backup_id generation
  setup_fixture dbx-drift
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  write_raw_database dbx "$PLAN_SOURCE/mismatch.esl"
  read_lifecycle || fail_test "drift fixture lifecycle unreadable"
  generation=$_lifecycle_generation
  : > "$SBCTL_LOG"
  if run_enrollment "$backup_id"; then
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
  local backup_id manifest root_id
  setup_fixture partial-readback
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  SBCTL_MISMATCH_PHASE=db
  : > "$SBCTL_LOG"
  if run_enrollment "$backup_id"; then
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
  root_id="$_lifecycle_transaction_id"
  SBCTL_MISMATCH_PHASE=""
  if recover_firmware_incident; then
    fail_test "contradictory firmware state admitted automatic recovery"
  fi
  read_lifecycle || fail_test "terminal firmware mismatch damaged lifecycle evidence"
  [[ "$_lifecycle_state" == recovery-required \
    && "$_lifecycle_transaction_id" == "$root_id" \
    && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 0 ]] \
    || fail_test "terminal firmware mismatch published a recovery attempt"
}

test_db_command_failure_after_effect() {
  local backup_id manifest
  setup_fixture db-command-failure
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  SBCTL_FAIL_PHASE=after-db
  : > "$SBCTL_LOG"
  if run_enrollment "$backup_id"; then
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
  SBCTL_FAIL_PHASE=after-PK
  : > "$SBCTL_LOG"
  : > "$ARTIFACT_LOG"
  if run_enrollment "$backup_id"; then
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
  ENROLLMENT_MUTATION_POINT=after-enrollment-artifact-repair
  : > "$SBCTL_LOG"
  if run_enrollment "$backup_id"; then
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

test_firmware_recovery_from_unbound_root() {
  local backup_id root_id root_manifest root_incident root_manifest_hash root_incident_hash
  local recovery_id recovery_manifest recovery_proof
  setup_fixture "recovery-unbound-root${ABSENT_MODE_FIXTURE_SUFFIX:-}"
  if [[ "${ABSENT_MODE_VARIABLES:-false}" == true ]]; then
    rm -f "$(firmware_variable_path AuditMode)" "$(firmware_variable_path DeployedMode)"
  fi
  backup_id=$(prepare_and_activate)
  run_lifecycle_transaction cleanup active active record_intervening_cleanup \
    || fail_test "intervening cleanup fixture failed"
  [[ $(current_setup_backup_id) == "$backup_id" ]] \
    || fail_test "intervening transaction hid the current setup plan"
  enter_setup_mode
  if run_lifecycle_transaction_with_preflight "enroll-secure-boot" "active" "active" \
    enrollment_preflight fail_before_enrollment_binding "$backup_id"; then
    fail_test "unbound enrollment incident reported success"
  fi
  read_lifecycle || fail_test "unbound enrollment incident was unreadable"
  [[ "$_lifecycle_state" == recovery-required ]] \
    || fail_test "unbound enrollment incident did not require recovery"
  root_id="$_lifecycle_transaction_id"
  root_manifest=$(lifecycle_manifest_path "$root_id")
  root_incident=$(lifecycle_incident_path "$root_id")
  root_manifest_hash=$(sha256_file "$root_manifest")
  root_incident_hash=$(sha256_file "$root_incident")
  jq -e '.firmware_backup == null and .enrollment_plan == null and
    .firmware_writes == [] and .file_rollback_policy == "restore"' \
    "$root_manifest" >/dev/null || fail_test "unbound root retained enrollment authority"

  : > "$SBCTL_LOG"
  : > "$ARTIFACT_LOG"
  recover_firmware_incident || fail_test "unbound enrollment incident did not recover"
  read_lifecycle || fail_test "unbound recovery result was unreadable"
  [[ "$_lifecycle_state" == active ]] || fail_test "unbound recovery did not restore active"
  recovery_id=$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")
  recovery_manifest=$(lifecycle_manifest_path "$recovery_id")
  jq -e --arg backup_id "$backup_id" '
    .kind == "recovery-attempt" and .operation == "firmware-recovery" and
    .status == "completed" and .firmware_backup.id == $backup_id and
    .enrollment_plan.backup_id == $backup_id and
    [.firmware_writes[].hierarchy] == ["db","KEK","PK"] and
    all(.firmware_writes[];
      .command_exit_code == 0 and .readback_status == "verified") and
    .domain_records.final_proof.schema_version == 2 and
    .domain_records.firmware.schema_version == 1
  ' "$recovery_manifest" >/dev/null || fail_test "unbound recovery proof was incomplete"
  [[ $(sha256_file "$root_manifest") == "$root_manifest_hash" \
    && $(sha256_file "$root_incident") == "$root_incident_hash" ]] \
    || fail_test "firmware recovery rewrote root evidence"
  mapfile -t partial_calls < <(grep -- '--partial' "$SBCTL_LOG")
  [[ "${partial_calls[*]}" == \
    'enroll-keys -m -f --ignore-immutable --partial db enroll-keys -m -f --ignore-immutable --partial KEK enroll-keys -m -f --ignore-immutable --partial PK' ]] \
    || fail_test "unbound recovery used the wrong enrollment order"
  [[ $(grep -Fxc artifact-proof "$ARTIFACT_LOG") -eq 1 ]] \
    || fail_test "firmware recovery omitted its second EFI verification"
  if [[ "${ABSENT_MODE_VARIABLES:-false}" == true ]]; then
    recovery_proof=$(read_control_document \
      "$(jq -r '.domain_records.firmware.path' "$recovery_manifest")") \
      || fail_test "absent-mode recovery proof is unreadable"
    jq -e '.modes == {SetupMode: 0, AuditMode: null, DeployedMode: null, SecureBoot: 0}' \
      <<< "$recovery_proof" >/dev/null \
      || fail_test "absent-mode recovery proof did not record null modes"
  fi
}

# The same interrupted enrollment and recovery on firmware without the
# optional mode variables.
test_firmware_recovery_from_unbound_root_absent_modes() {
  local ABSENT_MODE_VARIABLES=true ABSENT_MODE_FIXTURE_SUFFIX=-absent-modes
  test_firmware_recovery_from_unbound_root
}

test_setup_lineage_stops_at_unconfigure() {
  local unconfigure_id="11111111-1111-1111-1111-111111111111"
  local activation_id="22222222-2222-2222-2222-222222222222"
  local lineage_backup_id="33333333-3333-3333-3333-333333333333"
  # Names avoid the traversal's own locals, which shadow the stub's variables.
  local lineage_prior_path lineage_prior_hash lifecycle boundary_operation digest timestamp
  setup_fixture setup-lineage-boundary
  digest=$(printf 'a%.0s' {1..64})
  timestamp=2026-01-01T00:00:00Z
  # Schema-valid lifecycle documents, so the traversal reaches the boundary
  # instead of rejecting the fixture first.
  lifecycle_document() {
    local state="$1" operation="$2" id="$3"
    jq -cn --arg state "$state" --arg operation "$operation" --arg id "$id" \
      --arg manifest "$(lifecycle_manifest_path "$id")" --arg digest "$digest" \
      --arg timestamp "$timestamp" --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
      --arg version "$OMASECBOOT_VERSION" '{
        schema_version: $schema, writer_version: $version, generation: 2,
        state: $state, updated_at: $timestamp, transaction: null,
        last_transaction: {id: $id, operation: $operation, manifest: $manifest,
          manifest_sha256: $digest, completed_at: $timestamp},
        last_recovery: null, managed_settings: null, tracking_ownership: null
      }'
  }
  lineage_prior_path="${CASE_DIR}/prior-active-lifecycle.json"
  lifecycle_document active activate-secure-boot-plan "$activation_id" > "$lineage_prior_path"
  chmod 600 "$lineage_prior_path"
  lineage_prior_hash=$(sha256_file "$lineage_prior_path") || fail_test "could not hash lineage fixture"
  validate_lifecycle_document_references() { return 0; }
  validate_firmware_backup() { [[ "$1" == "$lineage_backup_id" ]]; }
  validate_enrollment_plan() { [[ "$1" == "$lineage_backup_id" ]]; }
  read_transaction_manifest() {
    if [[ "$1" == "$unconfigure_id" ]]; then
      _manifest_json=$(jq -cn --arg path "$lineage_prior_path" --arg hash "$lineage_prior_hash" \
        --arg operation "$boundary_operation" '{
        status:"completed",
        operation:$operation,
        firmware_backup:null,
        backups:[{kind:"prior-lifecycle",path:$path,sha256:$hash}]
      }')
    elif [[ "$1" == "$activation_id" ]]; then
      _manifest_json=$(jq -cn --arg id "$lineage_backup_id" '{
        status:"completed",
        operation:"activate-secure-boot-plan",
        firmware_backup:{id:$id,status:"complete"},
        backups:[]
      }')
    else
      return 1
    fi
    _manifest_id="$1"
  }
  for boundary_operation in unconfigure unconfigure-recovery; do
    lifecycle=$(lifecycle_document disabled "$boundary_operation" "$unconfigure_id")
    validate_lifecycle_json "$lifecycle" \
      || fail_test "${boundary_operation} lineage fixture is not a valid lifecycle document"
    if setup_backup_id_from_lifecycle_json "$lifecycle"; then
      fail_test "completed ${boundary_operation} retained an obsolete setup plan"
    fi
  done
  # Positive control: the same history without the boundary traverses to the
  # activation plan, so the negative assertions above are not vacuous.
  boundary_operation=cleanup
  lifecycle=$(lifecycle_document active cleanup "$unconfigure_id")
  validate_lifecycle_json "$lifecycle" \
    || fail_test "control lineage fixture is not a valid lifecycle document"
  [[ $(setup_backup_id_from_lifecycle_json "$lifecycle") == "$lineage_backup_id" ]] \
    || fail_test "non-boundary history did not traverse to the activation plan"
}

test_firmware_recovery_resolves_pending_effect() {
  local backup_id root_id root_manifest_hash root_incident_hash recovery_manifest
  setup_fixture recovery-pending-effect
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ENROLLMENT_MUTATION_POINT=after-db-command
  if run_enrollment "$backup_id"; then
    fail_test "pending-effect fixture reported success"
  fi
  read_lifecycle || fail_test "pending-effect root was unreadable"
  root_id="$_lifecycle_transaction_id"
  root_manifest_hash=$(sha256_file "$(lifecycle_manifest_path "$root_id")")
  root_incident_hash=$(sha256_file "$(lifecycle_incident_path "$root_id")")
  ENROLLMENT_MUTATION_POINT=""
  ENROLLMENT_MUTATION_USED=false
  : > "$SBCTL_LOG"
  recover_firmware_incident || fail_test "pending-effect incident did not recover"
  read_lifecycle || fail_test "pending-effect recovery was unreadable"
  recovery_manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")")
  jq -e '
    [.firmware_writes[].hierarchy] == ["db","KEK","PK"] and
    .firmware_writes[0].command_exit_code == null and
    .firmware_writes[0].readback_status == "verified" and
    all(.firmware_writes[1:][];
      .command_exit_code == 0 and .readback_status == "verified")
  ' "$recovery_manifest" >/dev/null \
    || fail_test "pending command effect was not resolved from direct readback"
  if grep -Fq -- '--partial db' "$SBCTL_LOG"; then
    fail_test "recovery replayed a db write whose effect was already present"
  fi
  [[ $(sha256_file "$(lifecycle_manifest_path "$root_id")") == "$root_manifest_hash" \
    && $(sha256_file "$(lifecycle_incident_path "$root_id")") == "$root_incident_hash" ]] \
    || fail_test "pending-effect recovery rewrote root evidence"
}

test_firmware_recovery_inherits_resolved_retry() {
  local backup_id first_attempt first_manifest first_manifest_hash final_manifest
  setup_fixture recovery-pending-retry
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ENROLLMENT_MUTATION_POINT=before-db-write
  if run_enrollment "$backup_id"; then
    fail_test "pending retry fixture reported success"
  fi
  ENROLLMENT_MUTATION_POINT=after-recovery-artifact-repair
  ENROLLMENT_MUTATION_USED=false
  if recover_firmware_incident; then
    fail_test "injected recovery artifact failure reported success"
  fi
  read_lifecycle || fail_test "failed recovery attempt was unreadable"
  [[ "$_lifecycle_state" == recovery-required \
    && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 1 ]] \
    || fail_test "failed recovery attempt did not remain recoverable"
  first_attempt=$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")
  first_manifest=$(lifecycle_manifest_path "$first_attempt")
  jq -e '(.firmware_writes | length) == 1 and
    .firmware_writes[0].command_exit_code == null and
    .firmware_writes[0].readback_status == "unchanged"' "$first_manifest" >/dev/null \
    || fail_test "first recovery attempt did not seal the pending resolution"
  first_manifest_hash=$(sha256_file "$first_manifest")

  ENROLLMENT_MUTATION_POINT=""
  ENROLLMENT_MUTATION_USED=false
  : > "$SBCTL_LOG"
  recover_firmware_incident || fail_test "resolved retry did not recover"
  read_lifecycle || fail_test "resolved retry result was unreadable"
  final_manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")")
  jq -e '
    [.firmware_writes[].hierarchy] == ["db","db","KEK","PK"] and
    .firmware_writes[0].readback_status == "unchanged" and
    all(.firmware_writes[1:][]; .readback_status == "verified")
  ' "$final_manifest" >/dev/null \
    || fail_test "resolved retry did not inherit the cumulative ledger"
  [[ $(sha256_file "$first_manifest") == "$first_manifest_hash" ]] \
    || fail_test "later firmware recovery rewrote prior attempt evidence"
  grep -Fxq 'enroll-keys -m -f --ignore-immutable --partial db' "$SBCTL_LOG" \
    || fail_test "resolved retry did not issue the bounded db retry"
}

test_firmware_recovery_retry_limit_is_cumulative() {
  local backup_id manifest command_count
  setup_fixture recovery-retry-limit
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  SBCTL_FAIL_PHASE=before-db
  if run_enrollment "$backup_id"; then
    fail_test "retry-limit root reported success"
  fi
  if recover_firmware_incident; then
    fail_test "second unchanged db attempt reported recovery success"
  fi
  SBCTL_FAIL_PHASE=""
  if recover_firmware_incident; then
    fail_test "third cumulative db attempt bypassed the retry limit"
  fi
  read_lifecycle || fail_test "retry-limit recovery state was unreadable"
  manifest=$(lifecycle_manifest_path \
    "$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")")
  jq -e '(.firmware_writes | length) == 2 and
    all(.firmware_writes[];
      .hierarchy == "db" and .readback_status == "unchanged")' "$manifest" >/dev/null \
    || fail_test "recovery reset the cumulative firmware retry ledger"
  command_count=$(grep -Fxc 'enroll-keys -m -f --ignore-immutable --partial db' "$SBCTL_LOG")
  [[ $command_count -eq 2 ]] || fail_test "retry limit issued ${command_count} db commands"
}

test_firmware_recovery_requires_windows_gate() {
  local backup_id root_id attempt_count phase rc
  for phase in before-db before-KEK before-PK; do
    setup_fixture "recovery-gate-${phase}"
    backup_id=$(prepare_and_activate)
    enter_setup_mode
    SBCTL_FAIL_PHASE="$phase"
    if run_enrollment "$backup_id" >/dev/null 2>&1; then
      fail_test "${phase}: gate fixture reported success"
    fi
    SBCTL_FAIL_PHASE=""
    read_lifecycle || fail_test "${phase}: gate fixture lifecycle unreadable"
    [[ "$_lifecycle_state" == recovery-required ]] \
      || fail_test "${phase}: gate fixture did not require recovery"
    root_id="$_lifecycle_transaction_id"
    attempt_count=$(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json")
    for rc in 1 2; do
      WINDOWS_RC=$rc
      : > "$SBCTL_LOG"
      : > "$ARTIFACT_LOG"
      if recover_firmware_incident >/dev/null 2>&1; then
        fail_test "${phase}: recovery continued past a Windows gate result ${rc}"
      fi
      if grep -Fq -- '--partial' "$SBCTL_LOG" || [[ -s "$ARTIFACT_LOG" ]]; then
        fail_test "${phase}: a refused gate still wrote firmware or artifacts"
      fi
      read_lifecycle || fail_test "${phase}: refused recovery lifecycle unreadable"
      [[ "$_lifecycle_state" == recovery-required \
        && "$_lifecycle_transaction_id" == "$root_id" \
        && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") == \
          "$attempt_count" ]] \
        || fail_test "${phase}: a refused gate consumed a recovery attempt"
    done
    WINDOWS_RC=0
    recover_firmware_incident || fail_test "${phase}: recovery failed after the gate passed"
    read_lifecycle || fail_test "${phase}: recovered lifecycle unreadable"
    [[ "$_lifecycle_state" == active ]] \
      || fail_test "${phase}: gated recovery did not restore active state"
  done
}

test_firmware_recovery_completes_post_pk_effect() {
  local backup_id manifest
  setup_fixture recovery-post-pk-effect
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  SBCTL_FAIL_PHASE=after-PK
  if run_enrollment "$backup_id"; then
    fail_test "post-PK recovery fixture reported success"
  fi
  SBCTL_FAIL_PHASE=""
  : > "$SBCTL_LOG"
  # An incident already at F3 reconciles without a new Windows gate.
  WINDOWS_RC=2
  recover_firmware_incident || fail_test "post-PK effect did not recover"
  WINDOWS_RC=0
  read_lifecycle || fail_test "post-PK recovery result was unreadable"
  manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")")
  jq -e '
    [.firmware_writes[].hierarchy] == ["db","KEK","PK"] and
    .firmware_writes[2].command_exit_code == 36 and
    all(.firmware_writes[]; .readback_status == "verified") and
    .domain_records.firmware != null
  ' "$manifest" >/dev/null || fail_test "post-PK recovery proof was incomplete"
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "post-PK recovery replayed an already completed firmware write"
  fi
}

test_firmware_recovery_leaves_unreadable_pending() {
  local backup_id root_id root_manifest attempt_count
  setup_fixture recovery-unreadable-pending
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  ENROLLMENT_MUTATION_POINT=after-db-command
  if run_enrollment "$backup_id"; then
    fail_test "unreadable pending fixture reported success"
  fi
  read_lifecycle || fail_test "unreadable pending root was unreadable"
  root_id="$_lifecycle_transaction_id"
  root_manifest=$(lifecycle_manifest_path "$root_id")
  rm -f "$(firmware_variable_path SetupMode)"
  if recover_firmware_incident; then
    fail_test "technical firmware uncertainty reported recovery success"
  fi
  read_lifecycle || fail_test "technical uncertainty damaged lifecycle evidence"
  attempt_count=$(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json")
  [[ "$_lifecycle_state" == recovery-required && "$attempt_count" == 0 \
    && "$_lifecycle_transaction_id" == "$root_id" ]] \
    || fail_test "technical uncertainty replaced the root incident"
  jq -e '.firmware_writes[-1].readback_status == "pending"' "$root_manifest" >/dev/null \
    || fail_test "technical uncertainty resolved an unreadable pending write"
}

test_firmware_recovery_resolves_failed_pk_readback() {
  local backup_id root_id root_manifest root_hash seal_hash attempt attempt_hash
  local final_manifest previous current tampered change
  setup_fixture recovery-failed-pk
  # Model the recorded hardware's absent optional mode variables and delayed
  # SetupMode observation, while keeping its original five-field write rows.
  rm -f "$(firmware_variable_path AuditMode)" "$(firmware_variable_path DeployedMode)"
  backup_id=$(prepare_and_activate)
  enter_setup_mode
  SBCTL_PK_SETUP_MODE=1
  if run_enrollment "$backup_id"; then
    fail_test "unconfirmed SetupMode exit reported enrollment complete"
  fi
  read_lifecycle || fail_test "failed PK incident was unreadable"
  root_id="$_lifecycle_transaction_id"
  root_manifest=$(lifecycle_manifest_path "$root_id")
  root_hash=$(sha256_file "$root_manifest")
  seal_hash=$(sha256_file "$(lifecycle_incident_path "$root_id")")
  jq -e '.current_phase == "enroll-pk" and .file_rollback_policy == "preserve" and
    [.firmware_writes[].readback_status] == ["verified","verified","failed"] and
    all(.firmware_writes[]; .command_exit_code == 0 and
      keys == ["command_exit_code","completed_at","hierarchy","readback_status","started_at"])' \
    "$root_manifest" >/dev/null || fail_test "failed PK fixture did not match historical evidence"

  : > "$SBCTL_LOG"
  : > "$ARTIFACT_LOG"
  if recover_firmware_incident; then
    fail_test "failed PK recovered before strict F3 was observed"
  fi
  write_state_variable SetupMode 0
  boot_id_value() { printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'; }
  write_raw_database dbx "$PLAN_SOURCE/mismatch.esl"
  if recover_firmware_incident; then
    fail_test "failed PK recovery accepted changed dbx"
  fi
  [[ ! -s "$SBCTL_LOG" && ! -s "$ARTIFACT_LOG" ]] \
    || fail_test "refused failed PK recovery mutated artifacts or invoked sbctl"
  read_lifecycle || fail_test "refused recovery damaged lifecycle state"
  [[ $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") == 0 ]] \
    || fail_test "refused failed PK recovery consumed an attempt"
  write_raw_database dbx "$PLAN_SOURCE/dbx.esl"

  ENROLLMENT_MUTATION_POINT=after-recovery-artifact-repair
  if recover_firmware_incident; then
    fail_test "interrupted failed PK reconciliation reported success"
  fi
  read_lifecycle || fail_test "interrupted PK recovery was unreadable"
  attempt=$(jq -r '.transaction.last_recovery_attempt.id' <<< "$_lifecycle_json")
  attempt_hash=$(sha256_file "$(lifecycle_manifest_path "$attempt")")
  jq -e '.firmware_writes[-1].readback_status == "verified" and
    .firmware_writes[-1].command_exit_code == 0' "$(lifecycle_manifest_path "$attempt")" \
    >/dev/null || fail_test "recovery did not persist the fresh PK observation"
  previous=$(read_control_document "$root_manifest")
  current=$(read_control_document "$(lifecycle_manifest_path "$attempt")")
  validate_recovery_manifest_evolution "$previous" "$current" firmware-recovery \
    || fail_test "valid historical PK reconciliation failed lineage validation"
  for change in \
    '.firmware_writes[-1].readback_status = "unchanged"' \
    '.firmware_writes[-1].command_exit_code = 1' \
    '.firmware_writes[-1].started_at = "2026-01-01T00:00:00Z"' \
    '.firmware_writes[0].readback_status = "unchanged"' \
    '.firmware_writes += [.firmware_writes[-1]]'; do
    tampered=$(jq -c "$change" <<< "$current")
    if validate_recovery_manifest_evolution "$previous" "$tampered" firmware-recovery; then
      fail_test "PK reconciliation lineage accepted changed authority: ${change}"
    fi
  done
  ENROLLMENT_MUTATION_POINT=""
  ENROLLMENT_MUTATION_USED=false
  WINDOWS_RC=2
  recover_firmware_incident || fail_test "failed PK reconciliation did not resume"
  read_lifecycle || fail_test "completed PK recovery was unreadable"
  [[ "$_lifecycle_state" == active ]] || fail_test "PK reconciliation did not restore active state"
  final_manifest=$(lifecycle_manifest_path \
    "$(jq -r '.last_recovery.final_attempt.id' <<< "$_lifecycle_json")")
  jq -e '[.firmware_writes[].hierarchy] == ["db","KEK","PK"] and
    all(.firmware_writes[]; .command_exit_code == 0 and .readback_status == "verified") and
    .domain_records.firmware != null and .domain_records.final_proof != null' \
    "$final_manifest" >/dev/null || fail_test "PK reconciliation proof was incomplete"
  if grep -Fq -- '--partial' "$SBCTL_LOG"; then
    fail_test "PK reconciliation issued another firmware write"
  fi
  [[ $(sha256_file "$root_manifest") == "$root_hash" \
    && $(sha256_file "$(lifecycle_incident_path "$root_id")") == "$seal_hash" \
    && $(sha256_file "$(lifecycle_manifest_path "$attempt")") == "$attempt_hash" ]] \
    || fail_test "PK reconciliation rewrote sealed predecessor evidence"
}

test_failed_pk_ledger_boundaries() {
  local ledger candidate frontier
  ledger='{"firmware_writes":[
    {"hierarchy":"db","command_exit_code":0,"readback_status":"verified"},
    {"hierarchy":"KEK","command_exit_code":0,"readback_status":"verified"},
    {"hierarchy":"PK","command_exit_code":0,"readback_status":"failed",
      "completed_at":"2026-09-10T12:22:51Z"}]}'
  firmware_ledger_matches_frontier "$ledger" F3 \
    || fail_test "terminal successful PK command cannot be reconciled at F3"
  for frontier in F0 F1 F2 invalid; do
    if firmware_ledger_matches_frontier "$ledger" "$frontier"; then
      fail_test "terminal failed PK authorized ${frontier} or a retry"
    fi
  done
  for candidate in \
    '.firmware_writes[-1].command_exit_code = 1' \
    '.firmware_writes[-1].command_exit_code = null' \
    '.firmware_writes[-1].hierarchy = "KEK"' \
    '.firmware_writes[0].readback_status = "failed"'; do
    if firmware_ledger_matches_frontier "$(jq -c "$candidate" <<< "$ledger")" F3; then
      fail_test "unsupported failure acquired PK reconciliation authority: ${candidate}"
    fi
  done
}

run_case() {
  local name="$1" function="$2" log pid registration_signal=""
  if [[ "$enrollment_test_case" != all && "$enrollment_test_case" != "$name" ]]; then
    return 0
  fi
  enrollment_test_case_matched=true
  log="${TEST_DIR}/case-${name}.log"
  trap 'registration_signal=INT' INT
  trap 'registration_signal=TERM' TERM
  trap 'registration_signal=HUP' HUP
  (
    trap - EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    "$function"
  ) > "$log" 2>&1 &
  pid=$!
  run_case_pids+=("$pid")
  run_case_names+=("$name")
  run_case_logs+=("$log")
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  case "$registration_signal" in
    INT) return 130 ;;
    TERM) return 143 ;;
    HUP) return 129 ;;
  esac
  if (( ${#run_case_pids[@]} >= enrollment_test_jobs )); then
    wait_for_cases || fail_test "enrollment test batch failed"
  fi
}

replay_case_log() {
  local log="$1" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line" >&2
  done < "$log"
}

wait_for_cases() {
  local index rc failed=false
  for index in "${!run_case_pids[@]}"; do
    rc=0
    wait "${run_case_pids[$index]}" || rc=$?
    replay_case_log "${run_case_logs[$index]}"
    if (( rc != 0 )); then
      printf 'FAIL: case failed: %s\n' "${run_case_names[$index]}" >&2
      failed=true
    fi
  done
  run_case_pids=()
  run_case_names=()
  run_case_logs=()
  [[ "$failed" == false ]]
}

enrollment_test_jobs=${ENROLLMENT_TEST_JOBS:-4}
enrollment_test_case=${ENROLLMENT_TEST_CASE:-all}
enrollment_test_case_matched=false
[[ "$enrollment_test_jobs" =~ ^[1-9][0-9]*$ && $enrollment_test_jobs -le 16 ]] \
  || fail_test "ENROLLMENT_TEST_JOBS must be between 1 and 16"
declare -a run_case_pids=() run_case_names=() run_case_logs=()

run_case parser test_esl_parser
run_case classifier test_setup_classifier
run_case pk-mode-contradictions test_pk_mode_contradictions
run_case config-parser test_config_boundary_parser
run_case preparation-consent test_preparation_consent
run_case incoherent-snapshot test_incoherent_snapshot_blocks
run_case bad-key test_bad_key_rolls_back
run_case confirmation-acknowledgments test_confirmation_requires_acknowledgments
run_case activation-environment-guard test_activation_environment_guard
run_case preparation test_preparation_and_backup
run_case absent-dbx test_absent_dbx_record
run_case missing-entry test_missing_current_entry_blocks
run_case firmware-frontiers test_firmware_frontier_classifier
run_case absent-modes test_absent_mode_variables
run_case observation-explanation test_observation_explanation
run_case sbctl-state-accepted test_sbctl_state_directory_accepted
run_case sbctl-state-absent test_sbctl_state_directory_absent
run_case sbctl-state-absent-rollback test_sbctl_state_directory_absent_rollback
run_case sbctl-leftover-directories test_sbctl_leftover_key_directories_refused
run_case sbctl-key-directory-present test_sbctl_key_directory_present
run_case stale-path-hash test_stale_path_hash_refuses_instruction
run_case sbctl-key-directory-present-rollback test_sbctl_key_directory_present_rollback
run_case sbctl-state-writable test_sbctl_state_directory_writable
run_case preflight-reasons test_preflight_reasons
run_case live-ledger-writer test_live_firmware_ledger_writer
run_case enrollment-success test_enrollment_guard_and_success
run_case partial-plan test_partial_plan_refusal
run_case firmware-command-evidence test_firmware_command_evidence_boundaries
run_case dbx-drift test_dbx_drift_blocks_cleanly
run_case partial-readback test_partial_readback_failure
run_case db-command-failure test_db_command_failure_after_effect
run_case pk-command-failure test_pk_command_failure_after_effect
run_case artifact-drift test_artifact_repair_drift_blocks_write
run_case plan-tamper test_plan_manifest_tamper_blocks
run_case windows-gate test_windows_gate_blocks_preparation
run_case recovery-unbound-root test_firmware_recovery_from_unbound_root
run_case recovery-unbound-root-absent-modes \
  test_firmware_recovery_from_unbound_root_absent_modes
run_case setup-lineage-boundary test_setup_lineage_stops_at_unconfigure
run_case recovery-pending-effect test_firmware_recovery_resolves_pending_effect
run_case recovery-pending-retry test_firmware_recovery_inherits_resolved_retry
run_case recovery-retry-limit test_firmware_recovery_retry_limit_is_cumulative
run_case recovery-post-pk-effect test_firmware_recovery_completes_post_pk_effect
run_case recovery-failed-pk test_firmware_recovery_resolves_failed_pk_readback
run_case failed-pk-ledger test_failed_pk_ledger_boundaries
run_case recovery-windows-gate test_firmware_recovery_requires_windows_gate
run_case recovery-unreadable-pending test_firmware_recovery_leaves_unreadable_pending
[[ "$enrollment_test_case_matched" == true ]] \
  || fail_test "unknown ENROLLMENT_TEST_CASE: ${enrollment_test_case}"
wait_for_cases || fail_test "enrollment test batch failed"

printf 'enrollment tests passed\n'
