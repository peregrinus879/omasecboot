#!/bin/bash
# Core authority for a finite native addition attempt. Public admission remains
# the fixed caller's responsibility. Directory creation derives from its targets.
# shellcheck disable=SC2154 # Session/lifecycle modules own transaction state.

declare -Ag _publication_stage_bodies=()
declare -Ag _publication_target_fds=()
declare -Ag _publication_stage_fds=()
declare -Ag _publication_directory_fds=()
declare -Ag _publication_directory_states=()
declare -Ag _publication_directory_mount_ids=()
declare -Ag _publication_stage_candidates=()
declare -Ag _publication_directory_pending=()
declare -Ag _publication_directory_candidates=()
declare -Ag _publication_directory_completed=()
_publication_mount_namespace=''
_publication_mount_invalid=false
_publication_plan=''
_publication_apply_phase=false
_publication_intent_matched=false
_publication_stable_context=''
_publication_signing_policy=''
_publication_original_configuration=''
# Bind the separately interpreted inspector to this Core source composition.
readonly PUBLICATION_CONTEXT_HELPER_SHA256=fc1489eac40f934b80e65fabe9c40243c50feaa4d205c0d483e282a76a531f23

publication_reset_attempt() {
  _publication_stage_bodies=()
  _publication_target_fds=()
  _publication_stage_fds=()
  _publication_directory_fds=()
  _publication_directory_states=()
  _publication_directory_mount_ids=()
  _publication_stage_candidates=()
  _publication_directory_pending=()
  _publication_directory_candidates=()
  _publication_directory_completed=()
  _publication_mount_namespace=''
  _publication_mount_invalid=false
  _publication_plan=''
  _publication_apply_phase=false
  _publication_intent_matched=false
  _publication_stable_context=''
  _publication_signing_policy=''
  _publication_original_configuration=''
}

# Selection runs before a new transaction owns a transition. Reassert the actual
# locks without acquiring replacement paths or relying on bookkeeping alone.
# Keep invalidation in the caller's shell so later recovery cannot trust lost FDs.
publication_recovery_selection_is_locked() {
  producer_session_validate_lock_bindings || return 1
  boot_locks_are_held && producer_runtime_is_clear || return 1
  flock -n 200 || { _OMASECBOOT_LIMINE_LOCK_OWNED=false; return 1; }
  flock -n 201 || { _OMASECBOOT_REPAIR_LOCK_OWNED=false; return 1; }
  producer_session_validate_lock_bindings
}

# publication_load_selected_original_basis EXPECTED_ROOT_REFERENCE INVOCATION
# Status 0 publishes _publication_selected_original_basis: transient selection
# plus the existing ref-only original basis. Status 1 is a selected but incomplete
# invocation; 2 is invalid/unselected evidence, unavailable locks or unsafe state.
# All failures clear output. Reader/recovery/cache globals remain caller-owned.
# This samples the full current lifecycle before and after resolution under both
# locks. It does not create an attempt, classify live targets or permit any write.
# Consumers must revalidate selection when constructing a new attempt; this value
# is neither a durable record nor permission that survives release of the locks.
publication_load_selected_original_basis() {
  local result rc=0 LC_ALL=C
  _publication_selected_original_basis=''
  [[ $# == 2 && ${_transaction_active:-false} == false ]] || return 2
  publication_recovery_selection_is_locked || return 2
  # Isolate the existing lifecycle/incident readers and semantic cache, but keep
  # lock validation/invalidation on both sides in this shell.
  result=$(
    local expected=$1 invocation=$2 lifecycle basis status=0 LC_ALL=C
    (( ${#expected} <= MAX_CONTROL_DOCUMENT_BYTES )) || exit 2
    expected=$(jq -cse 'if length == 1 then .[0] else error("expected one root reference") end' <<<"$expected") || exit 2
    load_recovery_context || exit 2
    lifecycle=$_lifecycle_json
    json_is '.[0] == .[1]' "[$expected,$_recovery_root_reference]" || exit 2
    publication_load_complete_original_basis "$_recovery_root_reference" "$invocation" || status=$?
    (( status == 0 || status == 1 )) || exit 2
    basis=$_publication_original_basis
    # Reading again validates the full chain and its external record closure,
    # not just generation or a cached in-memory recovery root.
    read_lifecycle || exit 2
    json_is '.[0] == .[1]' "[$lifecycle,$_lifecycle_json]" || exit 2
    (( status == 0 )) || exit 1
    jq -ce '.[0] as $lifecycle | .[1] as $basis |
      {schema:1,scope:"selected-original-basis",
       lifecycle:($lifecycle | {generation,transaction}),basis:$basis}' \
      <<<"[$lifecycle,$basis]" || exit 2
  ) || rc=$?
  publication_recovery_selection_is_locked || return 2
  (( rc != 1 )) || return 1
  (( rc == 0 && ${#result} + 1 <= MAX_CONTROL_DOCUMENT_BYTES )) || return 2
  _publication_selected_original_basis=$result
}

# Internal preparation constructor only. The manifest's first record binds the
# selected original basis before transition publication. It permits neither boot
# effects nor completed state; public recovery continues to refuse journals.
# Like the other begin_* primitives, its caller owns traps/failure finalization.
begin_publication_recovery_attempt() {
  local root invocation selected basis lifecycle transaction_id token boot_id owner timestamp self
  local directory backups document record reference path
  local _publication_member_record=''
  [[ $# == 2 && ${_transaction_active:-false} == false ]] || return 1
  root=$1 invocation=$2
  publication_load_selected_original_basis "$root" "$invocation" || return 1
  selected=$_publication_selected_original_basis
  basis=$(jq -c '.basis' <<<"$selected") || return 1
  load_recovery_context || return 1
  lifecycle=$_lifecycle_json
  json_is '.[0].lifecycle == (.[1] | {generation,transaction})' "[$selected,$lifecycle]" || return 1
  recovery_operation_for_lineage "$_recovery_root_manifest_json" publication-recovery >/dev/null || return 1
  if (( _recovery_attempt_count > 0 )); then
    publication_read_manifest_member "$(jq -r '.id' <<<"$_recovery_previous_manifest_json")" \
      "$_recovery_previous_manifest_json" "$(jq -c '.publication_records[0]' <<<"$_recovery_previous_manifest_json")" || return 1
    json_is '.[0].body.basis == .[1]' "[$_publication_member_record,$basis]" || return 1
  fi
  lifecycle_package_boundary_is_clear || return 1
  transaction_id=$(new_transaction_id) || return 1
  token=$(new_transaction_token) || return 1
  boot_id=$(boot_id_value) || return 1
  self=$BASHPID
  owner=$(manifest_owner_json "$self") || return 1
  timestamp=$(utc_timestamp) || return 1
  directory=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  [[ ! -e $directory && ! -L $directory ]] || return 1
  directory=$(create_transaction_dir "$transaction_id") || return 1
  backups=$(prior_lifecycle_backups "$directory") || return 1
  record=$(jq -cse --arg id "$transaction_id" --arg invocation "$invocation" \
    --argjson schema "$PUBLICATION_RECOVERY_BASIS_SCHEMA_VERSION" --arg timestamp "$timestamp" \
    --arg version "$OMASECBOOT_VERSION" 'if length == 1 then
      {schema_version:$schema,transaction_id:$id,invocation:$invocation,ordinal:1,previous:null,
       kind:"recovery-basis",body:{basis:.[0]},recorded_at:$timestamp,writer_version:$version}
      else error("expected one original basis") end' <<<"$basis") || return 1
  validate_publication_record_json "$transaction_id" 1 null "$record" || return 1
  (( $(LC_ALL=C printf '%s\n' "$record" | wc -c) <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  path="$directory/publication-1.json"
  printf '%s\n' "$record" | atomic_create_control_file "$path" 600 || return 1
  durable_sync "$path" && durable_sync "$directory" || return 1
  reference=$(transaction_artifact_reference "$path" "$PUBLICATION_RECOVERY_BASIS_SCHEMA_VERSION") || return 1
  document=$(publication_capture_hashed_document "$path" "$(jq -r '.sha256' <<<"$reference")") || return 1
  json_is '.[0] == .[1]' "[$record,$document]" || return 1
  lifecycle_failpoint after-publication-recovery-basis || return 1
  document=$(new_transaction_manifest "$(jq -cn \
    --arg id "$transaction_id" --arg timestamp "$timestamp" --arg boot "$boot_id" \
    --arg token_hash "$(sha256_text "$token")" --argjson owner "$owner" --argjson backups "$backups" \
    --argjson root "$_recovery_root_reference" --argjson previous "$_recovery_previous_reference" \
    --argjson attempt "$((_recovery_attempt_count+1))" --argjson reference "$reference" '{
      id:$id,kind:"recovery-attempt",operation:"publication-recovery",target_state:"active",
      created_at:$timestamp,boot_id:$boot,token_sha256:$token_hash,owner:$owner,
      prior_state:"recovery-required",file_rollback_policy:"preserve",backups:$backups,
      recovery:{attempt_number:$attempt,previous_attempt:$previous,root_incident:$root},
      publication_records:[$reference]}')") || return 1
  publish_new_transaction_manifest "$transaction_id" "$document" after-attempt-manifest-write || return 1
  publication_recovery_selection_is_locked && lifecycle_package_boundary_is_clear || return 1
  read_lifecycle || return 1
  json_is '.[0] == .[1]' "[$lifecycle,$_lifecycle_json]" || return 1
  activate_transaction_context "$transaction_id" "$token" publication-recovery active
  write_recovery_attempt_transition_lifecycle "$transaction_id" \
    "$(lifecycle_manifest_path "$transaction_id")" "$timestamp" || return 1
  lifecycle_failpoint after-attempt-transition-write
}

# Original authority parts of the owned preparatory attempt: the basis bound by
# its first record, the sealed original intent and context with their real
# references, and the plan effect ids. Data only; ownership and locks are
# reasserted here and by every writer, never inferred from these values.
publication_recovery_attempt_parts() {
  local basis root invocation
  local _publication_member_record=''
  _publication_recovery_attempt_basis='' _publication_recovery_attempt_parts=''
  producer_session_context_is_owned || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  json_is '.kind == "recovery-attempt" and .operation == "publication-recovery" and .status == "transition"' "$_manifest_json" || return 1
  publication_read_manifest_member "$_transaction_id" "$_manifest_json" \
    "$(jq -c '.publication_records[0]' <<<"$_manifest_json")" || return 1
  json_is '.kind == "recovery-basis" and .schema_version == 2' "$_publication_member_record" || return 1
  basis=$(jq -c '.body.basis' <<<"$_publication_member_record") || return 1
  root=$(jq -c '.root' <<<"$basis") || return 1
  invocation=$(jq -r '.invocation' <<<"$basis") || return 1
  publication_resolve_original_parts "$root" "$invocation" || return 1
  json_is '.[0] == .[1].basis' "[$basis,$_publication_original_parts]" || return 1
  _publication_recovery_attempt_basis=$basis
  _publication_recovery_attempt_parts=$_publication_original_parts
}

# Fresh acquisition for the owned attempt: a clean per-attempt view (existing
# pins must be this owner's and this transaction's), pinned ancestors of the
# configuration, the real collector, and equality with the sealed original.
publication_recovery_acquire_context() {
  local invocation=$1 intent=$2 config=$3 original=$4
  if (( ${#_publication_pins[@]} > 0 )); then
    [[ $_publication_pin_owner == "$BASHPID" && $_publication_pin_transaction == "$_transaction_id" ]] || return 1
  fi
  publication_reset_attempt
  _publication_invocation=$invocation
  _publication_intent=$intent
  _publication_retained=()
  _publication_mount_namespace=$(publication_namespace_value) || return 1
  publication_parent_binding "$(dirname "$config")" || return 1
  publication_collect_stable_context || return 1
  publication_compare_stable_context "$original" "$_publication_collected_context"
}

# prepare_publication_recovery_context
# Acquire the fresh stable context and attempt-local signing policy for the
# owned preparatory attempt through the real collector, require equality with
# the sealed original context, and bind both as the attempt's typed context
# authority (recovery-context). A replay reacquires and compares. No target is
# observed, nothing outside the private transaction directory is written, and
# the result permits neither a stage nor a canonical write.
prepare_publication_recovery_context() {
  local parts intent invocation config body original reference lookup_rc
  _publication_recovery_context_record='' _publication_recovery_context_reference=''
  [[ $# == 0 ]] || return 1
  publication_recovery_attempt_parts || return 1
  parts=$_publication_recovery_attempt_parts
  invocation=$(jq -r '.basis.invocation' <<<"$parts") || return 1
  intent=$(jq -c '.intent' <<<"$parts") || return 1
  original=$(jq -c '.context' <<<"$parts") || return 1
  config=$(jq -r '.configuration.path' <<<"$intent") || return 1
  if find_publication_record "$invocation" recovery-context; then
    body=$_publication_found_body reference=$_publication_found_reference
    if [[ $_publication_invocation == "$invocation" && -n $_publication_stable_context && -n $_publication_signing_policy ]]; then
      # Replay with live memory: the record, memory and a fresh acquisition of
      # both context and signing policy must agree, or memory authority ends.
      if ! json_is '.[0].context == .[1] and .[0].signing_policy == .[2] and .[3] == .[4]' \
          "[$body,$_publication_stable_context,$_publication_signing_policy,$_publication_intent,$intent]" ||
        ! publication_verify_stable_context ||
        ! json_is '.[0] == .[1]' "[$_publication_collected_signing_policy,$_publication_signing_policy]"; then
        _publication_stable_context='' _publication_signing_policy=''
        return 1
      fi
    else
      # A bound record without live memory (a durability retry after binding,
      # or another process view of this attempt) acquires afresh and must equal it.
      publication_recovery_acquire_context "$invocation" "$intent" "$config" "$original" || return 1
      json_is '.[0].context == .[1] and .[0].signing_policy == .[2]' \
        "[$body,$_publication_collected_context,$_publication_collected_signing_policy]" || return 1
      _publication_stable_context=$_publication_collected_context
      _publication_signing_policy=$_publication_collected_signing_policy
    fi
    sync_publication_reference "$reference" || return 1
    _publication_recovery_context_record=$body
    _publication_recovery_context_reference=$reference
    return 0
  else
    lookup_rc=$?
    (( lookup_rc == 1 )) || return 1
  fi
  publication_recovery_acquire_context "$invocation" "$intent" "$config" "$original" || return 1
  body=$(jq -cn --argjson context "$_publication_collected_context" --argjson policy "$_publication_collected_signing_policy" \
    --argjson original "$(jq -c '.authority.context' <<<"$parts")" \
    '{context:$context,original_context:$original,signing_policy:$policy}') || return 1
  append_publication_record "$invocation" recovery-context "$body" || return 1
  _publication_stable_context=$_publication_collected_context
  _publication_signing_policy=$_publication_collected_signing_policy
  _publication_recovery_context_record=$body
  _publication_recovery_context_reference=$_publication_record_reference
}

# authorize_publication_recovery_target EFFECT_ID
# One fresh conflict-classified observation of an original effect target under
# this attempt's live custody, joined to the bound retained copy and, for a
# locally signed EFI copy, a fresh signature verification under the attempt's
# policy. Only prior, desired or explicitly permitted absence is recorded;
# conflicts, missing or unsafe ancestors, lost custody and changed observations
# are refused without a record. Observed identities are live custody evidence
# for this attempt only. Data only: no stage, no canonical write.
authorize_publication_recovery_target() {
  local id basis parts invocation root context target parent state observation classification effect copy signature=null body existing lookup_rc
  local _publication_original_effect=''
  _publication_recovery_authorization_record='' _publication_recovery_authorization_reference=''
  [[ $# == 1 && $1 =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
  id=$1
  publication_recovery_attempt_parts || return 1
  basis=$_publication_recovery_attempt_basis parts=$_publication_recovery_attempt_parts
  invocation=$(jq -r '.basis.invocation' <<<"$parts") || return 1
  root=$(jq -c '.basis.root' <<<"$parts") || return 1
  [[ $_publication_invocation == "$invocation" && -n $_publication_stable_context && -n $_publication_signing_policy ]] || return 1
  find_publication_record "$invocation" recovery-context || return 1
  context=$_publication_found_body
  json_is '.[0].context == .[1] and .[0].signing_policy == .[2] and .[0].original_context == .[3].authority.context' \
    "[$context,$_publication_stable_context,$_publication_signing_policy,$parts]" || return 1
  find_publication_record "$invocation" retained-copy "$id" || return 1
  copy=$(jq -cn --argjson reference "$_publication_found_reference" --argjson file "$(jq -c '.file' <<<"$_publication_found_body")" \
    '{reference:$reference,file:$file}') || return 1
  validate_publication_retained_file "$_transaction_id" "$(jq -c '.file' <<<"$copy")" || return 1
  publication_resolve_original_effect "$root" "$invocation" "$id" || return 1
  effect=$_publication_original_effect
  json_is '.[0].basis == .[1] and .[0].desired.sha256 == .[2].file.sha256 and .[0].desired.bytes == .[2].file.bytes' \
    "[$effect,$basis,$copy]" || return 1
  target=$(jq -r '.target' <<<"$effect") || return 1
  parent=$(dirname "$target") || return 1
  publication_verify_live || return 1
  # Existing control-safe ancestors only. A missing ancestor is refused here;
  # target-derived creation belongs to the later readiness step.
  publication_parent_binding "$parent" || return 1
  state='{"kind":"absent","identity":null,"sha256":null,"link_target":null,"mode":0,"uid":0,"gid":0}'
  if [[ -e $target || -L $target ]]; then
    publication_verify_path_mount "$target" file "${_publication_directory_mount_ids[$parent]}" || return 1
    if [[ -n ${_publication_target_fds[$id]:-} ]] && fd_matches_path "${_publication_target_fds[$id]}" "$target"; then
      state=$(publication_fd_state "${_publication_target_fds[$id]}") || return 1
    else
      publication_pin_path "$target" file || return 1
      _publication_target_fds[$id]=$_publication_new_fd
      state=$(publication_fd_state "$_publication_new_fd") || return 1
    fi
    publication_verify_path_mount "$target" file "${_publication_directory_mount_ids[$parent]}" \
      "$(jq -r '.identity' <<<"$state")" || return 1
  fi
  observation=$(jq -cn --arg path "$target" --argjson state "$state" '{path:$path,state:$state}') || return 1
  classification=$(publication_original_data_decode classify <<<"[$effect,$observation]") || return 1
  json_is '.outcome == "prior" or .outcome == "desired" or .outcome == "allowed-absence"' "$classification" || return 1
  classification=$(jq -r '.outcome' <<<"$classification") || return 1
  if json_is '.signing == "local-efi"' "$effect"; then
    verify_publication_input "$(jq -r '.file.path' <<<"$copy")" || return 1
    signature=$(jq -cn --arg der "$(jq -r '.context.local_db_certificate_der_sha256' <<<"$context")" \
      '{verified:true,certificate_der_sha256:$der}') || return 1
  fi
  publication_verify_live || return 1
  body=$(jq -cn --arg id "$id" --arg target "$target" --argjson effect "$(jq -c 'del(.basis)' <<<"$effect")" \
    --argjson copy "$copy" --argjson observation "$observation" --argjson view "$_publication_parent_view" \
    --argjson parent "$_publication_parent" --arg classification "$classification" --argjson signature "$signature" \
    '{id:$id,target:$target,original_effect:$effect,copy:$copy,observation:$observation,mount_view:$view,
      parent:$parent,classification:$classification,signature:$signature}') || return 1
  if find_publication_record "$invocation" target-authorization "$id"; then
    existing=$_publication_found_body
    json_is '.[0] == .[1]' "[$body,$existing]" || return 1
    sync_publication_reference "$_publication_found_reference" || return 1
    _publication_recovery_authorization_record=$existing
    _publication_recovery_authorization_reference=$_publication_found_reference
    return 0
  else
    lookup_rc=$?
    (( lookup_rc == 1 )) || return 1
  fi
  producer_session_context_is_owned || return 1
  append_publication_record "$invocation" target-authorization "$body" || return 1
  _publication_recovery_authorization_record=$body
  _publication_recovery_authorization_reference=$_publication_record_reference
}

publication_retain_original_configuration() {
  local invocation=$1 intent=$2 source expected directory destination temporary hash bytes reference
  _publication_original_configuration=''
  producer_session_context_is_owned && publication_verify_live || return 1
  [[ $invocation =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ ]] || return 1
  source=$(jq -er '.configuration.path' <<<"$intent") || return 1
  expected=$(jq -er '.configuration.sha256' <<<"$intent") || return 1
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || return 1
  validate_control_file "$source" || return 1
  [[ $(sha256_file "$source") == "$expected" ]] || return 1
  directory=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  destination="$directory/publication-data-$invocation-original-configuration"
  if [[ ! -e $destination && ! -L $destination ]]; then
    temporary=$(mktemp "$directory/.publication-original.XXXXXX") || return 1
    if ! copy_publication_input "$source" "$temporary" || [[ $(sha256_file "$temporary") != "$expected" ]]; then
      rm -f -- "$temporary"; return 1
    fi
    if ! chmod 400 "$temporary" || ! durable_sync "$temporary"; then rm -f -- "$temporary"; return 1; fi
    if ! mv -T --update=none-fail --no-copy "$temporary" "$destination"; then rm -f -- "$temporary"; return 1; fi
  fi
  validate_private_control_file "$destination" || return 1
  hash=$(sha256_file "$destination") || return 1
  bytes=$(stat -Lc %s "$destination") || return 1
  [[ $hash == "$expected" ]] || return 1
  reference=$(jq -cn --arg path "$destination" --arg hash "$hash" --argjson bytes "$bytes" \
    '{path:$path,sha256:$hash,bytes:$bytes}') || return 1
  validate_publication_retained_file "$_transaction_id" "$reference" || return 1
  durable_sync "$destination" && durable_sync "$directory" || return 1
  publication_verify_live && [[ $(sha256_file "$source") == "$expected" ]] || return 1
  # This private file has no authority until the complete start record and
  # preserve policy are anchored together. No boot path has been changed.
  _publication_original_configuration=$reference
}

publication_context_helper_path() { printf '/usr/lib/omasecboot/publication-context.py\n'; }
publication_context_python_path() { readlink -f /usr/bin/python; }

# The fixed caller supplies the selected paths and held directory FDs. The
# inspector reads public certificate data only; enrollment owns key-pair proof.
publication_collect_stable_context() {
  local helper python helper_fd python_fd certificate_fd certificate helper_hash python_hash certificate_hash result
  local esp config sbctl_config_state sbctl_config_hash sbctl_executable_hash owner=$BASHPID rc=0
  esp=$(jq -r '.esp_path' <<<"$_publication_intent") || return 1
  config=$(jq -r '.configuration.path' <<<"$_publication_intent") || return 1
  check_publication_context_deps || return 1
  producer_session_context_is_owned && publication_verify_live || return 1
  [[ -n ${_publication_directory_fds[/]:-} && -n ${_publication_directory_fds[$esp]:-} ]] || return 1
  validate_sbctl_enrollment_boundary || return 1
  sbctl_config_state=$_sbctl_config_state
  sbctl_config_hash=$_sbctl_config_hash
  sbctl_executable_hash=$_sbctl_executable_hash
  certificate="$_sbctl_keydir/db/db.pem"
  validate_private_control_file "$certificate" || return 1
  helper=$(publication_context_helper_path) || return 1
  python=$(publication_context_python_path) || return 1
  validate_control_file "$helper" && validate_control_file "$python" && [[ -x $python ]] || return 1
  [[ $(producer_file_owner_package "$helper") == omasecboot && $(producer_file_owner_package "$python") == python ]] || return 1
  exec {helper_fd}<"$helper" || return 1
  if ! exec {python_fd}<"$python"; then exec {helper_fd}<&-; return 1; fi
  if ! exec {certificate_fd}<"$certificate"; then exec {helper_fd}<&- {python_fd}<&-; return 1; fi
  helper_hash=$(sha256_file "/proc/$owner/fd/$helper_fd") || rc=1
  python_hash=$(sha256_file "/proc/$owner/fd/$python_fd") || rc=1
  certificate_hash=$(sha256_file "/proc/$owner/fd/$certificate_fd") || rc=1
  [[ $helper_hash == "$PUBLICATION_CONTEXT_HELPER_SHA256" ]] || rc=1
  if (( rc == 0 )); then
    result=$( (
      set -o pipefail
      exec 3>&1
      diagnostics=$(/usr/bin/timeout --kill-after=2 65 /usr/bin/env -i LC_ALL=C PATH=/usr/bin HOME=/nonexistent \
        "/proc/$owner/fd/$python_fd" -I -S "/proc/$owner/fd/$helper_fd" \
        --root-fd "${_publication_directory_fds[/]}" \
        --esp-fd "${_publication_directory_fds[$esp]}" --root-path / --esp-path "$esp" \
        --config-path "$config" --certificate-fd "$certificate_fd" \
        2>&1 1>&3 | /usr/bin/base64 --wrap=0) || exit 1
      [[ -z $diagnostics ]]
    ) | jq -Rcse '
      if length <= 32768 and (test("[\u0000-\u0008\u000b\u000c\u000e-\u001f]") | not) then fromjson
      else error("invalid context framing") end |
      if keys == ["complete","context","format","schema"] and .format == "omasecboot-publication-context" and
        .schema == 1 and .complete == true then .context else error("incomplete context") end') || rc=1
  fi
  if (( rc == 0 )); then
    fd_matches_path "$helper_fd" "$helper" && fd_matches_path "$python_fd" "$python" && \
      fd_matches_path "$certificate_fd" "$certificate" && [[ $(sha256_file "$helper") == "$helper_hash" && \
      $(sha256_file "$python") == "$python_hash" && $(sha256_file "$certificate") == "$certificate_hash" ]] || rc=1
  fi
  if (( rc == 0 )); then
    validate_sbctl_enrollment_boundary && [[ $_sbctl_config_state == "$sbctl_config_state" && \
      $_sbctl_config_hash == "$sbctl_config_hash" && $_sbctl_executable_hash == "$sbctl_executable_hash" && \
      "$_sbctl_keydir/db/db.pem" == "$certificate" ]] || rc=1
  fi
  exec {helper_fd}<&- {python_fd}<&- {certificate_fd}<&-
  (( rc == 0 )) && publication_verify_live && publication_context_matches_intent "$result" "$_publication_intent" || return 1
  _publication_collected_context=$result
  _publication_collected_signing_policy=$(jq -cn --arg certificate "$certificate" --arg pem_hash "$certificate_hash" \
    --arg config "$(sbctl_config_path)" --arg config_state "$sbctl_config_state" --arg config_hash "$sbctl_config_hash" \
    --arg executable "$_sbctl_executable" --arg executable_hash "$sbctl_executable_hash" \
    '{certificate:$certificate,certificate_sha256:$pem_hash,configuration:$config,configuration_state:$config_state,
      configuration_sha256:$config_hash,executable:$executable,executable_sha256:$executable_hash}') || return 1
}

# Command-local identity includes ctime, unlike cross-lifetime context. It can
# detect a changed-and-restored control file during a key-using tool invocation.
publication_signer_stamp() {
  LC_ALL=C TZ=UTC stat -Lc '%d:%i:%f:%u:%g:%s:%y:%z' -- "$1"
}

publication_observe_signer() {
  local certificate config config_span policy certificate_stamp config_stamp executable_stamp
  producer_session_context_is_owned || return 1
  [[ -n $_publication_signing_policy && -n $_publication_stable_context ]] || return 1
  find_publication_authority_part "$_publication_invocation" context || return 1
  publication_compare_stable_context "$_publication_stable_context" "$_publication_found_body" || return 1
  validate_sbctl_enrollment_boundary || return 1
  certificate="$_sbctl_keydir/db/db.pem"
  config=$(sbctl_config_path) || return 1
  validate_private_control_file "$certificate" || return 1
  certificate_stamp=$(publication_signer_stamp "$certificate") || return 1
  executable_stamp=$(publication_signer_stamp "$_sbctl_executable") || return 1
  config_span=$config
  if [[ $_sbctl_config_state == absent ]]; then
    config_span=$(dirname "$config_span") || return 1
    while [[ ! -e $config_span && ! -L $config_span ]]; do config_span=$(dirname "$config_span") || return 1; done
    validate_control_directory "$config_span" || return 1
  fi
  config_stamp=$(publication_signer_stamp "$config_span") || return 1
  policy=$(jq -cn --arg certificate "$certificate" --arg pem_hash "$(sha256_file "$certificate")" \
    --arg config "$config" --arg config_state "$_sbctl_config_state" --arg config_hash "$_sbctl_config_hash" \
    --arg executable "$_sbctl_executable" --arg executable_hash "$_sbctl_executable_hash" \
    '{certificate:$certificate,certificate_sha256:$pem_hash,configuration:$config,configuration_state:$config_state,
      configuration_sha256:$config_hash,executable:$executable,executable_sha256:$executable_hash}') || return 1
  json_is '.[0] == .[1]' "[$policy,$_publication_signing_policy]" || return 1
  [[ $(publication_signer_stamp "$certificate") == "$certificate_stamp" && \
    $(publication_signer_stamp "$_sbctl_executable") == "$executable_stamp" && \
    $(publication_signer_stamp "$config_span") == "$config_stamp" ]] || return 1
  jq -cn --argjson policy "$policy" --arg certificate "$certificate_stamp" --arg config "$config_stamp" \
    --arg span "$config_span" --arg executable "$executable_stamp" \
    '{policy:$policy,certificate_stamp:$certificate,configuration_stamp:$config,configuration_span:$span,executable_stamp:$executable}'
}

publication_compare_stable_context() {
  validate_publication_context_json "$1" && validate_publication_context_json "$2" || return 2
  json_is '.[0] == .[1]' "[$1,$2]"
}

publication_verify_stable_context() {
  [[ -n $_publication_stable_context ]] || return 1
  find_publication_authority_part "$_publication_invocation" context || return 1
  json_is '.[0] == .[1]' "[$_publication_stable_context,$_publication_found_body]" || return 1
  sync_publication_reference "$_publication_found_reference" || return 1
  publication_collect_stable_context || return 1
  publication_compare_stable_context "$_publication_stable_context" "$_publication_collected_context"
}

# Mount IDs identify only a live, held mount. Neither these numbers nor FAT
# dev:ino values authorize a later recovery attempt after custody ends.
publication_namespace_value() {
  local namespace
  namespace=$(readlink "/proc/$BASHPID/ns/mnt") || return 1
  [[ $namespace =~ ^mnt:\[[1-9][0-9]*\]$ ]] || return 1
  printf '%s\n' "$namespace"
}

publication_fd_mount_id() {
  local fd=$1 line value='' bytes=0
  [[ $fd =~ ^[0-9]+$ ]] || return 1
  while IFS= read -r -n 257 line || [[ -n $line ]]; do
    (( ${#line} <= 256 )) || return 1
    bytes=$((bytes+${#line}+1))
    (( bytes <= 4096 )) || return 1
    if [[ $line == mnt_id:* ]]; then
      [[ -z $value && $line =~ ^mnt_id:[[:blank:]]+([1-9][0-9]*)$ ]] || return 1
      value=${BASH_REMATCH[1]}
    fi
  done <"/proc/$BASHPID/fdinfo/$fd"
  [[ -n $value ]] || return 1
  printf '%s\n' "$value"
}

publication_check_path_mount() {
  local path=$1 kind=$2 mount=$3 identity=${4:-} observed current_mount current_identity namespace
  # Open in a bounded child so a raced nonregular pathname cannot block Core.
  # The descriptor is freshly opened there; Java child inheritance is irrelevant.
  # shellcheck disable=SC2016 # This fixed script executes in the observer child.
  observed=$(LC_ALL=C /usr/bin/timeout --kill-after=1 5 /usr/bin/bash --noprofile --norc -p -c '
    set -euo pipefail
    [[ ! -L $1 ]] || exit 1
    case $2 in directory) [[ -d $1 ]] ;; file) [[ -f $1 ]] ;; *) exit 1 ;; esac
    exec 3<"$1"
    [[ ! -L $1 && $1 -ef /proc/self/fd/3 ]] || exit 1
    value="" bytes=0
    while IFS= read -r -n 257 line || [[ -n $line ]]; do
      (( ${#line} <= 256 )) || exit 1
      bytes=$((bytes+${#line}+1))
      (( bytes <= 4096 )) || exit 1
      if [[ $line == mnt_id:* ]]; then
        [[ -z $value && $line =~ ^mnt_id:[[:blank:]]+([1-9][0-9]*)$ ]] || exit 1
        value=${BASH_REMATCH[1]}
      fi
    done </proc/self/fdinfo/3
    [[ -n $value ]] || exit 1
    printf "%s " "$value"
    /usr/bin/stat -Lc "%d:%i" /proc/self/fd/3
    /usr/bin/stat -Lc "%i" /proc/self/ns/mnt
    [[ ! -L $1 && $1 -ef /proc/self/fd/3 ]]
  ' omasecboot-live-mount "$path" "$kind") || return 1
  [[ $observed =~ ^([1-9][0-9]*)\ ([0-9]+:[0-9]+)$'\n'([1-9][0-9]*)$ ]] || return 1
  current_mount=${BASH_REMATCH[1]} current_identity=${BASH_REMATCH[2]} namespace=${BASH_REMATCH[3]}
  [[ $current_mount == "$mount" && "mnt:[$namespace]" == "$_publication_mount_namespace" ]] || return 1
  [[ -z $identity || $current_identity == "$identity" ]]
}

publication_verify_path_mount() {
  [[ $_publication_mount_invalid == false ]] || return 1
  if ! publication_check_path_mount "$@"; then _publication_mount_invalid=true; return 1; fi
}

publication_check_live() {
  local path fd state mount body target stage parent
  [[ -n $_publication_mount_namespace && $_publication_pin_owner == "$BASHPID" && $_publication_pin_transaction == "$_transaction_id" ]] || return 1
  [[ $(publication_namespace_value) == "$_publication_mount_namespace" ]] || return 1
  for path in "${!_publication_directory_fds[@]}"; do
    fd=${_publication_directory_fds[$path]}
    mount=${_publication_directory_mount_ids[$path]}
    [[ $(realpath -e -- "$path") == "$path" ]] && fd_matches_path "$fd" "$path" || return 1
    [[ $(publication_fd_mount_id "$fd") == "$mount" ]] || return 1
    state=$(publication_fd_state "$fd") || return 1
    json_is '.[0] == .[1]' "[$state,${_publication_directory_states[$path]}]" || return 1
    publication_check_path_mount "$path" directory "$mount" "$(jq -r '.identity' <<<"$state")" || return 1
  done
  for body in "${_publication_stage_candidates[@]}"; do
    target=$(jq -r '.target' <<<"$body") || return 1
    stage=$(jq -r '.stage.path' <<<"$body") || return 1
    parent=$(dirname "$target") || return 1
    for path in "$target" "$stage"; do
      if [[ -e $path || -L $path ]]; then
        publication_check_path_mount "$path" file "${_publication_directory_mount_ids[$parent]}" || return 1
      fi
    done
  done
  [[ $(publication_namespace_value) == "$_publication_mount_namespace" ]]
}

publication_verify_live() {
  [[ $_publication_mount_invalid == false ]] || return 1
  if ! publication_check_live; then _publication_mount_invalid=true; return 1; fi
}

publication_fd_state() {
  local fd=$1 path="/proc/$BASHPID/fd/$1" metadata device inode mode uid gid kind hash=null
  metadata=$(stat -Lc '%d %i %f %u %g' "$path") || return 1
  read -r device inode mode uid gid <<<"$metadata"
  [[ $device =~ ^[0-9]+$ && $inode =~ ^[0-9]+$ && $mode =~ ^[0-9a-f]+$ && $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ ]] || return 1
  case $((16#$mode & 0170000)) in
    32768) kind='file'; hash=$(sha256_file "$path") || return 1; hash="\"$hash\"" ;;
    16384) kind=directory ;;
    *) return 1 ;;
  esac
  [[ $(stat -Lc '%d %i %f %u %g' "$path") == "$metadata" ]] || return 1
  jq -cn --arg kind "$kind" --arg identity "$device:$inode" --argjson mode "$((16#$mode))" \
    --argjson uid "$uid" --argjson gid "$gid" --argjson hash "$hash" \
    '{kind:$kind,identity:$identity,sha256:$hash,link_target:null,mode:$mode,uid:$uid,gid:$gid}'
}

publication_pin_path() {
  local path=$1 kind=$2 fd
  if [[ $kind == directory ]]; then
    if [[ $path == / ]]; then
      [[ $(stat -Lc %u /) == "$(control_owner_uid)" ]] && mode_is_control_safe "$(stat -Lc %a /)" || return 1
    else validate_control_directory "$path" || return 1; fi
    [[ -r $path && -x $path ]] || return 1
  else validate_control_file "$path" || return 1; fi
  exec {fd}<"$path" || return 1
  if ! fd_matches_path "$fd" "$path"; then exec {fd}<&-; return 1; fi
  _publication_pin_owner=$BASHPID
  _publication_pin_transaction=$_transaction_id
  _publication_pins+=("$fd")
  _publication_new_fd=$fd
}

publication_validate_targets() {
  publication_verify_live || return 1
  /usr/bin/timeout --kill-after=1 "$_producer_session_io_timeout" "$_producer_session_decoder_tool" \
    --validate-managed-targets <<<"$_publication_intent" || return 1
  publication_verify_live
}

publication_pin_directory() {
  local path=$1 fd
  publication_pin_path "$path" directory || return 1
  fd=$_publication_new_fd
  _publication_directory_fds[$path]=$fd
  _publication_directory_states[$path]=$(publication_fd_state "$fd") || return 1
  _publication_directory_mount_ids[$path]=$(publication_fd_mount_id "$fd") || return 1
}

# Each mkdir is an absent-to-directory effect beneath an already held parent.
# Neither EEXIST nor later existence can supply the missing live result custody.
publication_prepare_directory() {
  local path=$1 parent id body result fd mount
  parent=$(dirname "$path") || return 1
  if [[ -z ${_publication_directory_pending[$path]:-} ]]; then
    if [[ -e $path || -L $path ]]; then publication_pin_directory "$path"; return; fi
    body=$(jq -cn --arg path "$path" --argjson intent "$_publication_intent" '[$path,$intent]') || return 1
    # shellcheck disable=SC2016 # jq-local variables.
    json_is '.[0] as $path | .[1] as $intent | ($path | startswith($intent.esp_path + "/")) and
      any($intent.resources[].target,$intent.configuration.path; startswith($path + "/"))' "$body" || return 1
    [[ -n ${_publication_directory_fds[$parent]:-} ]] || return 1
    publication_validate_targets || return 1
    id=$(sha256_text "$path") || return 1
    body=$(jq -cn --arg id "$id" --arg path "$path" --arg parent "$parent" \
      --arg namespace "$_publication_mount_namespace" --arg mount "${_publication_directory_mount_ids[$parent]}" \
      --argjson state "${_publication_directory_states[$parent]}" \
      '{id:$id,path:$path,mount_namespace:$namespace,parent:{path:$parent,state:$state,mount_id:$mount}}') || return 1
    _publication_directory_pending[$path]=$body
  fi
  body=${_publication_directory_pending[$path]}
  id=$(jq -r '.id' <<<"$body") || return 1
  if [[ -n ${_publication_directory_completed[$path]:-} ]]; then
    publication_verify_live || return 1
    find_publication_record "$_publication_invocation" directory-created "$id" || return 1
    sync_publication_reference "$_publication_found_reference"
    return
  fi
  if [[ -z ${_publication_directory_candidates[$path]:-} ]]; then
    # A previous failed mkdir may have created a directory. Without the retained
    # result descriptor it remains unresolved, even if the bytes look harmless.
    [[ ! -e $path && ! -L $path ]] || return 1
    append_publication_record "$_publication_invocation" directory-pending "$body" || return 1
    publication_verify_live && publication_validate_targets || return 1
    [[ ! -e $path && ! -L $path ]] || return 1
    fd=${_publication_directory_fds[$parent]}
    mkdir -- "/proc/$BASHPID/fd/$fd/${path##*/}" || return 1
    publication_pin_directory "$path" || return 1
    mount=${_publication_directory_mount_ids[$path]}
    [[ $mount == "${_publication_directory_mount_ids[$parent]}" ]] || { _publication_mount_invalid=true; return 1; }
    result=$(jq -cn --arg id "$id" --arg path "$path" --arg mount "$mount" \
      --argjson state "${_publication_directory_states[$path]}" '{id:$id,path:$path,mount_id:$mount,state:$state}') || return 1
    _publication_directory_candidates[$path]=$result
  else
    find_publication_record "$_publication_invocation" directory-pending "$id" || return 1
    sync_publication_reference "$_publication_found_reference" || return 1
  fi
  publication_verify_live && publication_validate_targets || return 1
  durable_sync "$path" && durable_sync "$parent" || return 1
  publication_verify_live || return 1
  append_publication_record "$_publication_invocation" directory-created "${_publication_directory_candidates[$path]}" || return 1
  _publication_directory_completed[$path]=true
}

publication_parent_binding() {
  local parent=$1 create=${2:-false} current=/ component fd state mount esp previous=null components='[]' dependencies='[]' views='[]'
  local -a parts=()
  [[ $_publication_mount_invalid == false && $(publication_namespace_value) == "$_publication_mount_namespace" ]] || { _publication_mount_invalid=true; return 1; }
  if (( ${#_publication_directory_fds[@]} > 0 )); then publication_verify_live || return 1; fi
  esp=$(jq -r '.esp_path' <<<"$_publication_intent") || return 1
  IFS=/ read -r -a parts <<<"${parent#/}"
  for component in '' "${parts[@]}"; do
    [[ -z $component ]] || current="${current%/}/$component"
    fd=${_publication_directory_fds[$current]:-}
    if [[ $create == true && ( -z $fd || -n ${_publication_directory_pending[$current]:-} ) ]]; then
      publication_prepare_directory "$current" || return 1
      fd=${_publication_directory_fds[$current]}
    fi
    if [[ -z $fd ]]; then
      publication_pin_directory "$current" || return 1
      fd=${_publication_directory_fds[$current]}
    fi
    fd_matches_path "$fd" "$current" || return 1
    state=$(publication_fd_state "$fd") || return 1
    mount=${_publication_directory_mount_ids[$current]}
    if [[ $current == "$esp/"* ]]; then
      [[ $mount == "${_publication_directory_mount_ids[$esp]}" ]] || { _publication_mount_invalid=true; return 1; }
    fi
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

publication_stage_file() {
  local id=$1 target=$2 retained=$3 parent fd stage before state body
  producer_session_context_is_owned || return 1
  publication_verify_live || return 1
  if [[ -n ${_publication_stage_bodies[$id]:-} ]]; then
    find_publication_record "$_publication_invocation" boot-stage "$id" || return 1
    sync_publication_reference "$_publication_found_reference" || return 1
    _publication_stage_result=${_publication_stage_bodies[$id]}
    return 0
  fi
  if [[ -n ${_publication_stage_candidates[$id]:-} ]]; then
    body=${_publication_stage_candidates[$id]}
    stage=$(jq -r '.stage.path' <<<"$body") || return 1
    fd=${_publication_stage_fds[$id]}
    fd_matches_path "$fd" "$stage" || return 1
    state=$(publication_fd_state "$fd") || return 1
    json_is '.[0] == .[1].stage.state' "[$state,$body]" || return 1
    durable_sync "$stage" && durable_sync "$(dirname "$stage")" || return 1
    append_publication_record "$_publication_invocation" boot-stage "$body" || return 1
    _publication_stage_bodies[$id]=$body
    _publication_stage_result=$body
    return 0
  fi
  parent=$(dirname "$target") || return 1
  publication_parent_binding "$parent" true || return 1
  before='{"kind":"absent","identity":null,"sha256":null,"link_target":null,"mode":0,"uid":0,"gid":0}'
  if [[ -e $target || -L $target ]]; then
    publication_verify_path_mount "$target" file "${_publication_directory_mount_ids[$parent]}" || return 1
    publication_pin_path "$target" file || return 1
    _publication_target_fds[$id]=$_publication_new_fd
    before=$(publication_fd_state "$_publication_new_fd") || return 1
  fi
  validate_publication_retained_file "$_transaction_id" "$retained" || return 1
  stage=$(mktemp "$parent/.omasecboot-${_publication_invocation}-${id}.XXXXXX.stage") || return 1
  publication_pin_path "$stage" file || return 1
  fd=$_publication_new_fd
  _publication_stage_fds[$id]=$fd
  publication_verify_live && publication_verify_path_mount "$stage" file "${_publication_directory_mount_ids[$parent]}" || return 1
  cp -- "$(jq -r '.path' <<<"$retained")" "$stage" || return 1
  # The boot filesystem determines the stage's effective metadata. Never infer
  # canonical metadata from the private retained file's restrictive mode.
  state=$(publication_fd_state "$fd") || return 1
  [[ $(jq -r '.sha256' <<<"$state") == "$(jq -r '.sha256' <<<"$retained")" ]] || return 1
  fd_matches_path "$fd" "$stage" || return 1
  durable_sync "$stage" && durable_sync "$parent" || return 1
  body=$(jq -cn --arg id "$id" --arg target "$target" --arg stage "$stage" --argjson before "$before" \
    --argjson retained "$retained" --argjson state "$state" --argjson parent "$_publication_parent" --argjson view "$_publication_parent_view" \
    '{id:$id,target:$target,before:$before,retained:$retained,parent:$parent,mount_view:$view,stage:{path:$stage,state:$state}}') || return 1
  _publication_stage_candidates[$id]=$body
  publication_verify_live || return 1
  append_publication_record "$_publication_invocation" boot-stage "$body" || return 1
  _publication_stage_bodies[$id]=$body
  _publication_stage_result=$body
}

publication_stage_reply() {
  jq -c '.retained = .retained.path' <<<"$_publication_stage_result"
}

publication_capture_result() {
  local id=$1 body=${_publication_stage_bodies[$1]} target fd state expected
  target=$(jq -r '.target' <<<"$body") || return 1
  publication_verify_live || return 1
  fd=${_publication_stage_fds[$id]}
  if fd_matches_path "$fd" "$target"; then
    state=$(publication_fd_state "$fd") || return 1
    expected=$(jq -c '.stage.state' <<<"$body") || return 1
  elif [[ -n ${_publication_target_fds[$id]:-} ]] && fd_matches_path "${_publication_target_fds[$id]}" "$target"; then
    state=$(publication_fd_state "${_publication_target_fds[$id]}") || return 1
    expected=$(jq -c '.before' <<<"$body") || return 1
  elif json_is '.before.kind == "absent"' "$body" && [[ ! -e $target && ! -L $target ]]; then
    state=$(jq -c '.before' <<<"$body") || return 1
    expected=$state
  else return 1; fi
  json_is '.[0] == .[1]' "[$state,$expected]" || return 1
  _publication_observed=$state
}

publication_all_effects_applied() {
  local ids id expected target
  [[ -n $_publication_plan ]] || return 1
  ids=$(jq -r '.puts[].id, .configuration.id' <<<"$_publication_plan") || return 1
  for id in $ids; do
    find_publication_record "$_publication_invocation" effect-applied "$id" || return 1
    expected=$(jq -c '.state' <<<"$_publication_found_body") || return 1
    publication_capture_result "$id" || return 1
    json_is '.[0] == .[1]' "[$_publication_observed,$expected]" || return 1
    if [[ $id != configuration ]] && json_is '.signing == "local-efi"' "${_publication_retained[$id]}"; then
      target=$(jq -r '.target' <<<"${_publication_stage_bodies[$id]}") || return 1
      verify_publication_input "$target" || return 1
    fi
  done
}

publication_start_executor() {
  producer_session_context_is_owned || return 1
  publication_verify_live || return 1
  publication_verify_stable_context || return 1
  publication_validate_targets || return 1
  [[ $_producer_session_active == false && -n $_publication_plan ]] || return 1
  find_publication_record "$_publication_invocation" prepared-terminal || return 1
  json_is '.supervision_status == 0 and .worker_status == 0 and .decoder_status == 0 and .protocol_complete' "$_publication_found_body" || return 1
  sync_publication_reference "$_publication_found_reference" || return 1
  # A successful prepare result is not a certificate proof. Reverify both the
  # immutable inputs and filesystem-effective stages before enabling any put.
  local id retained stage state
  for id in "${!_publication_retained[@]}"; do
    if json_is '.signing == "local-efi"' "${_publication_retained[$id]}"; then
      retained=$(jq -r '.file.path' <<<"${_publication_retained[$id]}") || return 1
      stage=$(jq -r '.stage.path' <<<"${_publication_stage_bodies[$id]}") || return 1
      verify_publication_input "$retained" && verify_publication_input "$stage" || return 1
      fd_matches_path "${_publication_stage_fds[$id]}" "$stage" || return 1
      state=$(publication_fd_state "${_publication_stage_fds[$id]}") || return 1
      json_is '.[0] == .[1].stage.state' "[$state,${_publication_stage_bodies[$id]}]" || return 1
    fi
  done
  _publication_apply_phase=true
}

publication_handle_request() {
  local document=$1 operation id resource retained target config path hash bytes body plan stages='{}' fd pins='[]' directories='[]' state existing content_hash lookup_rc
  publication_verify_live || return 1
  operation=$(jq -r '.payload.operation' <<<"$document") || return 1
  case $operation in
    match-intent)
      [[ $_publication_apply_phase == false ]] || return 1
      json_is '.payload | keys == ["intent","operation"]' "$document" || return 1
      find_publication_authority_part "$_publication_invocation" intent || return 1
      json_is '.[0] == .[1] and .[0] == .[2].payload.intent' \
        "[$_publication_intent,$_publication_found_body,$document]" || return 1
      sync_publication_reference "$_publication_found_reference" || return 1
      publication_validate_targets || return 1
      _publication_intent_matched=true
      _producer_session_reply='{"accepted":true}'
      ;;
    stage-input)
      [[ $_publication_apply_phase == false && $_publication_intent_matched == true ]] || return 1
      json_is '.payload | keys == ["id","operation"]' "$document" || return 1
      id=$(jq -er '.payload.id' <<<"$document") || return 1
      resource=$(jq -ce --arg id "$id" '.resources[] | select(.id == $id)' <<<"$_publication_intent") || return 1
      [[ -n ${_publication_retained[$id]:-} ]] || return 1
      retained=$(jq -c '.file' <<<"${_publication_retained[$id]}") || return 1
      target=$(jq -r '.target' <<<"$resource") || return 1
      publication_stage_file "$id" "$target" "$retained" || return 1
      _producer_session_reply=$(publication_stage_reply) || return 1
      ;;
    stage-config)
      [[ $_publication_apply_phase == false && $_publication_intent_matched == true ]] || return 1
      json_is '.payload | keys == ["content","operation"] and (.content | type == "string" and (explode | all(.[]; . != 0)))' "$document" || return 1
      config=$(jq -r '.configuration.path' <<<"$_publication_intent") || return 1
      hash=$(sha256_file "$config") || return 1
      [[ $hash == "$(jq -r '.configuration.sha256' <<<"$_publication_intent")" ]] || return 1
      path="$(dirname "$(lifecycle_manifest_path "$_transaction_id")")/publication-data-$_publication_invocation-configuration"
      content_hash=$(jq -jr '.payload.content' <<<"$document" | sha256sum) || return 1
      content_hash=${content_hash%% *}
      if [[ -e $path || -L $path ]]; then
        validate_private_control_file "$path" || return 1
        [[ $(sha256_file "$path") == "$content_hash" ]] || return 1
      else
        jq -jr '.payload.content' <<<"$document" | atomic_create_control_file "$path" 400 || return 1
      fi
      durable_sync "$path" && durable_sync "$(dirname "$path")" || return 1
      publication_pin_path "$path" file || return 1
      hash=$(sha256_file "$path") || return 1
      bytes=$(stat -Lc %s "$path") || return 1
      retained=$(jq -cn --arg path "$path" --arg hash "$hash" --argjson bytes "$bytes" '{path:$path,sha256:$hash,bytes:$bytes}') || return 1
      body=$(jq -cn --argjson file "$retained" '{file:$file}') || return 1
      if find_publication_record "$_publication_invocation" configuration; then
        existing=$_publication_found_body
        json_is '.[0] == .[1]' "[$body,$existing]" || return 1
        sync_publication_reference "$_publication_found_reference" || return 1
      else
        lookup_rc=$?
        (( lookup_rc == 1 )) || return 1
        append_publication_record "$_publication_invocation" configuration "$body" || return 1
      fi
      publication_stage_file configuration "$config" "$retained" || return 1
      _producer_session_reply=$(publication_stage_reply) || return 1
      ;;
    prepare-plan)
      [[ $_publication_apply_phase == false ]] || return 1
      json_is '.payload | keys == ["operation","plan"]' "$document" || return 1
      plan=$(jq -c '.payload.plan' <<<"$document") || return 1
      for id in "${!_publication_stage_bodies[@]}"; do
        stages=$(jq -c --arg id "$id" --argjson body "${_publication_stage_bodies[$id]}" '.[$id]=$body' <<<"$stages") || return 1
      done
      validate_publication_plan_projection "$_publication_intent" "$stages" "$plan" || return 1
      publication_validate_targets || return 1
      /usr/bin/timeout --kill-after=1 "$_producer_session_io_timeout" "$_producer_session_decoder_tool" --validate-managed-plan <<<"$plan" || return 1
      append_publication_record "$_publication_invocation" plan "$plan" || return 1
      _publication_plan=$plan
      _producer_session_reply='{"accepted":true}'
      ;;
    application)
      [[ $_publication_apply_phase == true && -n $_publication_plan ]] || return 1
      json_is '.payload | keys == ["operation"]' "$document" || return 1
      for fd in "${_publication_pins[@]}"; do
        state=$(publication_fd_state "$fd") || return 1
        pins=$(jq -c --argjson fd "$fd" --argjson state "$state" '. += [{fd:$fd,state:$state}]' <<<"$pins") || return 1
      done
      for path in "${!_publication_directory_fds[@]}"; do
        directories=$(jq -c --arg path "$path" --argjson fd "${_publication_directory_fds[$path]}" \
          --arg mount "${_publication_directory_mount_ids[$path]}" --argjson state "${_publication_directory_states[$path]}" \
          '. + [{path:$path,fd:$fd,mount_id:$mount,identity:$state.identity}]' <<<"$directories") || return 1
      done
      _producer_session_reply=$(jq -cn --argjson plan "$_publication_plan" --argjson pins "$pins" \
        --arg namespace "$_publication_mount_namespace" --argjson directories "$directories" \
        '{plan:$plan,pins:$pins,mount_namespace:$namespace,directories:$directories}') || return 1
      ;;
    validate-plan)
      [[ $_publication_apply_phase == true ]] || return 1
      json_is '.payload | keys == ["operation","plan"]' "$document" || return 1
      json_is '.[0] == .[1].payload.plan' "[$_publication_plan,$document]" || return 1
      _producer_session_reply='{"accepted":true}'
      ;;
    frontier|before|stage|applied)
      [[ $_publication_apply_phase == true ]] || return 1
      id=$(jq -er '.payload.id | select(type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))' <<<"$document") || return 1
      [[ -n ${_publication_stage_bodies[$id]:-} ]] || return 1
      publication_handle_effect "$operation" "$id" "$document"
      ;;
    *) return 1 ;;
  esac
}

publication_handle_effect() {
  local operation=$1 id=$2 document=$3 body=${_publication_stage_bodies[$2]} pending expected record lookup_rc state path
  publication_capture_result "$id" || return 1
  case $operation in
    frontier)
      json_is '.payload | keys == ["id","operation"]' "$document" || return 1
      if find_publication_record "$_publication_invocation" effect-applied "$id"; then
        json_is '.[0] == .[1].state' "[$_publication_observed,$_publication_found_body]" || return 1
        _producer_session_reply=$(jq -c '{phase:"applied",observed:.state}' <<<"$_publication_found_body") || return 1
      else
        (( $? == 1 )) || return 1
        if find_publication_record "$_publication_invocation" effect-pending "$id"; then
          json_is '.[0] == .[1].observed or .[0] == .[1].result' "[$_publication_observed,$_publication_found_body]" || return 1
          _producer_session_reply=$(jq -c '{phase:"pending",observed:.result}' <<<"$_publication_found_body") || return 1
        else
          (( $? == 1 )) || return 1
          json_is '.[0] == .[1].before' "[$_publication_observed,$body]" || return 1
          _producer_session_reply='{"phase":"unstarted","observed":null}'
        fi
      fi
      ;;
    before)
      json_is '.payload | keys == ["id","operation","state"]' "$document" || return 1
      json_is '.[0] == .[1].payload.state' "[$_publication_observed,$document]" || return 1
      if find_publication_record "$_publication_invocation" effect-applied "$id"; then return 1; else (( $? == 1 )) || return 1; fi
      if find_publication_record "$_publication_invocation" effect-pending "$id"; then
        pending=$_publication_found_body
        json_is '.[0] == .[1].observed or .[0] == .[1].result' "[$_publication_observed,$pending]" || return 1
        sync_publication_reference "$_publication_found_reference" || return 1
        _producer_session_reply='{"accepted":true}'
        return 0
      else (( $? == 1 )) || return 1; fi
      json_is '.[0] == .[1].before' "[$_publication_observed,$body]" || return 1
      expected=$(jq -c 'if .before.kind == "file" and ((.before|del(.identity)) == (.stage.state|del(.identity))) then .before else .stage.state end' <<<"$body") || return 1
      record=$(jq -cn --arg id "$id" --argjson result "$expected" --argjson observed "$_publication_observed" \
        '{id:$id,result:$result,observed:$observed}') || return 1
      append_publication_record "$_publication_invocation" effect-pending "$record" || return 1
      _producer_session_reply='{"accepted":true}'
      ;;
    stage)
      json_is '.payload | keys == ["id","operation"]' "$document" || return 1
      find_publication_record "$_publication_invocation" effect-pending "$id" || return 1
      pending=$_publication_found_body
      json_is '.[0].result == .[1].stage.state' "[$pending,$body]" || return 1
      path=$(jq -r '.stage.path' <<<"$body") || return 1
      fd_matches_path "${_publication_stage_fds[$id]}" "$path" || return 1
      state=$(publication_fd_state "${_publication_stage_fds[$id]}") || return 1
      json_is '.[0] == .[1].stage.state' "[$state,$body]" || return 1
      sync_publication_reference "$_publication_found_reference" || return 1
      _producer_session_reply=$(jq -c '.stage' <<<"$body") || return 1
      ;;
    applied)
      json_is '.payload | keys == ["id","operation","state"]' "$document" || return 1
      find_publication_record "$_publication_invocation" effect-pending "$id" || return 1
      expected=$(jq -c '.result' <<<"$_publication_found_body") || return 1
      json_is '.[0] == .[1] and .[0] == .[2].payload.state' "[$_publication_observed,$expected,$document]" || return 1
      record=$(jq -cn --arg id "$id" --argjson state "$expected" '{id:$id,state:$state}') || return 1
      append_publication_record "$_publication_invocation" effect-applied "$record" || return 1
      _producer_session_reply='{"accepted":true}'
      ;;
  esac
}
