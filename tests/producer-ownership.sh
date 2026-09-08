#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154 # Hermetic overrides and sourced globals are intentional.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init producer-ownership

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

STABLE_ID=11111111-1111-1111-1111-111111111111
ROOT_ID=22222222-2222-2222-2222-222222222222
OLDER_ID=33333333-3333-3333-3333-333333333333
LATEST_ID=44444444-4444-4444-4444-444444444444
ROOT_EFI="${TEST_DIR}/boot/EFI/Linux/root.efi"
OLDER_EFI="${TEST_DIR}/boot/EFI/Linux/older.efi"
LATEST_EFI="${TEST_DIR}/boot/EFI/Linux/latest.efi"
DEFAULTS_FILE="${TEST_DIR}/limine-defaults"
TRACKED_PATHS="$ROOT_EFI"

state_dir_path() { printf '%s/state\n' "$TEST_DIR"; }
limine_default_config_path() { printf '%s\n' "$DEFAULTS_FILE"; }
control_owner_uid() { id -u; }
durable_sync() { :; }
limine_enrollment_hooks_present() { return 1; }
read_lifecycle() { :; }
list_enrolled_paths() { printf '%s\n' "$TRACKED_PATHS"; }

mkdir -p "$(transactions_dir_path)" "$(dirname "$ROOT_EFI")"
chmod 700 "$(state_dir_path)" "$(transactions_dir_path)"
printf '%s\n' \
  'ENABLE_VERIFICATION=no' \
  'ENABLE_ENROLL_LIMINE_CONFIG=yes' \
  'COMMANDS_BEFORE_SAVE="limine-reset-enroll"' \
  'COMMANDS_AFTER_SAVE="limine-enroll-config"' \
  > "$DEFAULTS_FILE"
printf 'root\n' > "$ROOT_EFI"
printf 'older\n' > "$OLDER_EFI"
printf 'latest\n' > "$LATEST_EFI"

create_ownership_pair() {
  local transaction_id="$1" paths="$2" transaction_dir timestamp settings
  local managed_document tracking_document
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  mkdir -p "$transaction_dir" || return 1
  chmod 700 "$transaction_dir" || return 1
  timestamp=2026-09-04T00:00:00Z
  settings=$(current_limine_managed_settings_record) || return 1
  managed_document=$(jq -cn \
    --argjson schema "$MANAGED_SETTINGS_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg id "$transaction_id" \
    --arg timestamp "$timestamp" --argjson settings "$settings" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      recorded_at: $timestamp,
      source: "repair",
      settings: $settings
    }') || return 1
  tracking_document=$(jq -cn \
    --argjson schema "$TRACKING_OWNERSHIP_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg id "$transaction_id" \
    --arg timestamp "$timestamp" --argjson paths "$paths" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      recorded_at: $timestamp,
      paths: $paths
    }') || return 1
  validate_managed_settings_record_json "$transaction_id" "$managed_document" || return 1
  validate_tracking_ownership_record_json "$transaction_id" "$tracking_document" || return 1
  printf '%s\n' "$managed_document" > "${transaction_dir}/managed-settings.json"
  printf '%s\n' "$tracking_document" > "${transaction_dir}/tracking-ownership.json"
  chmod 600 "${transaction_dir}/managed-settings.json" \
    "${transaction_dir}/tracking-ownership.json"
}

ownership_references() {
  local transaction_id="$1" transaction_dir managed tracking
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  managed=$(transaction_artifact_reference "${transaction_dir}/managed-settings.json" \
    "$MANAGED_SETTINGS_SCHEMA_VERSION") || return 1
  tracking=$(transaction_artifact_reference "${transaction_dir}/tracking-ownership.json" \
    "$TRACKING_OWNERSHIP_SCHEMA_VERSION") || return 1
  jq -cn --argjson managed "$managed" --argjson tracking "$tracking" \
    '{managed:$managed,tracking:$tracking}'
}

attempt_manifest() {
  local transaction_id="$1" previous="$2" references="$3" managed tracking
  managed=$(jq -c '.managed' <<< "$references") || return 1
  tracking=$(jq -c '.tracking' <<< "$references") || return 1
  jq -cn --arg id "$transaction_id" --argjson previous "$previous" \
    --argjson managed "$managed" --argjson tracking "$tracking" '{
      id: $id,
      kind: "recovery-attempt",
      recovery: {previous_attempt:$previous},
      domain_records: {managed_settings:$managed,tracking_ownership:$tracking}
    }'
}

assert_selected_paths() {
  local name="$1" previous_manifest="$2" expected="$3"
  _recovery_previous_manifest_json="$previous_manifest"
  _discovered_efi_files=("$ROOT_EFI")
  prepare_artifact_ownership || fail_test "${name}: ownership preparation failed"
  [[ "$(jq -Sc . <<< "$_repair_tracking_paths_json")" == "$(jq -Sc . <<< "$expected")" ]] \
    || fail_test "${name}: selected the wrong ownership paths"
}

create_ownership_pair "$STABLE_ID" '[]'
create_ownership_pair "$ROOT_ID" "$(jq -cn --arg path "$ROOT_EFI" '[$path]')"
create_ownership_pair "$OLDER_ID" \
  "$(jq -cn --arg root "$ROOT_EFI" --arg older "$OLDER_EFI" '[$older,$root] | sort')"
create_ownership_pair "$LATEST_ID" \
  "$(jq -cn --arg root "$ROOT_EFI" --arg latest "$LATEST_EFI" '[$latest,$root] | sort')"

stable_refs=$(ownership_references "$STABLE_ID")
root_refs=$(ownership_references "$ROOT_ID")
older_refs=$(ownership_references "$OLDER_ID")
latest_refs=$(ownership_references "$LATEST_ID")
_lifecycle_state=recovery-required
_lifecycle_json=$(jq -cn --argjson refs "$stable_refs" '{
  managed_settings:$refs.managed,
  tracking_ownership:$refs.tracking
}')
_recovery_root_manifest_json=$(jq -cn --arg id "$ROOT_ID" --argjson refs "$root_refs" '{
  id:$id,
  kind:"root",
  domain_records:{managed_settings:$refs.managed,tracking_ownership:$refs.tracking}
}')

no_refs='{"managed":null,"tracking":null}'
managed_only=$(jq -cn --argjson refs "$latest_refs" \
  '{managed:$refs.managed,tracking:null}')
root_expected=$(jq -cn --arg path "$ROOT_EFI" '[$path]')
latest_expected=$(jq -cn --arg root "$ROOT_EFI" --arg latest "$LATEST_EFI" \
  '[$latest,$root] | sort')

assert_selected_paths no-records "$(attempt_manifest "$LATEST_ID" null "$no_refs")" \
  "$root_expected"
assert_selected_paths managed-only \
  "$(attempt_manifest "$LATEST_ID" null "$managed_only")" "$root_expected"
assert_selected_paths complete-pair \
  "$(attempt_manifest "$LATEST_ID" null "$latest_refs")" "$latest_expected"

older_reference='{"id":"33333333-3333-3333-3333-333333333333"}'
older_manifest=$(attempt_manifest "$OLDER_ID" null "$older_refs")
validate_incident_reference() {
  [[ "$1" == "$older_reference" ]] || return 1
  _manifest_json="$older_manifest"
}
older_expected=$(jq -cn --arg root "$ROOT_EFI" --arg older "$OLDER_EFI" \
  '[$older,$root] | sort')
assert_selected_paths older-complete-pair \
  "$(attempt_manifest "$LATEST_ID" "$older_reference" "$no_refs")" "$older_expected"

tracking_only=$(jq -cn --argjson refs "$latest_refs" \
  '{managed:null,tracking:$refs.tracking}')
tracking_manifest=$(attempt_manifest "$LATEST_ID" null "$tracking_only")
_recovery_previous_manifest_json="$tracking_manifest"
if load_latest_recovery_ownership_records 2>/dev/null; then
  fail_test "tracking-only recovery ownership was accepted"
fi

domain_manifest=$(jq -cn --argjson refs "$latest_refs" '{
  kind:"root",
  status:"transition",
  operation:"test-ownership",
  domain_records:{
    bootnext:null,
    producer:null,
    final_proof:null,
    firmware:null,
    managed_settings:null,
    tracking_ownership:$refs.tracking,
    unconfigure:null,
    windows:null
  }
}')
if validate_transaction_domain_records "$LATEST_ID" "$domain_manifest" 2>/dev/null; then
  fail_test "tracking-only transaction manifest was accepted"
fi

printf 'producer ownership tests passed\n'
