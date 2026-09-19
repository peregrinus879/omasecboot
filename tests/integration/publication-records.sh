#!/usr/bin/env bash
# Immutable publication journal, manifest compatibility and failure-frontier tests.
# shellcheck disable=SC2154 # Lifecycle/record modules supply transaction globals.
set -euo pipefail
umask 077
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/../..")
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init publication-records
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/lifecycle.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/records.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/software.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/sign.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/producer-session.sh"
# Sourcing supplies the pure comparator; context acquisition is fixture-only.
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/publication.sh"
# shellcheck disable=SC2329
publication_collect_stable_context() { fail_test 'unexpected live context collection'; }
# shellcheck disable=SC2329,SC2154
state_dir_path() { printf '%s/state\n' "$CASE_DIR"; }
# shellcheck disable=SC2329
limine_lock_path() { printf '%s/boot.lock\n' "$CASE_DIR"; }
# shellcheck disable=SC2329
snapshot_restore_lock_path() { printf '%s/restore.lock\n' "$CASE_DIR"; }
# shellcheck disable=SC2329
pacman_database_lock_path() { printf '%s/pacman.lock\n' "$CASE_DIR"; }
# shellcheck disable=SC2329
control_owner_uid() { id -u; }
# shellcheck disable=SC2329
require_control_root() { :; }
INVOCATION=11111111-1111-4111-8111-111111111111
SYNC_FAULT=''
# shellcheck disable=SC2329
durable_sync() {
  local count
  if [[ -n $SYNC_FAULT && $1 == "$TXDIR" && ! -e $CASE_DIR/sync-failed && -e $TXDIR/publication-1.json ]]; then
    count=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
    if [[ $SYNC_FAULT == record && $count == 0 || $SYNC_FAULT == head && $count == 1 ]]; then
      touch "$CASE_DIR/sync-failed"
      return 1
    fi
  fi
  sync -f "$1"
}
setup_case() {
  local self=$BASHPID
  CASE_DIR=$TEST_DIR/$1
  mkdir -p "$CASE_DIR/esp"
  printf 'configuration\n' >"$CASE_DIR/esp/limine.conf"
  with_boot_repair_lock
  if [[ $1 == mixed-version-recovery ]]; then begin_lifecycle_transaction prepare-secure-boot disabled
  else begin_lifecycle_transaction sign active; fi
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  [[ $TXDIR == "$CASE_DIR/state/transactions/"* && -d $TXDIR ]] || return 1
  INTENT=$(jq -cn --arg esp "$CASE_DIR/esp" --arg source "$CASE_DIR/source" \
    --arg hash "$(sha256_file "$CASE_DIR/esp/limine.conf")" \
    '{operation:"add-kernel",esp_path:$esp,configuration:{path:($esp+"/limine.conf"),sha256:$hash},
      resources:[{id:"kernel",role:"kernel",source:$source,target:($esp+"/kernel"),sha256:$hash}]}')
  owner=$(manifest_owner_json "$self")
  SESSION=$(jq -cn --argjson owner "$owner" --arg boot "$(boot_id_value)" '{worker:$owner,supervisor:$owner,boot_id:$boot}')
}
count=0
run_case() {
  local name=$1 callback=$2
  # List mode prints every registration, loop-generated names included, and
  # runs nothing; the parallel runner consumes it.
  if [[ -n ${PUBLICATION_RECORDS_LIST:-} ]]; then printf '%s\n' "$name"; return 0; fi
  # Explicit focused runs report their selection; the default runs every case.
  # shellcheck disable=SC2053 # The optional selector is a documented glob.
  [[ -z ${PUBLICATION_RECORDS_CASE:-} || $name == $PUBLICATION_RECORDS_CASE ]] || return 0
  (setup_case "$name"; "$callback")
  printf 'PASS: publication records/%s\n' "$name"
  count=$((count+1))
}
compatibility() {
  local current=$_manifest_json old altered
  old=$(jq -c 'del(.publication_records) | .schema_version=2' <<<"$current")
  validate_transaction_manifest_json "$_transaction_id" "$old"
  altered=$(jq -c '.publication_records=[]' <<<"$old")
  if validate_transaction_manifest_json "$_transaction_id" "$altered" false; then return 1; fi
  altered=$(jq -c 'del(.publication_records)' <<<"$current")
  if validate_transaction_manifest_json "$_transaction_id" "$altered" false; then return 1; fi
  altered=$(jq -c '.publication_records=null' <<<"$current")
  if validate_transaction_manifest_json "$_transaction_id" "$altered" false; then return 1; fi
  if write_transaction_manifest_json "$old"; then return 1; fi
  printf '%s\n' "$old" >"$TXDIR/manifest.json"
  read_transaction_manifest "$_transaction_id"
  [[ $(jq -r '.schema_version' <<<"$_manifest_json") == 2 ]]
  if append_publication_record "$INVOCATION" intent "$INTENT"; then return 1; fi
}
rollback_boundary() {
  local before policy
  before=$(sha256_file "$TXDIR/manifest.json")
  if append_publication_record "$INVOCATION" intent "$INTENT"; then return 1; fi
  [[ $(sha256_file "$TXDIR/manifest.json") == "$before" && ! -e $TXDIR/publication-1.json ]]
  publication_authority_begin "$INVOCATION" "$INTENT"
  policy=$(jq -r '.file_rollback_policy' "$TXDIR/manifest.json")
  [[ $policy == preserve ]]
}
ordering() {
  local first before bad
  publication_authority_begin "$INVOCATION" "$INTENT"
  first=$_publication_record_reference
  append_publication_record "$INVOCATION" intent "$INTENT"
  [[ $_publication_record_reference == "$first" && ! -e $TXDIR/publication-2.json ]]
  bad=$(jq -c '.resources[0].source += "-different"' <<<"$INTENT")
  if append_publication_record "$INVOCATION" intent "$bad"; then return 1; fi
  [[ ! -e $TXDIR/publication-2.json ]]
  append_publication_record "$INVOCATION" session "$SESSION"
  before=$(sha256_file "$TXDIR/manifest.json")
  bad=$(jq -c '.publication_records = .publication_records[0:1]' "$TXDIR/manifest.json")
  if write_transaction_manifest_json "$bad"; then return 1; fi
  [[ $(sha256_file "$TXDIR/manifest.json") == "$before" ]]
}
sync_retry() {
  local before
  preserve_transaction_files_on_failure
  SYNC_FAULT=$SYNC_KIND
  if append_publication_record "$INVOCATION" intent "$INTENT"; then return 1; fi
  [[ -e $CASE_DIR/sync-failed ]]
  before=$(sha256_file "$TXDIR/publication-1.json")
  append_publication_record "$INVOCATION" intent "$INTENT"
  [[ $(sha256_file "$TXDIR/publication-1.json") == "$before" && ! -e $TXDIR/publication-2.json ]]
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 1' "$_manifest_json"
}
tamper() {
  publication_authority_begin "$INVOCATION" "$INTENT"
  printf ' ' >>"$TXDIR/publication-1.json"
  if read_transaction_manifest "$_transaction_id"; then return 1; fi
}
unknown_record() {
  preserve_transaction_files_on_failure
  if append_publication_record "$INVOCATION" unrecognized '{}'; then return 1; fi
  [[ ! -e $TXDIR/publication-1.json ]]
}
no_legacy_recovery() {
  local before root attempt
  publication_authority_begin "$INVOCATION" "$INTENT"
  append_publication_record "$INVOCATION" session "$SESSION"
  read_transaction_manifest "$_transaction_id"
  root=$_manifest_json
  if software_recovery_root_is_supported "$root"; then return 1; fi
  if recovery_operation_for_root_manifest "$root"; then return 1; fi
  attempt=$(jq -c '.publication_records=[]' <<<"$root")
  if validate_recovery_manifest_evolution "$root" "$attempt" software-recovery; then return 1; fi
  before=$(sha256_file "$TXDIR/publication-1.json")
  rollback_and_mark_recovery 17 'fixture session interruption'
  read_lifecycle
  [[ $_lifecycle_state == recovery-required ]]
  read_incident_seal "$(basename "$TXDIR")"
  [[ $(sha256_file "$TXDIR/publication-1.json") == "$before" ]]
  load_recovery_context
  if run_registered_recovery_locked; then return 1; fi
  [[ $(jq -r '.transaction.attempt_count' "$(state_dir_path)/lifecycle.json") == 0 ]]
}
no_partial_completion() {
  publication_authority_begin "$INVOCATION" "$INTENT"
  if commit_lifecycle_transaction; then return 1; fi
  read_lifecycle
  [[ $_lifecycle_state == transition ]]
}
producer_recovery_exclusion() {
  local owner boot record root without self=$BASHPID
  commit_lifecycle_transaction
  begin_lifecycle_transaction producer-limine active
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  preserve_transaction_files_on_failure
  owner=$(manifest_owner_json "$self")
  boot=$(boot_id_value)
  record=$(jq -cn --arg id "$_transaction_id" --arg timestamp "$(utc_timestamp)" \
    --arg boot "$boot" --arg version "$OMASECBOOT_VERSION" --argjson owner "$owner" \
    '{schema_version:1,transaction_id:$id,writer_version:$version,created_at:$timestamp,
      producer_class:"limine",subtype:"entry-tool",caller:"limine-entry-tool",operation:"producer-limine",
      owner:($owner + {boot_id:$boot,identity_kind:"script",identity:"/usr/bin/limine-entry-tool"})}')
  persist_transaction_domain_record producer producer.json 1 validate_producer_record_json '[]' "$record"
  read_transaction_manifest "$_transaction_id"
  [[ $(recovery_operation_for_root_manifest "$_manifest_json") == producer-recovery ]]
  publication_authority_begin "$INVOCATION" "$INTENT"
  read_transaction_manifest "$_transaction_id"
  root=$_manifest_json
  without=$(jq -c '.publication_records=[]' <<<"$root")
  validate_transaction_manifest_json "$_transaction_id" "$without"
  [[ $(recovery_operation_for_root_manifest "$without") == producer-recovery ]]
  if recovery_operation_for_root_manifest "$root"; then return 1; fi
  rollback_and_mark_recovery 18 'fixture interrupted managed producer'
  load_recovery_context
  if begin_lifecycle_recovery_attempt producer-recovery; then return 1; fi
  [[ $(jq -r '.transaction.attempt_count' "$(state_dir_path)/lifecycle.json") == 0 ]]
}
mixed_version_recovery() {
  local old id=$_transaction_id old_hash seal_hash
  old=$(jq -c 'del(.publication_records) | .schema_version=2' <<<"$_manifest_json")
  printf '%s\n' "$old" >"$TXDIR/manifest.json"
  read_transaction_manifest "$id"
  rollback_and_mark_recovery 17 'historical preparation interrupted'
  old_hash=$(sha256_file "$TXDIR/manifest.json")
  seal_hash=$(sha256_file "$TXDIR/incident.json")
  load_recovery_context
  begin_lifecycle_recovery_attempt software-recovery
  read_transaction_manifest "$_transaction_id"
  json_is '.schema_version == 3 and .publication_records == [] and .kind == "recovery-attempt"' "$_manifest_json"
  [[ $(sha256_file "$TXDIR/manifest.json") == "$old_hash" && $(sha256_file "$TXDIR/incident.json") == "$seal_hash" ]]
}

# Complete historical directory observations, from / to the target's parent.
# These synthetic identities/mounts describe one old view, not the live host.
# Only transaction records, retained ordinary bytes and a disposable stage are
# real filesystem evidence; every write stays under the harness's owned scratch.
directory_history() {
  local path paths='[]'
  PARENT_PATH=$CASE_DIR/esp/entries
  CHILD_PATH=$PARENT_PATH/linux
  path=$CHILD_PATH
  while [[ $path != / ]]; do
    paths=$(jq -c --arg path "$path" '[$path] + .' <<<"$paths")
    path=$(dirname "$path")
  done
  HISTORY=$(jq -c --argjson uid "$(id -u)" --argjson gid "$(id -g)" '
    ["/"] + . | to_entries | map({path:.value,mount_id:"42",state:{
      kind:"directory",identity:("8800:" + (.key + 1 | tostring)),sha256:null,
      link_target:null,mode:16832,uid:$uid,gid:$gid}})' <<<"$paths")
  printf 'ordinary publication fixture bytes\n' >"$CASE_DIR/source"
  INTENT=$(jq -c --arg target "$CHILD_PATH/${1:-kernel}" --arg hash "$(sha256_file "$CASE_DIR/source")" '
    .publication={kind:"addition",model:"directory-journal-fixture-v1"} |
    .resources[0].target=$target | .resources[0].sha256=$hash' <<<"$INTENT")
  PARENT_PENDING=$(directory_pending_body "$PARENT_PATH")
  PARENT_CREATED=$(directory_created_body "$PARENT_PATH")
  CHILD_PENDING=$(directory_pending_body "$CHILD_PATH")
  CHILD_CREATED=$(directory_created_body "$CHILD_PATH")
  # Optional complete-basis fixtures need the context before the session. The
  # absent variant keeps the same addition model but omits original context.
  if [[ -n ${2:-} ]]; then context_fixture; fi
  if [[ ${2:-} == start ]]; then
    original_configuration_fixture
    append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
  else
    preserve_transaction_files_on_failure
    append_publication_record "$INVOCATION" intent "$INTENT"
    if [[ ${2:-} == bound ]]; then append_publication_record "$INVOCATION" context "$CONTEXT"; fi
  fi
  append_publication_record "$INVOCATION" session "$SESSION"
}
directory_pending_body() {
  jq -ce --arg path "$1" --arg id "$(sha256_text "$1")" --arg parent "$(dirname "$1")" '
    .[] | select(.path == $parent) | {id:$id,path:$path,mount_namespace:"mnt:[8800]",
      parent:{path:.path,state:.state,mount_id:.mount_id}}' <<<"$HISTORY"
}
directory_created_body() {
  jq -ce --arg path "$1" --arg id "$(sha256_text "$1")" '
    .[] | select(.path == $path) | {id:$id,path:.path,state:.state,mount_id:.mount_id}' <<<"$HISTORY"
}
ordered_directory_records() {
  append_publication_record "$INVOCATION" directory-pending "$PARENT_PENDING"
  append_publication_record "$INVOCATION" directory-created "$PARENT_CREATED"
  append_publication_record "$INVOCATION" directory-pending "$CHILD_PENDING"
  append_publication_record "$INVOCATION" directory-created "$CHILD_CREATED"
}
journal_fingerprint() {
  local -a files
  shopt -s nullglob
  files=("$TXDIR/manifest.json" "$TXDIR"/publication-*.json "$TXDIR"/publication-data-*)
  sha256sum -- "${files[@]}"
}
validate_historical_journal() {
  # Exercise both the cold semantic reader and its reference-rechecking cache.
  _publication_validation_cache=()
  read_transaction_manifest "$_transaction_id"
  validate_publication_records "$_transaction_id" "$_manifest_json"
}
refuse_directory_record() {
  local kind=$1 body=$2 before ordinal previous document reference candidate path
  before=$(journal_fingerprint)
  ordinal=$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")
  path=$TXDIR/publication-$ordinal.json
  [[ ! -e $path && ! -L $path ]]
  if append_publication_record "$INVOCATION" "$kind" "$body"; then
    fail_test "$kind contradiction accepted by append"
  fi
  [[ ! -e $path && ! -L $path && $(journal_fingerprint) == "$before" ]] ||
    fail_test "$kind refusal changed the journal"

  # Independently hash-bind the rejected candidate to the actual accepted prefix.
  # Shape and reference validation must pass: only the semantic join is invalid.
  previous=$(jq -c '.publication_records[-1]' "$TXDIR/manifest.json")
  document=$(jq -cn --arg id "$_transaction_id" --arg invocation "$INVOCATION" \
    --arg kind "$kind" --argjson body "$body" --argjson ordinal "$ordinal" \
    --argjson previous "$previous" --arg timestamp "$(utc_timestamp)" --arg version "$OMASECBOOT_VERSION" '
    {schema_version:1,transaction_id:$id,invocation:$invocation,ordinal:$ordinal,previous:$previous,
      kind:$kind,body:$body,recorded_at:$timestamp,writer_version:$version}')
  validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document"
  printf '%s\n' "$document" >"$path"
  reference=$(transaction_artifact_reference "$path" 1)
  validate_artifact_reference_file "$reference" "$TXDIR"
  candidate=$(jq -c --argjson reference "$reference" '.publication_records += [$reference]' "$TXDIR/manifest.json")
  validate_transaction_manifest_json "$_transaction_id" "$candidate" false
  _publication_validation_cache=()
  if validate_publication_records "$_transaction_id" "$candidate"; then
    fail_test "$kind hash-valid historical contradiction accepted"
  fi
  if validate_publication_records "$_transaction_id" "$candidate" "$document"; then
    fail_test "$kind hash-valid pending contradiction accepted"
  fi
  # This unbound fixture record is ours; the accepted prefix stays immutable.
  rm -- "$path"
  [[ $(journal_fingerprint) == "$before" ]]
  validate_historical_journal
}
retain_stage_fixture() {
  local temporary retained ready metadata device inode mode uid gid signing=${1:-bytes}
  temporary=$(mktemp "$TXDIR/.publication-input.XXXXXX")
  retained=$TXDIR/publication-data-$INVOCATION-kernel
  cp -- "$CASE_DIR/source" "$temporary"
  # Ordinary distinct bytes stand for the already-retained signed output. This
  # tests provenance joins only; no signing tool, certificate or key is involved.
  if [[ $signing == local-efi ]]; then printf 'fixture signed representation\n' >>"$temporary"; fi
  cp -- "$temporary" "$retained"
  RETAINED_REFERENCE=$(jq -cn --arg path "$retained" --arg hash "$(sha256_file "$retained")" \
    --argjson bytes "$(stat -c %s "$retained")" '{path:$path,sha256:$hash,bytes:$bytes}')
  validate_publication_retained_file "$_transaction_id" "$RETAINED_REFERENCE"
  ready=$(jq -cn --arg temporary "$temporary" --argjson file "$RETAINED_REFERENCE" \
    --arg source "$(sha256_file "$CASE_DIR/source")" --arg signing "$signing" '
    {id:"kernel",file:$file,source_sha256:$source,signing:$signing,temporary:$temporary}')
  append_publication_record "$INVOCATION" input-ready "$ready"
  append_publication_record "$INVOCATION" retained "$(jq -c 'del(.temporary)' <<<"$ready")"
  mkdir -p "$CHILD_PATH"
  STAGED_PATH=$(mktemp "$CHILD_PATH/.omasecboot-$INVOCATION-kernel.XXXXXX.stage")
  cp -- "$retained" "$STAGED_PATH"
  metadata=$(stat -c '%d %i %f %u %g' "$STAGED_PATH")
  read -r device inode mode uid gid <<<"$metadata"
  STAGED_STATE=$(jq -cn --arg identity "$device:$inode" --arg hash "$(sha256_file "$STAGED_PATH")" \
    --argjson mode "$((16#$mode))" --argjson uid "$uid" --argjson gid "$gid" '
    {kind:"file",identity:$identity,sha256:$hash,link_target:null,mode:$mode,uid:$uid,gid:$gid}')
  STAGE=$(stage_from_history "$HISTORY")
}
stage_from_history() {
  # One coherent observation supplies components, dependencies and mount view.
  # Adversarial cases change this observation, not schema-required correlations.
  jq -cn --argjson history "$1" --arg parent "$CHILD_PATH" --arg stage "$STAGED_PATH" \
    --argjson state "$STAGED_STATE" --argjson retained "$RETAINED_REFERENCE" '
    {id:"kernel",target:($parent+"/kernel"),
      before:{kind:"absent",identity:null,sha256:null,link_target:null,mode:0,uid:0,gid:0},
      retained:$retained,stage:{path:$stage,state:$state},parent:{path:$parent,
        components:($history | map({path,entry:.state,directory:.state})),
        dependencies:($history | to_entries | map({path:.value.path,entry:.value.state,
          parent_identity:(if .key == 0 then null else $history[.key-1].state.identity end)}))},
      mount_view:{namespace:"mnt:[8800]",directories:($history | map({path,mount_id,identity:.state.identity}))}}'
}
ordered_parent_child() {
  directory_history
  ordered_directory_records
  validate_historical_journal
  json_is '.publication_records | length == 6' "$_manifest_json"
  [[ ! -e $PARENT_PATH ]]
}
child_before_created() {
  directory_history
  append_publication_record "$INVOCATION" directory-pending "$PARENT_PENDING"
  refuse_directory_record directory-pending "$CHILD_PENDING"
  append_publication_record "$INVOCATION" directory-created "$PARENT_CREATED"
  append_publication_record "$INVOCATION" directory-pending "$CHILD_PENDING"
  append_publication_record "$INVOCATION" directory-created "$CHILD_CREATED"
  validate_historical_journal
}
child_parent_mismatch() {
  local bad
  directory_history
  append_publication_record "$INVOCATION" directory-pending "$PARENT_PENDING"
  append_publication_record "$INVOCATION" directory-created "$PARENT_CREATED"
  case $MISMATCH in
    identity) bad=$(jq -c '.parent.state.identity="8800:999"' <<<"$CHILD_PENDING") ;;
    metadata) bad=$(jq -c '.parent.state.mode+=1' <<<"$CHILD_PENDING") ;;
    mount) bad=$(jq -c '.parent.mount_id="43"' <<<"$CHILD_PENDING") ;;
    namespace) bad=$(jq -c '.mount_namespace="mnt:[8801]"' <<<"$CHILD_PENDING") ;;
    *) return 1 ;;
  esac
  refuse_directory_record directory-pending "$bad"
  append_publication_record "$INVOCATION" directory-pending "$CHILD_PENDING"
  append_publication_record "$INVOCATION" directory-created "$CHILD_CREATED"
  validate_historical_journal
}
late_parent_after_descendant() {
  directory_history
  # A child can have an originally existing parent with no creation records.
  append_publication_record "$INVOCATION" directory-pending "$CHILD_PENDING"
  refuse_directory_record directory-pending "$PARENT_PENDING"
  append_publication_record "$INVOCATION" directory-created "$CHILD_CREATED"
  validate_historical_journal
}
late_ancestor_after_descendant() {
  local descendant
  directory_history version/kernel
  descendant=$(directory_pending_body "$CHILD_PATH/version")
  append_publication_record "$INVOCATION" directory-pending "$descendant"
  refuse_directory_record directory-pending "$PARENT_PENDING"
}
descendant_before_ancestor_created() {
  local descendant
  directory_history version/kernel
  # A=entries, B=linux, C=version. B is claimed existing, with no pending
  # record of its own, so the immediate-parent check cannot catch unresolved A.
  descendant=$(directory_pending_body "$CHILD_PATH/version")
  append_publication_record "$INVOCATION" directory-pending "$PARENT_PENDING"
  refuse_directory_record directory-pending "$descendant"
}
descendant_after_ancestor_created() {
  local descendant
  directory_history version/kernel
  descendant=$(directory_pending_body "$CHILD_PATH/version")
  append_publication_record "$INVOCATION" directory-pending "$PARENT_PENDING"
  append_publication_record "$INVOCATION" directory-created "$PARENT_CREATED"
  append_publication_record "$INVOCATION" directory-pending "$descendant"
  validate_historical_journal
  json_is '.publication_records | length == 5' "$_manifest_json"
}
descendant_ancestor_namespace_mismatch() {
  local descendant bad
  directory_history version/kernel
  descendant=$(directory_pending_body "$CHILD_PATH/version")
  append_publication_record "$INVOCATION" directory-pending "$PARENT_PENDING"
  append_publication_record "$INVOCATION" directory-created "$PARENT_CREATED"
  # The created receipt resolves A's ordering, but C must still share A's
  # namespace even though its immediate parent B has no journal records.
  bad=$(jq -c '.mount_namespace="mnt:[8801]"' <<<"$descendant")
  refuse_directory_record directory-pending "$bad"
  append_publication_record "$INVOCATION" directory-pending "$descendant"
  validate_historical_journal
}
matching_stage() {
  directory_history
  ordered_directory_records
  retain_stage_fixture
  append_publication_record "$INVOCATION" boot-stage "$STAGE"
  validate_historical_journal
  json_is '.publication_records | length == 9' "$_manifest_json"
}
stage_parent_mismatch() {
  local observation bad
  directory_history
  ordered_directory_records
  retain_stage_fixture
  # entries is a created non-immediate ancestor of the stage. Contradict its
  # original parent (the ESP), while both created-directory states still match.
  case $MISMATCH in
    identity) observation=$(jq -c --arg path "$CASE_DIR/esp" 'map(if .path == $path then .state.identity="8800:999" else . end)' <<<"$HISTORY") ;;
    metadata) observation=$(jq -c --arg path "$CASE_DIR/esp" 'map(if .path == $path then .state.mode+=1 else . end)' <<<"$HISTORY") ;;
    mount) observation=$(jq -c --arg path "$CASE_DIR/esp" 'map(if .path == $path then .mount_id="43" else . end)' <<<"$HISTORY") ;;
    namespace) observation=$HISTORY ;;
    *) return 1 ;;
  esac
  bad=$(stage_from_history "$observation")
  if [[ $MISMATCH == namespace ]]; then bad=$(jq -c '.mount_view.namespace="mnt:[8801]"' <<<"$bad"); fi
  refuse_directory_record boot-stage "$bad"
  append_publication_record "$INVOCATION" boot-stage "$STAGE"
  validate_historical_journal
}
stage_before_created() {
  directory_history
  append_publication_record "$INVOCATION" directory-pending "$PARENT_PENDING"
  retain_stage_fixture
  refuse_directory_record boot-stage "$STAGE"
  append_publication_record "$INVOCATION" directory-created "$PARENT_CREATED"
  append_publication_record "$INVOCATION" directory-pending "$CHILD_PENDING"
  append_publication_record "$INVOCATION" directory-created "$CHILD_CREATED"
  append_publication_record "$INVOCATION" boot-stage "$STAGE"
  validate_historical_journal
}
late_parent_after_stage() {
  directory_history
  retain_stage_fixture
  append_publication_record "$INVOCATION" boot-stage "$STAGE"
  refuse_directory_record directory-pending "$PARENT_PENDING"
}
directory_preserve_only() {
  local before altered
  matching_stage
  before=$(journal_fingerprint)
  altered=$(jq -c '.file_rollback_policy="restore"' "$TXDIR/manifest.json")
  if validate_transaction_manifest_json "$_transaction_id" "$altered" false; then
    fail_test 'nonempty directory journal accepted restore policy'
  fi
  if write_transaction_manifest_json "$altered"; then
    fail_test 'nonempty directory journal published restore policy'
  fi
  [[ $(journal_fingerprint) == "$before" ]]
  validate_historical_journal
}
historical_sealed_directories() {
  local before seal lifecycle journal id=$_transaction_id
  matching_stage
  journal=$(jq -c '.publication_records' "$TXDIR/manifest.json")
  rollback_and_mark_recovery 19 'fixture directory publication interrupted'
  read_incident_seal "$id"
  before=$(journal_fingerprint)
  seal=$(sha256_file "$TXDIR/incident.json")
  lifecycle=$(sha256_file "$(state_dir_path)/lifecycle.json")
  # Old stage/ancestor inodes have ceased to exist. Immutable retained bytes
  # remain, and historical validation must not demand live custody of the old ESP.
  rm -rf -- "$PARENT_PATH"
  [[ ! -e $PARENT_PATH && ! -e $STAGED_PATH ]]
  validate_historical_journal
  [[ $(jq -c '.publication_records' <<<"$_manifest_json") == "$journal" ]]
  read_incident_seal "$id"
  load_recovery_context
  if run_registered_recovery_locked; then fail_test 'sealed directory journal entered legacy recovery'; fi
  [[ $(journal_fingerprint) == "$before" && $(sha256_file "$TXDIR/incident.json") == "$seal" &&
    $(sha256_file "$(state_dir_path)/lifecycle.json") == "$lifecycle" ]]
}
# Stable identity is entirely synthetic. The root path is schema data, never a
# request to inspect the host root, block metadata, machine ID or signing keys.
context_fixture() {
  CONTEXT=$(jq -cn --arg esp "$CASE_DIR/esp" '{schema_version:1,architecture:"x86_64",
    machine_id:"0123456789abcdef0123456789abcdef",local_db_certificate_der_sha256:("a" * 64),
    configuration_path:($esp+"/limine.conf"),root:{path:"/",filesystem_type:"btrfs",
      filesystem_uuid:"22222222-2222-4222-8222-222222222222",
      subvolume:{kind:"subvolume",id:"256",uuid:"33333333-3333-4333-8333-333333333333"}},
    esp:{path:$esp,partition_scheme:"gpt",partition_type:"c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
      partition_uuid:"44444444-4444-4444-8444-444444444444",filesystem_type:"vfat",filesystem_uuid:"A1B2-C3D4"}}')
  # Only machine_id is Core's join into this opaque producer-owned JSON string.
  # Placement overrides and other model fields must not substitute for it.
  INTENT=$(jq -c --arg machine "$(jq -r '.machine_id' <<<"$CONTEXT")" '
    .publication={kind:"addition",model:({machine_id:$machine,
      entry_override:"fixture-entry",opaque:{fixture:true}} | tojson)}' <<<"$INTENT")
}
context_intent() {
  preserve_transaction_files_on_failure
  append_publication_record "$INVOCATION" intent "$INTENT"
}
context_accepted() {
  context_fixture
  CONTEXT=$(jq -c "${CONTEXT_FILTER:-.}" <<<"$CONTEXT")
  validate_publication_context_json "$CONTEXT"
  publication_context_matches_intent "$CONTEXT" "$INTENT"
  context_intent
  append_publication_record "$INVOCATION" context "$CONTEXT"
  append_publication_record "$INVOCATION" session "$SESSION"
  validate_historical_journal
  json_is '.publication_records | length == 3' "$_manifest_json"
  find_publication_record "$INVOCATION" context
  json_is '.[0] == .[1]' "[$CONTEXT,$_publication_found_body]"
}
refuse_context_record() {
  local body=$1 shape=${2:-valid} before ordinal path previous document reference candidate
  before=$(journal_fingerprint)
  ordinal=$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")
  path=$TXDIR/publication-$ordinal.json
  [[ ! -e $path && ! -L $path ]]
  if append_publication_record "$INVOCATION" context "$body"; then
    fail_test "context append accepted ${CONTEXT_FILTER:-$shape contradiction}"
  fi
  [[ ! -e $path && ! -L $path && $(journal_fingerprint) == "$before" ]] ||
    fail_test 'context refusal changed the journal'

  # As with directory contradictions, independently bind a candidate's actual
  # bytes to the accepted prefix. Schema failures and semantic failures are
  # checked separately; neither may hide behind an invalid hash or manifest.
  previous=$(jq -c '.publication_records[-1] // null' "$TXDIR/manifest.json")
  document=$(jq -cn --arg id "$_transaction_id" --arg invocation "$INVOCATION" \
    --argjson body "$body" --argjson ordinal "$ordinal" --argjson previous "$previous" \
    --arg timestamp "$(utc_timestamp)" --arg version "$OMASECBOOT_VERSION" '
    {schema_version:1,transaction_id:$id,invocation:$invocation,ordinal:$ordinal,previous:$previous,
      kind:"context",body:$body,recorded_at:$timestamp,writer_version:$version}')
  if [[ $shape == valid ]]; then
    validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document"
  elif validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document"; then
    fail_test "context record schema accepted $CONTEXT_FILTER"
  fi
  printf '%s\n' "$document" >"$path"
  reference=$(transaction_artifact_reference "$path" 1)
  validate_artifact_reference_file "$reference" "$TXDIR"
  candidate=$(jq -c --argjson reference "$reference" '.publication_records += [$reference]' "$TXDIR/manifest.json")
  validate_transaction_manifest_json "$_transaction_id" "$candidate" false
  _publication_validation_cache=()
  if validate_publication_records "$_transaction_id" "$candidate"; then
    fail_test "hash-valid historical context accepted ${CONTEXT_FILTER:-$shape contradiction}"
  fi
  if validate_publication_records "$_transaction_id" "$candidate" "$document"; then
    fail_test "hash-valid pending context accepted ${CONTEXT_FILTER:-$shape contradiction}"
  fi
  rm -- "$path"
  [[ $(journal_fingerprint) == "$before" ]]
  validate_historical_journal
}
context_no_intent() {
  context_fixture
  preserve_transaction_files_on_failure
  refuse_context_record "$CONTEXT"
}
context_after_session() {
  context_fixture
  context_intent
  append_publication_record "$INVOCATION" session "$SESSION"
  refuse_context_record "$CONTEXT"
}
context_duplicate() {
  local bad
  context_fixture
  context_intent
  append_publication_record "$INVOCATION" context "$CONTEXT"
  if [[ $DUPLICATE == changed ]]; then
    bad=$(jq -c '.root.subvolume.uuid="55555555-5555-4555-8555-555555555555"' <<<"$CONTEXT")
  else
    # An intervening invocation defeats the last-record retry shortcut without
    # starting this invocation's session: rejection must prove uniqueness.
    append_publication_record 66666666-6666-4666-8666-666666666666 intent "$INTENT"
    bad=$CONTEXT
  fi
  publication_context_matches_intent "$bad" "$INTENT"
  refuse_context_record "$bad"
}
context_retry() {
  local before reference
  context_fixture
  context_intent
  append_publication_record "$INVOCATION" context "$CONTEXT"
  before=$(journal_fingerprint)
  reference=$_publication_record_reference
  append_publication_record "$INVOCATION" context "$CONTEXT"
  [[ $_publication_record_reference == "$reference" && $(journal_fingerprint) == "$before" ]]
  validate_historical_journal
  json_is '.publication_records | length == 2' "$_manifest_json"
}
context_invocation_scope() {
  local first=$INVOCATION
  context_fixture
  context_intent
  append_publication_record "$INVOCATION" context "$CONTEXT"
  append_publication_record "$INVOCATION" session "$SESSION"
  INVOCATION=66666666-6666-4666-8666-666666666666
  # Another invocation's intent does not authorize this one's context.
  refuse_context_record "$CONTEXT"
  context_intent
  append_publication_record "$INVOCATION" context "$CONTEXT"
  append_publication_record "$INVOCATION" session "$SESSION"
  validate_historical_journal
  json_is '.publication_records | length == 6' "$_manifest_json"
  find_publication_record "$first" context
  find_publication_record "$INVOCATION" context
}
context_binding_mismatch() {
  local bad
  context_fixture
  bad=$(jq -c "$CONTEXT_FILTER" <<<"$CONTEXT")
  validate_publication_context_json "$bad"
  if publication_context_matches_intent "$bad" "$INTENT"; then fail_test 'context/intent mismatch accepted'; fi
  context_intent
  refuse_context_record "$bad"
}
context_model_mismatch() {
  context_fixture
  INTENT=$(jq -c "$INTENT_FILTER" <<<"$INTENT")
  # The intent's opaque model is still schema-valid; the context join must parse
  # it and require its exact machine_id, not a raw substring or placement name.
  context_intent
  if publication_context_matches_intent "$CONTEXT" "$INTENT"; then fail_test 'invalid model binding accepted'; fi
  refuse_context_record "$CONTEXT"
}
context_schema_invalid() {
  local CONTEXT_FILTER bad
  context_fixture
  context_intent
  while IFS= read -r CONTEXT_FILTER; do
    [[ -n $CONTEXT_FILTER ]] || continue
    bad=$(jq -c "$CONTEXT_FILTER" <<<"$CONTEXT")
    if validate_publication_context_json "$bad"; then fail_test "context schema accepted $CONTEXT_FILTER"; fi
    refuse_context_record "$bad" invalid
  done <<<"$CONTEXT_MUTATIONS"
}
context_historical() {
  local before seal lifecycle journal status=0 id=$_transaction_id
  context_fixture
  context_intent
  if [[ $CONTEXT_HISTORY == bound ]]; then append_publication_record "$INVOCATION" context "$CONTEXT"; fi
  append_publication_record "$INVOCATION" session "$SESSION"
  validate_historical_journal
  journal=$(jq -c '.publication_records' <<<"$_manifest_json")
  rollback_and_mark_recovery 20 'fixture context publication interrupted'
  before=$(journal_fingerprint)
  seal=$(sha256_file "$TXDIR/incident.json")
  lifecycle=$(sha256_file "$(state_dir_path)/lifecycle.json")
  rm -rf -- "$CASE_DIR/esp"
  [[ ! -e $CASE_DIR/esp ]]
  validate_historical_journal
  [[ $(jq -c '.publication_records' <<<"$_manifest_json") == "$journal" ]]
  read_incident_seal "$id"
  if [[ $CONTEXT_HISTORY == bound ]]; then
    find_publication_record "$INVOCATION" context
    json_is '.[0] == .[1]' "[$CONTEXT,$_publication_found_body]"
  else
    find_publication_record "$INVOCATION" context || status=$?
    [[ $status == 1 ]] || fail_test 'context-free history became invalid or acquired context'
    _publication_invocation=$INVOCATION
    _publication_stable_context=$CONTEXT
    # Even supplying fresh-looking identity in memory cannot replace the missing
    # historical authority. The collector tripwire must never be reached.
    if publication_verify_stable_context; then fail_test 'context invented for historical invocation'; fi
  fi
  load_recovery_context
  if run_registered_recovery_locked; then fail_test 'context journal entered legacy recovery'; fi
  if begin_lifecycle_recovery_attempt software-recovery; then fail_test 'context journal acquired legacy attempt'; fi
  [[ $(journal_fingerprint) == "$before" && $(sha256_file "$TXDIR/incident.json") == "$seal" &&
    $(sha256_file "$(state_dir_path)/lifecycle.json") == "$lifecycle" ]]
}
context_runtime_fixture() {
  local definition
  # The suite sources sign.sh once above. Use its actual bounded copier; a
  # second source would redefine readonly constants before these assertions run.
  _producer_session_io_timeout=2
  RUNTIME_COLLECTED=0 RUNTIME_COPY_CALLS=0 RUNTIME_LIVE_OBSERVATIONS=0
  RUNTIME_ORIGINAL_PATH=$TXDIR/publication-data-$INVOCATION-original-configuration
  printf '# ordinary exact-byte configuration\n\000\n\n' >"$CASE_DIR/esp/limine.conf"
  INTENT=$(jq -c --arg hash "$(sha256_file "$CASE_DIR/esp/limine.conf")" '.configuration.sha256=$hash' <<<"$INTENT")
  context_fixture
  # Replace platform observations and restrict parent binding to our fixture.
  # Actual directory opens, FD identity/state checks and the sticky live checker
  # remain in use; no host root, partition or certificate is inspected.
  # shellcheck disable=SC2329
  publication_namespace_value() { printf 'mnt:[8800]\n'; }
  # shellcheck disable=SC2329
  publication_parent_binding() {
    [[ $1 == "$CASE_DIR/esp" ]] && publication_pin_directory "$1"
  }
  # shellcheck disable=SC2329
  publication_fd_mount_id() {
    fd_matches_path "$1" "$CASE_DIR/esp" || return 1
    printf '42\n'
  }
  # shellcheck disable=SC2329
  publication_check_path_mount() {
    [[ $# == 4 && $1 == "$CASE_DIR/esp" && $2 == directory && $3 == 42 &&
      $4 == "$(control_file_identity "$CASE_DIR/esp")" ]] || return 1
    RUNTIME_LIVE_OBSERVATIONS=$((RUNTIME_LIVE_OBSERVATIONS+1))
    [[ ${RUNTIME_COPY_FAULT:-} != live-after-copy || $RUNTIME_LIVE_OBSERVATIONS != 2 ]]
  }
  # shellcheck disable=SC2329
  publication_collect_stable_context() {
    RUNTIME_COLLECTED=$((RUNTIME_COLLECTED+1))
    _publication_collected_context=$CONTEXT
  }
  definition=$(declare -f copy_publication_input)
  eval "${definition/copy_publication_input/context_runtime_actual_copy}"
  # Observe the actual source/destination callback, then run the real bounded
  # child. A result fault tests its caller's refusal and temporary-file cleanup.
  # shellcheck disable=SC2329
  copy_publication_input() {
    [[ $# == 2 && $1 == "$CASE_DIR/esp/limine.conf" && $2 == "$TXDIR/.publication-original."* ]] || return 1
    RUNTIME_COPY_CALLS=$((RUNTIME_COPY_CALLS+1))
    context_runtime_actual_copy "$@" || return 1
    [[ ${RUNTIME_COPY_FAULT:-} != copy-result ]]
  }
  definition=$(declare -f durable_sync)
  eval "${definition/durable_sync/context_runtime_actual_sync}"
  # shellcheck disable=SC2329
  durable_sync() {
    printf '%s\n' "$1" >>"$CASE_DIR/runtime-syncs"
    case ${RUNTIME_COPY_FAULT:-}:$1 in
      temporary-sync:"$TXDIR/.publication-original."*|destination-sync:"$RUNTIME_ORIGINAL_PATH"|directory-sync:"$TXDIR") return 1 ;;
    esac
    context_runtime_actual_sync "$@"
  }
}
context_runtime_boot_fingerprint() {
  find "$CASE_DIR/esp" -printf '%y %m %i %p\n' | sort
  find "$CASE_DIR/esp" -type f -print0 | sort -z | xargs -0 -r sha256sum --
}
context_runtime_launch() {
  local launch
  launch=$(jq -c --arg invocation "$INVOCATION" '. + {invocation:$invocation}' <<<"$SESSION")
  publication_authority_handler launch "$launch"
}
context_runtime_assert_start() {
  local reference file expected
  read_transaction_manifest "$_transaction_id"
  json_is '.file_rollback_policy == "preserve" and (.publication_records | length) == 1 and
    .publication_records[0].schema_version == 2' "$_manifest_json"
  jq -se 'map(.kind) == ["invocation-start"] and .[0].schema_version == 2' "$TXDIR"/publication-*.json >/dev/null
  reference=$(jq -c '.publication_records[0]' <<<"$_manifest_json")
  find_publication_record "$INVOCATION" invocation-start
  [[ $_publication_found_reference == "$reference" ]]
  expected=$(jq -cn --argjson intent "$INTENT" --argjson context "$CONTEXT" '
    {intent:$intent,context:$context,recovery:{recreate_missing:([$intent.resources[] | {id,target}] +
      [{id:"configuration",target:$intent.configuration.path}])}}')
  json_is '.[0] == (.[1] | del(.original_configuration))' "[$expected,$_publication_found_body]"
  file=$(jq -c '.original_configuration' <<<"$_publication_found_body")
  json_is '.[0] == .[1]' "[$file,$_publication_original_configuration]"
  [[ $(jq -r '.path' <<<"$file") == "$RUNTIME_ORIGINAL_PATH" &&
    $(jq -r '.sha256' <<<"$file") == "$(sha256_file "$CASE_DIR/esp/limine.conf")" &&
    $(jq -r '.bytes' <<<"$file") == "$(stat -c %s "$CASE_DIR/esp/limine.conf")" ]]
  validate_publication_retained_file "$_transaction_id" "$file"
  [[ $(stat -c %a "$RUNTIME_ORIGINAL_PATH") == 400 && $(stat -c %u "$RUNTIME_ORIGINAL_PATH") == "$(control_owner_uid)" ]]
  [[ $(control_file_identity "$RUNTIME_ORIGINAL_PATH") != "$(control_file_identity "$CASE_DIR/esp/limine.conf")" ]]
  cmp -- "$CASE_DIR/esp/limine.conf" "$RUNTIME_ORIGINAL_PATH"
  find_publication_authority_part "$INVOCATION" context
  [[ $_publication_found_reference == "$reference" && $_publication_found_container_kind == invocation-start &&
    $_publication_found_projection == .body.context ]]
}
context_runtime_begin() {
  local before
  local -a syncs
  context_runtime_fixture
  before=$(context_runtime_boot_fingerprint)
  publication_authority_begin "$INVOCATION" "$INTENT"
  [[ $RUNTIME_COLLECTED == 1 && $RUNTIME_COPY_CALLS == 1 && $RUNTIME_LIVE_OBSERVATIONS == 2 ]]
  mapfile -t syncs <"$CASE_DIR/runtime-syncs"
  [[ ${syncs[0]} == "$TXDIR/.publication-original."* && ${syncs[1]} == "$RUNTIME_ORIGINAL_PATH" && ${syncs[2]} == "$TXDIR" ]]
  context_runtime_assert_start
  context_runtime_launch
  jq -se 'map(.kind) == ["invocation-start","session"] and map(.schema_version) == [2,1] and
    .[1].previous.schema_version == 2' "$TXDIR"/publication-*.json >/dev/null
  validate_historical_journal
  [[ $(context_runtime_boot_fingerprint) == "$before" ]]
  release_publication_pins
}
context_runtime_copy_failure() {
  local before manifest retained_identity='' retained_hash='' fault=$RUNTIME_COPY_FAULT
  local -a temporary_files
  context_runtime_fixture
  before=$(context_runtime_boot_fingerprint)
  manifest=$(sha256_file "$TXDIR/manifest.json")
  if publication_authority_begin "$INVOCATION" "$INTENT"; then fail_test "runtime accepted $fault"; fi
  [[ $RUNTIME_COLLECTED == 1 && $RUNTIME_COPY_CALLS == 1 && -z $_publication_original_configuration ]]
  read_transaction_manifest "$_transaction_id"
  json_is '.file_rollback_policy == "restore" and .publication_records == []' "$_manifest_json"
  [[ $(sha256_file "$TXDIR/manifest.json") == "$manifest" && ! -e $TXDIR/publication-1.json ]]
  if context_runtime_launch; then fail_test 'failed original copy admitted launch'; fi
  [[ $(context_runtime_boot_fingerprint) == "$before" ]]
  shopt -s nullglob
  temporary_files=("$TXDIR"/.publication-original.*)
  (( ${#temporary_files[@]} == 0 )) || fail_test 'failed copy retained a temporary file'
  case $fault in
    copy-result|temporary-sync) [[ ! -e $RUNTIME_ORIGINAL_PATH ]] ;;
    *)
      retained_identity=$(control_file_identity "$RUNTIME_ORIGINAL_PATH")
      retained_hash=$(sha256_file "$RUNTIME_ORIGINAL_PATH")
      cmp -- "$CASE_DIR/esp/limine.conf" "$RUNTIME_ORIGINAL_PATH"
      ;;
  esac
  if [[ $fault == live-after-copy ]]; then [[ $_publication_mount_invalid == true ]]; fi
  RUNTIME_COPY_FAULT=''
  publication_authority_begin "$INVOCATION" "$INTENT"
  context_runtime_assert_start
  if [[ -n $retained_identity ]]; then
    [[ $(control_file_identity "$RUNTIME_ORIGINAL_PATH") == "$retained_identity" &&
      $(sha256_file "$RUNTIME_ORIGINAL_PATH") == "$retained_hash" && $RUNTIME_COPY_CALLS == 1 ]]
  else [[ $RUNTIME_COPY_CALLS == 2 ]]; fi
  context_runtime_launch
  validate_historical_journal
  [[ $(context_runtime_boot_fingerprint) == "$before" ]]
  release_publication_pins
}
context_runtime_existing_copy() {
  local before manifest identity hash reference
  context_runtime_fixture
  before=$(context_runtime_boot_fingerprint)
  manifest=$(sha256_file "$TXDIR/manifest.json")
  _publication_invocation=$INVOCATION _publication_intent=$INTENT _publication_stable_context=$CONTEXT
  _publication_mount_namespace=$(publication_namespace_value)
  publication_parent_binding "$CASE_DIR/esp"
  publication_retain_original_configuration "$INVOCATION" "$INTENT"
  reference=$_publication_original_configuration
  identity=$(control_file_identity "$RUNTIME_ORIGINAL_PATH")
  hash=$(sha256_file "$RUNTIME_ORIGINAL_PATH")
  [[ $RUNTIME_COPY_CALLS == 1 && $(sha256_file "$TXDIR/manifest.json") == "$manifest" && ! -e $TXDIR/publication-1.json ]]
  if context_runtime_launch; then fail_test 'unanchored original copy admitted launch'; fi
  publication_retain_original_configuration "$INVOCATION" "$INTENT"
  [[ $_publication_original_configuration == "$reference" && $RUNTIME_COPY_CALLS == 1 &&
    $(control_file_identity "$RUNTIME_ORIGINAL_PATH") == "$identity" && $(sha256_file "$RUNTIME_ORIGINAL_PATH") == "$hash" ]]
  publication_authority_begin "$INVOCATION" "$INTENT"
  context_runtime_assert_start
  [[ $RUNTIME_COPY_CALLS == 1 && $(control_file_identity "$RUNTIME_ORIGINAL_PATH") == "$identity" ]]
  context_runtime_launch
  validate_historical_journal
  [[ $(context_runtime_boot_fingerprint) == "$before" ]]
  release_publication_pins
}
context_runtime_conflicting_copy() {
  local before manifest identity hash
  context_runtime_fixture
  printf 'different pre-existing original configuration\n' >"$RUNTIME_ORIGINAL_PATH"
  chmod 400 "$RUNTIME_ORIGINAL_PATH"
  identity=$(control_file_identity "$RUNTIME_ORIGINAL_PATH")
  hash=$(sha256_file "$RUNTIME_ORIGINAL_PATH")
  before=$(context_runtime_boot_fingerprint)
  manifest=$(sha256_file "$TXDIR/manifest.json")
  if publication_authority_begin "$INVOCATION" "$INTENT"; then fail_test 'runtime replaced conflicting original bytes'; fi
  [[ $RUNTIME_COPY_CALLS == 0 && -z $_publication_original_configuration ]]
  read_transaction_manifest "$_transaction_id"
  json_is '.file_rollback_policy == "restore" and .publication_records == []' "$_manifest_json"
  if context_runtime_launch; then fail_test 'conflicting original copy admitted launch'; fi
  [[ $(control_file_identity "$RUNTIME_ORIGINAL_PATH") == "$identity" && $(sha256_file "$RUNTIME_ORIGINAL_PATH") == "$hash" &&
    $(sha256_file "$TXDIR/manifest.json") == "$manifest" && ! -e $TXDIR/publication-1.json &&
    $(context_runtime_boot_fingerprint) == "$before" ]]
  release_publication_pins
}
expect_context_comparison() {
  local expected=$1 actual=0
  publication_compare_stable_context "$2" "$3" || actual=$?
  [[ $actual == "$expected" ]] || fail_test "context comparison returned $actual, expected $expected"
}
context_comparator() {
  local filter changed
  context_fixture
  expect_context_comparison 0 "$CONTEXT" "$(jq -Sc . <<<"$CONTEXT")"
  for filter in '.architecture="aarch64"' '.machine_id="abcdef0123456789abcdef0123456789"' \
    '.local_db_certificate_der_sha256=("b" * 64)' '.configuration_path += ".other"' \
    '.root.filesystem_uuid="55555555-5555-4555-8555-555555555555"' \
    '.root.subvolume.uuid="55555555-5555-4555-8555-555555555555"' '.root.subvolume.id="257"' \
    '.esp.partition_uuid="55555555-5555-4555-8555-555555555555"' '.esp.filesystem_uuid="DEAD-BEEF"'; do
    changed=$(jq -c "$filter" <<<"$CONTEXT")
    expect_context_comparison 1 "$CONTEXT" "$changed"
    expect_context_comparison 1 "$changed" "$CONTEXT"
  done
  # Adjacent IDs above binary64 precision must remain distinct strings, including
  # at the highest non-metadata object ID boundary.
  for filter in '9007199254740992 9007199254740993' '18446744073709551359 18446744073709551360'; do
    local lower upper
    read -r lower upper <<<"$filter"
    expect_context_comparison 1 "$(jq -c --arg id "$lower" '.root.subvolume.id=$id' <<<"$CONTEXT")" \
      "$(jq -c --arg id "$upper" '.root.subvolume.id=$id' <<<"$CONTEXT")"
  done
  for filter in '.schema_version=2' '.root.subvolume.id=256' '.extra=true'; do
    changed=$(jq -c "$filter" <<<"$CONTEXT")
    expect_context_comparison 2 "$CONTEXT" "$changed"
    expect_context_comparison 2 "$changed" "$CONTEXT"
    expect_context_comparison 2 "$changed" "$changed"
  done
  expect_context_comparison 2 "$CONTEXT" '{'
  expect_context_comparison 2 '{' "$CONTEXT"
}

# These fixtures use actual transaction/journal/seal constructors. Only old
# platform observations and the meaning of ordinary retained bytes are synthetic.
basis_file_state() {
  local device inode mode uid gid
  read -r device inode mode uid gid < <(stat -c '%d %i %f %u %g' "$1")
  jq -cn --arg identity "$device:$inode" --arg hash "$(sha256_file "$1")" \
    --argjson mode "$((16#$mode))" --argjson uid "$uid" --argjson gid "$gid" '
    {kind:"file",identity:$identity,sha256:$hash,link_target:null,mode:$mode,uid:$uid,gid:$gid}'
}
basis_configuration_fixture() {
  local retained=$TXDIR/publication-data-$INVOCATION-configuration history before
  local CHILD_PATH=$CASE_DIR/esp STAGED_PATH STAGED_STATE RETAINED_REFERENCE
  printf 'literal rendered configuration naming retained hash %s\n' "$(jq -r '.retained.sha256' <<<"$STAGE")" >"$retained"
  RETAINED_REFERENCE=$(jq -cn --arg path "$retained" --arg hash "$(sha256_file "$retained")" \
    --argjson bytes "$(stat -c %s "$retained")" '{path:$path,sha256:$hash,bytes:$bytes}')
  append_publication_record "$INVOCATION" configuration "$(jq -cn --argjson file "$RETAINED_REFERENCE" '{file:$file}')"
  BASIS_CONFIGURATION_REF=$_publication_record_reference
  STAGED_PATH=$(mktemp "$CHILD_PATH/.omasecboot-$INVOCATION-configuration.XXXXXX.stage")
  cp -- "$retained" "$STAGED_PATH"
  STAGED_STATE=$(basis_file_state "$STAGED_PATH")
  before=$(basis_file_state "$CASE_DIR/esp/limine.conf")
  history=$(jq -c --arg parent "$CHILD_PATH" '[.[] | .path as $path |
    select($path == $parent or ($parent | startswith($path + "/")) or $path == "/")]' <<<"$HISTORY")
  CONFIGURATION_STAGE=$(stage_from_history "$history" | jq -c --arg target "$CHILD_PATH/limine.conf" \
    --argjson before "$before" '.id="configuration" | .target=$target | .before=$before')
  append_publication_record "$INVOCATION" boot-stage "$CONFIGURATION_STAGE"
}
basis_complete_fixture() {
  if [[ ${BASIS_SIGNING:-bytes} == local-efi ]]; then
    INTENT=$(jq -c '.operation="add-uki" | .resources[0].role="uki"' <<<"$INTENT")
  fi
  directory_history kernel "${BASIS_CONTEXT:-bound}"
  BASIS_INTENT_REF=$(jq -c '.publication_records[0]' "$TXDIR/manifest.json")
  if [[ ${BASIS_CONTEXT:-bound} == start ]]; then BASIS_START_REF=$BASIS_INTENT_REF; fi
  if [[ ${BASIS_CONTEXT:-bound} == bound ]]; then
    BASIS_CONTEXT_REF=$(jq -c '.publication_records[1]' "$TXDIR/manifest.json")
  fi
  ordered_directory_records
  retain_stage_fixture "${BASIS_SIGNING:-bytes}"
  BASIS_RETAINED_REF=$_publication_record_reference
  append_publication_record "$INVOCATION" boot-stage "$STAGE"
  [[ ${BASIS_PLAN:-bound} != partial ]] || return 0
  basis_configuration_fixture
  PLAN=$(jq -cn --arg invocation "$INVOCATION" --argjson resource "$STAGE" --argjson config "$CONFIGURATION_STAGE" '
    def put: {id,target,before,after:.stage.state,parent,retained:.retained.path};
    {format:"limine-prepared-publication",schema:1,invocation:$invocation,
      puts:[$resource | put],configuration:($config | put),deletes:[],references:[]}')
  if [[ ${BASIS_PLAN:-bound} == bound ]]; then
    append_publication_record "$INVOCATION" plan "$PLAN"
    BASIS_PLAN_REF=$_publication_record_reference
  fi
}
basis_seal_fixture() {
  rollback_and_mark_recovery 21 'fixture complete-plan interruption'
  read_lifecycle
  BASIS_ROOT_REF=$(jq -c '.transaction.root_incident' <<<"$_lifecycle_json")
  validate_incident_reference "$BASIS_ROOT_REF"
  BASIS_MANIFEST=$_manifest_json
}
expect_selection_status() {
  local expected=$1 actual=0
  shift
  _publication_selected_original_basis=stale-output
  publication_load_selected_original_basis "$@" || actual=$?
  [[ $actual == "$expected" ]] || fail_test "selected basis returned $actual, expected $expected"
  if (( expected == 0 )); then
    [[ -n $_publication_selected_original_basis && $_publication_selected_original_basis != stale-output ]]
  else [[ -z $_publication_selected_original_basis ]] || fail_test 'failed selection retained stale output'; fi
}
selection_valid() {
  local before saved original lifecycle
  basis_complete_fixture
  basis_seal_fixture
  publication_load_complete_original_basis "$BASIS_ROOT_REF" "$INVOCATION"
  original=$_publication_original_basis lifecycle=$_lifecycle_json
  # No current source, target or old stage is needed for selected historical data.
  rm -rf -- "$CASE_DIR/esp"
  rm -- "$CASE_DIR/source" "$TXDIR"/.publication-input.*
  before=$(basis_fixture_fingerprint)
  _lifecycle_state=caller-state _lifecycle_json=caller-lifecycle _lifecycle_generation=999
  _lifecycle_transaction_id=caller-id _lifecycle_read_status=caller-status
  _recovery_root_reference=caller-root _recovery_root_manifest_json=caller-root-manifest
  _recovery_previous_reference=caller-previous _recovery_previous_manifest_json=caller-previous-manifest
  _recovery_attempt_count=999 _recovery_target_state=caller-target _recovery_terminal_state=caller-terminal
  _recovery_producer_reference=caller-producer
  _manifest_json=caller-manifest _manifest_id=caller-manifest-id _manifest_sha256=caller-hash
  _incident_json=caller-incident _incident_read_status=caller-incident-status
  _publication_validation_cache=([sentinel]=caller-cache)
  saved=$(declare -p _lifecycle_state _lifecycle_json _lifecycle_generation _lifecycle_transaction_id _lifecycle_read_status \
    _recovery_root_reference _recovery_root_manifest_json _recovery_previous_reference _recovery_previous_manifest_json \
    _recovery_attempt_count _recovery_target_state _recovery_terminal_state _recovery_producer_reference \
    _manifest_json _manifest_id _manifest_sha256 _incident_json _incident_read_status _publication_validation_cache \
    _publication_original_basis _transaction_id _transaction_active)
  basis_reader_tripwires
  expect_selection_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  json_is 'keys == ["basis","lifecycle","schema","scope"] and .schema == 1 and .scope == "selected-original-basis"' \
    "$_publication_selected_original_basis"
  json_is '.[0].basis == .[1] and .[0].lifecycle == (.[2] | {generation,transaction})' \
    "[$_publication_selected_original_basis,$original,$lifecycle]"
  expect_selection_status 2 "$BASIS_ROOT_REF" "$INVOCATION" extra
  expect_selection_status 1 "$BASIS_ROOT_REF" 88888888-8888-4888-8888-888888888888
  [[ $(declare -p _lifecycle_state _lifecycle_json _lifecycle_generation _lifecycle_transaction_id _lifecycle_read_status \
    _recovery_root_reference _recovery_root_manifest_json _recovery_previous_reference _recovery_previous_manifest_json \
    _recovery_attempt_count _recovery_target_state _recovery_terminal_state _recovery_producer_reference \
    _manifest_json _manifest_id _manifest_sha256 _incident_json _incident_read_status _publication_validation_cache \
    _publication_original_basis _transaction_id _transaction_active) == "$saved" ]]
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
selection_sibling() {
  local first_root
  basis_complete_fixture
  basis_seal_fixture
  first_root=$BASIS_ROOT_REF
  rm -- "$(lifecycle_file_path)"
  detach_transaction_context
  begin_lifecycle_transaction sign active
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  preserve_transaction_files_on_failure
  append_publication_record "$INVOCATION" intent "$INTENT"
  basis_seal_fixture
  # Same store and invocation, two valid sealed roots. Only today's selection
  # may be consumed, regardless of cached caller recovery/basis globals.
  expect_basis_status 0 "$first_root" "$INVOCATION"
  _recovery_root_reference=$first_root
  expect_selection_status 2 "$first_root" "$INVOCATION"
  expect_selection_status 1 "$BASIS_ROOT_REF" "$INVOCATION"
}
selection_state() {
  local root before
  basis_complete_fixture
  basis_seal_fixture
  root=$BASIS_ROOT_REF
  rm -- "$(lifecycle_file_path)"
  if [[ $SELECTION_STATE != absent ]]; then
    detach_transaction_context
    begin_lifecycle_transaction sign active
    if [[ $SELECTION_STATE == stable ]]; then commit_lifecycle_transaction; fi
    detach_transaction_context
  fi
  before=$(basis_fixture_fingerprint)
  expect_selection_status 2 "$root" "$INVOCATION"
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
selection_incomplete() {
  basis_complete_fixture
  basis_seal_fixture
  expect_selection_status 1 "$BASIS_ROOT_REF" "$INVOCATION"
  if run_registered_recovery_locked; then fail_test 'selection admitted legacy recovery'; fi
  [[ $(jq -r '.transaction.attempt_count' "$(lifecycle_file_path)") == 0 ]]
}
selection_invalid() {
  local lifecycle invalid before
  basis_complete_fixture
  basis_seal_fixture
  lifecycle=$(read_control_document "$(lifecycle_file_path)")
  for invalid in '.transaction.attempt_count=33' '.transaction.attempt_count=1' \
    '.transaction.root_incident.sha256=("0"*64)' '.transaction.id="77777777-7777-4777-8777-777777777777"' \
    '.schema_version=999'; do
    jq -c "$invalid" <<<"$lifecycle" >"$(lifecycle_file_path)"
    before=$(basis_fixture_fingerprint)
    expect_selection_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
    [[ $(basis_fixture_fingerprint) == "$before" ]]
  done
  printf '%s\n' "$lifecycle" >"$(lifecycle_file_path)"
  expect_selection_status 2 "$BASIS_ROOT_REF $BASIS_ROOT_REF" "$INVOCATION"
  expect_selection_status 2 "$BASIS_ROOT_REF" "$INVOCATION"$'\n'
  printf ' ' >>"$TXDIR/incident.json"
  expect_selection_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
}
selection_fault() {
  local path
  case $SELECTION_FAULT in
    generation)
      jq '.generation += 1' "$(lifecycle_file_path)" >"$CASE_DIR/new-lifecycle"
      mv -- "$CASE_DIR/new-lifecycle" "$(lifecycle_file_path)" ;;
    closure) printf 'changed retained bytes\n' >>"$(jq -r '.retained.path' <<<"$STAGE")" ;;
    marker) ln -s "$CASE_DIR/absent-marker-target" "$(snapshot_restore_lock_path)" ;;
    boot-path|repair-path)
      if [[ $SELECTION_FAULT == boot-path ]]; then path=$(limine_lock_path)
      else path="$(state_dir_path)/repair.lock"; fi
      mv -- "$path" "$path.old"
      touch "$path" ;;
  esac
}
selection_drift() {
  basis_complete_fixture
  basis_seal_fixture
  # Inject after real complete-basis validation, before final lifecycle/lock
  # rechecks. Filesystem effects cross the reader subshell; no production seam.
  eval "$(declare -f publication_load_complete_original_basis | \
    sed '1s/publication_load_complete_original_basis/fixture_selection_original_basis/')"
  # shellcheck disable=SC2329
  publication_load_complete_original_basis() {
    fixture_selection_original_basis "$@" || return "$?"
    selection_fault
  }
  expect_selection_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
  if [[ $SELECTION_FAULT == boot-path ]]; then [[ $_OMASECBOOT_LIMINE_LOCK_OWNED == false ]]; fi
  if [[ $SELECTION_FAULT == repair-path ]]; then [[ $_OMASECBOOT_REPAIR_LOCK_OWNED == false ]]; fi
}
selection_lock() {
  local contender
  basis_complete_fixture
  basis_seal_fixture
  case $SELECTION_FAULT in
    boot-closed) exec 200>&- ;;
    repair-closed) exec 201>&- ;;
    boot-flag) _OMASECBOOT_LIMINE_LOCK_OWNED=false ;;
    repair-flag) _OMASECBOOT_REPAIR_LOCK_OWNED=false ;;
    contention)
      # A separate open-file description really holds the current boot lock;
      # unchanged path identity and stale true flags must not pass selection.
      exec {contender}>>"$(limine_lock_path)"
      flock -u 200
      flock -n "$contender" ;;
    *) selection_fault ;;
  esac
  expect_selection_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
  case $SELECTION_FAULT in
    boot-*|contention) [[ $_OMASECBOOT_LIMINE_LOCK_OWNED == false ]] ;;
    repair-*) [[ $_OMASECBOOT_REPAIR_LOCK_OWNED == false ]] ;;
    marker) [[ -L $(snapshot_restore_lock_path) ]] ;;
  esac
  if [[ $SELECTION_FAULT == contention ]]; then exec {contender}>&-; fi
}
expect_basis_status() {
  local expected=$1 actual=0
  shift
  _publication_original_basis=stale-output
  publication_load_complete_original_basis "$@" || actual=$?
  [[ $actual == "$expected" ]] || fail_test "original basis returned $actual, expected $expected"
  if (( expected == 0 )); then [[ -n $_publication_original_basis && $_publication_original_basis != stale-output ]]
  else [[ -z $_publication_original_basis ]] || fail_test 'failed basis retained stale output'; fi
}
recovery_basis_constructor() {
  local root_manifest root_seal root_journal first_attempt first_seal first_manifest original
  basis_complete_fixture
  basis_seal_fixture
  publication_load_complete_original_basis "$BASIS_ROOT_REF" "$INVOCATION"
  original=$_publication_original_basis
  root_manifest=$(sha256_file "$TXDIR/manifest.json")
  root_seal=$(sha256_file "$TXDIR/incident.json")
  root_journal=$(journal_fingerprint)
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  first_attempt=$_transaction_id
  current_transition_is_owned
  read_transaction_manifest "$first_attempt"
  json_is '.kind == "recovery-attempt" and .operation == "publication-recovery" and
    .file_rollback_policy == "preserve" and .recovery.attempt_number == 1 and
    (.publication_records | length) == 1 and all(.domain_records[]; . == null)' "$_manifest_json"
  find_publication_record "$INVOCATION" recovery-basis
  json_is '.[0].basis == .[1]' "[$_publication_found_body,$original]"
  if commit_lifecycle_recovery_attempt; then fail_test 'preparatory attempt completed'; fi
  read_lifecycle
  [[ $_lifecycle_state == transition ]]
  rollback_and_mark_recovery 24 'fixture publication preparation interrupted'
  load_recovery_context
  [[ $_recovery_attempt_count == 1 ]]
  first_seal=$(sha256_file "$(lifecycle_incident_path "$first_attempt")")
  first_manifest=$(sha256_file "$(lifecycle_manifest_path "$first_attempt")")
  if run_registered_recovery_locked; then fail_test 'preparatory attempt enabled public execution'; fi
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  current_transition_is_owned
  read_transaction_manifest "$_transaction_id"
  json_is '.recovery.attempt_number == 2 and .recovery.previous_attempt.ordinal == 1' "$_manifest_json"
  rollback_and_mark_recovery 25 'fixture second publication preparation interrupted'
  load_recovery_context
  [[ $_recovery_attempt_count == 2 ]]
  expect_selection_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  [[ $(sha256_file "$TXDIR/manifest.json") == "$root_manifest" &&
    $(sha256_file "$TXDIR/incident.json") == "$root_seal" && $(journal_fingerprint) == "$root_journal" &&
    $(sha256_file "$(lifecycle_incident_path "$first_attempt")") == "$first_seal" &&
    $(sha256_file "$(lifecycle_manifest_path "$first_attempt")") == "$first_manifest" ]]
}
recovery_basis_refusals() {
  local before flags
  basis_complete_fixture
  basis_seal_fixture
  before=$(basis_fixture_fingerprint)
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" 88888888-8888-4888-8888-888888888888; then return 1; fi
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION" extra; then return 1; fi
  _transaction_active=true
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"; then return 1; fi
  _transaction_active=false
  ln -s "$CASE_DIR/no-marker-target" "$(snapshot_restore_lock_path)"
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"; then return 1; fi
  rm -- "$(snapshot_restore_lock_path)"
  touch "$(pacman_database_lock_path)"
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"; then return 1; fi
  rm -- "$(pacman_database_lock_path)"
  flags=$_OMASECBOOT_LIMINE_LOCK_OWNED
  _OMASECBOOT_LIMINE_LOCK_OWNED=false
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"; then return 1; fi
  _OMASECBOOT_LIMINE_LOCK_OWNED=$flags
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
recovery_basis_incomplete() {
  local before
  basis_complete_fixture
  basis_seal_fixture
  before=$(basis_fixture_fingerprint)
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"; then return 1; fi
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
recovery_basis_schema_fences() {
  local manifest altered filter before body
  basis_complete_fixture
  basis_seal_fixture
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  read_transaction_manifest "$_transaction_id"
  manifest=$_manifest_json
  before=$(sha256_file "$(lifecycle_manifest_path "$_transaction_id")")
  for filter in '.publication_records=[]' '.schema_version=2 | del(.publication_records)' \
    '.kind="root" | .recovery=null | .prior_state="active"' '.operation="software-recovery"' \
    '.operation="producer-recovery"' '.target_state="disabled"' '.file_rollback_policy="restore"' \
    '.current_phase="retain-originals"' '.completed_phases=["retain-originals"]' \
    '.publication_records += .publication_records' \
    '.status="completed" | .completed_at=.created_at' \
    '.domain_records.final_proof=.publication_records[0]' \
    '.backups += [{kind:"absent-file",path:null,sha256:null,target:"/boot/foreign",uid:null,gid:null,mode:null}]'; do
    altered=$(jq -c "$filter" <<<"$manifest")
    if validate_transaction_manifest_json "$_transaction_id" "$altered" false; then
      fail_test "preparatory attempt admitted $filter"
    fi
  done
  find_publication_record "$INVOCATION" recovery-basis
  body=$_publication_found_body
  append_publication_record "$INVOCATION" recovery-basis "$body"
  if append_publication_record "$INVOCATION" intent "$INTENT"; then return 1; fi
  [[ $(sha256_file "$(lifecycle_manifest_path "$_transaction_id")") == "$before" ]]
}
recovery_basis_root_refused() {
  local original record before
  basis_complete_fixture
  basis_seal_fixture
  publication_load_complete_original_basis "$BASIS_ROOT_REF" "$INVOCATION"
  original=$_publication_original_basis
  rm -- "$(lifecycle_file_path)"
  detach_transaction_context
  begin_lifecycle_transaction sign active
  preserve_transaction_files_on_failure
  before=$(sha256_file "$(lifecycle_manifest_path "$_transaction_id")")
  record=$(jq -cn --argjson basis "$original" '{basis:$basis}')
  if append_publication_record "$INVOCATION" recovery-basis "$record"; then return 1; fi
  [[ $(sha256_file "$(lifecycle_manifest_path "$_transaction_id")") == "$before" &&
    ! -e $(dirname "$(lifecycle_manifest_path "$_transaction_id")")/publication-1.json ]]
}
recovery_basis_contradictions() {
  local manifest record path altered filter candidate prior prior_path
  basis_complete_fixture
  basis_seal_fixture
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  read_transaction_manifest "$_transaction_id"
  manifest=$_manifest_json
  path=$(jq -r '.publication_records[0].path' <<<"$manifest")
  record=$(read_control_document "$path")
  for filter in '.schema_version=1' '.kind="invocation-start"' '.ordinal=2' \
    '.body.basis.extra=true' '.body.basis.root.sha256=("0"*64)' \
    '.body.basis.configuration=.body.basis.plan' '.body.basis.resources=[]' \
    '.invocation="88888888-8888-4888-8888-888888888888" | .body.basis.invocation=.invocation'; do
    altered=$(jq -c "$filter" <<<"$record")
    printf '%s\n' "$altered" >"$path"
    candidate=$(jq -c --arg hash "$(sha256_file "$path")" '.publication_records[0].sha256=$hash' <<<"$manifest")
    if validate_transaction_manifest_json "$_transaction_id" "$candidate"; then
      fail_test "hash-valid recovery basis admitted $filter"
    fi
  done
  printf '%s\n' "$record" >"$path"
  prior_path=$(jq -r '.backups[0].path' <<<"$manifest")
  prior=$(read_control_document "$prior_path")
  for filter in '.transaction.attempt_count=1' \
    '.transaction.root_incident.sha256=("0"*64)' \
    '.transaction.id="88888888-8888-4888-8888-888888888888"'; do
    jq -c "$filter" <<<"$prior" >"$prior_path"
    candidate=$(jq -c --arg hash "$(sha256_file "$prior_path")" '.backups[0].sha256=$hash' <<<"$manifest")
    if validate_transaction_manifest_json "$_transaction_id" "$candidate"; then
      fail_test "hash-valid prior lifecycle admitted $filter"
    fi
  done
  printf '%s\n' "$prior" >"$prior_path"
  read_transaction_manifest "$_transaction_id"
}
recovery_basis_original_closure() {
  local path
  basis_complete_fixture
  basis_seal_fixture
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  read_transaction_manifest "$_transaction_id"
  if [[ $RECOVERY_TAMPER == record ]]; then path=$TXDIR/publication-1.json
  else path=$(jq -r '.retained.path' <<<"$STAGE"); fi
  printf 'changed original closure\n' >>"$path"
  if read_transaction_manifest "$_transaction_id"; then fail_test 'new attempt trusted cached original authority'; fi
}
recovery_basis_stale() {
  local attempt
  basis_complete_fixture
  basis_seal_fixture
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  attempt=$_transaction_id
  detach_transaction_context
  # A different boot invalidates the real old owner without changing its seal
  # or inventing a prepared/executor result. Only the fixture boot observation is replaced.
  # shellcheck disable=SC2329
  boot_id_value() { printf '99999999-9999-4999-8999-999999999999\n'; }
  reconcile_stale_lifecycle
  load_recovery_context
  [[ $_recovery_attempt_count == 1 ]]
  read_incident_seal "$attempt"
  json_is '.incident_status == "stale" and .kind == "attempt"' "$_incident_json"
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  current_transition_is_owned
  rollback_and_mark_recovery 26 'fixture post-boot retry failed'
  load_recovery_context
  [[ $_recovery_attempt_count == 2 ]]
}
recovery_basis_begin_window() {
  local before rc=0
  basis_complete_fixture
  basis_seal_fixture
  before=$(read_control_document "$(lifecycle_file_path)")
  # shellcheck disable=SC2329
  lifecycle_failpoint() { [[ $1 != "$RECOVERY_WINDOW" ]]; }
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION" || rc=$?
  (( rc != 0 )) || fail_test 'recovery begin failpoint did not fire'
  abandon_failed_begin "$rc" 'fixture recovery constructor'
  read_lifecycle
  [[ $_lifecycle_state == recovery-required && $_transaction_active == false ]]
  if [[ $RECOVERY_WINDOW == after-attempt-transition-write ]]; then
    json_is '.transaction.attempt_count == 1' "$_lifecycle_json"
  else json_is '.[0] == .[1]' "[$before,$_lifecycle_json]"; fi
}
recovery_basis_selection_drift() {
  basis_complete_fixture
  basis_seal_fixture
  # shellcheck disable=SC2329
  lifecycle_failpoint() {
    [[ $1 == after-attempt-manifest-write ]] || return 0
    jq "$RECOVERY_DRIFT" "$(lifecycle_file_path)" >"$CASE_DIR/drifted-lifecycle"
    mv -- "$CASE_DIR/drifted-lifecycle" "$(lifecycle_file_path)"
    read_lifecycle || return 1
    printf '%s\n' "$_lifecycle_json" >"$CASE_DIR/expected-drift"
  }
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"; then return 1; fi
  read_lifecycle
  [[ $_transaction_active == false && $_lifecycle_state == recovery-required ]]
  json_is '.[0] == .[1]' "[$_lifecycle_json,$(read_control_document "$CASE_DIR/expected-drift")]"
  json_is '.transaction.attempt_count == 0' "$_lifecycle_json"
}
recovery_basis_no_invocation_switch() {
  local first=$INVOCATION other=66666666-6666-4666-8666-666666666666 other_basis before path record manifest
  basis_complete_fixture
  INVOCATION=$other basis_complete_fixture
  basis_seal_fixture
  publication_load_complete_original_basis "$BASIS_ROOT_REF" "$other"
  other_basis=$_publication_original_basis
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$first"
  rollback_and_mark_recovery 27 'fixture selected original interrupted'
  before=$(basis_fixture_fingerprint)
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$other"; then return 1; fi
  [[ $(basis_fixture_fingerprint) == "$before" ]]
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$first"
  read_transaction_manifest "$_transaction_id"
  manifest=$_manifest_json
  path=$(jq -r '.publication_records[0].path' <<<"$manifest")
  record=$(jq -c --arg other "$other" --argjson basis "$other_basis" \
    '.invocation=$other | .body.basis=$basis' "$path")
  printf '%s\n' "$record" >"$path"
  manifest=$(jq -c --arg hash "$(sha256_file "$path")" '.publication_records[0].sha256=$hash' <<<"$manifest")
  printf '%s\n' "$manifest" >"$(lifecycle_manifest_path "$_transaction_id")"
  # Individually valid root-selected data must still join the immediately prior
  # attempt, including while transition is live rather than already sealed.
  validate_transaction_manifest_json "$_transaction_id" "$manifest"
  if read_lifecycle; then fail_test 'live retry changed selected original invocation'; fi
}
recovery_basis_late_boundary() {
  local rc=0 expected
  basis_complete_fixture
  basis_seal_fixture
  eval "$(declare -f validate_lifecycle_document_references | \
    sed '1s/validate_lifecycle_document_references/fixture_recovery_validate_references/')"
  # shellcheck disable=SC2329
  validate_lifecycle_document_references() {
    fixture_recovery_validate_references "$@" || return "$?"
    if [[ ! -e $CASE_DIR/late-injected ]] && json_is \
      '.state == "transition" and .transaction.operation == "publication-recovery"' "$1"; then
      case $RECOVERY_LATE in
        marker) touch "$(snapshot_restore_lock_path)" ;;
        pacman) touch "$(pacman_database_lock_path)" ;;
        boot|repair)
          local path
          if [[ $RECOVERY_LATE == boot ]]; then path=$(limine_lock_path)
          else path="$(state_dir_path)/repair.lock"; fi
          mv -- "$path" "$path.old"
          touch "$path" ;;
        selection|refreshed-selection)
          jq '.updated_at="2000-01-01T00:00:00Z"' "$(lifecycle_file_path)" >"$CASE_DIR/late-lifecycle"
          mv -- "$CASE_DIR/late-lifecycle" "$(lifecycle_file_path)"
          [[ $RECOVERY_LATE != refreshed-selection ]] || read_lifecycle || return 1 ;;
      esac
      sha256_file "$(lifecycle_file_path)" >"$CASE_DIR/late-expected-hash"
      touch "$CASE_DIR/late-injected"
    fi
  }
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION" || rc=$?
  (( rc != 0 )) && [[ -e $CASE_DIR/late-injected ]] || fail_test 'late boundary was not refused'
  abandon_failed_begin "$rc" 'fixture late recovery refusal'
  read -r expected <"$CASE_DIR/late-expected-hash"
  [[ $(sha256_file "$(lifecycle_file_path)") == "$expected" && $_transaction_active == false ]]
  read_lifecycle
  json_is '.state == "recovery-required" and .transaction.attempt_count == 0' "$_lifecycle_json"
  if [[ $RECOVERY_LATE == boot ]]; then [[ $_OMASECBOOT_LIMINE_LOCK_OWNED == false ]]; fi
  if [[ $RECOVERY_LATE == repair ]]; then [[ $_OMASECBOOT_REPAIR_LOCK_OWNED == false ]]; fi
}
recovery_basis_sync_window() {
  local rc=0 before attempt_directory
  basis_complete_fixture
  basis_seal_fixture
  before=$(read_control_document "$(lifecycle_file_path)")
  attempt_directory=$(dirname "$(lifecycle_manifest_path 77777777-7777-4777-8777-777777777777)")
  # shellcheck disable=SC2329
  new_transaction_id() { printf '77777777-7777-4777-8777-777777777777\n'; }
  eval "$(declare -f durable_sync | sed '1s/durable_sync/fixture_recovery_sync/')"
  # shellcheck disable=SC2329
  durable_sync() {
    local inject=false
    if [[ ! -e $CASE_DIR/recovery-sync-injected ]]; then
      case $RECOVERY_SYNC in
        prior-file) [[ $1 != "$attempt_directory/prior-lifecycle.json" ]] || inject=true ;;
        basis-file|basis-substitution) [[ $1 != "$attempt_directory/publication-1.json" ]] || inject=true ;;
        basis-directory)
          [[ $1 != "$attempt_directory" || ! -e $attempt_directory/publication-1.json ||
            -e $attempt_directory/manifest.json ]] || inject=true ;;
        manifest-directory)
          [[ $1 != "$attempt_directory" || ! -e $attempt_directory/manifest.json ]] || inject=true ;;
        lifecycle-directory)
          if [[ $1 == "$(state_dir_path)" ]] && json_is '.state == "transition" and
            .transaction.operation == "publication-recovery"' "$(read_control_document "$(lifecycle_file_path)")"; then inject=true; fi ;;
      esac
    fi
    if [[ $inject == true ]]; then
      touch "$CASE_DIR/recovery-sync-injected"
      if [[ $RECOVERY_SYNC == basis-substitution ]]; then
        fixture_recovery_sync "$@" || return "$?"
        jq '.body.basis.root_operation="windows-bootnext"' "$1" >"$CASE_DIR/substitute-basis"
        mv -- "$CASE_DIR/substitute-basis" "$1"
        return 0
      fi
      return 1
    fi
    fixture_recovery_sync "$@"
  }
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION" || rc=$?
  (( rc != 0 )) && [[ -e $CASE_DIR/recovery-sync-injected ]] || fail_test 'recovery sync fault did not fire'
  abandon_failed_begin "$rc" 'fixture recovery sync failure'
  read_lifecycle
  [[ $_lifecycle_state == recovery-required && $_transaction_active == false ]]
  if [[ $RECOVERY_SYNC == lifecycle-directory ]]; then
    json_is '.transaction.attempt_count == 1' "$_lifecycle_json"
    validate_incident_chain "$BASIS_ROOT_REF" "$(jq -c '.transaction.last_recovery_attempt' <<<"$_lifecycle_json")" 1 false
  else json_is '.[0] == .[1]' "[$before,$_lifecycle_json]"; fi
}
recovery_basis_capacity() {
  local template record_template seal_template previous ordinal id directory backups record reference manifest seal lifecycle before
  basis_complete_fixture
  basis_seal_fixture
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  rollback_and_mark_recovery 28 'fixture first bounded attempt'
  read_transaction_manifest "$_transaction_id"
  template=$_manifest_json
  record_template=$(read_control_document "$(jq -r '.publication_records[0].path' <<<"$template")")
  seal_template=$(read_control_document "$(lifecycle_incident_path "$_transaction_id")")
  read_lifecycle
  previous=$(jq -c '.transaction.last_recovery_attempt' <<<"$_lifecycle_json")
  # Synthesize immutable data from the real first failure, with each prior
  # lifecycle binding its own actual predecessor/count. Final validation uses
  # the real readers; this avoids quadratic repeated constructor work in setup.
  for ((ordinal=2; ordinal<=MAX_RECOVERY_ATTEMPT_SEALS; ordinal++)); do
    id=$(new_transaction_id)
    directory=$(create_transaction_dir "$id")
    backups=$(prior_lifecycle_backups "$directory")
    record=$(jq -c --arg id "$id" '.transaction_id=$id' <<<"$record_template")
    printf '%s\n' "$record" | atomic_create_control_file "$directory/publication-1.json" 600
    reference=$(transaction_artifact_reference "$directory/publication-1.json" 2)
    manifest=$(jq -c --arg id "$id" --argjson ordinal "$ordinal" --argjson previous "$previous" \
      --argjson backups "$backups" --argjson reference "$reference" '
      .id=$id | .recovery.attempt_number=$ordinal | .recovery.previous_attempt=$previous |
      .backups=$backups | .publication_records=[$reference]' <<<"$template")
    printf '%s\n' "$manifest" | atomic_create_control_file "$directory/manifest.json" 600
    seal=$(jq -c --arg id "$id" --arg manifest "$directory/manifest.json" \
      --arg hash "$(sha256_file "$directory/manifest.json")" --argjson ordinal "$ordinal" --argjson previous "$previous" '
      .id=$id | .manifest=$manifest | .manifest_sha256=$hash | .ordinal=$ordinal | .previous_attempt=$previous' <<<"$seal_template")
    printf '%s\n' "$seal" | atomic_create_control_file "$directory/incident.json" 600
    previous=$(incident_reference_from_json "$seal" "$directory/incident.json")
    lifecycle=$(jq -c --argjson previous "$previous" --argjson ordinal "$ordinal" '
      .generation+=1 | .transaction.last_recovery_attempt=$previous | .transaction.attempt_count=$ordinal' "$(lifecycle_file_path)")
    printf '%s\n' "$lifecycle" | atomic_write_control_file "$(lifecycle_file_path)" 644
  done
  read_lifecycle
  json_is '.transaction.attempt_count == 32' "$_lifecycle_json"
  before=$(basis_fixture_fingerprint)
  if begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"; then fail_test 'publication attempt33 admitted'; fi
  [[ $(basis_fixture_fingerprint) == "$before" && $_transaction_active == false ]]
}
recovery_copy_valid() {
  local original_manifest original_seal original_journal id before body reference source destination first
  basis_complete_fixture
  basis_seal_fixture
  original_manifest=$(sha256_file "$TXDIR/manifest.json")
  original_seal=$(sha256_file "$TXDIR/incident.json")
  original_journal=$(journal_fingerprint)
  if [[ ${COPY_EXPIRED:-false} == true ]]; then
    rm -rf -- "$CASE_DIR/esp"
    rm -- "$CASE_DIR/source" "$TXDIR"/.publication-input.*
  fi
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  # Fresh signature/platform/target authority belongs to the later engine. A
  # data copy must not sign, render or read expired producer/boot objects.
  # shellcheck disable=SC2329
  publication_run_sbctl() { fail_test 'recovery copy invoked signing/verification'; }
  for id in kernel configuration; do
    retain_publication_recovery_input "$id"
    body=$_publication_recovery_copy_record reference=$_publication_recovery_copy_reference
    source=$(jq -r '.original_retained.path' <<<"$body")
    destination=$(jq -r '.file.path' <<<"$body")
    cmp -- "$source" "$destination"
    [[ $(stat -c %a "$destination") == 400 && $source != "$destination" ]]
    json_is '.[0].file.sha256 == .[0].original_retained.sha256 and
      .[0].file.bytes == .[0].original_retained.bytes and .[1].schema_version == 2' "[$body,$reference]"
    if [[ $id == kernel && ${BASIS_SIGNING:-bytes} == local-efi ]]; then
      json_is '.original_source.sha256 != .file.sha256 and .signing == "local-efi"' "$body"
    fi
    publication_resolve_sealed_record "$BASIS_ROOT_REF" "$(jq -c '.original_record' <<<"$body")" \
      "$INVOCATION" "$(if [[ $id == configuration ]]; then printf configuration; else printf retained; fi)"
    first=$reference
    before=$(basis_fixture_fingerprint)
    retain_publication_recovery_input "$id"
    [[ $_publication_recovery_copy_reference == "$first" && $(basis_fixture_fingerprint) == "$before" ]]
  done
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 5' "$_manifest_json"
  if commit_lifecycle_recovery_attempt; then fail_test 'private copies enabled completion'; fi
  rollback_and_mark_recovery 29 'fixture complete private copies interrupted'
  load_recovery_context
  [[ $_recovery_attempt_count == 1 ]]
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  retain_publication_recovery_input kernel
  [[ $(sha256_file "$TXDIR/manifest.json") == "$original_manifest" &&
    $(sha256_file "$TXDIR/incident.json") == "$original_seal" && $(journal_fingerprint) == "$original_journal" ]]
}
recovery_copy_historical_root_name() {
  local legacy current
  legacy=$(jq -c '.operation="publication-recovery" | .schema_version=2 | del(.publication_records)' <<<"$_manifest_json")
  validate_transaction_manifest_json "$_transaction_id" "$legacy"
  current=$(jq -c '.schema_version=3 | .publication_records=[]' <<<"$legacy")
  validate_transaction_manifest_json "$_transaction_id" "$current"
  if recovery_operation_for_lineage "$legacy" publication-recovery; then return 1; fi
  if recovery_operation_for_root_manifest "$legacy"; then return 1; fi
  commit_lifecycle_transaction
  begin_lifecycle_transaction publication-recovery active
  if retain_publication_recovery_input kernel; then return 1; fi
  [[ -z $_publication_recovery_copy_record && -z $_publication_recovery_copy_reference ]]
}
recovery_copy_cache_fixture() {
  basis_complete_fixture
  basis_seal_fixture
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  retain_publication_recovery_input kernel
  COPY_BODY=$_publication_recovery_copy_record
  COPY_REF=$_publication_recovery_copy_reference
  read_transaction_manifest "$_transaction_id"
  COPY_MANIFEST=$_manifest_json
  COPY_CACHE_SLOT="$_transaction_id:$(control_owner_uid)"
  [[ -n ${_publication_recovery_validation_cache[$COPY_CACHE_SLOT]:-} ]]
  eval "$(declare -f publication_load_complete_original_basis | \
    sed '1s/publication_load_complete_original_basis/fixture_copy_load_basis/')"
  # Count expensive reconstruction without logging arguments or control data.
  # shellcheck disable=SC2329
  publication_load_complete_original_basis() {
    printf 'cold\n' >>"$CASE_DIR/cold-basis-calls"
    fixture_copy_load_basis "$@"
  }
}
recovery_copy_cache_reuse() {
  local before
  recovery_copy_cache_fixture
  before=$(basis_fixture_fingerprint)
  read_transaction_manifest "$_transaction_id"
  validate_publication_recovery_records "$_transaction_id" "$COPY_MANIFEST"
  [[ ! -e $CASE_DIR/cold-basis-calls ]] || fail_test 'warm copy validation reconstructed original semantics'
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
recovery_copy_cache_tamper() {
  local path
  recovery_copy_cache_fixture
  case $COPY_CACHE_FAULT in
    original-record) path=$TXDIR/publication-1.json ;;
    original-retained) path=$(jq -r '.original_retained.path' <<<"$COPY_BODY") ;;
    copied|copied-mode) path=$(jq -r '.file.path' <<<"$COPY_BODY") ;;
    record) path=$(jq -r '.path' <<<"$COPY_REF") ;;
    prior) path=$(jq -r '.backups[0].path' <<<"$COPY_MANIFEST") ;;
  esac
  if [[ $COPY_CACHE_FAULT == copied-mode ]]; then chmod 644 "$path"
  else chmod u+w "$path"; printf 'changed cached dependency\n' >>"$path"; fi
  if validate_publication_recovery_records "$_transaction_id" "$COPY_MANIFEST"; then
    fail_test "warm cache ignored $COPY_CACHE_FAULT"
  fi
  [[ -z ${_publication_recovery_validation_cache[$COPY_CACHE_SLOT]:-} ]] || fail_test 'failed cache entry was retained'
}
recovery_copy_cache_key_and_pending() {
  local altered pending saved
  recovery_copy_cache_fixture
  altered=$(jq -c '.recovery.attempt_number+=1' <<<"$COPY_MANIFEST")
  if validate_publication_recovery_records "$_transaction_id" "$altered"; then fail_test 'cache ignored changed lineage'; fi
  [[ -s $CASE_DIR/cold-basis-calls ]]
  read_transaction_manifest "$_transaction_id"
  saved=${_publication_recovery_validation_cache[$COPY_CACHE_SLOT]}
  pending=$(jq -c '.body.original_source.sha256=("0"*64)' "$(jq -r '.path' <<<"$COPY_REF")")
  if validate_publication_recovery_records "$_transaction_id" "$COPY_MANIFEST" "$pending"; then
    fail_test 'warm cache rescued a conflicting pending record'
  fi
  [[ ${_publication_recovery_validation_cache[$COPY_CACHE_SLOT]} == "$saved" ]] || fail_test 'pending validation changed cache'
}
# A2 groups reuse one real sealed root/owned attempt per failure family. Seams
# inject I/O failures only; the ownership, closure and journal readers stay real.
recovery_copy_a2_fixture() {
  local definition name
  basis_complete_fixture
  basis_seal_fixture
  COPY_ROOT_DIR=$TXDIR
  COPY_ROOT_BEFORE=$(journal_fingerprint)
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  COPY_SOURCE=$(jq -r '.retained.path' <<<"$STAGE")
  COPY_DEST=$TXDIR/publication-data-$INVOCATION-kernel
  COPY_EXPECTED=$(jq -cn --argjson record "$BASIS_RETAINED_REF" --argjson retained "$RETAINED_REFERENCE" \
    --argjson resource "$(jq -c '.resources[0]' <<<"$INTENT")" --arg destination "$COPY_DEST" \
    --arg signing "${BASIS_SIGNING:-bytes}" '
    {id:"kernel",original_record:$record,original_source:{path:$resource.source,sha256:$resource.sha256},
      original_retained:$retained,signing:$signing,file:($retained | .path=$destination)}')
  COPY_FAULT='' COPY_CALLS=0 COPY_TEMP='' COPY_OWNER_PATH=''
  for name in publication_run_sbctl verify_publication_input publication_input_is_efi \
    publication_verify_stable_context publication_collect_stable_context publication_validate_plan; do
    eval "$name() { fail_test 'private recovery copy reached $name'; }"
  done
  definition=$(declare -f copy_publication_input)
  eval "${definition/copy_publication_input/recovery_copy_a2_actual_copy}"
  # shellcheck disable=SC2329
  copy_publication_input() {
    local rc=0
    [[ $# == 2 && $1 == "$COPY_SOURCE" && $2 == "$TXDIR/.publication-copy."* ]] || return 1
    COPY_CALLS=$((COPY_CALLS+1)) COPY_TEMP=$2
    case $COPY_FAULT in
      copy-error)
        recovery_copy_a2_actual_copy "$1" "$CASE_DIR/absent-parent/output" || rc=$?
        (( rc != 0 )) || fail_test 'actual copier accepted missing destination parent' ;;
      copy-growth|copy-fifo)
        # Substitute only at the checked copier's open boundary. Original sealed
        # bytes are restored by inode before returning to the journal reader.
        command mv -- "$1" "$CASE_DIR/saved-copy-source"
        if [[ $COPY_FAULT == copy-growth ]]; then
          cp -- "$CASE_DIR/saved-copy-source" "$1"
          chmod u+w "$1"
          printf 'growth after validation, before bounded open\n' >>"$1"
          recovery_copy_a2_actual_copy "$@" || rc=$?
          (( rc == 0 )) && [[ $(stat -c %s "$2") -gt $(stat -c %s "$CASE_DIR/saved-copy-source") ]] ||
            fail_test 'growth seam did not exercise the actual successful bounded copy'
        else
          mkfifo -- "$1"
          # Only the deliberately blocking FIFO uses a local short deadline.
          local _producer_session_io_timeout=1
          recovery_copy_a2_actual_copy "$@" || rc=$?
          [[ $rc == 124 ]] || fail_test "FIFO copy returned $rc instead of deadline status"
        fi
        rm -- "$1"
        command mv -- "$CASE_DIR/saved-copy-source" "$1" ;;
      *) recovery_copy_a2_actual_copy "$@" || rc=$? ;;
    esac
    return "$rc"
  }
  definition=$(declare -f durable_sync)
  eval "${definition/durable_sync/recovery_copy_a2_actual_sync}"
  # shellcheck disable=SC2329
  durable_sync() {
    local n inject=false
    case $COPY_FAULT:$1 in
      temporary-sync:"$TXDIR/.publication-copy."*|ready-record-temp:"$TXDIR/.publication-2.json."*|\
      copied-record-temp:"$TXDIR/.publication-3.json."*|destination-sync:"$COPY_DEST") inject=true ;;
      ready-record-file:"$TXDIR/publication-2.json"|copied-record-file:"$TXDIR/publication-3.json") inject=true ;;
      ready-manifest-temp:"$TXDIR/.manifest.json."*|copied-manifest-temp:"$TXDIR/.manifest.json."*) inject=true ;;
      ready-manifest-file:"$TXDIR/manifest.json"|copied-manifest-file:"$TXDIR/manifest.json")
        n=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
        if [[ $COPY_FAULT == ready-manifest-file && $n == 2 || $COPY_FAULT == copied-manifest-file && $n == 3 ]]; then inject=true; fi ;;
      *:"$TXDIR")
        n=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
        case $COPY_FAULT in
          temporary-directory) [[ -e $TXDIR/publication-2.json ]] || inject=true ;;
          ready-record-directory) [[ ! -e $TXDIR/publication-2.json || $n != 1 ]] || inject=true ;;
          ready-manifest-directory) [[ $n != 2 ]] || inject=true ;;
          renamed-directory) [[ ! -e $COPY_DEST || -e $TXDIR/publication-3.json ]] || inject=true ;;
          copied-record-directory) [[ ! -e $TXDIR/publication-3.json || $n != 2 ]] || inject=true ;;
          copied-manifest-directory) [[ $n != 3 ]] || inject=true ;;
        esac ;;
    esac
    if [[ $inject == true ]]; then
      printf '%s\n' "$COPY_FAULT" >>"$CASE_DIR/copy-faults"
      return 1
    fi
    recovery_copy_a2_actual_sync "$@"
  }
  # shellcheck disable=SC2329
  mv() {
    if [[ ${*: -2:1} == "$TXDIR/.publication-copy."* && ${*: -1} == "$COPY_DEST" ]]; then
      case $COPY_FAULT in
        rename-before) printf '%s\n' "$COPY_FAULT" >>"$CASE_DIR/copy-faults"; return 1 ;;
        rename-after)
          command mv "$@" || return 1
          printf '%s\n' "$COPY_FAULT" >>"$CASE_DIR/copy-faults"
          return 1 ;;
      esac
    fi
    command mv "$@"
  }
  # A narrowly scoped owner-observation fault requires no privileged chown.
  # shellcheck disable=SC2329
  stat() {
    if [[ -n $COPY_OWNER_PATH && ${*: -1} == "$COPY_OWNER_PATH" && $* == *%u* ]]; then printf '999999\n'
    else command stat "$@"; fi
  }
}
recovery_copy_a2_refused() {
  _publication_recovery_copy_record=stale _publication_recovery_copy_reference=stale
  if retain_publication_recovery_input "${1:-kernel}"; then fail_test "copy accepted ${COPY_FAULT:-invalid authority}"; fi
  [[ -z $_publication_recovery_copy_record && -z $_publication_recovery_copy_reference ]] ||
    fail_test 'failed recovery copy retained outputs'
}
recovery_copy_a2_original_unchanged() {
  local TXDIR=$COPY_ROOT_DIR
  [[ $(journal_fingerprint) == "$COPY_ROOT_BEFORE" ]] || fail_test 'copy modified original journal or retained bytes'
  read_incident_seal "$(basename "$TXDIR")"
}
recovery_copy_a2_success() {
  local before reference identity calls=$COPY_CALLS
  COPY_FAULT=''
  retain_publication_recovery_input kernel
  json_is '.[0] == .[1]' "[$_publication_recovery_copy_record,$COPY_EXPECTED]"
  reference=$_publication_recovery_copy_reference
  cmp -- "$COPY_SOURCE" "$COPY_DEST"
  [[ $(stat -c %a "$COPY_DEST") == 400 ]]
  before=$(journal_fingerprint) identity=$(control_file_identity "$COPY_DEST")
  calls=$COPY_CALLS
  retain_publication_recovery_input kernel
  [[ $_publication_recovery_copy_reference == "$reference" && $COPY_CALLS == "$calls" &&
    $(control_file_identity "$COPY_DEST") == "$identity" && $(journal_fingerprint) == "$before" ]]
  recovery_copy_a2_original_unchanged
}
recovery_copy_a2_candidate() {
  # Create only the unbound next record, with its actual hash and predecessor.
  # The pending path is checked too, against the same hash-valid candidate.
  local document=$1 ordinal path reference candidate before cache
  before=$(journal_fingerprint)
  ordinal=$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")
  path=$TXDIR/publication-$ordinal.json
  [[ ! -e $path && ! -L $path ]]
  printf '%s\n' "$document" >"$path"
  reference=$(transaction_artifact_reference "$path" 2)
  validate_artifact_reference_file "$reference" "$TXDIR"
  candidate=$(jq -c --argjson ref "$reference" '.publication_records += [$ref]' "$TXDIR/manifest.json")
  validate_transaction_manifest_json "$_transaction_id" "$candidate" false
  cache=$(declare -p _publication_recovery_validation_cache)
  if validate_publication_recovery_records "$_transaction_id" "$candidate" "$document"; then
    fail_test "pending copy accepted $COPY_MUTATION"
  fi
  [[ $(declare -p _publication_recovery_validation_cache) == "$cache" ]] || fail_test 'pending candidate changed recovery cache'
  if validate_publication_recovery_records "$_transaction_id" "$candidate"; then
    fail_test "historical copy accepted $COPY_MUTATION"
  fi
  rm -- "$path"
  [[ $(journal_fingerprint) == "$before" ]]
  printf 'CHECK: copy candidate/%s\n' "$COPY_MUTATION"
}
recovery_copy_a2_document() {
  jq -cn --arg id "$_transaction_id" --arg invocation "$INVOCATION" --arg kind "$1" --argjson body "$2" \
    --argjson ordinal "$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")" \
    --argjson previous "$(jq -c '.publication_records[-1]' "$TXDIR/manifest.json")" \
    --arg timestamp "$(utc_timestamp)" --arg version "$OMASECBOOT_VERSION" '
    {schema_version:2,transaction_id:$id,invocation:$invocation,ordinal:$ordinal,previous:$previous,
      kind:$kind,body:$body,recorded_at:$timestamp,writer_version:$version}'
}
recovery_copy_a2_provenance() {
  local ready document altered filter COPY_MUTATION
  recovery_copy_a2_fixture
  ready=$(jq -c --arg temporary "$TXDIR/.publication-copy.ABC123" '. + {temporary:$temporary}' <<<"$COPY_EXPECTED")
  document=$(recovery_copy_a2_document retained-copy-ready "$ready")
  for filter in '.schema_version=1' '.body.id="kernel\n"' '.body.original_record.schema_version=2' \
    '.body.original_source.path+="/../source"' '.body.temporary+="x"' '.body.original_retained.bytes=9007199254740992' \
    '.body.file.bytes+=1' '.body.original_retained.sha256=("0"*64)' '.body.fresh_signature=true'; do
    altered=$(jq -c "$filter" <<<"$document")
    if validate_publication_record_json "$_transaction_id" 2 "$(jq -c '.previous' <<<"$document")" "$altered"; then
      fail_test "copy schema admitted $filter"
    fi
  done
  # shellcheck disable=SC2016 # jq-bound peer/plan references.
  for COPY_MUTATION in '.body.original_source.path+=".other"' '.body.original_source.sha256=("0"*64)' \
    '.body.original_record=$peer' '.body.original_record=$plan' '.body.original_record.path+=".foreign"' \
    '.body.id="configuration"' '.body.id="unknown"' '.body.signing="bytes"' \
    '.body.file.path+="-foreign"' '.body.original_retained.path+="-foreign"' \
    '.body.file.sha256=.body.original_source.sha256 | .body.original_retained.sha256=.body.file.sha256'; do
    altered=$(jq -c --argjson peer "$BASIS_CONFIGURATION_REF" --argjson plan "$BASIS_PLAN_REF" "$COPY_MUTATION" <<<"$document")
    validate_publication_record_json "$_transaction_id" 2 "$(jq -c '.previous' <<<"$document")" "$altered"
    recovery_copy_a2_candidate "$altered"
  done
  COPY_MUTATION=copied-before-ready
  recovery_copy_a2_candidate "$(recovery_copy_a2_document retained-copy "$COPY_EXPECTED")"
  COPY_FAULT=rename-before recovery_copy_a2_refused
  ready=$(jq -c '.body' "$TXDIR/publication-2.json")
  COPY_MUTATION=duplicate-ready
  recovery_copy_a2_candidate "$(recovery_copy_a2_document retained-copy-ready "$ready")"
  recovery_copy_a2_success
  COPY_MUTATION=duplicate-copy
  recovery_copy_a2_candidate "$(recovery_copy_a2_document retained-copy "$COPY_EXPECTED")"
  read_transaction_manifest "$_transaction_id"
  for filter in '.current_phase="copy"' '.completed_phases=["copy"]' \
    '.domain_records.final_proof=.publication_records[-1]' '.status="completed" | .completed_at=.created_at'; do
    if validate_transaction_manifest_json "$_transaction_id" "$(jq -c "$filter" <<<"$_manifest_json")" false; then
      fail_test "copied data removed preparatory fence: $filter"
    fi
  done
  if commit_lifecycle_recovery_attempt; then fail_test 'copied data enabled completion'; fi
}
recovery_copy_a2_raw() {
  local document altered COPY_MUTATION
  recovery_copy_a2_fixture
  document=$(recovery_copy_a2_document retained-copy-ready \
    "$(jq -c --arg temporary "$TXDIR/.publication-copy.ABC123" '. + {temporary:$temporary}' <<<"$COPY_EXPECTED")")
  for COPY_MUTATION in duplicate-id duplicate-source fractional-schema fractional-bytes; do
    case $COPY_MUTATION in
      duplicate-id) altered=${document/\"id\":\"kernel\"/\"id\":\"foreign\",\"id\":\"kernel\"} ;;
      duplicate-source) altered=${document/\"original_source\":/\"original_source\":null,\"original_source\":} ;;
      fractional-schema) altered=${document/\"schema_version\":2/\"schema_version\":2.00000000000000000001} ;;
      fractional-bytes)
        local bytes
        bytes=$(jq -r '.file.bytes' <<<"$COPY_EXPECTED")
        altered=${document//\"bytes\":$bytes/\"bytes\":$bytes.00000000000000000001} ;;
    esac
    [[ $altered != "$document" ]]
    # jq builds with decimal preservation can compare the untouched literals
    # exactly; numeric normalization still rounds away these fractions. Keep
    # the bytes raw for BOTH readers, never feed them that normalized document.
    json_is 'def rounded: walk(if type == "number" then . + 0 else . end);
      (.[0] | rounded) == .[1]' "[$altered,$document]"
    if [[ $COPY_MUTATION == fractional-bytes ]]; then
      validate_publication_record_json "$_transaction_id" 2 "$(jq -c '.previous' <<<"$document")" "$altered"
    fi
    recovery_copy_a2_candidate "$altered"
  done
  recovery_copy_a2_success
}
recovery_copy_a2_copy_faults() {
  local before identity hash fault calls
  local -a temporaries
  recovery_copy_a2_fixture
  before=$(journal_fingerprint)
  for fault in equal different; do
    cp -- "$COPY_SOURCE" "$COPY_DEST"
    [[ $fault != different ]] || printf 'unowned canonical bytes\n' >>"$COPY_DEST"
    chmod 400 "$COPY_DEST"
    identity=$(control_file_identity "$COPY_DEST") hash=$(sha256_file "$COPY_DEST")
    recovery_copy_a2_refused
    [[ $(control_file_identity "$COPY_DEST") == "$identity" && $(sha256_file "$COPY_DEST") == "$hash" &&
      $(stat -c %a "$COPY_DEST") == 400 && $COPY_CALLS == 0 ]]
    rm -- "$COPY_DEST"
    [[ $(journal_fingerprint) == "$before" ]]
  done
  for COPY_FAULT in copy-error copy-growth copy-fifo; do
    calls=$COPY_CALLS
    recovery_copy_a2_refused
    [[ $COPY_CALLS == "$((calls+1))" && ! -e $COPY_DEST && $(journal_fingerprint) == "$before" ]]
    shopt -s nullglob
    temporaries=("$TXDIR"/.publication-copy.*)
    [[ ${#temporaries[@]} == 0 ]]
    recovery_copy_a2_original_unchanged
    printf 'CHECK: actual copy/%s\n' "$COPY_FAULT"
  done
  recovery_copy_a2_success
}
recovery_copy_a2_sync_windows() {
  local fault count_before count_after before identity='' ready_hash='' copied_hash='' calls temp
  local -a temporaries
  recovery_copy_a2_fixture
  for fault in $COPY_WINDOWS; do
    COPY_FAULT=$fault
    count_before=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
    calls=$COPY_CALLS
    recovery_copy_a2_refused
    [[ -s $CASE_DIR/copy-faults ]] && [[ $(<"$CASE_DIR/copy-faults") == *"$fault" ]] || fail_test "sync seam missed $fault"
    count_after=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
    (( count_after >= count_before && count_after <= 3 ))
    case $fault in
      temporary-*|ready-record-*|ready-manifest-temp) [[ $count_after == 1 ]] ;;
      ready-manifest-*|rename-*|destination-sync|renamed-directory|copied-record-*|copied-manifest-temp) [[ $count_after == 2 ]] ;;
      copied-manifest-*) [[ $count_after == 3 ]] ;;
    esac
    if [[ -n $ready_hash ]]; then
      [[ $(sha256_file "$TXDIR/publication-2.json") == "$ready_hash" && $COPY_CALLS == "$calls" ]] ||
        fail_test 'bound or pending ready retry replaced evidence or recopied input'
    fi
    if [[ -n $copied_hash ]]; then [[ $(sha256_file "$TXDIR/publication-3.json") == "$copied_hash" ]]; fi
    if [[ -e $TXDIR/publication-2.json ]]; then
      ready_hash=$(sha256_file "$TXDIR/publication-2.json")
      temp=$(jq -r '.body.temporary' "$TXDIR/publication-2.json")
      [[ -e $temp || -e $COPY_DEST ]] || fail_test 'ready failure discarded both private candidates'
      [[ $count_before == 1 || $COPY_CALLS == "$calls" ]] || fail_test 'ready retry recopied input'
    fi
    if [[ -e $TXDIR/publication-3.json ]]; then copied_hash=$(sha256_file "$TXDIR/publication-3.json"); fi
    if [[ -n $identity ]]; then [[ $(control_file_identity "$COPY_DEST") == "$identity" ]]; fi
    if [[ -e $COPY_DEST ]]; then identity=$(control_file_identity "$COPY_DEST"); cmp -- "$COPY_SOURCE" "$COPY_DEST"; fi
    case $fault in
      temporary-sync|temporary-directory)
        shopt -s nullglob
        temporaries=("$TXDIR"/.publication-copy.*)
        [[ ${#temporaries[@]} == 0 && $count_after == 1 ]] ;;
      ready-record-temp)
        [[ -f $COPY_TEMP && ! -e $TXDIR/publication-2.json && $count_after == 1 ]]
        # No canonical record exists yet. Preserve the uncertain orphan itself,
        # but the next invocation must copy anew rather than invent authority.
        before=$(sha256_file "$COPY_TEMP") ;;
    esac
    printf 'CHECK: copy sync/%s (%s -> %s records)\n' "$fault" "$count_before" "$count_after"
  done
  recovery_copy_a2_success
  if [[ -n $ready_hash ]]; then [[ $(sha256_file "$TXDIR/publication-2.json") == "$ready_hash" ]]; fi
  if [[ -n $copied_hash ]]; then [[ $(sha256_file "$TXDIR/publication-3.json") == "$copied_hash" ]]; fi
  # Keep the pre-record uncertain temporary, if that window was exercised.
  if [[ -n ${before:-} ]]; then
    shopt -s nullglob
    temporaries=("$TXDIR"/.publication-copy.*)
    [[ ${#temporaries[@]} == 1 && $(sha256_file "${temporaries[0]}") == "$before" ]]
  fi
}
recovery_copy_a2_control_fingerprint() {
  # Inspect substituted controls without following links or opening special files.
  command stat -c '%F:%f:%u:%g:%d:%i:%s' -- "$1"
  if [[ -L $1 ]]; then readlink -- "$1"
  elif [[ -f $1 ]]; then sha256_file "$1"; fi
}
recovery_copy_a2_unsafe_ready() {
  local temporary location path fault before identity
  recovery_copy_a2_fixture
  COPY_FAULT=rename-before recovery_copy_a2_refused
  COPY_FAULT=''
  temporary=$(jq -r '.body.temporary' "$TXDIR/publication-2.json")
  for location in temporary destination; do
    if [[ $location == temporary ]]; then path=$temporary
    else command mv -- "$temporary" "$COPY_DEST"; path=$COPY_DEST; fi
    for fault in mode owner symlink directory fifo content; do
      command mv -- "$path" "$CASE_DIR/safe-ready-copy"
      case $fault in
        symlink) ln -s -- "$CASE_DIR/safe-ready-copy" "$path" ;;
        directory) mkdir -- "$path" ;;
        fifo) mkfifo -- "$path" ;;
        *) cp -- "$CASE_DIR/safe-ready-copy" "$path"
          case $fault in
            mode) chmod 644 "$path" ;;
            owner) COPY_OWNER_PATH=$path ;;
            content) chmod u+w "$path"; printf 'conflict\n' >>"$path"; chmod 400 "$path" ;;
          esac ;;
      esac
      # Never hash a deliberately substituted FIFO, including through a glob.
      before=$(sha256sum -- "$TXDIR/manifest.json" "$TXDIR"/publication-*.json)
      identity=$(recovery_copy_a2_control_fingerprint "$path")
      recovery_copy_a2_refused
      [[ $(sha256sum -- "$TXDIR/manifest.json" "$TXDIR"/publication-*.json) == "$before" &&
        $(recovery_copy_a2_control_fingerprint "$path") == "$identity" && $COPY_CALLS == 1 ]]
      COPY_OWNER_PATH=''
      if [[ $fault == directory ]]; then rmdir -- "$path"; else rm -- "$path"; fi
      command mv -- "$CASE_DIR/safe-ready-copy" "$path"
      printf 'CHECK: unsafe ready/%s/%s\n' "$location" "$fault"
    done
  done
  recovery_copy_a2_success
}
recovery_copy_a2_missing_ready() {
  local temporary manifest slot saved previous previous_hash seal_hash lifecycle_hash
  recovery_copy_a2_fixture
  COPY_FAULT=rename-before recovery_copy_a2_refused
  COPY_FAULT=''
  temporary=$(jq -r '.body.temporary' "$TXDIR/publication-2.json")
  read_transaction_manifest "$_transaction_id"
  manifest=$_manifest_json slot="$_transaction_id:$(control_owner_uid)"
  saved=${_publication_recovery_validation_cache[$slot]}
  json_is '.copies == []' "$saved"
  rm -- "$temporary"
  # Ready records bind provenance, not historical existence of an uncommitted
  # temporary or canonical file. Both cold and warm readers must retain that.
  validate_publication_recovery_records "$_transaction_id" "$manifest"
  [[ ${_publication_recovery_validation_cache[$slot]} == "$saved" ]]
  _publication_recovery_validation_cache=()
  validate_publication_recovery_records "$_transaction_id" "$manifest"
  recovery_copy_a2_refused
  [[ $COPY_CALLS == 1 && ! -e $COPY_DEST && ! -e $temporary && ! -e $TXDIR/publication-3.json ]]
  rollback_and_mark_recovery 30 'fixture ready copy lost before private rename'
  previous=$TXDIR
  previous_hash=$(sha256_file "$previous/manifest.json") seal_hash=$(sha256_file "$previous/incident.json")
  lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
  load_recovery_context
  if run_registered_recovery_locked; then fail_test 'incomplete private copy enabled public recovery'; fi
  [[ $(sha256_file "$(lifecycle_file_path)") == "$lifecycle_hash" ]]
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  COPY_DEST=$TXDIR/publication-data-$INVOCATION-kernel
  COPY_EXPECTED=$(jq -c --arg path "$COPY_DEST" '.file.path=$path' <<<"$COPY_EXPECTED")
  recovery_copy_a2_success
  [[ $COPY_CALLS == 2 && $(sha256_file "$previous/manifest.json") == "$previous_hash" &&
    $(sha256_file "$previous/incident.json") == "$seal_hash" && ! -e $temporary ]]
}
recovery_copy_a2_owner_loss() {
  local fault token=$OMASECBOOT_TRANSACTION_TOKEN path before
  recovery_copy_a2_fixture
  token=$OMASECBOOT_TRANSACTION_TOKEN
  before=$(journal_fingerprint)
  for fault in owner boot repair marker; do
    path=''
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN='invalid-token' ;;
      boot|repair)
        if [[ $fault == boot ]]; then path=$(limine_lock_path); else path=$(state_dir_path)/repair.lock; fi
        command mv -- "$path" "$path.saved"; touch "$path" ;;
      marker) touch "$(snapshot_restore_lock_path)" ;;
    esac
    recovery_copy_a2_refused
    [[ $COPY_CALLS == 0 && $(journal_fingerprint) == "$before" ]]
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN=$token ;;
      boot|repair)
        if [[ $fault == boot ]]; then [[ $_OMASECBOOT_LIMINE_LOCK_OWNED == false ]]
        else [[ $_OMASECBOOT_REPAIR_LOCK_OWNED == false ]]; fi
        rm -- "$path"; command mv -- "$path.saved" "$path"
        with_boot_repair_lock ;;
      marker) [[ -e $(snapshot_restore_lock_path) ]]; rm -- "$(snapshot_restore_lock_path)" ;;
    esac
  done
  # A marker appearing during actual copy must be seen before ready publication.
  # shellcheck disable=SC2329
  copy_publication_input() {
    COPY_CALLS=$((COPY_CALLS+1)) COPY_TEMP=$2
    recovery_copy_a2_actual_copy "$@" || return 1
    touch "$(snapshot_restore_lock_path)"
  }
  recovery_copy_a2_refused
  [[ $COPY_CALLS == 1 && -e $(snapshot_restore_lock_path) && -f $COPY_TEMP &&
    ! -e $COPY_DEST && $(journal_fingerprint) == "$before" ]]
  recovery_copy_a2_original_unchanged
}
recovery_copy_a2_peer_cache() {
  local peer=66666666-6666-4666-8666-666666666666 peer_file peer_record path manifest slot saved mode
  basis_complete_fixture
  INVOCATION=$peer basis_complete_fixture
  peer_file=$(jq -r '.retained.path' <<<"$STAGE")
  peer_record=$(jq -r '.path' <<<"$BASIS_CONFIGURATION_REF")
  basis_seal_fixture
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  retain_publication_recovery_input kernel
  read_transaction_manifest "$_transaction_id"
  manifest=$_manifest_json slot="$_transaction_id:$(control_owner_uid)"
  for path in "$peer_file" "$peer_record"; do
    saved=${_publication_recovery_validation_cache[$slot]}
    [[ -n $saved ]]
    mode=$(stat -c %a "$path")
    cp -- "$path" "$CASE_DIR/saved-peer"
    chmod u+w "$path"; printf 'unused peer changed\n' >>"$path"
    if validate_publication_recovery_records "$_transaction_id" "$manifest"; then fail_test 'warm copy cache ignored unused original invocation'; fi
    [[ -z ${_publication_recovery_validation_cache[$slot]:-} ]]
    cp -- "$CASE_DIR/saved-peer" "$path"; chmod "$mode" "$path"
    validate_publication_recovery_records "$_transaction_id" "$manifest"
  done
}
# A3 fresh authority: one fresh stable context and one classified observation per
# original effect inside the preparatory attempt. Platform acquisition and the
# signer are seamed; directory opens, FD identity/state checks, the sticky live
# checker, strict decoding and every journal reader stay real.
recovery_target_parent_binding() {
  local parent=$1 create=${2:-false} current component fd state mount previous=null components='[]' dependencies='[]' views='[]' rest
  local -a parts=()
  [[ $_publication_mount_invalid == false && $(publication_namespace_value) == "$_publication_mount_namespace" ]] || { _publication_mount_invalid=true; return 1; }
  if (( ${#_publication_directory_fds[@]} > 0 )); then publication_verify_live || return 1; fi
  [[ $parent == "$CASE_DIR/esp" || $parent == "$CASE_DIR/esp/"* ]] || return 1
  rest=${parent#"$CASE_DIR/esp"}
  if [[ -n $rest ]]; then IFS=/ read -r -a parts <<<"${rest#/}"; fi
  current=$CASE_DIR/esp
  for component in '' "${parts[@]}"; do
    [[ -z $component ]] || current="$current/$component"
    fd=${_publication_directory_fds[$current]:-}
    if [[ -z $fd ]]; then
      [[ $create == false ]] || fail_test "fresh recovery requested creation of $current"
      publication_pin_directory "$current" || return 1
      fd=${_publication_directory_fds[$current]}
    fi
    fd_matches_path "$fd" "$current" || return 1
    state=$(publication_fd_state "$fd") || return 1
    mount=${_publication_directory_mount_ids[$current]}
    publication_verify_path_mount "$current" directory "$mount" "$(jq -r '.identity' <<<"$state")" || return 1
    views=$(jq -c --arg path "$current" --arg mount "$mount" --argjson state "$state" \
      '. + [{path:$path,mount_id:$mount,identity:$state.identity}]' <<<"$views") || return 1
    components=$(jq -c --arg path "$current" --argjson state "$state" '. + [{path:$path,entry:$state,directory:$state}]' <<<"$components") || return 1
    dependencies=$(jq -c --arg path "$current" --argjson state "$state" --argjson previous "$previous" \
      '. + [{path:$path,entry:$state,parent_identity:$previous}]' <<<"$dependencies") || return 1
    previous=$(jq -c '.identity' <<<"$state") || return 1
  done
  _publication_parent=$(jq -cn --arg path "$parent" --argjson components "$components" --argjson dependencies "$dependencies" \
    '{path:$path,components:$components,dependencies:$dependencies}') || return 1
  _publication_parent_view=$(jq -cn --arg namespace "$_publication_mount_namespace" --argjson directories "$views" \
    '{namespace:$namespace,directories:$directories}') || return 1
  publication_verify_live
}
recovery_target_seams() {
  TARGET_COLLECTIONS=0 TARGET_VERIFICATIONS=0 TARGET_LIVE=0
  TARGET_POLICY=$(jq -cn '{certificate:"/var/lib/sbctl/keys/db/db.pem",certificate_sha256:("c"*64),
    configuration:"/etc/sbctl/sbctl.conf",configuration_state:"absent",configuration_sha256:"",
    executable:"/usr/bin/sbctl",executable_sha256:("e"*64)}')
  # shellcheck disable=SC2329
  publication_namespace_value() { printf 'mnt:[8800]\n'; }
  # shellcheck disable=SC2329
  publication_fd_mount_id() { printf '42\n'; }
  # shellcheck disable=SC2329
  publication_check_path_mount() {
    [[ ( $# == 3 || $# == 4 ) && $1 == "$CASE_DIR/esp"* && $3 == 42 ]] || return 1
    case $2 in directory) [[ -d $1 && ! -L $1 ]] || return 1 ;; file) [[ -f $1 && ! -L $1 ]] || return 1 ;; *) return 1 ;; esac
    [[ $# == 3 || $4 == "$(control_file_identity "$1")" ]] || return 1
    TARGET_LIVE=$((TARGET_LIVE+1))
    [[ ${TARGET_FAULT:-} != live ]]
  }
  # shellcheck disable=SC2329
  publication_parent_binding() { recovery_target_parent_binding "$@"; }
  # shellcheck disable=SC2329
  publication_collect_stable_context() {
    TARGET_COLLECTIONS=$((TARGET_COLLECTIONS+1))
    [[ ${TARGET_FAULT:-} != collect && $_publication_mount_invalid == false ]] || return 1
    _publication_collected_context=$(jq -c "${TARGET_CONTEXT_FILTER:-.}" <<<"$CONTEXT")
    _publication_collected_signing_policy=$TARGET_POLICY
  }
  # shellcheck disable=SC2329
  verify_publication_input() {
    TARGET_VERIFICATIONS=$((TARGET_VERIFICATIONS+1))
    # The kernel's private copy, its held stage and, once applied, its target.
    case $1 in
      "$TXDIR/publication-data-$INVOCATION-kernel"|"$CHILD_PATH/kernel") ;;
      *) [[ -n ${_publication_stage_bodies[kernel]:-} && $1 == "$(jq -r '.stage.path' <<<"${_publication_stage_bodies[kernel]}")" ]] ||
           fail_test "unexpected signature verification of $1" ;;
    esac
    return "${TARGET_SIGNATURE_STATUS:-0}"
  }
  # shellcheck disable=SC2329
  publication_run_sbctl() { fail_test 'fresh authorization invoked the signer directly'; }
  # shellcheck disable=SC2329
  publication_validate_targets() { fail_test 'fresh authorization invoked the native validator'; }
  # shellcheck disable=SC2329
  publication_prepare_directory() { fail_test 'fresh authorization created a directory'; }
  TARGET_REAL_STAGE_FILE=$(declare -f publication_stage_file)
  # shellcheck disable=SC2329
  publication_stage_file() { fail_test 'fresh authorization staged a file'; }
  # A narrowly scoped owner-observation fault requires no privileged chown.
  # shellcheck disable=SC2329
  stat() {
    if [[ -n ${TARGET_OWNER_PATH:-} && ${*: -1} == "$TARGET_OWNER_PATH" && $* == *%u* ]]; then printf '999999\n'
    else command stat "$@"; fi
  }
  TARGET_OWNER_PATH=''
}
recovery_target_fixture() {
  basis_complete_fixture
  basis_seal_fixture
  TARGET_ROOT_DIR=$TXDIR
  TARGET_ROOT_BEFORE=$(journal_fingerprint)
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  if [[ ${TARGET_COPIES:-both} != none ]]; then
    retain_publication_recovery_input kernel
    TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
    if [[ ${TARGET_COPIES:-both} == both ]]; then
      retain_publication_recovery_input configuration
      TARGET_CONFIG_COPY=$_publication_recovery_copy_record TARGET_CONFIG_COPY_REF=$_publication_recovery_copy_reference
    fi
  fi
  recovery_target_seams
}
recovery_target_original_unchanged() {
  local TXDIR=$TARGET_ROOT_DIR
  [[ $(journal_fingerprint) == "$TARGET_ROOT_BEFORE" ]] || fail_test 'fresh authorization modified the original root'
  read_incident_seal "$(basename "$TXDIR")"
}
recovery_target_context_refused() {
  local before
  before=$(journal_fingerprint)
  _publication_recovery_context_record=stale _publication_recovery_context_reference=stale
  if prepare_publication_recovery_context; then fail_test "context accepted ${1:-invalid acquisition}"; fi
  [[ -z $_publication_recovery_context_record && -z $_publication_recovery_context_reference ]] || fail_test 'refused context retained outputs'
  [[ $(journal_fingerprint) == "$before" ]] || fail_test "refused context changed the journal: ${1:-}"
  [[ -z $_publication_stable_context && -z $_publication_signing_policy ]] || fail_test 'refused context kept memory authority'
}
recovery_target_refused() {
  local before
  before=$(journal_fingerprint)
  _publication_recovery_authorization_record=stale _publication_recovery_authorization_reference=stale
  if authorize_publication_recovery_target "${2:-kernel}"; then fail_test "authorization accepted ${1:-invalid target}"; fi
  [[ -z $_publication_recovery_authorization_record && -z $_publication_recovery_authorization_reference ]] ||
    fail_test 'refused authorization retained outputs'
  [[ $(journal_fingerprint) == "$before" ]] || fail_test "refused authorization changed the journal: ${1:-}"
}
recovery_target_assert_context() {
  local body=$1 reference=$2 original
  json_is '.[0].context == .[1] and .[0].signing_policy == .[2]' "[$body,$CONTEXT,$TARGET_POLICY]"
  if [[ ${BASIS_CONTEXT:-bound} == start ]]; then original=$(jq -cn --argjson ref "$BASIS_START_REF" '{reference:$ref,projection:".body.context"}')
  else original=$(jq -cn --argjson ref "$BASIS_CONTEXT_REF" '{reference:$ref,projection:".body"}'); fi
  json_is '.[0].original_context == .[1]' "[$body,$original]"
  jq -e --argjson reference "$reference" '.publication_records | index($reference) != null' "$TXDIR/manifest.json" >/dev/null
  jq -e --argjson body "$body" '.schema_version == 2 and .kind == "recovery-context" and .body == $body' "$(jq -r '.path' <<<"$reference")" >/dev/null
  # The record is the attempt's typed context authority part.
  find_publication_authority_part "$INVOCATION" context
  json_is '.[0] == .[1]' "[$_publication_found_body,$CONTEXT]"
  [[ $_publication_found_reference == "$reference" && $_publication_found_container_kind == recovery-context &&
    $_publication_found_projection == .body.context ]]
}
recovery_target_assert_authorization() {
  local id=$1 classification=$2 body=$3 reference=$4 copy copy_reference target state=null der
  if [[ $id == kernel ]]; then copy=$TARGET_KERNEL_COPY copy_reference=$TARGET_KERNEL_COPY_REF target=$CHILD_PATH/kernel
  else copy=$TARGET_CONFIG_COPY copy_reference=$TARGET_CONFIG_COPY_REF target=$CASE_DIR/esp/limine.conf; fi
  if [[ $classification != allowed-absence ]]; then state=$(basis_file_state "$target"); fi
  der=$(jq -r '.local_db_certificate_der_sha256' <<<"$CONTEXT")
  # shellcheck disable=SC2016 # jq-bound expected values.
  jq -e --arg id "$id" --arg target "$target" --arg classification "$classification" --argjson copy "$copy" \
    --argjson ref "$copy_reference" --argjson state "$state" --arg der "$der" '
    .id == $id and .target == $target and .classification == $classification and
    .copy.reference == $ref and .copy.file == $copy.file and .observation.path == .target and
    .original_effect.id == $id and (.original_effect | has("basis") | not) and
    .original_effect.desired.sha256 == $copy.file.sha256 and .mount_view.namespace == "mnt:[8800]" and
    .parent.path == (.target | split("/")[:-1] | join("/")) and
    (.mount_view.directories | map({path,identity})) == (.parent.components | map({path,identity:.directory.identity})) and
    (if $classification == "allowed-absence" then .observation.state.kind == "absent" else .observation.state == $state end) and
    (if .original_effect.signing == "local-efi" then .signature == {verified:true,certificate_der_sha256:$der}
     else .signature == null end)' <<<"$body" >/dev/null
  jq -e --argjson reference "$reference" '.publication_records | index($reference) != null' "$TXDIR/manifest.json" >/dev/null
  jq -e --argjson body "$body" '.schema_version == 2 and .kind == "target-authorization" and .body == $body' "$(jq -r '.path' <<<"$reference")" >/dev/null
}
recovery_target_valid() {
  local context_body context_reference before body reference kernel_reference verifications
  recovery_target_fixture
  # Authorization needs the fresh context first, and the context needs no target.
  recovery_target_refused before-context kernel
  prepare_publication_recovery_context
  context_body=$_publication_recovery_context_record context_reference=$_publication_recovery_context_reference
  [[ $TARGET_COLLECTIONS == 1 ]]
  recovery_target_assert_context "$context_body" "$context_reference"
  # Replay re-acquires, compares and rebinds the same record.
  before=$(journal_fingerprint)
  prepare_publication_recovery_context
  [[ $_publication_recovery_context_reference == "$context_reference" && $(journal_fingerprint) == "$before" && $TARGET_COLLECTIONS == 2 ]]
  # The resource target is absent: v1 original absence or v2 explicit recreation.
  authorize_publication_recovery_target kernel
  body=$_publication_recovery_authorization_record kernel_reference=$_publication_recovery_authorization_reference
  recovery_target_assert_authorization kernel allowed-absence "$body" "$kernel_reference"
  if [[ ${BASIS_SIGNING:-bytes} == local-efi ]]; then [[ $TARGET_VERIFICATIONS == 1 ]]; else [[ $TARGET_VERIFICATIONS == 0 ]]; fi
  verifications=$TARGET_VERIFICATIONS
  # The configuration target still carries the original bytes.
  authorize_publication_recovery_target configuration
  body=$_publication_recovery_authorization_record reference=$_publication_recovery_authorization_reference
  recovery_target_assert_authorization configuration prior "$body" "$reference"
  [[ $TARGET_VERIFICATIONS == "$verifications" ]]
  # Unchanged observations replay to the same records without new evidence.
  before=$(journal_fingerprint)
  authorize_publication_recovery_target kernel
  [[ $_publication_recovery_authorization_reference == "$kernel_reference" ]]
  authorize_publication_recovery_target configuration
  [[ $_publication_recovery_authorization_reference == "$reference" && $(journal_fingerprint) == "$before" ]]
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 8 and all(.schema_version == 2)' "$_manifest_json"
  # A changed target after authorization is a changed observation, not a rewrite.
  cp -- "$(jq -r '.file.path' <<<"$TARGET_CONFIG_COPY")" "$CASE_DIR/esp/limine.conf.next"
  command mv -- "$CASE_DIR/esp/limine.conf.next" "$CASE_DIR/esp/limine.conf"
  recovery_target_refused changed-observation configuration
  json_is '.[0] == .[1]' "[$(jq -c '.body' "$(jq -r '.path' <<<"$reference")"),$body]"
  # Fresh observations still fence completion and phases.
  if commit_lifecycle_recovery_attempt; then fail_test 'fresh authorizations enabled completion'; fi
  recovery_target_original_unchanged
  # Interruption seals this attempt; a new attempt observes afresh in a new
  # process, whose pins are its own. Release this process's pins to model that.
  rollback_and_mark_recovery 31 'fixture authorization interrupted'
  load_recovery_context
  [[ $_recovery_attempt_count == 1 ]]
  release_publication_pins
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  retain_publication_recovery_input kernel
  TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
  prepare_publication_recovery_context
  [[ $TARGET_COLLECTIONS == 3 ]]
  authorize_publication_recovery_target kernel
  recovery_target_assert_authorization kernel allowed-absence "$_publication_recovery_authorization_record" "$_publication_recovery_authorization_reference"
  recovery_target_original_unchanged
}
recovery_target_desired_and_conflicts() {
  local body reference
  recovery_target_fixture
  prepare_publication_recovery_context
  # Desired bytes already present under a new inode classify as desired, with a
  # fresh signature check of the private copy for local EFI.
  cp -- "$(jq -r '.file.path' <<<"$TARGET_KERNEL_COPY")" "$CHILD_PATH/kernel"
  chmod 600 "$CHILD_PATH/kernel"
  authorize_publication_recovery_target kernel
  body=$_publication_recovery_authorization_record reference=$_publication_recovery_authorization_reference
  recovery_target_assert_authorization kernel desired "$body" "$reference"
  # Third-state configuration content is a conflict: refused without a record.
  printf 'unrelated third-state configuration\n' >"$CASE_DIR/esp/limine.conf"
  recovery_target_refused third-state-content configuration
  # Absent configuration is permitted only by v2 explicit recreation.
  rm -- "$CASE_DIR/esp/limine.conf"
  if [[ ${BASIS_CONTEXT:-bound} == start ]]; then
    authorize_publication_recovery_target configuration
    recovery_target_assert_authorization configuration allowed-absence "$_publication_recovery_authorization_record" "$_publication_recovery_authorization_reference"
  else
    recovery_target_refused absent-configuration configuration
  fi
  recovery_target_original_unchanged
}
recovery_target_refusals() {
  local fault before target
  recovery_target_fixture
  target=$CHILD_PATH/kernel
  for fault in context-machine context-certificate context-esp collect; do
    case $fault in
      context-machine) TARGET_CONTEXT_FILTER='.machine_id="22222222222222222222222222222222"' ;;
      context-certificate) TARGET_CONTEXT_FILTER='.local_db_certificate_der_sha256=("b"*64)' ;;
      context-esp) TARGET_CONTEXT_FILTER='.esp.partition_uuid="cccccccc-cccc-4ccc-8ccc-cccccccccccc"' ;;
      collect) TARGET_FAULT=collect ;;
    esac
    recovery_target_context_refused "$fault"
    TARGET_CONTEXT_FILTER='' TARGET_FAULT=''
    printf 'CHECK: context refusal/%s\n' "$fault"
  done
  prepare_publication_recovery_context
  recovery_target_refused unknown-id unknown
  recovery_target_refused reserved-id original-configuration
  # A missing ancestor is refused before any pin exists; creation is later work.
  # A pinned ancestor that later disappears invalidates the live view instead.
  for fault in missing-parent symlink directory unsafe-mode foreign-owner third-state live moved-parent; do
    before=$(basis_fixture_fingerprint)
    case $fault in
      missing-parent|moved-parent) command mv -- "$CHILD_PATH" "$CHILD_PATH.moved" ;;
      symlink) ln -s -- "$CASE_DIR/source" "$target" ;;
      directory) mkdir -- "$target" ;;
      unsafe-mode) cp -- "$(jq -r '.file.path' <<<"$TARGET_KERNEL_COPY")" "$target"; chmod 666 "$target" ;;
      foreign-owner) cp -- "$(jq -r '.file.path' <<<"$TARGET_KERNEL_COPY")" "$target"; chmod 600 "$target"; TARGET_OWNER_PATH=$target ;;
      third-state) printf 'unrelated bytes\n' >"$target" ;;
      live) TARGET_FAULT=live ;;
    esac
    recovery_target_refused "$fault" kernel
    # A non-regular object at a held mount is lost custody and latches, like a
    # failed live check; unsafe or conflicting regular files simply refuse.
    case $fault in
      live|moved-parent|symlink|directory) [[ $_publication_mount_invalid == true ]] || fail_test "lost custody not latched after $fault" ;;
      *) [[ $_publication_mount_invalid == false ]] || fail_test "live view invalidated by $fault" ;;
    esac
    case $fault in
      directory) rmdir -- "$target"; _publication_mount_invalid=false ;;
      symlink) rm -- "$target"; _publication_mount_invalid=false ;;
      live) TARGET_FAULT='' _publication_mount_invalid=false ;;
      missing-parent|moved-parent) command mv -- "$CHILD_PATH.moved" "$CHILD_PATH"; _publication_mount_invalid=false ;;
      foreign-owner) TARGET_OWNER_PATH=''; rm -- "$target" ;;
      *) rm -- "$target" ;;
    esac
    [[ $(basis_fixture_fingerprint) == "$before" ]] || fail_test "refusal $fault left filesystem changes"
    printf 'CHECK: target refusal/%s\n' "$fault"
  done
  if [[ ${BASIS_SIGNING:-bytes} == local-efi ]]; then
    for fault in 1 2; do
      TARGET_SIGNATURE_STATUS=$fault recovery_target_refused "signature-status-$fault" kernel
      printf 'CHECK: target refusal/signature-status-%s\n' "$fault"
    done
    [[ $TARGET_VERIFICATIONS == 2 ]]
  fi
  authorize_publication_recovery_target kernel
  recovery_target_assert_authorization kernel allowed-absence "$_publication_recovery_authorization_record" "$_publication_recovery_authorization_reference"
  recovery_target_original_unchanged
}
recovery_target_capture_fixture() {
  # Capture valid record bodies without binding them, so hash-valid candidates
  # derive from real writer output. The seam refuses only the selected append.
  local definition
  recovery_target_fixture
  TARGET_TOKEN=$OMASECBOOT_TRANSACTION_TOKEN
  definition=$(declare -f append_publication_record)
  eval "${definition/append_publication_record/recovery_target_actual_append}"
  # shellcheck disable=SC2329
  append_publication_record() {
    if [[ -n ${TARGET_CAPTURE:-} && $2 == "$TARGET_CAPTURE" ]]; then
      printf '%s\n' "$3" >"$CASE_DIR/captured-$2"
      return 1
    fi
    recovery_target_actual_append "$@"
  }
}
recovery_target_candidate() {
  # Both the pending and the historical reader must refuse this hash-valid record.
  recovery_copy_a2_candidate "$(recovery_copy_a2_document "$1" "$2")"
}
recovery_target_schema_refused() {
  local kind=$1 body=$2 filter=$3 altered
  altered=$(jq -c "$filter" <<<"$(recovery_copy_a2_document "$kind" "$body")")
  if validate_publication_record_json "$_transaction_id" "$(jq -r '.ordinal' <<<"$altered")" \
    "$(jq -c '.previous' <<<"$altered")" "$altered"; then fail_test "$kind schema admitted $filter"; fi
}
recovery_target_semantic_candidate() {
  # The mutation must pass the record schema, then fail the recovery reader.
  local kind=$1 body=$2 COPY_MUTATION=$3 altered
  shift 3
  altered=$(jq -c "$@" "$COPY_MUTATION" <<<"$body")
  validate_publication_record_json "$_transaction_id" "$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")" \
    "$(jq -c '.publication_records[-1]' "$TXDIR/manifest.json")" "$(recovery_copy_a2_document "$kind" "$altered")" ||
    fail_test "$kind mutation refused by schema instead of semantics: $COPY_MUTATION"
  recovery_target_candidate "$kind" "$altered"
}
recovery_target_mutations() {
  local context_valid kernel_valid config_valid filter mutation
  recovery_target_capture_fixture
  TARGET_CAPTURE=recovery-context recovery_target_context_refused capture
  TARGET_CAPTURE=''
  context_valid=$(<"$CASE_DIR/captured-recovery-context")
  for filter in '.schema_version=1' '.body.extra=true' '.body.context.schema_version=2' \
    '.body.original_context.projection=".body.intent"' '.body.signing_policy.configuration_sha256="x"' \
    '.body.signing_policy.configuration_state="present"' '.body.signing_policy.executable="usr/bin/sbctl"' \
    'del(.body.signing_policy)'; do
    recovery_target_schema_refused recovery-context "$context_valid" "$filter"
  done
  # The envelope invocation must be the basis invocation: a semantic refusal.
  COPY_MUTATION=context-foreign-invocation
  recovery_copy_a2_candidate "$(jq -c '.invocation="88888888-8888-4888-8888-888888888888"' <<<"$(recovery_copy_a2_document recovery-context "$context_valid")")"
  # The fresh context must equal the sealed original through its real containing
  # record and projection, and match the sealed original intent.
  # shellcheck disable=SC2016 # jq-bound peer references.
  for mutation in '.context.machine_id="22222222222222222222222222222222"' \
    '.context.local_db_certificate_der_sha256=("b"*64)' '.context.esp.partition_uuid="cccccccc-cccc-4ccc-8ccc-cccccccccccc"' \
    '.original_context.reference=$plan' '.original_context.reference=$retained' \
    '.original_context.projection=(if .original_context.projection == ".body" then ".body.context" else ".body" end)'; do
    recovery_target_semantic_candidate recovery-context "$context_valid" "$mutation" \
      --argjson plan "$BASIS_PLAN_REF" --argjson retained "$BASIS_RETAINED_REF"
  done
  prepare_publication_recovery_context
  COPY_MUTATION=duplicate-context
  recovery_target_candidate recovery-context "$_publication_recovery_context_record"
  # Effect, copy join and signature mutations use the kernel candidate before it binds.
  TARGET_CAPTURE=target-authorization recovery_target_refused capture kernel
  TARGET_CAPTURE=''
  kernel_valid=$(<"$CASE_DIR/captured-target-authorization")
  for filter in '.schema_version=1' '.body.classification="conflict-content"' '.body.classification="unknown"' \
    '.body.observation.state.kind="directory"' '.body.extra=true' '.body.original_effect.basis={}' \
    '.body.copy.reference.schema_version=1' '.body.mount_view.namespace="mnt:[0]"' 'del(.body.signature)' \
    '.body.target="relative/path"' '.body.observation.path=(.body.target+"x")' '.body.parent.path+="/x"' \
    '.body.mount_view.directories[0].identity="1:1"' '.body.original_effect.id="other"'; do
    recovery_target_schema_refused target-authorization "$kernel_valid" "$filter"
  done
  COPY_MUTATION='authorization-foreign-invocation'
  recovery_copy_a2_candidate "$(jq -c '.invocation="88888888-8888-4888-8888-888888888888"' <<<"$(recovery_copy_a2_document target-authorization "$kernel_valid")")"
  # shellcheck disable=SC2016 # jq-bound peer references.
  for mutation in '.classification="desired"' '.classification="prior"' \
    '.copy.reference=$context' '.copy.reference=$ready' '.copy.file.sha256=("0"*64)' '.copy.file.bytes+=1' \
    '.original_effect.desired.sha256=("0"*64)' '.original_effect.absence.allowed=false' \
    '.original_effect.before={kind:"file",sha256:("0"*64)}' '.original_effect.authority.plan.projection=".body.configuration"'; do
    recovery_target_semantic_candidate target-authorization "$kernel_valid" "$mutation" \
      --argjson context "$_publication_recovery_context_reference" --argjson ready "$(jq -c '.publication_records[1]' "$TXDIR/manifest.json")"
  done
  if [[ ${BASIS_SIGNING:-bytes} == local-efi ]]; then
    # Only signed bytes make the source and retained hashes distinct.
    for mutation in '.signature.certificate_der_sha256=("0"*64)' \
      '.original_effect.signing="bytes" | .signature=null' \
      '.original_effect.original_source.sha256=.original_effect.desired.sha256'; do
      recovery_target_semantic_candidate target-authorization "$kernel_valid" "$mutation"
    done
  else
    recovery_target_semantic_candidate target-authorization "$kernel_valid" \
      '.original_effect.signing="local-efi" | .signature={verified:true,certificate_der_sha256:("a"*64)}'
  fi
  # Cross-record custody and observation mutations use the configuration
  # candidate after the kernel authorization is bound.
  authorize_publication_recovery_target kernel
  COPY_MUTATION=duplicate-authorization
  recovery_target_candidate target-authorization "$_publication_recovery_authorization_record"
  TARGET_CAPTURE=target-authorization recovery_target_refused capture configuration
  TARGET_CAPTURE=''
  config_valid=$(<"$CASE_DIR/captured-target-authorization")
  json_is '.classification == "prior"' "$config_valid"
  # shellcheck disable=SC2016 # jq-bound uid.
  for mutation in '.classification="desired"' '.classification="allowed-absence"' \
    '.observation.state.sha256=.original_effect.desired.sha256' \
    '.observation.state={kind:"absent",identity:null,sha256:null,link_target:null,mode:0,uid:0,gid:0}' \
    '.observation.state.mode=33206' '.mount_view.namespace="mnt:[1]"'; do
    recovery_target_semantic_candidate target-authorization "$config_valid" "$mutation" --argjson uid "$(control_owner_uid)"
  done
  recovery_target_schema_refused target-authorization "$config_valid" '.body.observation.state.uid=999999'
  authorize_publication_recovery_target configuration
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 8' "$_manifest_json"
  for filter in '.current_phase="observe"' '.completed_phases=["observe"]' \
    '.domain_records.final_proof=.publication_records[-1]' '.status="completed" | .completed_at=.created_at'; do
    if validate_transaction_manifest_json "$_transaction_id" "$(jq -c "$filter" <<<"$_manifest_json")" false; then
      fail_test "fresh authority removed preparatory fence: $filter"
    fi
  done
  if commit_lifecycle_recovery_attempt; then fail_test 'fresh authority enabled completion'; fi
  recovery_target_original_unchanged
}
recovery_target_order() {
  local body history _publication_original_effect=''
  # Without a bound copy for its id, an authorization is refused by writer and reader.
  TARGET_COPIES=kernel recovery_target_capture_fixture
  # Reader level: a well-formed authorization cannot precede the attempt's context.
  publication_resolve_original_effect "$BASIS_ROOT_REF" "$INVOCATION" kernel
  history=$(jq -c --arg esp "$CASE_DIR/esp" '[.[] | select(.path == $esp or (.path | startswith($esp + "/")))]' <<<"$HISTORY")
  body=$(jq -cn --argjson effect "$(jq -c 'del(.basis)' <<<"$_publication_original_effect")" \
    --argjson copy "$TARGET_KERNEL_COPY" --argjson reference "$TARGET_KERNEL_COPY_REF" --argjson history "$history" '
    {id:"kernel",target:$effect.target,original_effect:$effect,copy:{reference:$reference,file:$copy.file},
      observation:{path:$effect.target,state:{kind:"absent",identity:null,sha256:null,link_target:null,mode:0,uid:0,gid:0}},
      mount_view:{namespace:"mnt:[8800]",directories:($history | map({path,mount_id,identity:.state.identity}))},
      parent:{path:($effect.target | split("/")[:-1] | join("/")),
        components:($history | map({path,entry:.state,directory:.state})),
        dependencies:($history | to_entries | map({path:.value.path,entry:.value.state,
          parent_identity:(if .key == 0 then null else $history[.key-1].state.identity end)}))},
      classification:"allowed-absence",signature:null}')
  COPY_MUTATION='authorization-before-context'
  recovery_target_candidate target-authorization "$body"
  prepare_publication_recovery_context
  recovery_target_refused missing-copy configuration
  TARGET_CAPTURE=target-authorization recovery_target_refused capture kernel
  TARGET_CAPTURE=''
  body=$(<"$CASE_DIR/captured-target-authorization")
  recovery_target_semantic_candidate target-authorization "$body" '.id="configuration" | .original_effect.id="configuration"'
  authorize_publication_recovery_target kernel
  recovery_target_original_unchanged
}
recovery_target_replay_drift() {
  local reference verifications saved path fault
  recovery_target_fixture
  TARGET_TOKEN=$OMASECBOOT_TRANSACTION_TOKEN
  prepare_publication_recovery_context
  reference=$_publication_recovery_context_reference
  # Platform drift at a live replay ends memory authority; later replays re-acquire.
  TARGET_CONTEXT_FILTER='.machine_id="22222222222222222222222222222222"'
  recovery_target_context_refused replay-machine-drift
  recovery_target_refused memory-cleared kernel
  TARGET_CONTEXT_FILTER=''
  prepare_publication_recovery_context
  [[ $_publication_recovery_context_reference == "$reference" && -n $_publication_stable_context ]]
  saved=$TARGET_POLICY
  TARGET_POLICY=$(jq -c '.executable_sha256=("f"*64)' <<<"$TARGET_POLICY")
  recovery_target_context_refused replay-policy-drift
  TARGET_POLICY=$saved
  prepare_publication_recovery_context
  # Memory that disagrees with the durable record authorizes nothing.
  saved=$_publication_stable_context
  _publication_stable_context=$(jq -c '.machine_id="22222222222222222222222222222222"' <<<"$saved")
  recovery_target_refused memory-context-drift kernel
  _publication_stable_context=$saved
  saved=$_publication_signing_policy
  _publication_signing_policy=$(jq -c '.executable_sha256=("f"*64)' <<<"$saved")
  recovery_target_refused memory-policy-drift kernel
  _publication_signing_policy=$saved
  authorize_publication_recovery_target kernel
  reference=$_publication_recovery_authorization_reference
  # A replay re-verifies a local EFI copy rather than adopting the old result.
  verifications=$TARGET_VERIFICATIONS
  authorize_publication_recovery_target kernel
  [[ $_publication_recovery_authorization_reference == "$reference" ]]
  if [[ ${BASIS_SIGNING:-bytes} == local-efi ]]; then [[ $TARGET_VERIFICATIONS == $((verifications+1)) ]]
  else [[ $TARGET_VERIFICATIONS == "$verifications" ]]; fi
  # A latched live view refuses both writers without any new fault.
  _publication_mount_invalid=true
  recovery_target_context_refused latched-view
  recovery_target_refused latched-view kernel
  _publication_mount_invalid=false
  prepare_publication_recovery_context
  # A changed mount namespace at replay latches and refuses.
  # shellcheck disable=SC2329
  publication_namespace_value() { printf 'mnt:[8801]\n'; }
  recovery_target_refused namespace-drift kernel
  [[ $_publication_mount_invalid == true ]]
  # shellcheck disable=SC2329
  publication_namespace_value() { printf 'mnt:[8800]\n'; }
  _publication_mount_invalid=false
  # Lost lock bindings refuse authorization as they refuse context preparation.
  for fault in boot repair; do
    if [[ $fault == boot ]]; then path=$(limine_lock_path); else path=$(state_dir_path)/repair.lock; fi
    command mv -- "$path" "$path.saved"; touch "$path"
    recovery_target_refused "$fault-lock" kernel
    rm -- "$path"; command mv -- "$path.saved" "$path"
    with_boot_repair_lock
  done
  # A record whose bytes no longer match its manifest reference is refused, even
  # with an equal body, before it can be adopted or synced.
  path=$(jq -r '.path' <<<"$reference")
  cp -- "$path" "$CASE_DIR/saved-authorization"
  chmod u+w "$path"; jq -c '.recorded_at="2000-01-01T00:00:00Z"' "$CASE_DIR/saved-authorization" >"$path"; chmod 600 "$path"
  recovery_target_refused rebound-record kernel
  cp -- "$CASE_DIR/saved-authorization" "$path"; chmod 600 "$path"
  authorize_publication_recovery_target kernel
  [[ $_publication_recovery_authorization_reference == "$reference" ]]
  recovery_target_original_unchanged
}
# A4a fresh stages and readiness: disposable sibling stages from the private
# copies for authorized targets, then the finite plan projection. Still no
# canonical write; the native validator is a fixture executable here.
recovery_ready_fixture() {
  recovery_target_fixture
  eval "$TARGET_REAL_STAGE_FILE"
  cat >"$CASE_DIR/native" <<EOF
#!/usr/bin/bash
set -euo pipefail
[[ \$# == 1 ]] || exit 64
case \$1 in
  --validate-managed-plan)
    plan=\$(cat)
    [[ -z \${READY_NATIVE_SLEEP:-} ]] || sleep "\$READY_NATIVE_SLEEP"
    jq -e '.format == "limine-prepared-publication" and .schema == 1 and .deletes == [] and .references == []' <<<"\$plan" >/dev/null
    printf '%s\n' "\$plan" >>"$CASE_DIR/native-validated-plans"
    exit "\${READY_NATIVE_STATUS:-0}" ;;
  --validate-managed-targets)
    intent=\$(cat)
    jq -e 'has("publication") and (.resources | length) >= 1 and (.configuration.path | type == "string")' <<<"\$intent" >/dev/null
    printf '%s\n' "\$intent" >>"$CASE_DIR/native-validated-targets"
    exit "\${APPLY_NATIVE_STATUS:-0}" ;;
  *) exit 64 ;;
esac
EOF
  chmod 755 "$CASE_DIR/native"
  exec {READY_NATIVE_FD}<"$CASE_DIR/native"
  prepare_publication_recovery_context
  authorize_publication_recovery_target kernel
  READY_KERNEL_AUTH=$_publication_recovery_authorization_record
  authorize_publication_recovery_target configuration
  READY_CONFIG_AUTH=$_publication_recovery_authorization_record
}
recovery_ready_stage_files() { find "$CASE_DIR/esp" -name '.omasecboot-*' -type f | sort; }
recovery_ready_stage_refused() {
  local before files
  before=$(journal_fingerprint) files=$(recovery_ready_stage_files)
  _publication_recovery_stage_record=stale _publication_recovery_stage_reference=stale
  if stage_publication_recovery_target "${2:-kernel}"; then fail_test "stage accepted ${1:-invalid state}"; fi
  [[ -z $_publication_recovery_stage_record && -z $_publication_recovery_stage_reference ]] || fail_test 'refused stage retained outputs'
  [[ $(journal_fingerprint) == "$before" && $(recovery_ready_stage_files) == "$files" ]] || fail_test "refused stage left evidence: ${1:-}"
}
recovery_ready_refused() {
  local before
  before=$(journal_fingerprint)
  _publication_recovery_ready_record=stale _publication_recovery_ready_reference=stale
  if ready_publication_recovery_plan "$@"; then fail_test "readiness accepted ${READY_REFUSAL:-invalid state}"; fi
  [[ -z $_publication_recovery_ready_record && -z $_publication_recovery_ready_reference ]] || fail_test 'refused readiness retained outputs'
  [[ $(journal_fingerprint) == "$before" ]] || fail_test "refused readiness changed the journal: ${READY_REFUSAL:-}"
}
recovery_ready_assert_stage() {
  local id=$1 authorization=$2 body=$3 reference=$4 stage
  stage=$(jq -r '.stage.path' <<<"$body")
  # shellcheck disable=SC2016 # jq-bound authorization.
  jq -e --argjson auth "$authorization" '.id == $auth.id and .target == $auth.target and .before == $auth.observation.state and
    .retained == $auth.copy.file and .stage.state.sha256 == $auth.copy.file.sha256 and .stage.state.kind == "file" and
    .mount_view == $auth.mount_view and .parent == $auth.parent' <<<"$body" >/dev/null
  [[ $(dirname "$stage") == "$(dirname "$(jq -r '.target' <<<"$body")")" && $(basename "$stage") == .omasecboot-$INVOCATION-$id.*.stage ]]
  cmp -- "$(jq -r '.retained.path' <<<"$body")" "$stage"
  [[ $(basis_file_state "$stage") == "$(jq -c '.stage.state' <<<"$body")" ]]
  jq -e --argjson reference "$reference" '.publication_records | index($reference) != null' "$TXDIR/manifest.json" >/dev/null
  jq -e --argjson body "$body" '.schema_version == 2 and .kind == "recovery-stage" and .body == $body' "$(jq -r '.path' <<<"$reference")" >/dev/null
  json_is '.[0] == .[1]' "[$body,${_publication_stage_bodies[$id]}]"
}
recovery_ready_expected_plan() {
  jq -cn --arg invocation "$INVOCATION" --argjson kernel "$1" --argjson config "$2" '
    def put: {id,target,before,after:.stage.state,parent,retained:.retained.path};
    {format:"limine-prepared-publication",schema:1,invocation:$invocation,
      puts:[$kernel | put],configuration:($config | put),deletes:[],references:[]}'
}
recovery_ready_valid() {
  local body reference kernel_stage config_stage before plan files initial
  recovery_ready_fixture
  # The sealed original root left its own two stage siblings on the fixture ESP.
  initial=$(recovery_ready_stage_files | wc -l)
  recovery_ready_refused_before_stages
  stage_publication_recovery_target kernel
  body=$_publication_recovery_stage_record reference=$_publication_recovery_stage_reference
  recovery_ready_assert_stage kernel "$READY_KERNEL_AUTH" "$body" "$reference"
  kernel_stage=$body
  json_is '.before.kind == "absent"' "$body"
  # Replay rebinds the same stage record and file without a second stage.
  before=$(journal_fingerprint) files=$(recovery_ready_stage_files)
  stage_publication_recovery_target kernel
  [[ $_publication_recovery_stage_reference == "$reference" && $(journal_fingerprint) == "$before" && $(recovery_ready_stage_files) == "$files" ]]
  READY_REFUSAL=configuration-unstaged recovery_ready_refused "$READY_NATIVE_FD"
  stage_publication_recovery_target configuration
  config_stage=$_publication_recovery_stage_record
  recovery_ready_assert_stage configuration "$READY_CONFIG_AUTH" "$config_stage" "$_publication_recovery_stage_reference"
  json_is '.before.kind == "file"' "$config_stage"
  [[ $(recovery_ready_stage_files | wc -l) == $((initial+2)) ]]
  # Readiness is the pure projection, validated by the native executable too.
  READY_NATIVE_STATUS=1 READY_REFUSAL=native-status-1 recovery_ready_refused "$READY_NATIVE_FD"
  # Ten records exist (basis, four copies, context, two authorizations, two
  # stages); a refused readiness leaves no eleventh.
  [[ ! -e $TXDIR/publication-11.json ]]
  ready_publication_recovery_plan "$READY_NATIVE_FD"
  plan=$_publication_recovery_ready_record reference=$_publication_recovery_ready_reference
  json_is '.[0] == .[1]' "[$plan,$(recovery_ready_expected_plan "$kernel_stage" "$config_stage")]"
  json_is '.[0] == .[1]' "[$plan,$_publication_plan]"
  [[ $(jq -c . "$CASE_DIR/native-validated-plans" | sort -u | wc -l) == 1 && $(jq -c . "$CASE_DIR/native-validated-plans" | tail -1) == "$plan" ]]
  jq -e --argjson reference "$reference" '.publication_records | index($reference) != null' "$TXDIR/manifest.json" >/dev/null
  jq -e --argjson body "$plan" '.schema_version == 2 and .kind == "recovery-ready" and .body == $body' "$(jq -r '.path' <<<"$reference")" >/dev/null
  before=$(journal_fingerprint)
  ready_publication_recovery_plan
  [[ $_publication_recovery_ready_reference == "$reference" && $(journal_fingerprint) == "$before" ]]
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 11 and all(.schema_version == 2)' "$_manifest_json"
  # No canonical target changed; the stages are hidden siblings only.
  [[ ! -e $CHILD_PATH/kernel ]]
  [[ $(basis_file_state "$CASE_DIR/esp/limine.conf") == "$(jq -c '.observation.state' <<<"$READY_CONFIG_AUTH")" ]]
  for filter in '.current_phase="apply"' '.completed_phases=["apply"]' \
    '.domain_records.final_proof=.publication_records[-1]' '.status="completed" | .completed_at=.created_at'; do
    if validate_transaction_manifest_json "$_transaction_id" "$(jq -c "$filter" <<<"$_manifest_json")" false; then
      fail_test "readiness removed preparatory fence: $filter"
    fi
  done
  if commit_lifecycle_recovery_attempt; then fail_test 'readiness enabled completion'; fi
  recovery_target_original_unchanged
  # Interruption leaves the old stages unbound on the ESP; a fresh attempt
  # observes, stages and binds anew without touching them.
  rollback_and_mark_recovery 33 'fixture readiness interrupted'
  release_publication_pins
  files=$(recovery_ready_stage_files)
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  retain_publication_recovery_input kernel
  TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
  retain_publication_recovery_input configuration
  TARGET_CONFIG_COPY=$_publication_recovery_copy_record TARGET_CONFIG_COPY_REF=$_publication_recovery_copy_reference
  prepare_publication_recovery_context
  authorize_publication_recovery_target kernel
  authorize_publication_recovery_target configuration
  stage_publication_recovery_target kernel
  stage_publication_recovery_target configuration
  ready_publication_recovery_plan "$READY_NATIVE_FD"
  # The new siblings interleave with the old ones in sorted order; every old
  # sibling is still present and untouched.
  [[ $(recovery_ready_stage_files | wc -l) == $((initial+4)) ]]
  [[ -z $(comm -13 <(recovery_ready_stage_files) <(printf '%s\n' "$files")) ]]
  recovery_target_original_unchanged
}
# Readiness re-proves the held stages: a changed, replaced or removed sibling
# refuses it, even as a replay of recorded readiness; the validator deadline
# refuses before any record.
recovery_ready_custody() {
  local stage
  recovery_ready_fixture
  stage_publication_recovery_target kernel
  stage_publication_recovery_target configuration
  stage=$(jq -r '.stage.path' <<<"$_publication_recovery_stage_record")
  _producer_session_io_timeout=1 READY_NATIVE_SLEEP=3 READY_REFUSAL=native-timeout recovery_ready_refused "$READY_NATIVE_FD"
  printf 'altered\n' >>"$stage"
  READY_REFUSAL=stage-modified recovery_ready_refused "$READY_NATIVE_FD"
  # The exact bytes on the same inode readmit the held stage.
  cp -- "$(jq -r '.retained.path' <<<"$_publication_recovery_stage_record")" "$stage"
  ready_publication_recovery_plan "$READY_NATIVE_FD"
  cp -- "$stage" "$stage.next"; command mv -- "$stage.next" "$stage"
  READY_REFUSAL=stage-replaced recovery_ready_refused "$READY_NATIVE_FD"
  rm -- "$stage"
  READY_REFUSAL=stage-removed recovery_ready_refused
  recovery_target_original_unchanged
}
# Another process view of the attempt replays the context without stage
# memory: a vanished unpinned ancestor refuses staging without creating a
# directory, and a durable stage this view did not create is neither adopted
# nor duplicated, so readiness stays refused.
recovery_ready_ancestors_and_memory() {
  recovery_ready_fixture
  release_publication_pins
  _publication_stable_context='' _publication_signing_policy=''
  prepare_publication_recovery_context
  command mv -- "$CHILD_PATH" "$CHILD_PATH.moved"
  recovery_ready_stage_refused ancestor-missing kernel
  [[ ! -e $CHILD_PATH ]]
  command mv -- "$CHILD_PATH.moved" "$CHILD_PATH"
  _publication_mount_invalid=false
  authorize_publication_recovery_target kernel
  stage_publication_recovery_target kernel
  release_publication_pins
  _publication_stable_context='' _publication_signing_policy=''
  prepare_publication_recovery_context
  recovery_ready_stage_refused stage-not-held kernel
  authorize_publication_recovery_target configuration
  stage_publication_recovery_target configuration
  READY_REFUSAL=kernel-stage-not-held recovery_ready_refused "$READY_NATIVE_FD"
  recovery_target_original_unchanged
}
recovery_ready_refused_before_stages() {
  READY_REFUSAL=nothing-staged recovery_ready_refused
  READY_REFUSAL=nothing-staged-native recovery_ready_refused "$READY_NATIVE_FD"
}
recovery_ready_refusals() {
  local target copy token fault
  recovery_target_fixture
  eval "$TARGET_REAL_STAGE_FILE"
  target=$CHILD_PATH/kernel
  # Without a context there is no memory authority; without an authorization
  # there is nothing to stage. Neither creates a stage file.
  recovery_ready_stage_refused before-context kernel
  prepare_publication_recovery_context
  recovery_ready_stage_refused before-authorization kernel
  authorize_publication_recovery_target kernel
  # Malformed, unauthorized or extra arguments are refused before any proof.
  recovery_ready_stage_refused malformed-id 'kernel!'
  recovery_ready_stage_refused unauthorized-id extra
  if stage_publication_recovery_target kernel extra; then fail_test 'stage accepted an extra argument'; fi
  # The bound private copy must still be exact before a stage is cut from it.
  copy=$(jq -r '.copy.file.path' <<<"$_publication_recovery_authorization_record")
  command mv -- "$copy" "$copy.away"
  recovery_ready_stage_refused copy-missing kernel
  command mv -- "$copy.away" "$copy"
  cp -- "$copy" "$CASE_DIR/saved-copy"
  chmod u+w "$copy"; printf 'altered\n' >>"$copy"
  recovery_ready_stage_refused copy-altered kernel
  cp -- "$CASE_DIR/saved-copy" "$copy"; chmod 400 "$copy"
  # A target that changed since its authorization is not staged.
  printf 'appeared after authorization\n' >"$target"
  recovery_ready_stage_refused target-appeared kernel
  rm -- "$target"
  stage_publication_recovery_target kernel
  authorize_publication_recovery_target configuration
  # An in-place change or a vanished present target is refused as well.
  cp -- "$CASE_DIR/esp/limine.conf" "$CASE_DIR/saved-configuration"
  printf 'appended\n' >>"$CASE_DIR/esp/limine.conf"
  recovery_ready_stage_refused target-modified configuration
  cp -- "$CASE_DIR/saved-configuration" "$CASE_DIR/esp/limine.conf"
  command mv -- "$CASE_DIR/esp/limine.conf" "$CASE_DIR/esp/limine.conf.away"
  recovery_ready_stage_refused target-absent configuration
  command mv -- "$CASE_DIR/esp/limine.conf.away" "$CASE_DIR/esp/limine.conf"
  cp -- "$(jq -r '.file.path' <<<"$TARGET_CONFIG_COPY")" "$CASE_DIR/esp/limine.conf.next"
  command mv -- "$CASE_DIR/esp/limine.conf.next" "$CASE_DIR/esp/limine.conf"
  recovery_ready_stage_refused target-replaced configuration
  READY_REFUSAL=configuration-unstaged recovery_ready_refused
  # Lost ownership or the restore marker refuse both writers.
  token=$OMASECBOOT_TRANSACTION_TOKEN
  for fault in owner marker; do
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN='invalid-token' ;;
      marker) touch "$(snapshot_restore_lock_path)" ;;
    esac
    recovery_ready_stage_refused "$fault" kernel
    READY_REFUSAL=$fault recovery_ready_refused
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN=$token ;;
      marker) rm -- "$(snapshot_restore_lock_path)" ;;
    esac
  done
  # A latched live view refuses staging and readiness without a new fault.
  _publication_mount_invalid=true
  recovery_ready_stage_refused latched kernel
  READY_REFUSAL=latched recovery_ready_refused
  _publication_mount_invalid=false
  # An unreadable or non-executable native descriptor is refused before any record.
  exec {fd}<"$CASE_DIR/source"
  READY_REFUSAL=native-not-executable recovery_ready_refused "$fd"
  exec {fd}<&-
  READY_REFUSAL=native-bad-fd recovery_ready_refused 999
  READY_REFUSAL=native-arity recovery_ready_refused 1 2
  recovery_target_original_unchanged
}
recovery_ready_peer_root() {
  local peer=66666666-6666-4666-8666-666666666666
  basis_complete_fixture
  INVOCATION=$peer basis_complete_fixture
  basis_seal_fixture
  TARGET_ROOT_DIR=$TXDIR
  TARGET_ROOT_BEFORE=$(journal_fingerprint)
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  retain_publication_recovery_input kernel
  TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
  retain_publication_recovery_input configuration
  TARGET_CONFIG_COPY=$_publication_recovery_copy_record TARGET_CONFIG_COPY_REF=$_publication_recovery_copy_reference
  recovery_target_seams
  eval "$TARGET_REAL_STAGE_FILE"
  prepare_publication_recovery_context
  authorize_publication_recovery_target kernel
  authorize_publication_recovery_target configuration
  stage_publication_recovery_target kernel
  stage_publication_recovery_target configuration
  # Whole-root scheduling across invocations is later work: refuse readiness.
  READY_REFUSAL=peer-invocation recovery_ready_refused
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 10' "$_manifest_json"
  recovery_target_original_unchanged
}
recovery_ready_mutations() {
  local stage_valid ready_valid filter mutation definition
  recovery_ready_fixture
  definition=$(declare -f append_publication_record)
  eval "${definition/append_publication_record/recovery_ready_actual_append}"
  # shellcheck disable=SC2329
  append_publication_record() {
    if [[ -n ${READY_CAPTURE:-} && $2 == "$READY_CAPTURE" ]]; then
      printf '%s\n' "$3" >"$CASE_DIR/captured-$2"
      return 1
    fi
    recovery_ready_actual_append "$@"
  }
  READY_CAPTURE=recovery-stage
  if stage_publication_recovery_target kernel; then fail_test 'captured stage accepted'; fi
  READY_CAPTURE=''
  stage_valid=$(<"$CASE_DIR/captured-recovery-stage")
  # The refused writer left its candidate stage file; a fresh writer call must
  # create its own stage rather than adopting an unbound sibling.
  for filter in '.schema_version=1' '.body.extra=true' '.body.before.kind="directory"' 'del(.body.mount_view)' \
    '.body.stage.state.kind="absent"' '.body.retained.path="/elsewhere"'; do
    recovery_target_schema_refused recovery-stage "$stage_valid" "$filter"
  done
  # shellcheck disable=SC2016 # jq-bound values.
  for mutation in '.before={kind:"file",identity:"8800:9007199254740993",sha256:.retained.sha256,link_target:null,mode:33152,uid:.parent.components[0].entry.uid,gid:0}' \
    '.retained.sha256=("0"*64)' '.retained.bytes+=1' '.stage.state.sha256=("0"*64)' '.mount_view.namespace="mnt:[1]"' \
    '.id="configuration"' '.target+="-x"' '.stage.state.uid+=1' '.parent.dependencies[0].entry.identity="8800:1"' \
    '.parent.components[0].entry.identity="8800:1" | .parent.components[0].directory.identity="8800:1" | .mount_view.directories[0].identity="8800:1"' \
    '.stage.path=(.stage.path | sub("-kernel\\."; "-configuration."))'; do
    recovery_target_semantic_candidate recovery-stage "$stage_valid" "$mutation"
  done
  stage_publication_recovery_target kernel
  COPY_MUTATION=duplicate-stage
  recovery_target_candidate recovery-stage "$_publication_recovery_stage_record"
  stage_publication_recovery_target configuration
  READY_CAPTURE=recovery-ready
  if ready_publication_recovery_plan; then fail_test 'captured readiness accepted'; fi
  READY_CAPTURE=''
  ready_valid=$(<"$CASE_DIR/captured-recovery-ready")
  for filter in '.schema_version=1' '.body.deletes=[{}]' '.body.schema=2' 'del(.body.references)' '.body.puts[0].after.kind="absent"'; do
    recovery_target_schema_refused recovery-ready "$ready_valid" "$filter"
  done
  # shellcheck disable=SC2016 # jq-bound values.
  for mutation in '.puts[0].after.sha256=("0"*64)' '.puts[0].target+="x"' '.puts[0].before={kind:"absent",identity:null,sha256:null,link_target:null,mode:0,uid:0,gid:0} | .puts[0].before=.configuration.before' \
    '.configuration.id="kernel" | .puts[0].id="configuration"' \
    '.puts+=[.configuration]' '.puts=[]' '.configuration.retained=.puts[0].retained' \
    '.puts[0].parent.dependencies[0].entry.identity="8800:1"' '.configuration.after.sha256=("1"*64)'; do
    recovery_target_semantic_candidate recovery-ready "$ready_valid" "$mutation"
  done
  # The plan's invocation is bound to its envelope by schema; a foreign envelope
  # with a matching body is refused by the reader against the basis invocation.
  COPY_MUTATION='ready-foreign-invocation'
  recovery_copy_a2_candidate "$(jq -c '.invocation="88888888-8888-4888-8888-888888888888" | .body.invocation=.invocation' \
    <<<"$(recovery_copy_a2_document recovery-ready "$ready_valid")")"
  ready_publication_recovery_plan
  COPY_MUTATION=duplicate-ready
  recovery_target_candidate recovery-ready "$_publication_recovery_ready_record"
  COPY_MUTATION='stage-after-ready'
  recovery_target_candidate recovery-stage "$_publication_recovery_stage_record"
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 11' "$_manifest_json"
  recovery_target_original_unchanged
}
recovery_ready_cache_and_sync() {
  local slot index path window kind ordinal count existing definition
  recovery_ready_fixture
  stage_publication_recovery_target kernel
  stage_publication_recovery_target configuration
  ready_publication_recovery_plan
  read_transaction_manifest "$_transaction_id"
  slot="$_transaction_id:$(control_owner_uid)"
  [[ -n ${_publication_recovery_validation_cache[$slot]:-} ]]
  for index in 8 9 10; do
    path=$(jq -r --argjson n "$index" '.publication_records[$n].path' <<<"$_manifest_json")
    cp -- "$path" "$CASE_DIR/saved-record"
    chmod u+w "$path"; printf 'changed readiness\n' >>"$path"
    if validate_publication_recovery_records "$_transaction_id" "$_manifest_json"; then fail_test "warm cache ignored $(basename "$path")"; fi
    [[ -z ${_publication_recovery_validation_cache[$slot]:-} ]] || fail_test 'failed cache entry was retained'
    cp -- "$CASE_DIR/saved-record" "$path"; chmod 600 "$path"
    validate_publication_recovery_records "$_transaction_id" "$_manifest_json"
  done
  recovery_target_original_unchanged
  # Durability windows: an unbound stage/readiness record and a bound but
  # unsynced head are adopted by the retry without a second record or stage.
  definition=$(declare -f durable_sync)
  eval "${definition/durable_sync/recovery_ready_actual_sync}"
  TARGET_WINDOW='' TARGET_WINDOW_ORDINAL=0
  # shellcheck disable=SC2329
  durable_sync() {
    local n inject=false
    if [[ -n $TARGET_WINDOW && ! -e $CASE_DIR/target-sync-fault ]]; then
      n=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
      case $TARGET_WINDOW:$1 in
        record-file:"$TXDIR/publication-$TARGET_WINDOW_ORDINAL.json") inject=true ;;
        manifest-file:"$TXDIR/manifest.json") [[ $n != "$TARGET_WINDOW_ORDINAL" ]] || inject=true ;;
      esac
    fi
    if [[ $inject == true ]]; then printf '%s\n' "$TARGET_WINDOW" >"$CASE_DIR/target-sync-fault"; return 1; fi
    recovery_ready_actual_sync "$@"
  }
  for kind in stage ready; do
    for window in record-file manifest-file; do
      rollback_and_mark_recovery 34 "fixture readiness window $kind/$window"
      release_publication_pins
      begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
      TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
      retain_publication_recovery_input kernel
      TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
      retain_publication_recovery_input configuration
      TARGET_CONFIG_COPY=$_publication_recovery_copy_record TARGET_CONFIG_COPY_REF=$_publication_recovery_copy_reference
      prepare_publication_recovery_context
      authorize_publication_recovery_target kernel
      authorize_publication_recovery_target configuration
      if [[ $kind == ready ]]; then stage_publication_recovery_target kernel; stage_publication_recovery_target configuration; fi
      ordinal=$(( $(jq -r '.publication_records | length' "$TXDIR/manifest.json") + 1 ))
      rm -f -- "$CASE_DIR/target-sync-fault"
      TARGET_WINDOW=$window TARGET_WINDOW_ORDINAL=$ordinal
      if [[ $kind == stage ]]; then
        if stage_publication_recovery_target kernel; then fail_test "stage accepted sync window $window"; fi
      else
        if ready_publication_recovery_plan; then fail_test "readiness accepted sync window $window"; fi
      fi
      TARGET_WINDOW=''
      [[ -s $CASE_DIR/target-sync-fault ]] || fail_test "sync seam missed $kind/$window"
      count=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
      case $window in record-file) [[ $count == $((ordinal-1)) ]] ;; manifest-file) [[ $count == "$ordinal" ]] ;; esac
      existing=''
      if [[ -e $TXDIR/publication-$ordinal.json ]]; then existing=$(sha256_file "$TXDIR/publication-$ordinal.json"); fi
      if [[ $kind == stage ]]; then stage_publication_recovery_target kernel; else ready_publication_recovery_plan; fi
      [[ $(jq -r '.publication_records | length' "$TXDIR/manifest.json") == "$ordinal" ]]
      [[ -z $existing || $(sha256_file "$TXDIR/publication-$ordinal.json") == "$existing" ]] || fail_test "retry rewrote $kind record after $window"
      recovery_target_original_unchanged
      printf 'CHECK: readiness sync/%s/%s (%s -> %s records)\n' "$kind" "$window" "$count" "$ordinal"
    done
  done
}
# A4b fresh execution: the attempt's readiness plan is applied through the real
# authority handler with a scripted worker (the fixture performs the atomic
# rename the JVM worker performs), recording recovery-executor, effect
# frontiers and the result; completion stays refused and a failed/preserve
# seal keeps the canonical writes for a later no-op attempt.
recovery_apply_fixture() {
  recovery_ready_fixture
  stage_publication_recovery_target kernel
  stage_publication_recovery_target configuration
  ready_publication_recovery_plan "$READY_NATIVE_FD"
  APPLY_PLAN=$_publication_plan
}
recovery_apply_launch() {
  publication_authority_handler launch "$(jq -c --arg invocation "$INVOCATION" '. + {invocation:$invocation}' <<<"$SESSION")"
}
recovery_apply_request() {
  local extra=${2:-'{}'} payload
  payload=$(jq -cn --arg op "$1" --argjson extra "$extra" '{operation:$op} + $extra')
  _producer_session_reply=''
  publication_authority_handler request "$(jq -cn --arg invocation "$INVOCATION" --argjson payload "$payload" '{invocation:$invocation,payload:$payload}')"
}
recovery_apply_terminal() {
  publication_authority_handler terminal "$(jq -cn --arg invocation "$INVOCATION" --argjson status "${1:-0}" --argjson worker "${2:-0}" \
    '{invocation:$invocation,completion_acknowledged:true,protocol_complete:true,supervision_status:$status,worker_status:$worker,decoder_status:0}')"
}
# An identical repeat of a launch or result is the writer's durability retry:
# adopted without a second record. A different repeat is refused by the reader.
recovery_apply_idempotent() {
  local before
  before=$(journal_fingerprint)
  "$@"
  [[ $(journal_fingerprint) == "$before" ]] || fail_test "identical repeat changed the journal: $*"
}
recovery_apply_refused() {
  local before
  before=$(journal_fingerprint)
  if "$@"; then fail_test "apply step accepted: ${APPLY_REFUSAL:-$*}"; fi
  [[ $(journal_fingerprint) == "$before" ]] || fail_test "refused apply step changed the journal: ${APPLY_REFUSAL:-$*}"
}
recovery_apply_start_refused() {
  local before phase=$_publication_apply_phase
  before=$(journal_fingerprint)
  if publication_start_recovery_executor "$@"; then fail_test "executor start accepted: ${APPLY_REFUSAL:-}"; fi
  [[ $_publication_apply_phase == "$phase" && $(journal_fingerprint) == "$before" ]] || fail_test "refused executor start left state: ${APPLY_REFUSAL:-}"
}
# Drive one effect as the worker would: unstarted frontier, before, pending
# frontier, then either the atomic rename of the sibling or the no-op path.
recovery_apply_effect() {
  local id=$1 body stage target before
  body=${_publication_stage_bodies[$id]}
  stage=$(jq -r '.stage.path' <<<"$body") target=$(jq -r '.target' <<<"$body") before=$(jq -c '.before' <<<"$body")
  recovery_apply_request frontier "$(jq -cn --arg id "$id" '{id:$id}')"
  json_is '.phase == "unstarted" and .observed == null' "$_producer_session_reply"
  recovery_apply_request before "$(jq -cn --arg id "$id" --argjson state "$before" '{id:$id,state:$state}')"
  json_is '.accepted' "$_producer_session_reply"
  recovery_apply_request frontier "$(jq -cn --arg id "$id" '{id:$id}')"
  json_is '.phase == "pending" and .observed != null' "$_producer_session_reply"
  if json_is '.before.kind == "file" and ((.before|del(.identity)) == (.stage.state|del(.identity)))' "$body"; then
    recovery_apply_request applied "$(jq -cn --arg id "$id" --argjson state "$before" '{id:$id,state:$state}')"
  else
    recovery_apply_request stage "$(jq -cn --arg id "$id" '{id:$id}')"
    json_is '.[0] == .[1].stage' "[$_producer_session_reply,$body]"
    command mv -- "$stage" "$target"
    durable_sync "$target" && durable_sync "$(dirname "$target")"
    recovery_apply_request applied "$(jq -cn --arg id "$id" --argjson state "$(jq -c '.stage.state' <<<"$body")" '{id:$id,state:$state}')"
  fi
  json_is '.accepted' "$_producer_session_reply"
  recovery_apply_request frontier "$(jq -cn --arg id "$id" '{id:$id}')"
  json_is '.phase == "applied"' "$_producer_session_reply"
}
recovery_apply_assert_records() {
  local count=$1 status=$2
  read_transaction_manifest "$_transaction_id"
  json_is ".publication_records | length == $count and all(.schema_version == 2)" "$_manifest_json"
  jq -se --argjson n "$count" --argjson status "$status" '
    length == $n and (map(.kind)[11:] == ["recovery-executor","recovery-effect-pending","recovery-effect-applied",
      "recovery-effect-pending","recovery-effect-applied","recovery-result"][:($n-11)]) and
    (.[11].body.supervisor == .[11].body.worker) and
    (if $n == 17 then .[16].body.supervision_status == $status and .[16].body.invocation == .[16].invocation else true end)' \
    "$TXDIR"/publication-{1,2,3,4,5,6,7,8,9}.json "$TXDIR"/publication-1[0-9].json >/dev/null
}
recovery_apply_copy_identities() {
  jq -r '.puts[].retained, .configuration.retained' <<<"$APPLY_PLAN" | while IFS= read -r path; do
    basis_file_state "$path" | jq -r '.identity'
  done | jq -Rsc 'split("\n") | map(select(length > 0))'
}
recovery_apply_session() {
  # The full scripted apply session for the current attempt.
  publication_start_recovery_executor "$READY_NATIVE_FD"
  [[ $_publication_apply_phase == true ]]
  recovery_apply_launch
  recovery_apply_request application
  # Every stage and every private copy of the plan is pinned for the worker.
  # shellcheck disable=SC2016 # jq-local reply/plan values.
  json_is '.[0] as $reply | .[1] as $plan | .[2] as $copies | $reply.plan == $plan and
    ($reply.directories | length) > 0 and $reply.mount_namespace == "mnt:[8800]" and
    all(($plan.puts + [$plan.configuration])[]; .after.identity as $after | any($reply.pins[]; .state.identity == $after)) and
    all($copies[]; . as $copy | any($reply.pins[]; .state.identity == $copy))' \
    "[$_producer_session_reply,$APPLY_PLAN,$(recovery_apply_copy_identities)]"
  recovery_apply_request validate-plan "$(jq -cn --argjson plan "$APPLY_PLAN" '{plan:$plan}')"
  json_is '.accepted' "$_producer_session_reply"
  recovery_apply_effect kernel
  recovery_apply_effect configuration
  recovery_apply_request complete
  json_is '.accepted' "$_producer_session_reply"
  recovery_apply_terminal 0
}
recovery_apply_valid() {
  local before kernel_identity config_identity
  recovery_apply_fixture
  recovery_apply_session
  cmp -- "$CHILD_PATH/kernel" "$(jq -r '.file.path' <<<"$TARGET_KERNEL_COPY")"
  cmp -- "$CASE_DIR/esp/limine.conf" "$(jq -r '.file.path' <<<"$TARGET_CONFIG_COPY")"
  recovery_apply_assert_records 17 0
  # The attempt is closed: a second executor start, a different result and
  # another effect are refused without a record; an identical result and an
  # identical launch are adopted without a record.
  APPLY_REFUSAL=start-after-result recovery_apply_start_refused "$READY_NATIVE_FD"
  recovery_apply_idempotent recovery_apply_terminal 0
  APPLY_REFUSAL=launch-after-result recovery_apply_refused recovery_apply_launch
  APPLY_REFUSAL=different-result recovery_apply_refused recovery_apply_terminal 0 1
  APPLY_REFUSAL=effect-after-result recovery_apply_refused recovery_apply_request before \
    "$(jq -cn --argjson state "$(jq -c '.stage.state' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  if commit_lifecycle_recovery_attempt; then fail_test 'apply enabled completion'; fi
  for filter in '.current_phase="apply"' '.status="completed" | .completed_at=.created_at'; do
    if validate_transaction_manifest_json "$_transaction_id" "$(jq -c "$filter" <<<"$_manifest_json")" false; then
      fail_test "apply removed preparatory fence: $filter"
    fi
  done
  recovery_target_original_unchanged
  # This attempt's siblings became the targets; the original root's two remain.
  [[ $(recovery_ready_stage_files | wc -l) == 2 ]]
  # A failed seal with preserve policy keeps the canonical writes.
  rollback_and_mark_recovery 35 'fixture apply sealed'
  release_publication_pins
  cmp -- "$CHILD_PATH/kernel" "$(jq -r '.file.path' <<<"$TARGET_KERNEL_COPY")"
  cmp -- "$CASE_DIR/esp/limine.conf" "$(jq -r '.file.path' <<<"$TARGET_CONFIG_COPY")"
  kernel_identity=$(basis_file_state "$CHILD_PATH/kernel") config_identity=$(basis_file_state "$CASE_DIR/esp/limine.conf")
  # A fresh attempt observes both targets as desired and applies as a no-op.
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  retain_publication_recovery_input kernel
  TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
  retain_publication_recovery_input configuration
  TARGET_CONFIG_COPY=$_publication_recovery_copy_record TARGET_CONFIG_COPY_REF=$_publication_recovery_copy_reference
  prepare_publication_recovery_context
  authorize_publication_recovery_target kernel
  json_is '.classification == "desired"' "$_publication_recovery_authorization_record"
  authorize_publication_recovery_target configuration
  json_is '.classification == "desired"' "$_publication_recovery_authorization_record"
  stage_publication_recovery_target kernel
  stage_publication_recovery_target configuration
  ready_publication_recovery_plan "$READY_NATIVE_FD"
  APPLY_PLAN=$_publication_plan
  recovery_apply_session
  recovery_apply_assert_records 17 0
  [[ $(basis_file_state "$CHILD_PATH/kernel") == "$kernel_identity" && $(basis_file_state "$CASE_DIR/esp/limine.conf") == "$config_identity" ]]
  # No-op puts leave their unbound siblings beside the two original ones.
  [[ $(recovery_ready_stage_files | wc -l) == 4 ]]
  recovery_target_original_unchanged
}
recovery_apply_refusals() {
  local before fd stage copy token fault
  recovery_ready_fixture
  stage_publication_recovery_target kernel
  # Nothing executes before readiness: no executor start, no launch, no request.
  APPLY_REFUSAL=before-readiness recovery_apply_start_refused "$READY_NATIVE_FD"
  APPLY_REFUSAL=launch-outside-apply recovery_apply_refused recovery_apply_launch
  APPLY_REFUSAL=application-before-executor recovery_apply_refused recovery_apply_request application
  stage_publication_recovery_target configuration
  ready_publication_recovery_plan "$READY_NATIVE_FD"
  APPLY_PLAN=$_publication_plan
  # Native target validation, bad descriptors and arity refuse the start.
  APPLY_NATIVE_STATUS=1 APPLY_REFUSAL=native-targets-status-1 recovery_apply_start_refused "$READY_NATIVE_FD"
  exec {fd}<"$CASE_DIR/source"
  APPLY_REFUSAL=native-not-executable recovery_apply_start_refused "$fd"
  exec {fd}<&-
  APPLY_REFUSAL=native-bad-fd recovery_apply_start_refused 999
  APPLY_REFUSAL=arity recovery_apply_start_refused 1 2
  # A changed held stage, a changed private copy or a failed signature refuse
  # the start; exact restoration readmits it.
  stage=$(jq -r '.stage.path' <<<"${_publication_stage_bodies[kernel]}")
  printf 'altered\n' >>"$stage"
  APPLY_REFUSAL=stage-modified recovery_apply_start_refused "$READY_NATIVE_FD"
  cp -- "$(jq -r '.retained.path' <<<"${_publication_stage_bodies[kernel]}")" "$stage"
  copy=$(jq -r '.file.path' <<<"$TARGET_KERNEL_COPY")
  cp -- "$copy" "$CASE_DIR/saved-copy"
  chmod u+w "$copy"; printf 'altered\n' >>"$copy"
  APPLY_REFUSAL=copy-altered recovery_apply_start_refused "$READY_NATIVE_FD"
  cp -- "$CASE_DIR/saved-copy" "$copy"; chmod 400 "$copy"
  TARGET_SIGNATURE_STATUS=1 APPLY_REFUSAL=signature recovery_apply_start_refused "$READY_NATIVE_FD"
  # Lost ownership, the restore marker and a latched view refuse the start.
  token=$OMASECBOOT_TRANSACTION_TOKEN
  for fault in owner marker latched; do
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN='invalid-token' ;;
      marker) touch "$(snapshot_restore_lock_path)" ;;
      latched) _publication_mount_invalid=true ;;
    esac
    APPLY_REFUSAL=$fault recovery_apply_start_refused "$READY_NATIVE_FD"
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN=$token ;;
      marker) rm -- "$(snapshot_restore_lock_path)" ;;
      latched) _publication_mount_invalid=false ;;
    esac
  done
  publication_start_recovery_executor "$READY_NATIVE_FD"
  APPLY_REFUSAL=start-repeated recovery_apply_refused publication_start_recovery_executor "$READY_NATIVE_FD"
  [[ $_publication_apply_phase == true ]]
  # Requests before the launch, then preparation requests and wrong payloads
  # during apply, are refused without a record.
  recovery_apply_launch
  recovery_apply_idempotent recovery_apply_launch
  APPLY_REFUSAL=retain recovery_apply_refused recovery_apply_request retain '{"id":"kernel"}'
  APPLY_REFUSAL=stage-input recovery_apply_refused recovery_apply_request stage-input '{"id":"kernel"}'
  APPLY_REFUSAL=prepare-plan recovery_apply_refused recovery_apply_request prepare-plan "$(jq -cn --argjson plan "$APPLY_PLAN" '{plan:$plan}')"
  APPLY_REFUSAL=match-intent recovery_apply_refused recovery_apply_request match-intent "$(jq -cn --argjson intent "$_publication_intent" '{intent:$intent}')"
  recovery_apply_request application
  APPLY_REFUSAL=validate-other-plan recovery_apply_refused recovery_apply_request validate-plan \
    "$(jq -cn --argjson plan "$(jq -c '.puts[0].after.sha256=("0"*64)' <<<"$APPLY_PLAN")" '{plan:$plan}')"
  recovery_apply_request validate-plan "$(jq -cn --argjson plan "$APPLY_PLAN" '{plan:$plan}')"
  # A target that appears after the executor start refuses its first effect request.
  printf 'appeared\n' >"$CHILD_PATH/kernel"
  APPLY_REFUSAL=frontier-with-appeared-target recovery_apply_refused recovery_apply_request frontier '{"id":"kernel"}'
  APPLY_REFUSAL=before-with-appeared-target recovery_apply_refused recovery_apply_request before \
    "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  rm -- "$CHILD_PATH/kernel"
  APPLY_REFUSAL=unknown-effect recovery_apply_refused recovery_apply_request frontier '{"id":"extra"}'
  APPLY_REFUSAL=configuration-before-kernel recovery_apply_refused recovery_apply_request before \
    "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[configuration]}")" '{id:"configuration",state:$state}')"
  APPLY_REFUSAL=wrong-before-state recovery_apply_refused recovery_apply_request before \
    "$(jq -cn --argjson state "$(jq -c '.stage.state' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  APPLY_REFUSAL=stage-before-pending recovery_apply_refused recovery_apply_request stage '{"id":"kernel"}'
  APPLY_REFUSAL=applied-before-pending recovery_apply_refused recovery_apply_request applied \
    "$(jq -cn --argjson state "$(jq -c '.stage.state' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  # Completion before every effect is applied is refused; a successful result
  # claimed early is recorded as a failed result and closes the attempt.
  recovery_apply_effect kernel
  APPLY_REFUSAL=complete-early recovery_apply_refused recovery_apply_request complete
  before=$(journal_fingerprint)
  if recovery_apply_terminal 0; then fail_test 'premature success result accepted'; fi
  [[ $(journal_fingerprint) != "$before" ]]
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 15' "$_manifest_json"
  jq -e '.kind == "recovery-result" and .schema_version == 2 and .body.supervision_status == 1' "$TXDIR/publication-15.json" >/dev/null
  APPLY_REFUSAL=effect-after-failed-result recovery_apply_refused recovery_apply_request before \
    "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[configuration]}")" '{id:"configuration",state:$state}')"
  recovery_apply_idempotent recovery_apply_terminal 1
  APPLY_REFUSAL=different-failed-result recovery_apply_refused recovery_apply_terminal 1 1
  # The kernel write stands; the configuration target never changed.
  cmp -- "$CHILD_PATH/kernel" "$(jq -r '.file.path' <<<"$TARGET_KERNEL_COPY")"
  [[ $(basis_file_state "$CASE_DIR/esp/limine.conf") == "$(jq -c '.before' <<<"${_publication_stage_bodies[configuration]}")" ]]
  if commit_lifecycle_recovery_attempt; then fail_test 'failed result enabled completion'; fi
  recovery_target_original_unchanged
}
# Custody between the executor start and the worker's requests: a held stage
# changed in place or replaced refuses the stage and applied requests; a
# success claim with an unapplied effect becomes a failed result.
recovery_apply_custody() {
  local stage before
  recovery_apply_fixture
  publication_start_recovery_executor "$READY_NATIVE_FD"
  recovery_apply_launch
  recovery_apply_request application
  recovery_apply_request validate-plan "$(jq -cn --argjson plan "$APPLY_PLAN" '{plan:$plan}')"
  recovery_apply_request frontier '{"id":"kernel"}'
  recovery_apply_request before "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  stage=$(jq -r '.stage.path' <<<"${_publication_stage_bodies[kernel]}")
  printf 'altered\n' >>"$stage"
  APPLY_REFUSAL=stage-modified recovery_apply_refused recovery_apply_request stage '{"id":"kernel"}'
  cp -- "$(jq -r '.retained.path' <<<"${_publication_stage_bodies[kernel]}")" "$stage"
  recovery_apply_request stage '{"id":"kernel"}'
  cp -- "$stage" "$stage.next"; command mv -- "$stage.next" "$stage"
  APPLY_REFUSAL=stage-replaced recovery_apply_refused recovery_apply_request stage '{"id":"kernel"}'
  APPLY_REFUSAL=applied-with-replaced-stage recovery_apply_refused recovery_apply_request applied \
    "$(jq -cn --argjson state "$(jq -c '.stage.state' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  before=$(journal_fingerprint)
  if recovery_apply_terminal 0; then fail_test 'success claimed with an unapplied effect'; fi
  [[ $(journal_fingerprint) != "$before" && ! -e $CHILD_PATH/kernel ]]
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 14' "$_manifest_json"
  [[ $(jq -r '.kind' "$TXDIR/publication-12.json" "$TXDIR/publication-13.json" "$TXDIR/publication-14.json" | tr '\n' ' ') == 'recovery-executor recovery-effect-pending recovery-result ' ]]
  jq -e '.body.supervision_status == 1' "$TXDIR/publication-14.json" >/dev/null
  recovery_target_original_unchanged
}
recovery_apply_mutations() {
  local executor_valid pending_valid applied_valid result_valid filter mutation definition
  recovery_apply_fixture
  definition=$(declare -f append_publication_record)
  eval "${definition/append_publication_record/recovery_apply_actual_append}"
  # shellcheck disable=SC2329
  append_publication_record() {
    if [[ -n ${APPLY_CAPTURE:-} && $2 == "$APPLY_CAPTURE" ]]; then
      printf '%s\n' "$3" >"$CASE_DIR/captured-$2"
      return 1
    fi
    recovery_apply_actual_append "$@"
  }
  publication_start_recovery_executor "$READY_NATIVE_FD"
  APPLY_CAPTURE=recovery-executor
  if recovery_apply_launch; then fail_test 'captured executor accepted'; fi
  APPLY_CAPTURE=''
  executor_valid=$(<"$CASE_DIR/captured-recovery-executor")
  for filter in '.schema_version=1' '.body.extra=true' 'del(.body.boot_id)' '.body.worker.uid=0'; do
    recovery_target_schema_refused recovery-executor "$executor_valid" "$filter"
  done
  for mutation in '.supervisor.pid+=1' '.supervisor.start_time+="0"' '.boot_id="99999999-9999-4999-8999-999999999999"'; do
    recovery_target_semantic_candidate recovery-executor "$executor_valid" "$mutation"
  done
  recovery_apply_launch
  COPY_MUTATION=duplicate-executor
  recovery_target_candidate recovery-executor "$executor_valid"
  recovery_apply_request application
  recovery_apply_request validate-plan "$(jq -cn --argjson plan "$APPLY_PLAN" '{plan:$plan}')"
  recovery_apply_request frontier '{"id":"kernel"}'
  APPLY_CAPTURE=recovery-effect-pending
  if recovery_apply_request before "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"; then
    fail_test 'captured pending accepted'
  fi
  APPLY_CAPTURE=''
  pending_valid=$(<"$CASE_DIR/captured-recovery-effect-pending")
  for filter in '.schema_version=1' '.body.extra=true' '.body.result.kind="absent"' 'del(.body.observed)'; do
    recovery_target_schema_refused recovery-effect-pending "$pending_valid" "$filter"
  done
  # shellcheck disable=SC2016 # jq-bound values.
  for mutation in '.observed=.result' '.result.sha256=("0"*64)' '.result.identity="8800:1"' '.id="configuration"'; do
    recovery_target_semantic_candidate recovery-effect-pending "$pending_valid" "$mutation"
  done
  # An applied record before its pending is refused as data too.
  COPY_MUTATION=applied-before-pending
  recovery_target_candidate recovery-effect-applied "$(jq -c '{id,state:.result}' <<<"$pending_valid")"
  recovery_apply_request before "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  COPY_MUTATION=duplicate-pending
  recovery_target_candidate recovery-effect-pending "$pending_valid"
  recovery_apply_request stage '{"id":"kernel"}'
  command mv -- "$(jq -r '.stage.path' <<<"${_publication_stage_bodies[kernel]}")" "$CHILD_PATH/kernel"
  durable_sync "$CHILD_PATH/kernel" && durable_sync "$CHILD_PATH"
  APPLY_CAPTURE=recovery-effect-applied
  if recovery_apply_request applied "$(jq -cn --argjson state "$(jq -c '.stage.state' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"; then
    fail_test 'captured applied accepted'
  fi
  APPLY_CAPTURE=''
  applied_valid=$(<"$CASE_DIR/captured-recovery-effect-applied")
  for filter in '.schema_version=1' '.body.extra=true' '.body.state.kind="absent"'; do
    recovery_target_schema_refused recovery-effect-applied "$applied_valid" "$filter"
  done
  # shellcheck disable=SC2016 # jq-bound values.
  for mutation in '.state.sha256=("0"*64)' '.state.identity="8800:1"' '.id="configuration"'; do
    recovery_target_semantic_candidate recovery-effect-applied "$applied_valid" "$mutation"
  done
  recovery_apply_request applied "$(jq -cn --argjson state "$(jq -c '.stage.state' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
  COPY_MUTATION=duplicate-applied
  recovery_target_candidate recovery-effect-applied "$applied_valid"
  recovery_apply_effect configuration
  recovery_apply_request complete
  APPLY_CAPTURE=recovery-result
  if recovery_apply_terminal 0; then fail_test 'captured result accepted'; fi
  APPLY_CAPTURE=''
  result_valid=$(<"$CASE_DIR/captured-recovery-result")
  for filter in '.schema_version=1' '.body.extra=true' '.body.invocation="88888888-8888-4888-8888-888888888888"' '.body.worker_status=-1'; do
    recovery_target_schema_refused recovery-result "$result_valid" "$filter"
  done
  for mutation in '.completion_acknowledged=false' '.protocol_complete=false' '.worker_status=1' '.decoder_status=1'; do
    recovery_target_semantic_candidate recovery-result "$result_valid" "$mutation"
  done
  recovery_apply_terminal 0
  COPY_MUTATION=duplicate-result
  recovery_target_candidate recovery-result "$result_valid"
  COPY_MUTATION=executor-after-result
  recovery_target_candidate recovery-executor "$executor_valid"
  recovery_apply_assert_records 17 0
  recovery_target_original_unchanged
}
# The applied state of an effect: its before state for a no-op put (a present
# target already equal to the stage), otherwise the stage state.
recovery_apply_result_state() {
  jq -c 'if .before.kind == "file" and ((.before|del(.identity)) == (.stage.state|del(.identity))) then .before else .stage.state end' \
    <<<"${_publication_stage_bodies[$1]}"
}
recovery_apply_window_step() {
  case $1 in
    executor) recovery_apply_launch ;;
    pending) recovery_apply_request before "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')" ;;
    applied) recovery_apply_request applied "$(jq -cn --argjson state "$(recovery_apply_result_state kernel)" '{id:"kernel",state:$state}')" ;;
    result) recovery_apply_terminal 0 ;;
  esac
}
recovery_apply_cache_and_sync() {
  local slot index path window kind ordinal count existing definition
  recovery_apply_fixture
  recovery_apply_session
  read_transaction_manifest "$_transaction_id"
  slot="$_transaction_id:$(control_owner_uid)"
  [[ -n ${_publication_recovery_validation_cache[$slot]:-} ]]
  for index in 11 12 13 16; do
    path=$(jq -r --argjson n "$index" '.publication_records[$n].path' <<<"$_manifest_json")
    cp -- "$path" "$CASE_DIR/saved-record"
    chmod u+w "$path"; printf 'changed apply\n' >>"$path"
    if validate_publication_recovery_records "$_transaction_id" "$_manifest_json"; then fail_test "warm cache ignored $(basename "$path")"; fi
    [[ -z ${_publication_recovery_validation_cache[$slot]:-} ]] || fail_test 'failed cache entry was retained'
    cp -- "$CASE_DIR/saved-record" "$path"; chmod 600 "$path"
    validate_publication_recovery_records "$_transaction_id" "$_manifest_json"
  done
  recovery_target_original_unchanged
  # Durability windows for a pending effect and the result: the retry adopts
  # the unbound or unsynced record without a second one.
  definition=$(declare -f durable_sync)
  eval "${definition/durable_sync/recovery_apply_actual_sync}"
  TARGET_WINDOW='' TARGET_WINDOW_ORDINAL=0
  # shellcheck disable=SC2329
  durable_sync() {
    local n inject=false
    if [[ -n $TARGET_WINDOW && ! -e $CASE_DIR/target-sync-fault ]]; then
      n=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
      case $TARGET_WINDOW:$1 in
        record-file:"$TXDIR/publication-$TARGET_WINDOW_ORDINAL.json") inject=true ;;
        manifest-file:"$TXDIR/manifest.json") [[ $n != "$TARGET_WINDOW_ORDINAL" ]] || inject=true ;;
      esac
    fi
    if [[ $inject == true ]]; then printf '%s\n' "$TARGET_WINDOW" >"$CASE_DIR/target-sync-fault"; return 1; fi
    recovery_apply_actual_sync "$@"
  }
  for kind in executor pending applied result; do
    for window in record-file manifest-file; do
      rollback_and_mark_recovery 36 "fixture apply window $kind/$window"
      release_publication_pins
      begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
      TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
      retain_publication_recovery_input kernel
      TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
      retain_publication_recovery_input configuration
      TARGET_CONFIG_COPY=$_publication_recovery_copy_record TARGET_CONFIG_COPY_REF=$_publication_recovery_copy_reference
      prepare_publication_recovery_context
      authorize_publication_recovery_target kernel
      authorize_publication_recovery_target configuration
      stage_publication_recovery_target kernel
      stage_publication_recovery_target configuration
      ready_publication_recovery_plan "$READY_NATIVE_FD"
      APPLY_PLAN=$_publication_plan
      publication_start_recovery_executor "$READY_NATIVE_FD"
      if [[ $kind != executor ]]; then
        recovery_apply_launch
        recovery_apply_request application
        recovery_apply_request validate-plan "$(jq -cn --argjson plan "$APPLY_PLAN" '{plan:$plan}')"
      fi
      case $kind in
        pending) recovery_apply_request frontier '{"id":"kernel"}' ;;
        applied)
          # After the case's first apply the kernel target holds the desired
          # bytes, so this is the no-op path: before, no stage, no rename.
          recovery_apply_request before "$(jq -cn --argjson state "$(jq -c '.before' <<<"${_publication_stage_bodies[kernel]}")" '{id:"kernel",state:$state}')"
          if ! json_is '.[0] == .[1].before' "[$(recovery_apply_result_state kernel),${_publication_stage_bodies[kernel]}]"; then
            recovery_apply_request stage '{"id":"kernel"}'
            command mv -- "$(jq -r '.stage.path' <<<"${_publication_stage_bodies[kernel]}")" "$CHILD_PATH/kernel"
            durable_sync "$CHILD_PATH/kernel" && durable_sync "$CHILD_PATH"
          fi ;;
        result) recovery_apply_effect kernel; recovery_apply_effect configuration; recovery_apply_request complete ;;
      esac
      ordinal=$(( $(jq -r '.publication_records | length' "$TXDIR/manifest.json") + 1 ))
      rm -f -- "$CASE_DIR/target-sync-fault"
      TARGET_WINDOW=$window TARGET_WINDOW_ORDINAL=$ordinal
      if recovery_apply_window_step "$kind"; then fail_test "$kind accepted sync window $window"; fi
      TARGET_WINDOW=''
      [[ -s $CASE_DIR/target-sync-fault ]] || fail_test "sync seam missed $kind/$window"
      count=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
      case $window in record-file) [[ $count == $((ordinal-1)) ]] ;; manifest-file) [[ $count == "$ordinal" ]] ;; esac
      existing=''
      if [[ -e $TXDIR/publication-$ordinal.json ]]; then existing=$(sha256_file "$TXDIR/publication-$ordinal.json"); fi
      recovery_apply_window_step "$kind"
      [[ $(jq -r '.publication_records | length' "$TXDIR/manifest.json") == "$ordinal" ]]
      [[ -z $existing || $(sha256_file "$TXDIR/publication-$ordinal.json") == "$existing" ]] || fail_test "retry rewrote $kind record after $window"
      recovery_target_original_unchanged
      printf 'CHECK: apply sync/%s/%s (%s -> %s records)\n' "$kind" "$window" "$count" "$ordinal"
    done
  done
}
recovery_apply_root_journal_refused() {
  # Ordinary root journals reject the execution kinds even when well formed.
  local kind body ordinal previous document state
  context_fixture
  preserve_transaction_files_on_failure
  append_publication_record "$INVOCATION" intent "$INTENT"
  state=$(jq -cn --argjson uid "$(control_owner_uid)" '{kind:"file",identity:"8800:1",sha256:("0"*64),link_target:null,mode:33152,uid:$uid,gid:0}')
  for kind in recovery-executor recovery-effect-pending recovery-effect-applied recovery-result; do
    case $kind in
      recovery-executor) body=$SESSION ;;
      recovery-effect-pending) body=$(jq -cn --argjson state "$state" '{id:"kernel",observed:{kind:"absent",identity:null,sha256:null,link_target:null,mode:0,uid:0,gid:0},result:$state}') ;;
      recovery-effect-applied) body=$(jq -cn --argjson state "$state" '{id:"kernel",state:$state}') ;;
      recovery-result) body=$(jq -cn --arg invocation "$INVOCATION" '{invocation:$invocation,completion_acknowledged:true,protocol_complete:true,supervision_status:0,worker_status:0,decoder_status:0}') ;;
    esac
    ordinal=$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")
    previous=$(jq -c '.publication_records[-1]' "$TXDIR/manifest.json")
    document=$(jq -cn --arg id "$_transaction_id" --arg invocation "$INVOCATION" --argjson body "$body" --arg kind "$kind" \
      --argjson ordinal "$ordinal" --argjson previous "$previous" --arg timestamp "$(utc_timestamp)" --arg version "$OMASECBOOT_VERSION" '
      {schema_version:2,transaction_id:$id,invocation:$invocation,ordinal:$ordinal,previous:$previous,
        kind:$kind,body:$body,recorded_at:$timestamp,writer_version:$version}')
    validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document" || fail_test "well-formed $kind failed its schema"
    if append_publication_record "$INVOCATION" "$kind" "$body"; then fail_test "root journal admitted $kind"; fi
  done
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 1' "$_manifest_json"
}
recovery_target_root_journal_refused() {
  # Ordinary root journals reject the fresh-authority kinds even when well formed.
  local body document ordinal previous
  context_fixture
  preserve_transaction_files_on_failure
  append_publication_record "$INVOCATION" intent "$INTENT"
  TARGET_POLICY=$(jq -cn '{certificate:"/var/lib/sbctl/keys/db/db.pem",certificate_sha256:("c"*64),
    configuration:"/etc/sbctl/sbctl.conf",configuration_state:"absent",configuration_sha256:"",
    executable:"/usr/bin/sbctl",executable_sha256:("e"*64)}')
  body=$(jq -cn --argjson context "$CONTEXT" --argjson policy "$TARGET_POLICY" \
    --argjson reference "$(jq -c '.publication_records[0]' "$TXDIR/manifest.json")" \
    '{context:$context,original_context:{reference:$reference,projection:".body"},signing_policy:$policy}')
  ordinal=$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")
  previous=$(jq -c '.publication_records[-1]' "$TXDIR/manifest.json")
  document=$(jq -cn --arg id "$_transaction_id" --arg invocation "$INVOCATION" --argjson body "$body" \
    --argjson ordinal "$ordinal" --argjson previous "$previous" --arg timestamp "$(utc_timestamp)" --arg version "$OMASECBOOT_VERSION" '
    {schema_version:2,transaction_id:$id,invocation:$invocation,ordinal:$ordinal,previous:$previous,
      kind:"recovery-context",body:$body,recorded_at:$timestamp,writer_version:$version}')
  validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document"
  if append_publication_record "$INVOCATION" recovery-context "$body"; then fail_test 'root journal admitted recovery-context'; fi
  read_transaction_manifest "$_transaction_id"
  json_is '.publication_records | length == 1' "$_manifest_json"
}
recovery_target_cache() {
  local slot path index
  recovery_target_fixture
  prepare_publication_recovery_context
  authorize_publication_recovery_target kernel
  authorize_publication_recovery_target configuration
  read_transaction_manifest "$_transaction_id"
  slot="$_transaction_id:$(control_owner_uid)"
  [[ -n ${_publication_recovery_validation_cache[$slot]:-} ]]
  # Warm validation must recheck every fresh-authority record on each hit.
  for index in 5 6 7; do
    path=$(jq -r --argjson n "$index" '.publication_records[$n].path' <<<"$_manifest_json")
    cp -- "$path" "$CASE_DIR/saved-record"
    chmod u+w "$path"; printf 'changed fresh authority\n' >>"$path"
    if validate_publication_recovery_records "$_transaction_id" "$_manifest_json"; then fail_test "warm cache ignored $(basename "$path")"; fi
    [[ -z ${_publication_recovery_validation_cache[$slot]:-} ]] || fail_test 'failed cache entry was retained'
    cp -- "$CASE_DIR/saved-record" "$path"; chmod 600 "$path"
    validate_publication_recovery_records "$_transaction_id" "$_manifest_json"
    [[ -n ${_publication_recovery_validation_cache[$slot]:-} ]]
  done
  recovery_target_original_unchanged
}
recovery_target_fresh_attempt() {
  # Each sync window needs an unbound record, so every window gets a new
  # attempt, modelled as a new process view whose pins are its own.
  rollback_and_mark_recovery 32 "fixture fresh-authority window $1"
  release_publication_pins
  begin_publication_recovery_attempt "$BASIS_ROOT_REF" "$INVOCATION"
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  retain_publication_recovery_input kernel
  TARGET_KERNEL_COPY=$_publication_recovery_copy_record TARGET_KERNEL_COPY_REF=$_publication_recovery_copy_reference
  retain_publication_recovery_input configuration
  TARGET_CONFIG_COPY=$_publication_recovery_copy_record TARGET_CONFIG_COPY_REF=$_publication_recovery_copy_reference
}
recovery_target_sync_windows() {
  local window ordinal kind count existing='' definition
  recovery_target_fixture
  definition=$(declare -f durable_sync)
  eval "${definition/durable_sync/recovery_target_actual_sync}"
  TARGET_WINDOW='' TARGET_WINDOW_ORDINAL=0
  # shellcheck disable=SC2329
  durable_sync() {
    local n inject=false
    if [[ -n $TARGET_WINDOW && ! -e $CASE_DIR/target-sync-fault ]]; then
      n=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
      case $TARGET_WINDOW:$1 in
        record-temp:"$TXDIR/.publication-$TARGET_WINDOW_ORDINAL.json."*) inject=true ;;
        record-file:"$TXDIR/publication-$TARGET_WINDOW_ORDINAL.json") inject=true ;;
        record-directory:"$TXDIR") [[ ! -e $TXDIR/publication-$TARGET_WINDOW_ORDINAL.json || $n != $((TARGET_WINDOW_ORDINAL-1)) ]] || inject=true ;;
        manifest-temp:"$TXDIR/.manifest.json."*) [[ $n != $((TARGET_WINDOW_ORDINAL-1)) ]] || inject=true ;;
        manifest-file:"$TXDIR/manifest.json") [[ $n != "$TARGET_WINDOW_ORDINAL" ]] || inject=true ;;
        manifest-directory:"$TXDIR") [[ $n != "$TARGET_WINDOW_ORDINAL" ]] || inject=true ;;
      esac
    fi
    if [[ $inject == true ]]; then printf '%s\n' "$TARGET_WINDOW" >"$CASE_DIR/target-sync-fault"; return 1; fi
    recovery_target_actual_sync "$@"
  }
  for kind in context authorization; do
    # shellcheck disable=SC2153 # Case-prefix window list, like COPY_WINDOWS.
    for window in $TARGET_WINDOWS; do
      [[ $kind == context ]] || prepare_publication_recovery_context
      ordinal=$(( $(jq -r '.publication_records | length' "$TXDIR/manifest.json") + 1 ))
      rm -f -- "$CASE_DIR/target-sync-fault"
      TARGET_WINDOW=$window TARGET_WINDOW_ORDINAL=$ordinal
      if [[ $kind == context ]]; then
        if prepare_publication_recovery_context; then fail_test "context accepted sync window $window"; fi
        [[ -z $_publication_recovery_context_record && -z $_publication_recovery_context_reference ]]
      else
        if authorize_publication_recovery_target kernel; then fail_test "authorization accepted sync window $window"; fi
        [[ -z $_publication_recovery_authorization_record && -z $_publication_recovery_authorization_reference ]]
      fi
      TARGET_WINDOW=''
      [[ -s $CASE_DIR/target-sync-fault ]] || fail_test "sync seam missed $kind/$window"
      count=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
      case $window in
        record-*|manifest-temp) [[ $count == $((ordinal-1)) ]] ;;
        manifest-*) [[ $count == "$ordinal" ]] ;;
      esac
      existing=''
      if [[ -e $TXDIR/publication-$ordinal.json ]]; then existing=$(sha256_file "$TXDIR/publication-$ordinal.json"); fi
      # The retry adopts the exact pending or bound record from the same fresh
      # observation; no second record and no rewritten evidence.
      if [[ $kind == context ]]; then prepare_publication_recovery_context; else authorize_publication_recovery_target kernel; fi
      [[ $(jq -r '.publication_records | length' "$TXDIR/manifest.json") == "$ordinal" ]]
      [[ -z $existing || $(sha256_file "$TXDIR/publication-$ordinal.json") == "$existing" ]] || fail_test "retry rewrote $kind record after $window"
      jq -e --argjson ordinal "$ordinal" '.publication_records[$ordinal-1].path | endswith("/publication-\($ordinal).json")' "$TXDIR/manifest.json" >/dev/null
      recovery_target_original_unchanged
      printf 'CHECK: fresh authority sync/%s/%s (%s -> %s records)\n' "$kind" "$window" "$count" "$ordinal"
      recovery_target_fresh_attempt "$kind/$window"
    done
  done
  recovery_target_original_unchanged
}
recovery_target_owner_loss() {
  local fault path before collections
  recovery_target_fixture
  TARGET_TOKEN=$OMASECBOOT_TRANSACTION_TOKEN
  before=$(journal_fingerprint)
  for fault in owner boot repair marker; do
    path=''
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN='invalid-token' ;;
      boot|repair)
        if [[ $fault == boot ]]; then path=$(limine_lock_path); else path=$(state_dir_path)/repair.lock; fi
        command mv -- "$path" "$path.saved"; touch "$path" ;;
      marker) touch "$(snapshot_restore_lock_path)" ;;
    esac
    collections=$TARGET_COLLECTIONS
    recovery_target_context_refused "$fault"
    [[ $TARGET_COLLECTIONS == "$collections" && $(journal_fingerprint) == "$before" ]]
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN=$TARGET_TOKEN ;;
      boot|repair)
        rm -- "$path"; command mv -- "$path.saved" "$path"
        with_boot_repair_lock ;;
      marker) rm -- "$(snapshot_restore_lock_path)" ;;
    esac
  done
  prepare_publication_recovery_context
  before=$(journal_fingerprint)
  for fault in owner marker; do
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN='invalid-token' ;;
      marker) touch "$(snapshot_restore_lock_path)" ;;
    esac
    recovery_target_refused "$fault" kernel
    [[ $(journal_fingerprint) == "$before" ]]
    case $fault in
      owner) OMASECBOOT_TRANSACTION_TOKEN=$TARGET_TOKEN ;;
      marker) rm -- "$(snapshot_restore_lock_path)" ;;
    esac
  done
  authorize_publication_recovery_target kernel
  recovery_target_original_unchanged
}
expect_resolver_status() {
  local expected=$1 actual=0
  shift
  _publication_resolved_record=stale-output
  _publication_resolved_manifest=stale-output
  _publication_resolved_root_reference=stale-output
  publication_resolve_sealed_record "$@" || actual=$?
  [[ $actual == "$expected" ]] || fail_test "sealed resolver returned $actual, expected $expected"
  if (( expected == 0 )); then
    [[ -n $_publication_resolved_record && $_publication_resolved_record != stale-output &&
      -n $_publication_resolved_manifest && -n $_publication_resolved_root_reference ]]
  else
    [[ -z $_publication_resolved_record && -z $_publication_resolved_manifest && -z $_publication_resolved_root_reference ]] ||
      fail_test 'failed resolver retained stale outputs'
  fi
}
basis_assert_projection() {
  local basis=$_publication_original_basis refs ref kind
  if [[ ${BASIS_CONTEXT:-bound} == start ]]; then
    json_is 'keys == ["configuration","invocation","plan","resources","root","root_operation","root_target_state","schema","scope","start"] and
      .schema == 2 and .scope == "original-invocation-basis" and .root_operation == "sign" and .root_target_state == "active"' "$basis"
    json_is '.[0].root == .[1] and .[0].start == .[2] and .[0].plan == .[3] and
      .[0].configuration == .[4] and .[0].resources == [{id:"kernel",retained:.[5]}]' \
      "[$basis,$BASIS_ROOT_REF,$BASIS_START_REF,$BASIS_PLAN_REF,$BASIS_CONFIGURATION_REF,$BASIS_RETAINED_REF]"
    refs=$(jq -c '.start,.plan,.configuration,.resources[].retained' <<<"$basis")
  else
    json_is 'keys == ["configuration","context","intent","invocation","plan","resources","root","root_operation","root_target_state","schema","scope"] and
    .schema == 1 and .scope == "original-invocation-basis" and .root_operation == "sign" and .root_target_state == "active" and
    (.resources | type == "array")' "$basis"
    json_is '.[0].root == .[1] and .[0].intent == .[2] and .[0].context == .[3] and
    .[0].plan == .[4] and .[0].configuration == .[5] and .[0].resources == [{id:"kernel",retained:.[6]}]' \
    "[$basis,$BASIS_ROOT_REF,$BASIS_INTENT_REF,$BASIS_CONTEXT_REF,$BASIS_PLAN_REF,$BASIS_CONFIGURATION_REF,$BASIS_RETAINED_REF]"
    refs=$(jq -c '.intent,.context,.plan,.configuration,.resources[].retained' <<<"$basis")
  fi
  [[ $(jq -r '.invocation' <<<"$basis") == "$INVOCATION" ]]
  while IFS= read -r ref; do
    # shellcheck disable=SC2016 # jq-local reference.
    json_is '.[1] as $ref | .[0].publication_records | index($ref) != null' "[$BASIS_MANIFEST,$ref]"
    kind=$(jq -r '.kind' "$(jq -r '.path' <<<"$ref")")
    expect_resolver_status 0 "$BASIS_ROOT_REF" "$ref" "$INVOCATION" "$kind"
    json_is '.[0] == .[1]' "[$BASIS_MANIFEST,$_publication_resolved_manifest]"
    json_is '.[0] == .[1]' "[$BASIS_ROOT_REF,$_publication_resolved_root_reference]"
  done <<<"$refs"
  [[ $_publication_original_basis == "$basis" ]]
}
basis_fixture_fingerprint() {
  # Only this case's ordinary fixture tree, including names, modes and contents.
  find "$CASE_DIR" -printf '%y %m %p\n' | sort
  find "$CASE_DIR" -type f -print0 | sort -z | xargs -0 -r sha256sum --
}
basis_reader_tripwires() {
  local name
  for name in boot_id_value process_stat_fields new_transaction_id new_transaction_token \
    begin_lifecycle_transaction begin_lifecycle_recovery_attempt recovery_operation_for_root_manifest \
    publication_collect_stable_context publication_validate_plan publication_verify_stable_context \
    publication_authority_begin publication_authority_handler producer_session_context_is_owned \
    atomic_create_control_file atomic_write_control_file write_transaction_manifest_json durable_sync; do
    eval "$name() { fail_test 'historical data reader reached $name'; }"
  done
}
basis_valid_read_only() {
  local before git_before seal_hash manifest_hash basis saved
  basis_complete_fixture
  basis_seal_fixture
  jq -se 'all(.[]; .kind != "prepared-terminal" and .kind != "executor" and .kind != "terminal")' "$TXDIR"/publication-*.json >/dev/null
  before=$(basis_fixture_fingerprint)
  git_before=$(git -C "$ROOT_DIR" rev-parse HEAD; git -C "$ROOT_DIR" ls-files --stage)
  seal_hash=$(sha256_file "$TXDIR/incident.json")
  manifest_hash=$(sha256_file "$TXDIR/manifest.json")
  # Shadowed normal reader globals and unrelated runtime context must survive
  # both successful resolution and rejection, including the cache contents.
  _manifest_json=caller-manifest _manifest_id=caller-id _manifest_sha256=caller-hash
  _incident_json=caller-incident _incident_read_status=caller-status
  _transaction_id=77777777-7777-4777-8777-777777777777
  _recovery_root_reference=caller-lineage _publication_invocation=caller-invocation
  _publication_stable_context=caller-context
  _publication_validation_cache=([sentinel]=caller-cache)
  saved=$(declare -p _manifest_json _manifest_id _manifest_sha256 _incident_json _incident_read_status \
    _transaction_id _transaction_active _recovery_root_reference _publication_invocation _publication_stable_context _publication_validation_cache)
  basis_reader_tripwires
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  basis=$_publication_original_basis
  basis_assert_projection
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" retained
  expect_basis_status 1 "$BASIS_ROOT_REF" 88888888-8888-4888-8888-888888888888
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  [[ $_publication_original_basis == "$basis" ]]
  [[ $(declare -p _manifest_json _manifest_id _manifest_sha256 _incident_json _incident_read_status \
    _transaction_id _transaction_active _recovery_root_reference _publication_invocation _publication_stable_context _publication_validation_cache) == "$saved" ]]
  [[ $(basis_fixture_fingerprint) == "$before" && $(sha256_file "$TXDIR/incident.json") == "$seal_hash" &&
    $(sha256_file "$TXDIR/manifest.json") == "$manifest_hash" ]]
  [[ $(git -C "$ROOT_DIR" rev-parse HEAD; git -C "$ROOT_DIR" ls-files --stage) == "$git_before" ]]
}
basis_expired_objects() {
  local before
  basis_complete_fixture
  basis_seal_fixture
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  before=$_publication_original_basis
  rm -rf -- "$CASE_DIR/esp"
  rm -- "$CASE_DIR/source" "$TXDIR"/.publication-input.*
  [[ ! -e $STAGED_PATH && ! -e $CASE_DIR/esp/limine.conf && ! -e $CASE_DIR/source ]]
  basis_reader_tripwires
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  [[ $_publication_original_basis == "$before" ]]
  basis_assert_projection
}
basis_distinct_source_hash() {
  local source_hash retained_hash before
  basis_complete_fixture
  source_hash=$(sha256_file "$CASE_DIR/source")
  retained_hash=$(jq -r '.sha256' <<<"$RETAINED_REFERENCE")
  [[ $source_hash != "$retained_hash" ]]
  basis_seal_fixture
  before=$(journal_fingerprint)
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  basis_assert_projection
  expect_resolver_status 0 "$BASIS_ROOT_REF" "$BASIS_RETAINED_REF" "$INVOCATION" retained
  json_is '.[0].body.source_sha256 == .[1] and .[0].body.file.sha256 == .[2] and .[0].body.signing == "local-efi"' \
    "[$_publication_resolved_record,\"$source_hash\",\"$retained_hash\"]"
  if [[ ${BASIS_CONTEXT:-bound} == start ]]; then
    expect_resolver_status 0 "$BASIS_ROOT_REF" "$BASIS_START_REF" "$INVOCATION" invocation-start
    [[ $(jq -r '.body.intent.resources[0].sha256' <<<"$_publication_resolved_record") == "$source_hash" ]]
  else
    expect_resolver_status 0 "$BASIS_ROOT_REF" "$BASIS_INTENT_REF" "$INVOCATION" intent
    [[ $(jq -r '.body.resources[0].sha256' <<<"$_publication_resolved_record") == "$source_hash" ]]
  fi
  expect_resolver_status 0 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" plan
  [[ $(jq -r '.body.puts[0].after.sha256' <<<"$_publication_resolved_record") == "$retained_hash" && $(journal_fingerprint) == "$before" ]]
}
basis_failed_preparation_terminal() {
  basis_complete_fixture
  append_publication_record "$INVOCATION" prepared-terminal "$(jq -cn --arg invocation "$INVOCATION" '
    {invocation:$invocation,completion_acknowledged:false,protocol_complete:false,decoder_status:0,worker_status:19,supervision_status:19}')"
  basis_seal_fixture
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  basis_assert_projection
}
basis_other_partial_invocation() {
  local other=66666666-6666-4666-8666-666666666666 selected
  basis_complete_fixture
  selected=$INVOCATION
  append_publication_record "$other" intent "$INTENT"
  append_publication_record "$other" context "$CONTEXT"
  append_publication_record "$other" session "$SESSION"
  basis_seal_fixture
  expect_basis_status 0 "$BASIS_ROOT_REF" "$selected"
  basis_assert_projection
  expect_basis_status 1 "$BASIS_ROOT_REF" "$other"
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$other" plan
  # Successful projection has not made this mixed enclosing root completable.
  if recovery_operation_for_root_manifest "$BASIS_MANIFEST"; then fail_test 'basis relaxed recovery registry'; fi
}
basis_ineligible() {
  basis_complete_fixture
  basis_seal_fixture
  basis_reader_tripwires
  expect_basis_status 1 "$BASIS_ROOT_REF" "$INVOCATION"
}
basis_unbound_plan() {
  local ordinal previous document path ref
  basis_complete_fixture
  ordinal=$(jq -r '(.publication_records | length)+1' "$TXDIR/manifest.json")
  previous=$(jq -c '.publication_records[-1]' "$TXDIR/manifest.json")
  path=$TXDIR/publication-$ordinal.json
  document=$(jq -cn --arg id "$_transaction_id" --arg invocation "$INVOCATION" --argjson ordinal "$ordinal" \
    --argjson previous "$previous" --argjson body "$PLAN" --arg timestamp "$(utc_timestamp)" --arg version "$OMASECBOOT_VERSION" '
    {schema_version:1,transaction_id:$id,invocation:$invocation,ordinal:$ordinal,previous:$previous,kind:"plan",
      body:$body,recorded_at:$timestamp,writer_version:$version}')
  validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document"
  printf '%s\n' "$document" >"$path"
  ref=$(transaction_artifact_reference "$path" 1)
  # Prove it really is a complete valid candidate against the accepted prefix.
  validate_publication_records "$_transaction_id" "$(jq -c --argjson ref "$ref" '.publication_records += [$ref]' "$TXDIR/manifest.json")"
  basis_seal_fixture
  expect_basis_status 1 "$BASIS_ROOT_REF" "$INVOCATION"
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$ref" "$INVOCATION" plan
}
basis_bad_locators() {
  local filter bad before
  basis_complete_fixture
  basis_seal_fixture
  before=$(basis_fixture_fingerprint)
  for filter in '.schema_version=2' '.schema_version="1"' '.ordinal=1' '.invocation="11111111-1111-4111-8111-111111111111"' \
    '.root={}' '.sha256=("0" * 64)' '.sha256 += "\n"' '.path += ".unbound"' 'del(.sha256)'; do
    bad=$(jq -c "$filter" <<<"$BASIS_PLAN_REF")
    expect_resolver_status 2 "$BASIS_ROOT_REF" "$bad" "$INVOCATION" plan
  done
  for filter in '.schema_version=2' '.manifest={}' '.kind="attempt" | .ordinal=1' '.id="77777777-7777-4777-8777-777777777777"' \
    '.ordinal=1' '.operation="setup"' '.status="stale"' '.sha256=("0" * 64)' '.sha256 += "\n"' '.path += ".unbound"'; do
    bad=$(jq -c "$filter" <<<"$BASIS_ROOT_REF")
    expect_resolver_status 2 "$bad" "$BASIS_PLAN_REF" "$INVOCATION" plan
    expect_basis_status 2 "$bad" "$INVOCATION"
  done
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" retained
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" 77777777-7777-4777-8777-777777777777 plan
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" unknown
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" plan extra
  expect_basis_status 2 "$BASIS_ROOT_REF" "$INVOCATION" extra
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF $BASIS_PLAN_REF" "$INVOCATION" plan
  expect_basis_status 2 "$BASIS_ROOT_REF $BASIS_ROOT_REF" "$INVOCATION"
  expect_basis_status 2 "$BASIS_ROOT_REF" "$INVOCATION"$'\n'
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
basis_sibling_root() {
  local first_root first_record sibling_root sibling_record
  basis_complete_fixture
  basis_seal_fixture
  first_root=$BASIS_ROOT_REF first_record=$BASIS_PLAN_REF
  # Fixture-only loss of current lifecycle creates a second real sealed root in
  # the same transaction store. Both histories are valid; membership differs.
  rm -- "$(state_dir_path)/lifecycle.json"
  detach_transaction_context
  begin_lifecycle_transaction sign active
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  preserve_transaction_files_on_failure
  append_publication_record "$INVOCATION" intent "$INTENT"
  sibling_record=$_publication_record_reference
  basis_seal_fixture
  sibling_root=$BASIS_ROOT_REF
  expect_resolver_status 0 "$sibling_root" "$sibling_record" "$INVOCATION" intent
  expect_resolver_status 2 "$first_root" "$sibling_record" "$INVOCATION" intent
  expect_resolver_status 2 "$sibling_root" "$first_record" "$INVOCATION" plan
  # Resolving the supplied first root still succeeds while current lifecycle
  # names the sibling. Data resolution explicitly supplies no selection proof.
  expect_basis_status 0 "$first_root" "$INVOCATION"
  json_is '.[0].root == .[1]' "[$_publication_original_basis,$first_root]"
  expect_basis_status 1 "$sibling_root" "$INVOCATION"
}
basis_attempt_refused() {
  local root attempt
  commit_lifecycle_transaction
  begin_lifecycle_transaction sign active
  TXDIR=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
  rollback_and_mark_recovery 22 'fixture signing preparation failed'
  load_recovery_context
  root=$_recovery_root_reference
  begin_lifecycle_recovery_attempt software-recovery
  rollback_and_mark_recovery 23 'fixture recovery attempt failed'
  read_lifecycle
  attempt=$(jq -c '.transaction.last_recovery_attempt' <<<"$_lifecycle_json")
  validate_incident_reference "$attempt"
  json_is '.kind == "attempt"' "$_incident_json"
  expect_basis_status 2 "$attempt" "$INVOCATION"
  expect_resolver_status 2 "$attempt" '{}' "$INVOCATION" intent
  # A valid sealed empty root is data, but supplies no original invocation.
  expect_basis_status 1 "$root" "$INVOCATION"
  expect_resolver_status 2 "$root" '{}' "$INVOCATION" intent
}
basis_tampered_closure() {
  local path before
  basis_complete_fixture
  basis_seal_fixture
  # Exercise an already-proved closure too; a prior success cannot rescue bytes.
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  case $TAMPER in
    seal) path=$TXDIR/incident.json; printf ' ' >>"$path" ;;
    seal-manifest-digest)
      path=$TXDIR/incident.json
      before=$(jq -c '.manifest_sha256 += "\n"' "$path")
      printf '%s\n' "$before" >"$path"
      BASIS_ROOT_REF=$(incident_reference_from_json "$before" "$path")
      ;;
    manifest) path=$TXDIR/manifest.json; printf ' ' >>"$path" ;;
    record) path=$(jq -r '.path' <<<"$BASIS_PLAN_REF"); printf ' ' >>"$path" ;;
    retained) path=$(jq -r '.path' <<<"$RETAINED_REFERENCE"); printf 'substituted retained bytes\n' >"$path" ;;
    missing-retained) path=$(jq -r '.path' <<<"$RETAINED_REFERENCE"); rm -- "$path" ;;
    configuration) path=$TXDIR/publication-data-$INVOCATION-configuration; printf 'substituted config\n' >"$path" ;;
    original-configuration) path=$TXDIR/publication-data-$INVOCATION-original-configuration; chmod 600 "$path"; printf 'substituted original config\n' >"$path" ;;
    *) return 1 ;;
  esac
  before=$(basis_fixture_fingerprint)
  expect_basis_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_INTENT_REF" "$INVOCATION" intent
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
# Rebind deliberately contradictory ordinary fixture documents all the way to
# a new seal hash. This isolates semantic/envelope failures from trivial stale
# hashes. It never repairs or rewrites a production incident.
basis_rebind_contradiction() {
  local ordinal total path document previous=null references='[]' ref seal
  total=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
  for ((ordinal=1; ordinal<=total; ordinal++)); do
    path=$TXDIR/publication-$ordinal.json
    document=$(jq -c --argjson previous "$previous" '.previous=$previous' "$path")
    document=$(jq -c "$CONTRADICTION" <<<"$document")
    printf '%s\n' "$document" >"$path"
    ref=$(transaction_artifact_reference "$path" "$(jq -r '.schema_version' <<<"$document")")
    references=$(jq -c --argjson ref "$ref" '. + [$ref]' <<<"$references")
    previous=$ref
  done
  document=$(jq -c --argjson refs "$references" '.publication_records=$refs' "$TXDIR/manifest.json")
  validate_transaction_manifest_json "$_transaction_id" "$document" false
  printf '%s\n' "$document" >"$TXDIR/manifest.json"
  seal=$(jq -c --arg hash "$(sha256_file "$TXDIR/manifest.json")" '.manifest_sha256=$hash' "$TXDIR/incident.json")
  validate_incident_seal_json "$_transaction_id" "$seal"
  printf '%s\n' "$seal" >"$TXDIR/incident.json"
  BASIS_ROOT_REF=$(incident_reference_from_json "$seal" "$TXDIR/incident.json")
  BASIS_PLAN_REF=$(jq -c '.publication_records[-1]' "$TXDIR/manifest.json")
}
basis_hash_valid_contradiction() {
  local before
  basis_complete_fixture
  basis_seal_fixture
  basis_rebind_contradiction
  before=$(basis_fixture_fingerprint)
  expect_basis_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" plan
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
basis_stored_invocation_newline() {
  local CONTRADICTION reference kind document before intent_reference
  basis_complete_fixture
  basis_seal_fixture
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  case $INVOCATION_NEWLINE in
    complete)
      # Keep the plan body's UUID equal to its envelope. All other historical
      # invocation joins use the trimmed shell value, so this remains a complete
      # legacy-valid root while every stored envelope names a different identity.
      CONTRADICTION='.invocation += "\n" | if .kind == "plan" then .body.invocation=.invocation else . end'
      kind=plan
      ;;
    context)
      # The clean intent/plan must not borrow context from a distinct stored
      # invocation, even when the legacy reader conflates their shell values.
      CONTRADICTION='if .kind == "context" then .invocation += "\n" else . end'
      kind=context
      ;;
    *) return 1 ;;
  esac
  basis_rebind_contradiction
  # Unlike the malformed-root cases above, both the complete cold journal read
  # and the actual incident reference/seal read MUST succeed. Rebound hashes,
  # exact membership and all legacy joins are valid before the new API is tried.
  _publication_validation_cache=()
  validate_transaction_manifest_json "$_transaction_id" "$(read_control_document "$TXDIR/manifest.json")"
  validate_incident_reference "$BASIS_ROOT_REF"
  read_incident_seal "$_transaction_id"
  BASIS_MANIFEST=$_manifest_json
  if [[ $kind == plan ]]; then reference=$BASIS_PLAN_REF
  else reference=$(jq -c '.publication_records[1]' <<<"$BASIS_MANIFEST"); fi
  publication_read_manifest_member "$_transaction_id" "$BASIS_MANIFEST" "$reference"
  document=$_publication_member_record
  jq -e --arg invocation "$INVOCATION" --arg kind "$kind" '
    .kind == $kind and .invocation == ($invocation + "\n") and .invocation != $invocation' <<<"$document" >/dev/null
  # Explicitly establish the old extraction alias without changing any reader.
  [[ $(jq -r '.invocation' <<<"$document") == "$INVOCATION" ]]
  if [[ $kind == plan ]]; then json_is '.body.invocation == .invocation' "$document"; fi
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$reference" "$INVOCATION" "$kind"
  expect_basis_status 1 "$BASIS_ROOT_REF" "$INVOCATION"
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$reference" "$INVOCATION"$'\n' "$kind"
  expect_basis_status 2 "$BASIS_ROOT_REF" "$INVOCATION"$'\n'
  if [[ $INVOCATION_NEWLINE == context ]]; then
    # A correctly stored clean member remains resolvable; the whole basis is
    # ineligible specifically because no exact-identity context can be selected.
    expect_resolver_status 0 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" plan
  else
    intent_reference=$(jq -c '.publication_records[0]' <<<"$BASIS_MANIFEST")
    expect_resolver_status 2 "$BASIS_ROOT_REF" "$intent_reference" "$INVOCATION" intent
  fi
  [[ -z $_publication_original_basis && $(basis_fixture_fingerprint) == "$before" ]]
}
basis_retained_trim_alias() {
  local CONTRADICTION reference document resource before
  basis_complete_fixture
  basis_seal_fixture
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  case $RETAINED_ALIAS in
    id) CONTRADICTION='if .kind == "input-ready" or .kind == "retained" then .body.id += "\n" else . end' ;;
    source) CONTRADICTION='if .kind == "input-ready" or .kind == "retained" then .body.source_sha256 += "\n" else . end' ;;
    source-both)
      # Equal raw strings still must be exact digests. This exercises the strict
      # digest bound independently of the new raw equality comparison.
      CONTRADICTION='if .kind == "input-ready" or .kind == "retained" then .body.source_sha256 += "\n"
        elif .kind == "intent" then .body.resources[0].sha256 += "\n" else . end'
      ;;
    *) return 1 ;;
  esac
  basis_rebind_contradiction
  _publication_validation_cache=()
  validate_transaction_manifest_json "$_transaction_id" "$(read_control_document "$TXDIR/manifest.json")"
  validate_incident_reference "$BASIS_ROOT_REF"
  read_incident_seal "$_transaction_id"
  # Both ready and retained were changed and rebound; rejection must come from
  # new original-basis joins, not a stale hash or a broken ready/retained pair.
  reference=$(transaction_artifact_reference "$(jq -r '.path' <<<"$BASIS_RETAINED_REF")" 1)
  publication_read_manifest_member "$_transaction_id" "$_manifest_json" "$reference"
  document=$_publication_member_record
  resource=$(jq -c '(.body.intent // .body).resources[0]' "$TXDIR/publication-1.json")
  if [[ $RETAINED_ALIAS == id ]]; then
    json_is '.[0].body.id == (.[1].id + "\n") and .[0].body.id != .[1].id' "[$document,$resource]"
    [[ $(jq -r '.body.id' <<<"$document") == "$(jq -r '.id' <<<"$resource")" ]]
  else
    json_is '.body.source_sha256 | endswith("\n") and length == 65' "$document"
    [[ $(jq -r '.body.source_sha256' <<<"$document") == "$(jq -r '.sha256' <<<"$resource")" ]]
    if [[ $RETAINED_ALIAS == source-both ]]; then
      json_is '.[0].body.source_sha256 == .[1].sha256' "[$document,$resource]"
    else
      json_is '.[0].body.source_sha256 != .[1].sha256' "[$document,$resource]"
    fi
  fi
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_basis_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
  # Generic historical data resolution retains the actual stored value; it
  # must neither normalize it nor silently make it eligible as original basis.
  expect_resolver_status 0 "$BASIS_ROOT_REF" "$reference" "$INVOCATION" retained
  json_is '.[0] == .[1]' "[$document,$_publication_resolved_record]"
  [[ -z $_publication_original_basis && $(basis_fixture_fingerprint) == "$before" ]]
}

basis_parsed_document_substitution() {
  local SUBSTITUTE_PATH SUBSTITUTE_FILTER definition original substituted before reference expected_basis
  basis_complete_fixture
  basis_seal_fixture
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  expected_basis=$_publication_original_basis
  case $SUBSTITUTION in
    member)
      reference=$BASIS_INTENT_REF
      SUBSTITUTE_PATH=$(jq -r '.path' <<<"$reference")
      SUBSTITUTE_FILTER='.body.resources[0].source += "-substituted"'
      ;;
    manifest) SUBSTITUTE_PATH=$TXDIR/manifest.json; SUBSTITUTE_FILTER='.target_state="disabled"' ;;
    seal) SUBSTITUTE_PATH=$TXDIR/incident.json; SUBSTITUTE_FILTER='.writer_version += "-substituted"' ;;
    *) return 1 ;;
  esac
  original=$(read_control_document "$SUBSTITUTE_PATH")
  substituted=$(jq -c "$SUBSTITUTE_FILTER" <<<"$original")
  json_is '.[0] != .[1]' "[$original,$substituted]"
  before=$(basis_fixture_fingerprint)
  definition=$(declare -f read_control_document)
  eval "${definition/read_control_document/basis_unsubstituted_document}"
  # Simulate a transient different parsed document with the original pathname
  # bytes already restored at every hash check. The seam changes no validator,
  # hash helper, capture function, schema, or fixture file.
  # shellcheck disable=SC2329
  read_control_document() {
    local document
    document=$(basis_unsubstituted_document "$@") || return 1
    if [[ $1 == "$SUBSTITUTE_PATH" ]]; then jq -c "$SUBSTITUTE_FILTER" <<<"$document"
    else printf '%s\n' "$document"; fi
  }
  [[ $(read_control_document "$SUBSTITUTE_PATH") == "$substituted" ]]
  _publication_validation_cache=()
  validate_incident_reference "$BASIS_ROOT_REF"
  # Legacy validation succeeds under the seam. The two root substitutions must
  # be rejected specifically by captured-buffer equality, not a broken record.
  case $SUBSTITUTION in
    manifest) json_is '.target_state == "disabled"' "$_manifest_json" ;;
    seal) json_is '.writer_version | endswith("-substituted")' "$_incident_json" ;;
  esac
  basis_reader_tripwires
  if [[ $SUBSTITUTION == member ]]; then
    expect_resolver_status 0 "$BASIS_ROOT_REF" "$reference" "$INVOCATION" intent
    json_is '.[0] == .[1] and .[0] != .[2]' "[$_publication_resolved_record,$original,$substituted]"
    expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
    [[ $_publication_original_basis == "$expected_basis" ]]
  else
    expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_PLAN_REF" "$INVOCATION" plan
    expect_basis_status 2 "$BASIS_ROOT_REF" "$INVOCATION"
  fi
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}

expect_capture_status() {
  local expected=$1 actual=0
  shift
  CAPTURE_OUTPUT=stale-output
  CAPTURE_OUTPUT=$(publication_capture_hashed_document "$@" 2>/dev/null) || actual=$?
  [[ $actual == "$expected" ]] || fail_test "document capture returned $actual, expected $expected"
  if (( expected != 0 )); then [[ -z $CAPTURE_OUTPUT ]] || fail_test 'failed capture exposed parsed output'; fi
}
capture_literal_bytes() {
  local path=$CASE_DIR/capture.json compact='{"fixture":"ordinary bytes"}' raw_hash compact_hash
  printf ' { "fixture": "ordinary bytes" }\n\n' >"$path"
  raw_hash=$(sha256_file "$path")
  compact_hash=$(sha256_text "$compact")
  [[ $raw_hash != "$compact_hash" ]]
  expect_capture_status 0 "$path" "$raw_hash"
  [[ $CAPTURE_OUTPUT == "$compact" ]]
  # Equal parsed JSON does not make its differently serialized bytes hash-bound.
  expect_capture_status 1 "$path" "$compact_hash"
  [[ $(sha256_file "$path") == "$raw_hash" ]]
}
capture_malformed_bytes() {
  local path=$CASE_DIR/capture.json prefix='{"fixture":"prefixsuffix"}' hash
  case $CAPTURE_MALFORMED in
    nul)
      printf '{"fixture":"prefix\\u0000suffix"}\n' >"$path"
      expect_capture_status 0 "$path" "$(sha256_file "$path")"
      printf '{"fixture":"prefix\0suffix"}\n' >"$path"
      # A shell string capture that drops raw NUL could falsely match this hash.
      expect_capture_status 1 "$path" "$(sha256_text "$prefix"$'\n')"
      ;;
    trailing-json) printf '%s\n{"extra":"value"}\n' "$prefix" >"$path" ;;
    truncated-json) printf '{"fixture":"prefix' >"$path" ;;
    *) return 1 ;;
  esac
  hash=$(sha256_file "$path")
  # Exact raw hash is necessary but not sufficient: parsing must use those same
  # bytes and require one complete JSON value, not a prefix or normalized copy.
  expect_capture_status 1 "$path" "$hash"
  [[ $(sha256_file "$path") == "$hash" ]]
}
capture_after_validation_fault() {
  local path=$CASE_DIR/capture.json replacement=$CASE_DIR/capture-replacement.json hash definition
  printf '{"fixture":"complete ordinary document"}\n' >"$path"
  hash=$(sha256_file "$path")
  cp -- "$path" "$replacement"
  validate_private_control_file "$path"
  definition=$(declare -f validate_private_control_file)
  eval "${definition/validate_private_control_file/capture_original_private_control_file}"
  # The real control-file check succeeds, then only this ordinary fixture path
  # changes before dd opens it. Absolute dd/timeout and the capture stay real.
  # shellcheck disable=SC2329
  validate_private_control_file() {
    capture_original_private_control_file "$@" || return 1
    [[ $1 == "$path" ]] || return 0
    case $CAPTURE_FAULT in
      truncate) truncate -s 12 -- "$path" ;;
      disappear) rm -- "$path" ;;
      symlink) rm -- "$path"; ln -s -- "$replacement" "$path" ;;
      *) return 1 ;;
    esac
  }
  expect_capture_status 1 "$path" "$hash"
  case $CAPTURE_FAULT in
    truncate) [[ $(stat -c %s "$path") == 12 ]] ;;
    disappear) [[ ! -e $path && ! -L $path ]] ;;
    symlink) [[ -L $path && $(sha256_file "$replacement") == "$hash" ]] ;;
  esac
}
capture_size_boundary() {
  local path=$CASE_DIR/capture.json document='{"limit":true}' hash
  printf '%s%*s' "$document" "$((MAX_CONTROL_DOCUMENT_BYTES-${#document}))" '' >"$path"
  [[ $(stat -c %s "$path") == "$MAX_CONTROL_DOCUMENT_BYTES" ]]
  hash=$(sha256_file "$path")
  expect_capture_status 0 "$path" "$hash"
  [[ $CAPTURE_OUTPUT == "$document" ]]
  printf ' ' >>"$path"
  [[ $(stat -c %s "$path") == "$((MAX_CONTROL_DOCUMENT_BYTES+1))" ]]
  # Even the exact hash of the valid max+1-byte document cannot bypass the bound.
  expect_capture_status 1 "$path" "$(sha256_file "$path")"
  # Nor may a bounded reader silently accept the previously valid max-byte prefix.
  expect_capture_status 1 "$path" "$hash"
}

basis_multiple_resource_order() {
  local extra_id=alpha_initramfs extra_source=$CASE_DIR/source-initramfs extra_target
  local temporary retained ready extra_reference extra_stage kernel_reference file stage state before refs ref
  extra_target=$CASE_DIR/esp/entries/linux/$extra_id
  printf 'distinct initramfs fixture bytes\n' >"$extra_source"
  INTENT=$(jq -c --arg id "$extra_id" --arg source "$extra_source" --arg target "$extra_target" \
    --arg hash "$(sha256_file "$extra_source")" '.resources += [{id:$id,role:"initramfs",source:$source,target:$target,sha256:$hash}]' <<<"$INTENT")
  directory_history kernel "${BASIS_CONTEXT:-bound}"
  ordered_directory_records
  # Persist the second logical resource first. Neither journal order nor sorted
  # map keys match the original intent's [kernel, alpha_initramfs] order.
  temporary=$(mktemp "$TXDIR/.publication-input.XXXXXX")
  retained=$TXDIR/publication-data-$INVOCATION-$extra_id
  cp -- "$extra_source" "$temporary"
  cp -- "$temporary" "$retained"
  file=$(jq -cn --arg path "$retained" --arg hash "$(sha256_file "$retained")" \
    --argjson bytes "$(stat -c %s "$retained")" '{path:$path,sha256:$hash,bytes:$bytes}')
  ready=$(jq -cn --arg id "$extra_id" --argjson file "$file" --arg temporary "$temporary" '
    {id:$id,file:$file,source_sha256:$file.sha256,signing:"bytes",temporary:$temporary}')
  append_publication_record "$INVOCATION" input-ready "$ready"
  append_publication_record "$INVOCATION" retained "$(jq -c 'del(.temporary)' <<<"$ready")"
  extra_reference=$_publication_record_reference
  mkdir -p "$CHILD_PATH"
  stage=$(mktemp "$CHILD_PATH/.omasecboot-$INVOCATION-$extra_id.XXXXXX.stage")
  cp -- "$retained" "$stage"
  state=$(basis_file_state "$stage")
  extra_stage=$(STAGED_PATH=$stage STAGED_STATE=$state RETAINED_REFERENCE=$file stage_from_history "$HISTORY" |
    jq -c --arg id "$extra_id" --arg target "$extra_target" '.id=$id | .target=$target')
  append_publication_record "$INVOCATION" boot-stage "$extra_stage"
  retain_stage_fixture
  kernel_reference=$_publication_record_reference
  append_publication_record "$INVOCATION" boot-stage "$STAGE"
  basis_configuration_fixture
  PLAN=$(jq -cn --arg invocation "$INVOCATION" --argjson kernel "$STAGE" --argjson extra "$extra_stage" \
    --argjson config "$CONFIGURATION_STAGE" '
    def put: {id,target,before,after:.stage.state,parent,retained:.retained.path};
    {format:"limine-prepared-publication",schema:1,invocation:$invocation,
      puts:[$kernel,$extra | put],configuration:($config | put),deletes:[],references:[]}')
  append_publication_record "$INVOCATION" plan "$PLAN"
  basis_seal_fixture
  before=$(basis_fixture_fingerprint)
  expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  json_is '.[0].resources == [{id:"kernel",retained:.[1]},{id:"alpha_initramfs",retained:.[2]}] and
    .[0].scope == "original-invocation-basis"' "[$_publication_original_basis,$kernel_reference,$extra_reference]"
  refs=$(jq -c '.resources[]' <<<"$_publication_original_basis")
  while IFS= read -r ref; do
    expect_resolver_status 0 "$BASIS_ROOT_REF" "$(jq -c '.retained' <<<"$ref")" "$INVOCATION" retained
    json_is '.[0].body.id == .[1].id' "[$_publication_resolved_record,$ref]"
  done <<<"$refs"
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
basis_corrupt_partial_peer() {
  local selected=$INVOCATION other=66666666-6666-4666-8666-666666666666 peer_file before
  basis_complete_fixture
  INVOCATION=$other
  append_publication_record "$INVOCATION" intent "$INTENT"
  append_publication_record "$INVOCATION" context "$CONTEXT"
  append_publication_record "$INVOCATION" session "$SESSION"
  retain_stage_fixture
  peer_file=$(jq -r '.path' <<<"$RETAINED_REFERENCE")
  INVOCATION=$selected
  basis_seal_fixture
  expect_basis_status 0 "$BASIS_ROOT_REF" "$selected"
  expect_basis_status 1 "$BASIS_ROOT_REF" "$other"
  printf 'corrupt peer retained bytes\n' >"$peer_file"
  before=$(basis_fixture_fingerprint)
  expect_basis_status 2 "$BASIS_ROOT_REF" "$selected"
  expect_resolver_status 2 "$BASIS_ROOT_REF" "$BASIS_INTENT_REF" "$selected" intent
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
# Schema-2 authority uses ordinary immutable fixture bytes, including a binary
# original configuration in the copy test. No signing or platform acquisition.
original_configuration_fixture() {
  local path=$TXDIR/publication-data-$INVOCATION-original-configuration
  atomic_create_control_file "$path" 400 <"$CASE_DIR/esp/limine.conf"
  ORIGINAL_CONFIGURATION_REF=$(jq -cn --arg path "$path" --arg hash "$(sha256_file "$path")" \
    --argjson bytes "$(stat -c %s "$path")" '{path:$path,sha256:$hash,bytes:$bytes}')
}
start_fixture() {
  context_fixture
  original_configuration_fixture
  START_BODY=$(jq -cn --argjson intent "$INTENT" --argjson context "$CONTEXT" --argjson file "$ORIGINAL_CONFIGURATION_REF" '
    {intent:$intent,context:$context,original_configuration:$file,
      recovery:{recreate_missing:([$intent.resources[] | {id,target}] + [{id:"configuration",target:$intent.configuration.path}])}}')
}
start_document() {
  jq -cn --arg id "$_transaction_id" --arg invocation "$INVOCATION" --argjson body "$1" \
    --arg timestamp "$(utc_timestamp)" --arg version "$OMASECBOOT_VERSION" '
    {schema_version:2,transaction_id:$id,invocation:$invocation,ordinal:1,previous:null,
      kind:"invocation-start",body:$body,recorded_at:$timestamp,writer_version:$version}'
}
start_schema() {
  local filter bad document legacy
  start_fixture
  document=$(start_document "$START_BODY")
  validate_publication_record_json "$_transaction_id" 1 null "$document"
  while IFS= read -r filter; do
    [[ -n $filter ]] || continue
    bad=$(jq -c "$filter" <<<"$document")
    if validate_publication_record_json "$_transaction_id" 1 null "$bad"; then fail_test "start schema accepted $filter"; fi
  done <<'MUTATIONS'
.schema_version=1
.schema_version=3
.schema_version="2"
.kind="intent"
.kind="unknown"
.invocation += "\n"
.body.extra=true
del(.body.context)
del(.body.intent)
del(.body.original_configuration)
del(.body.recovery)
.body.intent.extra=true
del(.body.intent.publication)
.body.intent.publication.kind="replacement"
.body.intent.operation="remove"
.body.intent.resources=[]
.body.intent.resources += [.body.intent.resources[0]]
.body.intent.resources[0].id="configuration"
.body.intent.resources[0].id="original-configuration"
.body.intent.resources[0].id += "\n"
.body.intent.resources[0].id=""
.body.intent.resources[0].id=("a" * 65)
.body.intent.resources[0].sha256 += "\n"
.body.intent.configuration.sha256 += "\n"
.body.intent.resources[0].target += "/../elsewhere"
.body.intent.resources[0].source += "//alias"
.body.intent.resources[0].target += "\n"
.body.intent.resources[0].target="/outside/esp"
.body.intent.configuration.path="/outside/esp"
.body.recovery=null
.body.recovery=true
.body.recovery={recreate_missing:true}
.body.recovery.extra=true
.body.recovery.recreate_missing=[]
.body.recovery.recreate_missing |= reverse
.body.recovery.recreate_missing += [.body.recovery.recreate_missing[0]]
.body.recovery.recreate_missing[0].extra=true
.body.recovery.recreate_missing[0].id="unselected"
.body.recovery.recreate_missing[0].target += ".other"
.body.recovery.recreate_missing[1].target += ".other"
.body.recovery.recreate_missing[1].id="original-configuration"
.body.original_configuration.extra=true
.body.original_configuration.bytes="14"
.body.original_configuration.bytes=-1
.body.original_configuration.bytes=0.5
.body.original_configuration.sha256=("0" * 64)
.body.original_configuration.sha256 += "\n"
.body.original_configuration.path |= sub("original-configuration$"; "configuration")
.body.original_configuration.path += "-other"
.body.original_configuration.path |= sub("11111111"; "22222222")
MUTATIONS
  # Historical resource/digest anchors remain untouched, including old aliases.
  legacy=$(jq -c '.schema_version=1 | .kind="intent" | .body=.body.intent |
    .body.resources[0].id += "\n" | .body.resources[0].sha256 += "\n"' <<<"$document")
  validate_publication_record_json "$_transaction_id" 1 null "$legacy"
  if validate_publication_record_json "$_transaction_id" 1 null "$(jq -c '.schema_version=2' <<<"$legacy")"; then return 1; fi
}
start_valid() {
  local reference part status
  # Source bytes are not text-normalized while copied or validated.
  printf 'original\000configuration\n\n' >"$CASE_DIR/esp/limine.conf"
  INTENT=$(jq -c --arg hash "$(sha256_file "$CASE_DIR/esp/limine.conf")" '.configuration.sha256=$hash' <<<"$INTENT")
  start_fixture
  append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
  reference=$_publication_record_reference
  json_is '.schema_version == 2' "$reference"
  validate_historical_journal
  json_is '.file_rollback_policy == "preserve" and (.publication_records | length) == 1' "$_manifest_json"
  for part in intent context recovery original_configuration; do
    find_publication_authority_part "$INVOCATION" "$part"
    [[ $_publication_found_container_kind == invocation-start && $_publication_found_projection == ".body.$part" ]]
    json_is '.[0] == .[1]' "[$reference,$_publication_found_reference]"
    json_is '.[0] == .[1]' "[$(jq -c ".$part" <<<"$START_BODY"),$_publication_found_body]"
    status=0
    find_publication_record "$INVOCATION" "$part" || status=$?
    [[ $status == 1 ]] || fail_test 'actual-kind lookup fabricated a legacy record'
  done
  find_publication_record "$INVOCATION" invocation-start
  json_is '.[0] == .[1]' "[$START_BODY,$_publication_found_body]"
  cmp -- "$CASE_DIR/esp/limine.conf" "$(jq -r '.path' <<<"$ORIGINAL_CONFIGURATION_REF")"
  append_publication_record "$INVOCATION" session "$SESSION"
  validate_historical_journal
  jq -se 'map(.schema_version) == [2,1] and .[1].previous.schema_version == 2' "$TXDIR"/publication-*.json >/dev/null
  if commit_lifecycle_transaction; then fail_test 'start made nonempty journal completable'; fi
  if recovery_operation_for_root_manifest "$_manifest_json"; then fail_test 'start entered legacy recovery'; fi
}
start_binding_mismatch() {
  local filter bad before
  start_fixture
  before=$(journal_fingerprint)
  for filter in '.context.machine_id="abcdef0123456789abcdef0123456789"' '.context.root.path="/other"' \
    '.context.esp.path += "-other" | .context.configuration_path=(.context.esp.path+"/limine.conf")' \
    '.context.configuration_path += ".other"' '.intent.publication.model="not-json"' \
    '.intent.publication.model="[]"'; do
    bad=$(jq -c "$filter" <<<"$START_BODY")
    validate_publication_record_json "$_transaction_id" 1 null "$(start_document "$bad")"
    if append_publication_record "$INVOCATION" invocation-start "$bad"; then fail_test "start accepted $filter"; fi
    [[ $(journal_fingerprint) == "$before" && ! -e $TXDIR/publication-1.json ]]
  done
}
expect_authority_status() {
  local expected=$1 actual=0
  shift
  _publication_found_body=stale _publication_found_reference=stale
  _publication_found_container_kind=stale _publication_found_projection=stale
  find_publication_authority_part "$@" || actual=$?
  [[ $actual == "$expected" ]] || fail_test "authority lookup returned $actual, expected $expected"
  if (( expected != 0 )); then
    [[ -z $_publication_found_body && -z $_publication_found_reference &&
      -z $_publication_found_container_kind && -z $_publication_found_projection ]]
  fi
}
start_mixed_history() {
  local old=66666666-6666-4666-8666-666666666666 old_intent old_context start before original_configuration_for_old
  start_fixture
  preserve_transaction_files_on_failure
  append_publication_record "$old" intent "$INTENT"
  old_intent=$_publication_record_reference
  append_publication_record "$old" context "$CONTEXT"
  old_context=$_publication_record_reference
  append_publication_record "$old" session "$SESSION"
  append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
  start=$_publication_record_reference
  append_publication_record "$INVOCATION" session "$SESSION"
  validate_historical_journal
  jq -se 'map(.schema_version) == [1,1,1,2,1] and .[4].previous.schema_version == 2' "$TXDIR"/publication-*.json >/dev/null
  expect_authority_status 0 "$old" intent
  [[ $_publication_found_container_kind == intent && $_publication_found_projection == .body && $_publication_found_reference == "$old_intent" ]]
  expect_authority_status 0 "$old" context
  [[ $_publication_found_container_kind == context && $_publication_found_projection == .body && $_publication_found_reference == "$old_context" ]]
  expect_authority_status 1 "$old" recovery
  expect_authority_status 1 "$old" original_configuration
  expect_authority_status 0 "$INVOCATION" intent
  [[ $_publication_found_reference == "$start" && $_publication_found_projection == .body.intent ]]
  expect_authority_status 1 77777777-7777-4777-8777-777777777777 recovery
  expect_authority_status 2 "$INVOCATION" unsupported
  before=$(journal_fingerprint)
  # New and legacy forms share uniqueness maps, including non-tail duplicates.
  if append_publication_record "$INVOCATION" intent "$INTENT"; then return 1; fi
  if append_publication_record "$INVOCATION" context "$CONTEXT"; then return 1; fi
  if append_publication_record "$INVOCATION" invocation-start "$START_BODY"; then return 1; fi
  original_configuration_for_old=$(jq -c --arg old "$old" '.original_configuration.path |= sub("11111111-1111-4111-8111-111111111111"; $old)' <<<"$START_BODY")
  if append_publication_record "$old" invocation-start "$original_configuration_for_old"; then return 1; fi
  [[ $(journal_fingerprint) == "$before" ]]
  # Corrupt any anchored record: lookup must return 2 rather than fall back to
  # the valid legacy record, and must clear every stale projection output.
  printf ' ' >>"$(jq -r '.path' <<<"$start")"
  expect_authority_status 2 "$old" intent
  expect_authority_status 2 "$INVOCATION" recovery
}
start_original_copy() {
  local path before START_COPY_PATH
  start_fixture
  path=$(jq -r '.path' <<<"$ORIGINAL_CONFIGURATION_REF")
  START_COPY_PATH=$path
  if [[ ${COPY_PHASE:-bound} == bound ]]; then
    append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
    validate_historical_journal
  fi
  case $COPY_FAULT in
    hash) chmod 600 "$path"; printf 'substituted configuration\n' >"$path" ;;
    size) chmod 600 "$path"; printf ' ' >>"$path" ;;
    mode) chmod 644 "$path" ;;
    missing) rm -- "$path" ;;
    symlink) rm -- "$path"; ln -s -- "$CASE_DIR/esp/limine.conf" "$path" ;;
    directory) rm -- "$path"; mkdir -- "$path" ;;
    fifo) rm -- "$path"; mkfifo -- "$path" ;;
    owner)
      # Fixture metadata seam supplies a foreign owner without privilege.
      # shellcheck disable=SC2329
      stat() {
        if [[ $* == *"$START_COPY_PATH"* && $* == *%u* ]]; then printf '999999\n'
        else command stat "$@"; fi
      }
      ;;
    *) return 1 ;;
  esac
  before=$(sha256_file "$TXDIR/manifest.json")
  if [[ ${COPY_PHASE:-bound} == bound ]]; then
    # First lookup exercises the warm cache; the second performs cold joins.
    expect_authority_status 2 "$INVOCATION" original_configuration
    _publication_validation_cache=()
    if read_transaction_manifest "$_transaction_id"; then fail_test 'cold reader accepted invalid original bytes'; fi
  else
    if append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"; then return 1; fi
    [[ ! -e $TXDIR/publication-1.json ]]
  fi
  [[ $(sha256_file "$TXDIR/manifest.json") == "$before" ]]
}
start_reference_schema() {
  local candidate reference document schema
  start_fixture
  append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
  validate_historical_journal
  reference=$_publication_record_reference
  for schema in 1 3 '"2"'; do
    candidate=$(jq -c --argjson schema "$schema" '.publication_records[0].schema_version=$schema' <<<"$_manifest_json")
    if validate_publication_records "$_transaction_id" "$candidate"; then fail_test 'reference/envelope mismatch accepted'; fi
    if publication_read_manifest_member "$_transaction_id" "$candidate" "$(jq -c '.publication_records[0]' <<<"$candidate")"; then return 1; fi
  done
  # Even the proper schema cannot rescue an unsupported kind/envelope pairing.
  candidate=$(jq -c '.publication_records[0].sha256 += "\n"' <<<"$_manifest_json")
  if validate_publication_records "$_transaction_id" "$candidate"; then fail_test 'start reference accepted newline digest alias'; fi
  document=$(jq -c '.kind="context" | .body=.body.context' "$TXDIR/publication-1.json")
  printf '%s\n' "$document" >"$TXDIR/publication-1.json"
  reference=$(transaction_artifact_reference "$TXDIR/publication-1.json" 2)
  candidate=$(jq -c --argjson ref "$reference" '.publication_records=[$ref]' <<<"$_manifest_json")
  if validate_publication_records "$_transaction_id" "$candidate"; then return 1; fi
}
start_atomic_windows() {
  local definition START_ORIGINAL_PATH before policy records changed
  start_fixture
  START_ORIGINAL_PATH=$(jq -r '.path' <<<"$ORIGINAL_CONFIGURATION_REF")
  definition=$(declare -f write_transaction_manifest_json)
  eval "${definition/write_transaction_manifest_json/start_actual_manifest_write}"
  # Count the real CAS invocations and inspect candidate authority before any
  # manifest write. A separate policy helper would fail this tripwire.
  # shellcheck disable=SC2329
  preserve_transaction_files_on_failure() { fail_test 'start used separate preserve write'; }
  # shellcheck disable=SC2329
  write_transaction_manifest_json() {
    printf 'write\n' >>"$CASE_DIR/manifest-writes"
    json_is '.file_rollback_policy == "preserve" and (.publication_records | length) == 1 and
      .publication_records[0].schema_version == 2' "$1" || return 1
    [[ -e $TXDIR/publication-1.json ]] || return 1
    if [[ $START_WINDOW == before-bind && ! -e $CASE_DIR/start-fault ]]; then touch "$CASE_DIR/start-fault"; return 1; fi
    start_actual_manifest_write "$@" || return 1
    if [[ $START_WINDOW == after-bind && ! -e $CASE_DIR/start-fault ]]; then touch "$CASE_DIR/start-fault"; return 1; fi
  }
  # shellcheck disable=SC2329
  durable_sync() {
    local records policy hit=false
    records=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
    policy=$(jq -r '.file_rollback_policy' "$TXDIR/manifest.json")
    [[ $records == 0 && $policy == restore || $records == 1 && $policy == preserve ]] || fail_test 'torn start/policy state'
    if [[ ! -e $CASE_DIR/start-fault ]]; then
      case $START_WINDOW in
        original-file) [[ $1 != "$START_ORIGINAL_PATH" ]] || hit=true ;;
        original-directory) [[ $1 != "$TXDIR" || -e $TXDIR/publication-1.json ]] || hit=true ;;
        record-temporary) [[ $1 != "$TXDIR/.publication-1.json."* ]] || hit=true ;;
        record-directory) [[ $1 != "$TXDIR" || ! -e $TXDIR/publication-1.json || $records != 0 ]] || hit=true ;;
        record-file) [[ $1 != "$TXDIR/publication-1.json" || $records != 0 ]] || hit=true ;;
        manifest-temporary) [[ $1 != "$TXDIR/.manifest.json."* ]] || hit=true ;;
        manifest-directory) [[ $1 != "$TXDIR" || $records != 1 ]] || hit=true ;;
        manifest-file) [[ $1 != "$TXDIR/manifest.json" || $records != 1 ]] || hit=true ;;
        final-directory)
          if [[ $1 == "$TXDIR" && $records == 1 ]]; then
            if [[ -e $CASE_DIR/first-head-sync ]]; then hit=true; else touch "$CASE_DIR/first-head-sync"; fi
          fi
          ;;
      esac
    fi
    if [[ $hit == true ]]; then touch "$CASE_DIR/start-fault"; return 1; fi
    sync -f "$1"
  }
  if append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"; then
    fail_test "start ignored injected $START_WINDOW failure"
  fi
  [[ -e $CASE_DIR/start-fault && -z $_publication_record_reference ]]
  records=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
  policy=$(jq -r '.file_rollback_policy' "$TXDIR/manifest.json")
  case $START_WINDOW in
    after-bind|manifest-directory|manifest-file|final-directory) [[ $records == 1 && $policy == preserve ]] ;;
    *) [[ $records == 0 && $policy == restore ]] ;;
  esac
  if [[ -e $TXDIR/publication-1.json ]]; then
    before=$(journal_fingerprint)
    changed=$(jq -c '.context.local_db_certificate_der_sha256=("b" * 64)' <<<"$START_BODY")
    if append_publication_record "$INVOCATION" invocation-start "$changed"; then fail_test 'changed candidate context accepted'; fi
    changed=$(jq -c '.intent.resources[0].target += ".other" | .recovery.recreate_missing[0].target=.intent.resources[0].target' <<<"$START_BODY")
    if append_publication_record "$INVOCATION" invocation-start "$changed"; then fail_test 'changed candidate intent accepted'; fi
    changed=$(jq -c '.recovery.recreate_missing=[]' <<<"$START_BODY")
    if append_publication_record "$INVOCATION" invocation-start "$changed"; then fail_test 'changed candidate permission accepted'; fi
    [[ $(journal_fingerprint) == "$before" ]]
    before=$(sha256_file "$TXDIR/publication-1.json")
  else before=''; fi
  append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
  [[ -z $before || $(sha256_file "$TXDIR/publication-1.json") == "$before" ]]
  [[ ! -e $TXDIR/publication-2.json ]]
  validate_historical_journal
  json_is '.file_rollback_policy == "preserve" and (.publication_records | length) == 1' "$_manifest_json"
  # Successful retry is a sync-only operation, with no second CAS.
  before=$(wc -l <"$CASE_DIR/manifest-writes")
  append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
  [[ $(wc -l <"$CASE_DIR/manifest-writes") == "$before" ]]
  if [[ $START_WINDOW == before-bind || $START_WINDOW == manifest-temporary ]]; then [[ $before == 2 ]]
  else [[ $before == 1 ]]; fi
}
start_candidate_collision() {
  local document before candidate path=$TXDIR/publication-1.json
  start_fixture
  document=$(start_document "$START_BODY")
  case $START_COLLISION in
    different-kind) document=$(jq -c '.schema_version=1 | .kind="intent" | .body=.body.intent' <<<"$document") ;;
    different-invocation) document=$(jq -c '.invocation="77777777-7777-4777-8777-777777777777"' <<<"$document") ;;
    bad-schema) document=$(jq -c '.schema_version=3' <<<"$document") ;;
    mode|exact) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$document" >"$path"
  if [[ $START_COLLISION == mode ]]; then chmod 644 "$path"; fi
  before=$(journal_fingerprint)
  if [[ $START_COLLISION == exact ]]; then
    append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
    [[ $(sha256_file "$path") == "$(sha256_text "$document"$'\n')" ]]
  else
    if append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"; then return 1; fi
    [[ $(journal_fingerprint) == "$before" ]]
  fi
  candidate=$(jq -c '.publication_records' "$TXDIR/manifest.json")
  if [[ $START_COLLISION == exact ]]; then json_is 'length == 1 and .[0].schema_version == 2' "$candidate"
  else [[ $candidate == '[]' ]]; fi
}
start_candidate_substitution() {
  local START_SUBSTITUTION_PATH=$TXDIR/publication-1.json before definition changed
  start_fixture
  before=$(sha256_file "$TXDIR/manifest.json")
  if [[ $START_SUBSTITUTION == sync ]]; then
    # Replace a candidate with another valid context after the successful record
    # sync, before the writer obtains the actual reference it would publish.
    # shellcheck disable=SC2329
    durable_sync() {
      local changed
      sync -f "$1" || return 1
      if [[ $1 == "$START_SUBSTITUTION_PATH" && ! -e $CASE_DIR/substituted ]]; then
        changed=$(jq -c '.body.context.local_db_certificate_der_sha256=("b" * 64)' "$START_SUBSTITUTION_PATH") || return 1
        printf '%s\n' "$changed" >"$START_SUBSTITUTION_PATH"
        touch "$CASE_DIR/substituted"
      fi
    }
    if append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"; then
      fail_test 'substituted synced candidate acquired authority'
    fi
    [[ $(sha256_file "$TXDIR/manifest.json") == "$before" && -z $_publication_record_reference ]]
    before=$(journal_fingerprint)
    if append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"; then return 1; fi
  else
    append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
    before=$(journal_fingerprint)
    definition=$(declare -f read_control_document)
    eval "${definition/read_control_document/start_actual_read_document}"
    # A differing parsed answer cannot masquerade as the actual visible head.
    # All pathname bytes/hash checks still see the real original record.
    # shellcheck disable=SC2329
    read_control_document() {
      local document
      document=$(start_actual_read_document "$@") || return 1
      if [[ $1 == "$START_SUBSTITUTION_PATH" ]]; then jq -c '.body.context.local_db_certificate_der_sha256=("b" * 64)' <<<"$document"
      else printf '%s\n' "$document"; fi
    }
    changed=$(jq -c '.local_db_certificate_der_sha256=("b" * 64)' <<<"$CONTEXT")
    if append_publication_invocation_start "$INVOCATION" "$INTENT" "$changed" "$ORIGINAL_CONFIGURATION_REF"; then
      fail_test 'substituted parsed head rescued a different invocation start'
    fi
    append_publication_invocation_start "$INVOCATION" "$INTENT" "$CONTEXT" "$ORIGINAL_CONFIGURATION_REF"
  fi
  [[ $(journal_fingerprint) == "$before" ]]
}

# Fresh content APIs exercise the real sealed closure with ordinary fixture
# bytes. Observations are data only; no signer, live context or target acquisition.
expect_original_effect() {
  local expected=$1 actual=0
  shift
  _publication_original_effect=stale-output
  publication_resolve_original_effect "$@" || actual=$?
  [[ $actual == "$expected" ]] || fail_test "original effect returned $actual, expected $expected"
  if (( expected == 0 )); then
    json_is '.scope == "original-effect-data"' "$_publication_original_effect"
  else [[ -z $_publication_original_effect ]] || fail_test 'failed effect kept output'; fi
}
expect_original_classification() {
  local expected=$1 outcome=$2 actual=0
  shift 2
  _publication_content_classification=stale-output
  publication_classify_original_content "$@" || actual=$?
  [[ $actual == "$expected" ]] || fail_test "original classification returned $actual, expected $expected ($outcome)"
  if (( expected == 2 )); then
    [[ -z $_publication_content_classification ]] || fail_test 'invalid classification kept output'
  else
    jq -e --arg outcome "$outcome" '.scope == "original-content-classification" and .outcome == $outcome' \
      <<<"$_publication_content_classification" >/dev/null
  fi
}
original_observation() {
  jq -cn --argjson effect "$1" --argjson state "$2" '{path:$effect.target,state:$state}'
}
original_content_matrix() {
  local before effect config observation absent saved resource_expected=0 resource_outcome=allowed-absence
  local config_expected=1 config_outcome=conflict-absence
  basis_complete_fixture
  basis_seal_fixture
  if [[ ${ORIGINAL_BEFORE:-absent} == file ]]; then
    # A separately hash-bound historical resource before image, not a live put.
    local CONTRADICTION='if .kind == "boot-stage" and .body.id == "kernel" then
      .body.before=(.body.stage.state | .identity="8800:9007199254740993" | .sha256=("a" * 64) | .mode=33206)
      elif .kind == "plan" then
      .body.puts[0].before=(.body.puts[0].after | .identity="8800:9007199254740993" | .sha256=("a" * 64) | .mode=33206)
      else . end'
    basis_rebind_contradiction
    resource_expected=1 resource_outcome=conflict-absence
  fi
  if [[ ${BASIS_CONTEXT:-bound} == start ]]; then
    resource_expected=0 resource_outcome=allowed-absence config_expected=0 config_outcome=allowed-absence
  fi
  before=$(basis_fixture_fingerprint)
  _publication_original_basis=caller-basis _publication_resolved_record=caller-record
  _publication_resolved_manifest=caller-manifest _publication_resolved_root_reference=caller-root
  saved=$(declare -p _publication_original_basis _publication_resolved_record _publication_resolved_manifest _publication_resolved_root_reference)
  basis_reader_tripwires
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" kernel
  effect=$_publication_original_effect
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" configuration
  config=$_publication_original_effect
  json_is '.[0].basis.root == .[1] and .[0].basis.invocation == .[2] and
    .[0].before.kind == .[3].puts[0].before.kind and .[0].desired.sha256 == .[3].puts[0].after.sha256 and
    .[0].authority.plan.projection == ".body.puts[0]" and .[0].authority.retained.projection == ".body.file"' \
    "[$effect,$BASIS_ROOT_REF,\"$INVOCATION\",$(jq -c '.body' "$(jq -r '.path' <<<"$BASIS_PLAN_REF")")]"
  json_is '.effect_kind == "configuration" and .signing == "bytes" and .authority.plan.projection == ".body.configuration"' "$config"
  if [[ ${BASIS_CONTEXT:-bound} == start ]]; then
    json_is '.basis.schema == 2 and .absence.reason == "original-recreate-missing" and
      .absence.pair == {id:.id,target:.target} and .absence.authority.reference == .basis.start and
      .authority.intent == {reference:.basis.start,projection:".body.intent"} and
      .authority.context == {reference:.basis.start,projection:".body.context"}' "$config"
  else
    json_is '.basis.schema == 1 and .absence.reason == "original-before" and .absence.allowed == false and
      .absence.authority == {reference:.basis.plan,projection:".body.configuration.before"}' "$config"
  fi
  absent='{"kind":"absent","identity":null,"sha256":null,"link_target":null,"mode":0,"uid":0,"gid":0}'
  expect_original_classification "$resource_expected" "$resource_outcome" "$BASIS_ROOT_REF" "$INVOCATION" kernel "$(original_observation "$effect" "$absent")"
  expect_original_classification "$config_expected" "$config_outcome" "$BASIS_ROOT_REF" "$INVOCATION" configuration "$(original_observation "$config" "$absent")"
  # A same-context third state is still a conflict for both resource and config.
  publication_compare_stable_context "$CONTEXT" "$CONTEXT"
  for effect in "$effect" "$config"; do
    observation=$(jq -cn --argjson effect "$effect" --argjson uid "$(control_owner_uid)" '
      {path:$effect.target,state:{kind:"file",identity:"18446744073709551615:9007199254740993",
        sha256:$effect.desired.sha256,link_target:null,mode:33188,uid:$uid,gid:0}}')
    expect_original_classification 0 desired "$BASIS_ROOT_REF" "$INVOCATION" "$(jq -r '.id' <<<"$effect")" "$observation"
    json_is '.[0].observation == .[1] and (.[0] | has("receipt") | not) and
      (.[0].original_effect.before | keys) == ["kind","sha256"]' "[$_publication_content_classification,$observation]"
    observation=$(jq -c '.state.sha256=("b" * 64)' <<<"$observation")
    expect_original_classification 1 conflict-content "$BASIS_ROOT_REF" "$INVOCATION" "$(jq -r '.id' <<<"$effect")" "$observation"
    if json_is '.before.kind == "file"' "$effect"; then
      observation=$(jq -c --argjson effect "$effect" '.state.sha256=$effect.before.sha256' <<<"$observation")
      expect_original_classification 0 prior "$BASIS_ROOT_REF" "$INVOCATION" "$(jq -r '.id' <<<"$effect")" "$observation"
    fi
  done
  [[ $(declare -p _publication_original_basis _publication_resolved_record _publication_resolved_manifest _publication_resolved_root_reference) == "$saved" ]]
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_equal_hashes() {
  local before effect observation CONTRADICTION
  basis_complete_fixture
  basis_seal_fixture
  CONTRADICTION='if .kind == "boot-stage" and .body.id == "kernel" then .body.before=.body.stage.state
    elif .kind == "plan" then .body.puts[0].before=.body.puts[0].after else . end'
  basis_rebind_contradiction
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" kernel
  effect=$_publication_original_effect
  json_is '.before.sha256 == .desired.sha256' "$effect"
  observation=$(original_observation "$effect" "$(jq -c '.puts[0].after | .identity="9007199254740992:9007199254740993" | .mode=33188' <<<"$PLAN")")
  expect_original_classification 0 desired "$BASIS_ROOT_REF" "$INVOCATION" kernel "$observation"
  json_is '.observation.state.identity == "9007199254740992:9007199254740993"' "$_publication_content_classification"
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_distinct_hashes() {
  local effect before observation
  basis_complete_fixture
  basis_seal_fixture
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" kernel
  effect=$_publication_original_effect
  json_is '.signing == "local-efi" and .original_source.sha256 != .desired.sha256 and .desired.sha256 == .retained.sha256' "$effect"
  observation=$(original_observation "$effect" "$(jq -c '.puts[0].after | .identity="9:999"' <<<"$PLAN")")
  expect_original_classification 0 desired "$BASIS_ROOT_REF" "$INVOCATION" kernel "$observation"
  observation=$(jq -c --argjson effect "$effect" '.state.sha256=$effect.original_source.sha256' <<<"$observation")
  expect_original_classification 1 conflict-content "$BASIS_ROOT_REF" "$INVOCATION" kernel "$observation"
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_invalid_observation() {
  local before effect observation bad filter
  basis_complete_fixture
  basis_seal_fixture
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" kernel
  effect=$_publication_original_effect
  observation=$(original_observation "$effect" "$(jq -c '.puts[0].after' <<<"$PLAN")")
  while IFS= read -r filter; do
    bad=$(jq -c "$filter" <<<"$observation")
    expect_original_classification 2 invalid "$BASIS_ROOT_REF" "$INVOCATION" kernel "$bad"
  done <<'MUTATIONS'
.path += ".other"
.path += "\n"
.extra=true
.state.extra=true
del(.state.gid)
.state.uid += 1
.state.uid="0"
.state.gid=4294967296
.state.mode=33202
.state.mode=33190
.state.mode=16384
.state.mode=40960
.state.mode=4096
.state.mode=65536
.state.mode=0.5
.state.kind="directory"
.state.kind="symlink"
.state.kind="unknown"
.state.kind="unreadable"
.state.link_target="/elsewhere"
.state.identity="1:2\n"
.state.identity="1:2\r"
.state.identity="18446744073709551616:1"
.state.identity="1:-1"
.state.identity=9007199254740993
.state.sha256 += "\n"
.state.sha256 += "\r"
.state.sha256 |= ascii_upcase
.state.kind="absent"
.state=null
MUTATIONS
  for bad in "$observation $observation" '[' 'null' '[]' \
    "${observation/\"mode\":33152/\"mode\":33152.0000000000000000001}" \
    "${observation/\"mode\":33152/\"mode\":33152,\"mode\":33152}"; do
    expect_original_classification 2 invalid "$BASIS_ROOT_REF" "$INVOCATION" kernel "$bad"
  done
  bad=$(printf '%*s' "$((MAX_CONTROL_DOCUMENT_BYTES+1))" '')
  expect_original_classification 2 invalid "$BASIS_ROOT_REF" "$INVOCATION" kernel "$bad"
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_no_projection_authority() {
  local before effect observation fake
  basis_complete_fixture
  basis_seal_fixture
  before=$(basis_fixture_fingerprint)
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" configuration
  effect=$_publication_original_effect
  observation=$(original_observation "$effect" '{"kind":"absent","identity":null,"sha256":null,"link_target":null,"mode":0,"uid":0,"gid":0}')
  fake=$(jq -c '.absence.allowed=true | .basis.schema=2 | .basis.start=.basis.intent | .desired.sha256=("b" * 64)' <<<"$effect")
  _publication_original_effect=$fake _publication_original_basis=$(jq -c '.basis' <<<"$fake")
  _publication_found_body='{"recreate_missing":[{"id":"configuration","target":"/fake"}]}'
  basis_reader_tripwires
  expect_original_classification 1 conflict-absence "$BASIS_ROOT_REF" "$INVOCATION" configuration "$observation"
  [[ $_publication_original_effect == "$fake" ]]
  observation=$(original_observation "$effect" "$(jq -c '.configuration.after | .sha256=("b" * 64)' <<<"$PLAN")")
  expect_original_classification 1 conflict-content "$BASIS_ROOT_REF" "$INVOCATION" configuration "$observation"
  expect_original_effect 2 "$fake" "$INVOCATION" configuration
  expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" unknown
  expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" $'kernel\n'
  expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" $'kernel\r'
  expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" ''
  expect_original_effect 1 "$BASIS_ROOT_REF" 77777777-7777-4777-8777-777777777777 kernel
  expect_original_classification 2 invalid "$BASIS_ROOT_REF" "$INVOCATION" unknown "$observation"
  expect_original_classification 2 invalid "$BASIS_ROOT_REF" "$INVOCATION" configuration
  expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION"
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_expired_objects() {
  local before effect observation
  basis_complete_fixture
  basis_seal_fixture
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" kernel
  effect=$_publication_original_effect
  observation=$(original_observation "$effect" "$(jq -c '.puts[0].after | .identity="700:9007199254740993"' <<<"$PLAN")")
  rm -rf -- "$CASE_DIR/esp"
  rm -- "$CASE_DIR/source" "$TXDIR"/.publication-input.*
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_original_classification 0 desired "$BASIS_ROOT_REF" "$INVOCATION" kernel "$observation"
  # The supplied observation can say file even though no target exists here.
  # Success therefore proves classification only, never actual presence/custody.
  [[ ! -e $(jq -r '.target' <<<"$effect") && $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_actual_new_inode() {
  local before effect observation fresh=$CASE_DIR/fresh-ordinary-copy state
  basis_complete_fixture
  basis_seal_fixture
  cp -- "$(jq -r '.path' <<<"$RETAINED_REFERENCE")" "$fresh"
  state=$(basis_file_state "$fresh")
  json_is '.[0].identity != .[1].puts[0].after.identity and .[0].sha256 == .[1].puts[0].after.sha256' "[$state,$PLAN]"
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" kernel
  effect=$_publication_original_effect
  observation=$(original_observation "$effect" "$state")
  expect_original_classification 0 desired "$BASIS_ROOT_REF" "$INVOCATION" kernel "$observation"
  json_is '.[0].observation == .[1] and (.[0] | keys) == ["observation","original_effect","outcome","schema","scope"]' \
    "[$_publication_content_classification,$observation]"
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_raw_join() {
  local before CONTRADICTION
  basis_complete_fixture
  basis_seal_fixture
  case $ORIGINAL_RAW in
    config-before-newline)
      CONTRADICTION='if .kind == "boot-stage" and .body.id == "configuration" then .body.before.sha256 += "\n"
        elif .kind == "plan" then .body.configuration.before.sha256 += "\n" else . end' ;;
    retained-newline)
      CONTRADICTION='if .kind == "input-ready" or .kind == "retained" then .body.file.sha256 += "\n"
        elif .kind == "boot-stage" and .body.id == "kernel" then .body.retained.sha256 += "\n" | .body.stage.state.sha256 += "\n"
        elif .kind == "plan" then .body.puts[0].after.sha256 += "\n" else . end' ;;
    retained-id)
      CONTRADICTION='if .kind == "input-ready" or .kind == "retained" then .body.id += "\n" else . end' ;;
    retained-source)
      CONTRADICTION='if .kind == "input-ready" or .kind == "retained" then .body.source_sha256 += "\n" else . end' ;;
    retained-cr)
      CONTRADICTION='if .kind == "input-ready" or .kind == "retained" then .body.file.sha256 += "\r" else . end' ;;
    target)
      CONTRADICTION='if .kind == "plan" then .body.puts[0].target += ".other" else . end' ;;
    unknown-kind)
      CONTRADICTION='if .kind == "plan" then .kind="unknown" else . end' ;;
    permission)
      CONTRADICTION='if .kind == "invocation-start" then .body.recovery.recreate_missing[0].target += ".other" else . end' ;;
    *) return 1 ;;
  esac
  basis_rebind_contradiction
  if [[ $ORIGINAL_RAW == config-before-newline || $ORIGINAL_RAW == retained-newline ]]; then
    # Existing historical readers accept these shell-trim aliases. The complete
    # basis is genuinely valid there; new effect data must reject the raw bytes.
    expect_basis_status 0 "$BASIS_ROOT_REF" "$INVOCATION"
  fi
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  if [[ $ORIGINAL_RAW == config-before-newline ]]; then
    expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" configuration
  else expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" kernel; fi
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_raw_precision() {
  local before path reference bytes document previous=null references='[]' ordinal total seal
  basis_complete_fixture
  basis_seal_fixture
  total=$(jq -r '.publication_records | length' "$TXDIR/manifest.json")
  bytes=$(jq -r '.bytes' <<<"$RETAINED_REFERENCE")
  for ((ordinal=1; ordinal<=total; ordinal++)); do
    path=$TXDIR/publication-$ordinal.json
    document=$(jq -c --argjson previous "$previous" '.previous=$previous' "$path")
    # The legacy jq floor/comparison and raw -r extraction round this fraction
    # back to the actual byte count. No normalized rewrite touches this token.
    document=${document//\"bytes\":$bytes/\"bytes\":$bytes.0000000000000000001}
    printf '%s\n' "$document" >"$path"
    reference=$(transaction_artifact_reference "$path" "$(jq -r '.schema_version' <<<"$document")")
    references=$(jq -c --argjson reference "$reference" '. + [$reference]' <<<"$references")
    previous=$reference
  done
  document=$(jq -c --argjson refs "$references" '.publication_records=$refs' "$TXDIR/manifest.json")
  printf '%s\n' "$document" >"$TXDIR/manifest.json"
  seal=$(jq -c --arg hash "$(sha256_file "$TXDIR/manifest.json")" '.manifest_sha256=$hash' "$TXDIR/incident.json")
  printf '%s\n' "$seal" >"$TXDIR/incident.json"
  BASIS_ROOT_REF=$(incident_reference_from_json "$seal" "$TXDIR/incident.json")
  before=$(basis_fixture_fingerprint)
  basis_reader_tripwires
  expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" kernel
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}
original_content_ineligible_or_corrupt() {
  local before
  basis_complete_fixture
  basis_seal_fixture
  if [[ ${BASIS_PLAN:-bound} == partial ]]; then
    before=$(basis_fixture_fingerprint)
    basis_reader_tripwires
    expect_original_effect 1 "$BASIS_ROOT_REF" "$INVOCATION" kernel
    expect_original_classification 2 invalid "$BASIS_ROOT_REF" "$INVOCATION" kernel '{}'
  else
    expect_original_effect 0 "$BASIS_ROOT_REF" "$INVOCATION" kernel
    printf 'corrupted ordinary retained bytes\n' >"$(jq -r '.path' <<<"$RETAINED_REFERENCE")"
    before=$(basis_fixture_fingerprint)
    basis_reader_tripwires
    expect_original_effect 2 "$BASIS_ROOT_REF" "$INVOCATION" kernel
    expect_original_classification 2 invalid "$BASIS_ROOT_REF" "$INVOCATION" kernel '{}'
  fi
  [[ $(basis_fixture_fingerprint) == "$before" ]]
}

if [[ -n ${PUBLICATION_RECORDS_CASE:-} ]]; then printf 'Selected publication-journal cases: %s\n' "$PUBLICATION_RECORDS_CASE"; fi
run_case compatibility compatibility
run_case rollback-boundary rollback_boundary
run_case ordering ordering
SYNC_KIND=record run_case record-sync-retry sync_retry
SYNC_KIND='head' run_case head-sync-retry sync_retry
run_case tampered-reference tamper
run_case unknown-record unknown_record
run_case no-legacy-recovery no_legacy_recovery
run_case no-partial-completion no_partial_completion
run_case producer-recovery-exclusion producer_recovery_exclusion
run_case mixed-version-recovery mixed_version_recovery
run_case ordered-parent-child ordered_parent_child
run_case child-before-parent-created child_before_created
MISMATCH=identity run_case child-parent-state-mismatch child_parent_mismatch
MISMATCH=metadata run_case child-parent-metadata-mismatch child_parent_mismatch
MISMATCH=mount run_case child-parent-mount-mismatch child_parent_mismatch
MISMATCH=namespace run_case child-parent-namespace-mismatch child_parent_mismatch
run_case late-parent-after-descendant late_parent_after_descendant
run_case late-ancestor-after-descendant late_ancestor_after_descendant
run_case descendant-before-nonimmediate-ancestor-created descendant_before_ancestor_created
run_case descendant-after-nonimmediate-ancestor-created descendant_after_ancestor_created
run_case descendant-nonimmediate-ancestor-namespace-mismatch descendant_ancestor_namespace_mismatch
run_case matching-created-ancestor-stage matching_stage
MISMATCH=identity run_case stage-pending-parent-state-mismatch stage_parent_mismatch
MISMATCH=metadata run_case stage-pending-parent-metadata-mismatch stage_parent_mismatch
MISMATCH=mount run_case stage-pending-parent-mount-mismatch stage_parent_mismatch
MISMATCH=namespace run_case stage-pending-parent-namespace-mismatch stage_parent_mismatch
run_case stage-before-parent-created stage_before_created
run_case late-parent-after-stage late_parent_after_stage
run_case directory-journal-preserve-only directory_preserve_only
run_case historical-sealed-directories historical_sealed_directories
run_case context-bound context_accepted
CONTEXT_FILTER='.architecture="aarch64"' run_case context-aarch64 context_accepted
run_case context-without-intent context_no_intent
run_case context-after-session context_after_session
DUPLICATE=changed run_case context-duplicate-changed context_duplicate
DUPLICATE=identical run_case context-duplicate-nontail context_duplicate
run_case context-idempotent-retry context_retry
run_case context-per-invocation context_invocation_scope
CONTEXT_FILTER='.machine_id="abcdef0123456789abcdef0123456789"' run_case context-wrong-machine context_binding_mismatch
CONTEXT_FILTER='.esp.path += "-other" | .configuration_path=(.esp.path+"/limine.conf")' run_case context-wrong-esp context_binding_mismatch
CONTEXT_FILTER='.configuration_path += ".other"' run_case context-wrong-config context_binding_mismatch
CONTEXT_FILTER='.root.path="/other"' run_case context-wrong-root context_binding_mismatch
INTENT_FILTER='del(.publication)' run_case context-legacy-intent context_model_mismatch
INTENT_FILTER='.publication.model="not-json"' run_case context-malformed-model context_model_mismatch
INTENT_FILTER='.publication.model="[]"' run_case context-nonobject-model context_model_mismatch
INTENT_FILTER='.publication.model |= (fromjson | del(.machine_id) | tojson)' run_case context-model-without-machine context_model_mismatch
INTENT_FILTER='.publication.model |= (fromjson | .entry_override=.machine_id | .machine_id="abcdef0123456789abcdef0123456789" | tojson)' run_case context-placement-is-not-machine context_model_mismatch
INTENT_FILTER='.publication.model |= (fromjson | .machine_id=123 | tojson)' run_case context-numeric-model-machine context_model_mismatch
CONTEXT_MUTATIONS='
.extra=true
.root.extra=true
.root.subvolume.extra=true
.esp.extra=true
.root.mount_id="42"
.root.identity="8800:1"
.root.subvolume.generation="9007199254740993"
' run_case context-unknown-fields context_schema_invalid
CONTEXT_MUTATIONS='
.schema_version=0
.schema_version=2
.schema_version="1"
.schema_version=null
del(.schema_version)
' run_case context-unknown-versions context_schema_invalid
CONTEXT_MUTATIONS='
del(.architecture)
.architecture="i686"
.machine_id="00000000000000000000000000000000"
.machine_id="0123456789ABCDEF0123456789ABCDEF"
.machine_id="0123456789abcdef0123456789abcde"
.machine_id=null
.local_db_certificate_der_sha256="abcd"
.root.filesystem_uuid="00000000-0000-0000-0000-000000000000"
.esp.partition_uuid="not-a-uuid"
.esp.partition_scheme="mbr"
.esp.partition_type="55555555-5555-4555-8555-555555555555"
.esp.filesystem_type="ext4"
.esp.filesystem_uuid="a1b2-c3d4"
.esp.filesystem_uuid="A1B2C3D4"
.root.filesystem_type="overlay"
' run_case context-invalid-identities context_schema_invalid
CONTEXT_MUTATIONS='
.root.path="relative"
.root.path="//"
.root.path="/../root"
.configuration_path="/outside/limine.conf"
.configuration_path=(.esp.path+"/../limine.conf")
.configuration_path=(.esp.path+"//limine.conf")
.configuration_path=(.esp.path+"/./limine.conf")
.configuration_path=(.esp.path+"-other/limine.conf")
.esp.path += "/"
.esp.path="/"
' run_case context-noncanonical-paths context_schema_invalid
CONTEXT_FILTER='.root.subvolume.id="9007199254740993"' run_case context-subvolume-precision context_accepted
CONTEXT_FILTER='.root.subvolume.id="18446744073709551360"' run_case context-subvolume-upper-bound context_accepted
CONTEXT_MUTATIONS='
.root.subvolume.id=256
.root.subvolume.id=9007199254740993
.root.subvolume.id="5"
.root.subvolume.id="255"
.root.subvolume.id="18446744073709551361"
.root.subvolume.id="18446744073709551615"
.root.subvolume.id="18446744073709551616"
.root.subvolume.id="184467440737095513600"
.root.subvolume.id="-256"
.root.subvolume.id="0256"
.root.subvolume.id="+256"
.root.subvolume.id="2.56e2"
.root.subvolume.id="256.0"
.root.subvolume.id=""
.root.subvolume.id=null
' run_case context-subvolume-id-bounds context_schema_invalid
CONTEXT_MUTATIONS='
.root.subvolume.uuid=null
.root.subvolume.uuid="00000000-0000-0000-0000-000000000000"
.root.subvolume.uuid="256"
.root.subvolume.uuid=256
.root.subvolume.id=.root.subvolume.uuid
.root.subvolume.kind="snapshot"
.root.subvolume=null
' run_case context-subvolume-uuid-not-id context_schema_invalid
CONTEXT_FILTER='.root.subvolume={kind:"top-level",id:"5",uuid:null}' run_case context-top-level-null-uuid context_accepted
CONTEXT_FILTER='.root.subvolume.kind="top-level" | .root.subvolume.id="5"' run_case context-top-level-generated-uuid context_accepted
CONTEXT_MUTATIONS='
.root.subvolume={kind:"top-level",id:5,uuid:null}
.root.subvolume={kind:"top-level",id:"256",uuid:null}
.root.subvolume={kind:"top-level",id:"05",uuid:null}
.root.subvolume={kind:"top-level",id:"5",uuid:"00000000-0000-0000-0000-000000000000"}
.root.subvolume={kind:"top-level",id:"5"}
' run_case context-top-level-invalid context_schema_invalid
CONTEXT_FILTER='.root.filesystem_type="ext4" | .root.subvolume=null' run_case context-ext4-whole-filesystem context_accepted
CONTEXT_FILTER='.root.filesystem_type="xfs" | .root.subvolume=null' run_case context-xfs-whole-filesystem context_accepted
CONTEXT_MUTATIONS='
.root.filesystem_type="ext4"
.root.filesystem_type="xfs"
.root.filesystem_type="ext4" | del(.root.subvolume)
.root.filesystem_type="xfs" | .root.subvolume={}
' run_case context-whole-filesystem-requires-null context_schema_invalid
CONTEXT_HISTORY=bound run_case context-historical-after-object-loss context_historical
CONTEXT_HISTORY=absent run_case context-free-historical-no-retrofit context_historical
run_case context-runtime-begin-before-launch context_runtime_begin
for runtime_copy_fault in copy-result temporary-sync destination-sync directory-sync live-after-copy; do
  RUNTIME_COPY_FAULT=$runtime_copy_fault run_case "context-runtime-original-copy-$runtime_copy_fault" context_runtime_copy_failure
done
run_case context-runtime-original-copy-exact-existing-retry context_runtime_existing_copy
run_case context-runtime-original-copy-conflicting-existing-refused context_runtime_conflicting_copy
run_case context-comparator-status-and-precision context_comparator
CONTEXT_MUTATIONS='.root.subvolume.id="256\n"' run_case context-subvolume-trailing-newline context_schema_invalid
# Trailing newlines must not exploit end anchors; embedded replacements retain
# each field's required length so length checks alone cannot reject them.
CONTEXT_MUTATIONS='
.root.filesystem_uuid += "\n"
.root.subvolume.uuid += "\n"
.esp.partition_uuid += "\n"
.machine_id += "\n"
.local_db_certificate_der_sha256 += "\n"
.esp.filesystem_uuid += "\n"
.root.filesystem_uuid |= (.[0:2] + "\n" + .[3:])
.root.subvolume.uuid |= (.[0:2] + "\n" + .[3:])
.esp.partition_uuid |= (.[0:2] + "\n" + .[3:])
.machine_id |= (.[0:2] + "\n" + .[3:])
.local_db_certificate_der_sha256 |= (.[0:2] + "\n" + .[3:])
.esp.filesystem_uuid |= (.[0:2] + "\n" + .[3:])
' run_case context-identity-newlines context_schema_invalid
run_case sealed-basis-valid-ref-only-read-only basis_valid_read_only
run_case sealed-basis-after-old-object-loss basis_expired_objects
BASIS_SIGNING=local-efi run_case sealed-basis-distinct-source-and-retained-hashes basis_distinct_source_hash
run_case sealed-basis-failed-prepared-terminal basis_failed_preparation_terminal
run_case sealed-basis-selected-invocation-with-partial-peer basis_other_partial_invocation
BASIS_CONTEXT=absent run_case sealed-basis-missing-context-ineligible basis_ineligible
BASIS_PLAN=partial run_case sealed-basis-partial-input-ineligible basis_ineligible
BASIS_PLAN=unbound run_case sealed-basis-valid-unbound-plan-ineligible basis_unbound_plan
run_case sealed-basis-exact-locators basis_bad_locators
run_case sealed-basis-sibling-root-membership basis_sibling_root
run_case sealed-basis-actual-attempt-refused basis_attempt_refused
TAMPER=seal run_case sealed-basis-tampered-seal basis_tampered_closure
TAMPER=seal-manifest-digest run_case sealed-basis-exact-sealed-manifest-digest basis_tampered_closure
TAMPER=manifest run_case sealed-basis-tampered-manifest basis_tampered_closure
TAMPER=record run_case sealed-basis-tampered-record basis_tampered_closure
TAMPER=retained run_case sealed-basis-substituted-retained basis_tampered_closure
TAMPER=missing-retained run_case sealed-basis-missing-retained basis_tampered_closure
TAMPER=configuration run_case sealed-basis-substituted-configuration basis_tampered_closure
CONTRADICTION='if .kind == "plan" then .ordinal-=1 else . end' run_case sealed-basis-hash-valid-wrong-ordinal basis_hash_valid_contradiction
CONTRADICTION='if .kind == "plan" then .transaction_id="77777777-7777-4777-8777-777777777777" else . end' run_case sealed-basis-hash-valid-sibling-envelope basis_hash_valid_contradiction
CONTRADICTION='if .kind == "plan" then .invocation="77777777-7777-4777-8777-777777777777" else . end' run_case sealed-basis-hash-valid-wrong-invocation basis_hash_valid_contradiction
CONTRADICTION='if .kind == "plan" then .kind="retained" else . end' run_case sealed-basis-hash-valid-wrong-kind basis_hash_valid_contradiction
CONTRADICTION='if .kind == "retained" then .body.source_sha256=("0" * 64) else . end' run_case sealed-basis-hash-valid-broken-source-join basis_hash_valid_contradiction
CONTRADICTION='if .kind == "plan" then .body.puts=[] else . end' run_case sealed-basis-hash-valid-incomplete-bound-plan basis_hash_valid_contradiction
CONTRADICTION='if .kind == "plan" then .body.configuration.target += ".other" else . end' run_case sealed-basis-hash-valid-substituted-target basis_hash_valid_contradiction
CONTRADICTION='if .kind == "plan" then .body.puts[0].after.sha256=("0" * 64) else . end' run_case sealed-basis-hash-valid-substituted-desired-hash basis_hash_valid_contradiction
INVOCATION_NEWLINE=complete run_case sealed-basis-hash-valid-stored-invocation-newline basis_stored_invocation_newline
INVOCATION_NEWLINE=context run_case sealed-basis-hash-valid-stored-context-invocation-newline basis_stored_invocation_newline
RETAINED_ALIAS=id run_case sealed-basis-hash-valid-retained-id-newline basis_retained_trim_alias
RETAINED_ALIAS=source run_case sealed-basis-hash-valid-retained-source-newline basis_retained_trim_alias
RETAINED_ALIAS=source-both run_case sealed-basis-hash-valid-equal-source-newline basis_retained_trim_alias
SUBSTITUTION=member run_case sealed-basis-captured-member-not-substituted-parse basis_parsed_document_substitution
SUBSTITUTION=manifest run_case sealed-basis-captured-manifest-parse-mismatch basis_parsed_document_substitution
SUBSTITUTION=seal run_case sealed-basis-captured-seal-parse-mismatch basis_parsed_document_substitution
run_case capture-literal-bytes-not-normalized-json capture_literal_bytes
CAPTURE_MALFORMED=nul run_case capture-raw-nul capture_malformed_bytes
CAPTURE_MALFORMED=trailing-json run_case capture-trailing-json-value capture_malformed_bytes
CAPTURE_MALFORMED=truncated-json run_case capture-truncated-json capture_malformed_bytes
CAPTURE_FAULT=truncate run_case capture-truncated-after-validation capture_after_validation_fault
CAPTURE_FAULT=disappear run_case capture-read-failure-after-validation capture_after_validation_fault
CAPTURE_FAULT=symlink run_case capture-nofollow-after-validation capture_after_validation_fault
run_case capture-exact-size-boundary capture_size_boundary
run_case sealed-basis-original-multiple-resource-order basis_multiple_resource_order
run_case sealed-basis-corrupt-partial-peer basis_corrupt_partial_peer
run_case invocation-start-exact-schema-permission-and-legacy-shapes start_schema
run_case invocation-start-original-bytes-typed-views-and-closed-gates start_valid
run_case invocation-start-context-intent-binding start_binding_mismatch
run_case invocation-start-mixed-history-duplicates-and-no-rescue start_mixed_history
run_case invocation-start-reference-envelope-schemas start_reference_schema
for COPY_FAULT in hash size mode missing symlink directory fifo owner; do
  COPY_PHASE=bound run_case "invocation-start-original-copy-$COPY_FAULT-cache-and-cold" start_original_copy
  COPY_PHASE=unbound run_case "invocation-start-original-copy-$COPY_FAULT-before-bind" start_original_copy
done
for START_WINDOW in original-file original-directory record-temporary record-directory record-file before-bind \
  manifest-temporary after-bind manifest-directory manifest-file final-directory; do
  run_case "invocation-start-atomic-$START_WINDOW" start_atomic_windows
done
for START_COLLISION in different-kind different-invocation bad-schema mode exact; do
  run_case "invocation-start-candidate-$START_COLLISION" start_candidate_collision
done
START_SUBSTITUTION=sync run_case invocation-start-candidate-sync-substitution start_candidate_substitution
START_SUBSTITUTION='head' run_case invocation-start-visible-head-parse-substitution start_candidate_substitution
BASIS_CONTEXT=start run_case invocation-start-sealed-basis2-ref-only-read-only basis_valid_read_only
BASIS_CONTEXT=start run_case invocation-start-sealed-basis2-expired-objects basis_expired_objects
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case invocation-start-sealed-basis2-source-retained-hashes basis_distinct_source_hash
BASIS_CONTEXT=start BASIS_PLAN=partial run_case invocation-start-sealed-basis2-partial-ineligible basis_ineligible
BASIS_CONTEXT=start BASIS_PLAN=unbound run_case invocation-start-sealed-basis2-unbound-plan-ineligible basis_unbound_plan
BASIS_CONTEXT=start run_case invocation-start-sealed-basis2-multiple-resource-order basis_multiple_resource_order
BASIS_CONTEXT=start TAMPER=original-configuration run_case invocation-start-sealed-basis2-corrupt-original-copy basis_tampered_closure
BASIS_CONTEXT=start RETAINED_ALIAS=id run_case invocation-start-sealed-basis2-raw-retained-id basis_retained_trim_alias
BASIS_CONTEXT=start RETAINED_ALIAS=source run_case invocation-start-sealed-basis2-raw-source-hash basis_retained_trim_alias
BASIS_CONTEXT=start CONTRADICTION='if .kind == "invocation-start" then .body.recovery.recreate_missing=[] else . end' \
  run_case invocation-start-sealed-basis2-hash-valid-permission-contradiction basis_hash_valid_contradiction
run_case original-content-v1-absent-resource-existing-config original_content_matrix
ORIGINAL_BEFORE='file' run_case original-content-v1-missing-retained-resource-refused original_content_matrix
BASIS_CONTEXT=start ORIGINAL_BEFORE='file' run_case original-content-v2-explicit-resource-config-recreation original_content_matrix
run_case original-content-equal-prior-desired-prefers-desired original_content_equal_hashes
BASIS_SIGNING=local-efi run_case original-content-v1-source-is-not-signed-desired original_content_distinct_hashes
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case original-content-v2-source-is-not-signed-desired original_content_distinct_hashes
run_case original-content-unsafe-malformed-observations original_content_invalid_observation
run_case original-content-projected-policy-and-invalid-identifiers original_content_no_projection_authority
run_case original-content-expired-target-source-stage original_content_expired_objects
run_case original-content-actual-same-bytes-new-inode original_content_actual_new_inode
for ORIGINAL_RAW in config-before-newline retained-newline retained-id retained-source retained-cr target unknown-kind; do
  run_case "original-content-exact-raw-$ORIGINAL_RAW" original_content_raw_join
done
BASIS_CONTEXT=start ORIGINAL_RAW=permission run_case original-content-v2-exact-original-permission original_content_raw_join
run_case original-content-raw-byte-count-precision original_content_raw_precision
BASIS_PLAN=partial run_case original-content-incomplete-basis original_content_ineligible_or_corrupt
run_case original-content-corrupt-retained-closure original_content_ineligible_or_corrupt
run_case selected-basis-v1-current-read-only selection_valid
BASIS_CONTEXT=start run_case selected-basis-v2-current-read-only selection_valid
run_case selected-basis-sibling-current-root selection_sibling
for SELECTION_STATE in absent stable transition; do
  run_case "selected-basis-state-$SELECTION_STATE" selection_state
done
BASIS_PLAN=partial run_case selected-basis-incomplete-plan selection_incomplete
BASIS_CONTEXT=absent run_case selected-basis-missing-context selection_incomplete
run_case selected-basis-invalid-lifecycle-and-evidence selection_invalid
for SELECTION_FAULT in generation closure marker boot-path repair-path; do
  run_case "selected-basis-drift-$SELECTION_FAULT" selection_drift
done
for SELECTION_FAULT in boot-closed repair-closed boot-flag repair-flag boot-path repair-path contention marker; do
  run_case "selected-basis-lock-$SELECTION_FAULT" selection_lock
done
run_case recovery-basis-v1-constructor-and-repeat recovery_basis_constructor
BASIS_CONTEXT=start run_case recovery-basis-v2-constructor-and-repeat recovery_basis_constructor
run_case recovery-basis-constructor-precondition-refusals recovery_basis_refusals
BASIS_PLAN=partial run_case recovery-basis-partial-plan-refused recovery_basis_incomplete
BASIS_CONTEXT=absent run_case recovery-basis-context-free-refused recovery_basis_incomplete
run_case recovery-basis-schema-and-completion-fences recovery_basis_schema_fences
run_case recovery-basis-original-root-refused recovery_basis_root_refused
run_case recovery-basis-hash-valid-reference-and-prior-contradictions recovery_basis_contradictions
for RECOVERY_TAMPER in record retained; do
  run_case "recovery-basis-original-$RECOVERY_TAMPER-rechecked" recovery_basis_original_closure
done
run_case recovery-basis-stale-attempt-and-new-boot-retry recovery_basis_stale
for RECOVERY_WINDOW in after-publication-recovery-basis after-attempt-manifest-write after-attempt-transition-write; do
  run_case "recovery-basis-begin-$RECOVERY_WINDOW" recovery_basis_begin_window
done
RECOVERY_DRIFT='.generation+=1' run_case recovery-basis-generation-drift-before-transition recovery_basis_selection_drift
RECOVERY_DRIFT='.updated_at="2000-01-01T00:00:00Z"' run_case recovery-basis-whole-lifecycle-drift-before-transition recovery_basis_selection_drift
run_case recovery-basis-retry-cannot-switch-original-invocation recovery_basis_no_invocation_switch
for RECOVERY_LATE in marker pacman boot repair selection refreshed-selection; do
  run_case "recovery-basis-late-$RECOVERY_LATE" recovery_basis_late_boundary
done
for RECOVERY_SYNC in prior-file basis-file basis-directory manifest-directory lifecycle-directory basis-substitution; do
  run_case "recovery-basis-sync-$RECOVERY_SYNC" recovery_basis_sync_window
done
run_case recovery-basis-capacity32-preserved-refuse33 recovery_basis_capacity
run_case recovery-copy-v1-bytes-configuration-and-fresh-retry recovery_copy_valid
BASIS_CONTEXT=start BASIS_SIGNING=local-efi COPY_EXPIRED=true run_case recovery-copy-v2-signed-hash-and-expired-objects recovery_copy_valid
run_case recovery-copy-historical-root-operation-name recovery_copy_historical_root_name
run_case recovery-copy-cache-reuses-semantics recovery_copy_cache_reuse
for COPY_CACHE_FAULT in original-record original-retained copied copied-mode record prior; do
  run_case "recovery-copy-cache-$COPY_CACHE_FAULT-rechecked" recovery_copy_cache_tamper
done
run_case recovery-copy-cache-lineage-and-pending-key recovery_copy_cache_key_and_pending
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-copy-a2-provenance-and-order recovery_copy_a2_provenance
run_case recovery-copy-a2-raw-json recovery_copy_a2_raw
run_case recovery-copy-a2-copy-faults-and-conflicts recovery_copy_a2_copy_faults
COPY_WINDOWS='temporary-sync temporary-directory ready-record-temp ready-record-directory ready-record-file ready-manifest-temp ready-manifest-directory ready-manifest-file' \
  run_case recovery-copy-a2-sync-ready-retries recovery_copy_a2_sync_windows
COPY_WINDOWS='rename-before rename-after destination-sync renamed-directory copied-record-temp copied-record-directory copied-record-file copied-manifest-temp copied-manifest-directory copied-manifest-file' \
  run_case recovery-copy-a2-sync-copied-retries recovery_copy_a2_sync_windows
run_case recovery-copy-a2-unsafe-ready-controls recovery_copy_a2_unsafe_ready
run_case recovery-copy-a2-missing-ready-fresh-attempt recovery_copy_a2_missing_ready
run_case recovery-copy-a2-owner-lock-marker-loss recovery_copy_a2_owner_loss
run_case recovery-copy-a2-cache-unused-peer-closure recovery_copy_a2_peer_cache
run_case recovery-target-v1-context-classification-and-fresh-retry recovery_target_valid
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-target-v2-signed-context-classification-and-fresh-retry recovery_target_valid
run_case recovery-target-v1-desired-and-conflicts recovery_target_desired_and_conflicts
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-target-v2-desired-and-conflicts recovery_target_desired_and_conflicts
run_case recovery-target-v1-refusals recovery_target_refusals
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-target-v2-refusals recovery_target_refusals
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-target-v2-hash-valid-mutations recovery_target_mutations
run_case recovery-target-v1-hash-valid-mutations recovery_target_mutations
run_case recovery-target-copy-order recovery_target_order
run_case recovery-target-v1-replay-drift recovery_target_replay_drift
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-target-v2-replay-drift recovery_target_replay_drift
run_case recovery-target-root-journal-refused recovery_target_root_journal_refused
run_case recovery-target-cache-rechecked recovery_target_cache
# Three durability shapes per kind: an unbound candidate record, a bound but
# unsynced head, and an unsynced directory. Each needs a fresh attempt, and the
# temp-file windows exercise the same append code the copy windows already cover.
TARGET_WINDOWS='record-file manifest-file manifest-directory' \
  run_case recovery-target-sync-windows recovery_target_sync_windows
run_case recovery-target-owner-lock-marker-loss recovery_target_owner_loss
run_case recovery-ready-v1-stages-plan-and-fresh-retry recovery_ready_valid
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-ready-v2-signed-stages-plan-and-fresh-retry recovery_ready_valid
run_case recovery-ready-refusals recovery_ready_refusals
run_case recovery-ready-stage-custody recovery_ready_custody
run_case recovery-ready-ancestors-and-memory recovery_ready_ancestors_and_memory
run_case recovery-ready-peer-invocation-refused recovery_ready_peer_root
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-ready-hash-valid-mutations recovery_ready_mutations
run_case recovery-ready-cache-and-sync-windows recovery_ready_cache_and_sync
run_case recovery-apply-v1-effects-result-and-fresh-retry recovery_apply_valid
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-apply-v2-signed-effects-result-and-fresh-retry recovery_apply_valid
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-apply-refusals recovery_apply_refusals
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-apply-hash-valid-mutations recovery_apply_mutations
BASIS_CONTEXT=start BASIS_SIGNING=local-efi run_case recovery-apply-stage-custody recovery_apply_custody
run_case recovery-apply-cache-and-sync-windows recovery_apply_cache_and_sync
run_case recovery-apply-root-journal-refused recovery_apply_root_journal_refused
[[ -z ${PUBLICATION_RECORDS_LIST:-} ]] || exit 0
(( count > 0 )) || fail_test 'publication-journal selection matched no cases'
printf 'Passed %s publication-journal contracts.\n' "$count"
