#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2154 # Hermetic overrides and sourced globals are intentional.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-recovery-publication.XXXXXX")
SYNC_LOG="${TEST_DIR}/sync.log"
ATTEMPT_ID=11111111-1111-1111-1111-111111111111
ROOT_ID=22222222-2222-2222-2222-222222222222

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "${ROOT_DIR}/lib/lifecycle.sh"

state_dir_path() { printf '%s/state\n' "$TEST_DIR"; }
control_owner_uid() { id -u; }
durable_sync() { printf '%s\n' "$1" >> "$SYNC_LOG"; }

root_reference=$(jq -cn --arg id "$ROOT_ID" '{
  id:$id,
  kind:"root",
  operation:"package-producer",
  ordinal:0,
  path:"/root-incident.json",
  sha256:("a" * 64),
  status:"failed"
}')
attempt_reference=$(jq -cn --arg id "$ATTEMPT_ID" '{
  id:$id,
  kind:"attempt",
  operation:"producer-recovery",
  ordinal:1,
  path:"/attempt-incident.json",
  sha256:("b" * 64),
  status:"failed"
}')
root_seal=$(jq -cn --arg manifest "/root-manifest.json" \
  '{kind:"root",manifest:$manifest}')
root_manifest_document='{
  "kind":"root",
  "operation":"package-producer",
  "prior_state":"active",
  "target_state":"active",
  "file_rollback_policy":"preserve",
  "domain_records":{"producer":{"schema_version":1}}
}'
TEST_PUBLICATION_MODE=failed

read_incident_seal() {
  local status=failed
  [[ "$TEST_PUBLICATION_MODE" == failed ]] || status=completed
  _incident_json=$(jq -cn --arg status "$status" --argjson root "$root_reference" '{
    kind:"attempt",
    incident_status:$status,
    root_incident:$root,
    ordinal:1
  }')
}

incident_reference_from_json() {
  if [[ "$TEST_PUBLICATION_MODE" == failed ]]; then
    printf '%s\n' "$attempt_reference"
  else
    jq -c '.status = "completed"' <<< "$attempt_reference"
  fi
}

validate_incident_reference() {
  _incident_json="$root_seal"
  _manifest_json="$root_manifest_document"
}

read_transaction_manifest() {
  _manifest_json='{
    "operation":"producer-recovery",
    "target_state":"active",
    "completed_at":"2026-09-04T00:00:00Z",
    "domain_records":{
      "final_proof":{"path":"/final-proof.json","schema_version":2,"sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
      "managed_settings":null,
      "tracking_ownership":null
    }
  }'
}

read_lifecycle() {
  if [[ "$TEST_PUBLICATION_MODE" == failed ]]; then
    _lifecycle_state=recovery-required
    _lifecycle_json=$(jq -cn --argjson root "$root_reference" \
      --argjson attempt "$attempt_reference" '{
        transaction:{
          root_incident:$root,
          last_recovery_attempt:$attempt,
          attempt_count:1
        }
      }')
  else
    _lifecycle_state=active
    _lifecycle_json=$(jq -cn --arg id "$ATTEMPT_ID" '{
      last_recovery:{final_attempt:{id:$id}}
    }')
  fi
}

assert_lifecycle_resynced() {
  local name="$1" lifecycle parent
  lifecycle=$(lifecycle_file_path)
  parent=$(dirname "$lifecycle")
  [[ $(grep -Fxc "$lifecycle" "$SYNC_LOG") -eq 1 \
    && $(grep -Fxc "$parent" "$SYNC_LOG") -eq 1 ]] \
    || fail_test "${name}: lifecycle durability was not reconfirmed"
}

mkdir -p "$(state_dir_path)"
mkdir -p "$(dirname "$(lifecycle_manifest_path "$ATTEMPT_ID")")"
printf '{}\n' > "$(lifecycle_manifest_path "$ATTEMPT_ID")"
: > "$SYNC_LOG"
_transaction_active=true
_transaction_id="$ATTEMPT_ID"
_OMASECBOOT_LIMINE_LOCK_OWNED=true
_OMASECBOOT_REPAIR_LOCK_OWNED=true
publish_failed_recovery_attempt || fail_test "failed publication retry was rejected"
assert_lifecycle_resynced failed-publication

: > "$SYNC_LOG"
TEST_PUBLICATION_MODE=resolved
_transaction_active=true
_transaction_id="$ATTEMPT_ID"
publish_resolved_recovery_attempt || fail_test "resolved publication retry was rejected"
assert_lifecycle_resynced resolved-publication

printf 'recovery publication tests passed\n'
