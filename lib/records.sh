#!/bin/bash
# shellcheck disable=SC2154 # Transaction globals come from the sourced lifecycle module.
# OmaSecBoot: domain record schemas, references, validators, and persistence

readonly PRODUCER_RECORD_SCHEMA_VERSION=1
readonly FINAL_PROOF_SCHEMA_VERSION=2
readonly FIRMWARE_PROOF_SCHEMA_VERSION=1
readonly BOOTNEXT_RECORD_SCHEMA_VERSION=1
readonly WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION=1
readonly WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION=1
readonly MANAGED_SETTINGS_SCHEMA_VERSION=1
readonly TRACKING_OWNERSHIP_SCHEMA_VERSION=1
# shellcheck disable=SC2034 # New record writers live in sign.sh.
readonly UNCONFIGURE_INTENT_SCHEMA_VERSION=2
# shellcheck disable=SC2034 # New record writers live in sign.sh.
readonly UNCONFIGURE_PROOF_SCHEMA_VERSION=2
# Schema 1 always managed both loaders. Read its original semantics while
# schema 2 writers explicitly record whether the fallback belongs to the intent.
# shellcheck disable=SC2034 # Historical manifest validation lives in lifecycle.sh.
readonly UNCONFIGURE_READ_SCHEMAS='[1,2]'
readonly MAX_EXPECTED_EFI_ARTIFACTS=4096
readonly PUBLICATION_RECORD_SCHEMA_VERSION=1
readonly PUBLICATION_INVOCATION_START_SCHEMA_VERSION=2
readonly PUBLICATION_RECOVERY_BASIS_SCHEMA_VERSION=2
# This is stable identity, separate from boot-stage mount/inode observations.
# shellcheck disable=SC2016 # jq schema definitions, not shell expressions.
readonly PUBLICATION_CONTEXT_JQ_DEFS='
  def context_path: . == "/" or (absolute_path and (split("/")[1:] | all(.[]; . != "" and . != "." and . != "..")));
  def context_uuid: type == "string" and length == 36 and uuid and . != "00000000-0000-0000-0000-000000000000";
  def subvolume_id: type == "string" and test("\\A[1-9][0-9]{0,19}\\z") and
    (length < 20 or . <= "18446744073709551360") and (length > 3 or (length == 3 and . >= "256"));
  def publication_context:
    type == "object" and keys == ["architecture","configuration_path","esp","local_db_certificate_der_sha256","machine_id","root","schema_version"] and
    .schema_version == 1 and (.architecture == "x86_64" or .architecture == "aarch64") and
    (.machine_id | type == "string" and length == 32 and test("^[0-9a-f]{32}$") and . != "00000000000000000000000000000000") and
    (.local_db_certificate_der_sha256 | type == "string" and length == 64 and digest) and (.configuration_path | absolute_path and context_path) and
    (.root | type == "object" and keys == ["filesystem_type","filesystem_uuid","path","subvolume"] and
      (.path | context_path) and (.filesystem_uuid | context_uuid) and
      (if .filesystem_type == "btrfs" then
         (.subvolume | type == "object" and keys == ["id","kind","uuid"] and
           (if .kind == "top-level" then .id == "5" and (.uuid == null or (.uuid | context_uuid))
            elif .kind == "subvolume" then (.id | subvolume_id) and (.uuid | context_uuid) else false end))
       else (.filesystem_type == "ext2" or .filesystem_type == "ext3" or .filesystem_type == "ext4" or .filesystem_type == "xfs") and .subvolume == null end)) and
    (.esp | type == "object" and keys == ["filesystem_type","filesystem_uuid","partition_scheme","partition_type","partition_uuid","path"] and
      (.path | absolute_path and context_path) and .partition_scheme == "gpt" and
      .partition_type == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" and (.partition_uuid | context_uuid) and
      .filesystem_type == "vfat" and (.filesystem_uuid | type == "string" and length == 9 and test("^[0-9A-F]{4}-[0-9A-F]{4}$"))) and
    (. as $context | .root.path != .esp.path and (.configuration_path | startswith($context.esp.path + "/")));
'

validate_publication_context_json() {
  json_is "${OMASECBOOT_JQ_DEFS}${PUBLICATION_CONTEXT_JQ_DEFS}"'publication_context' "$1"
}

publication_context_matches_intent() {
  local context=$1 intent=$2
  validate_publication_context_json "$context" || return 1
  # The model is producer-owned; machine_id is the host identity already captured
  # by that producer, distinct from its optional entry placement overrides.
  # shellcheck disable=SC2016
  json_is '.[0] as $context | .[1] as $intent |
    $context.root.path == "/" and $context.esp.path == $intent.esp_path and
    $context.configuration_path == $intent.configuration.path and
    ($intent.publication.model | fromjson | .machine_id) == $context.machine_id' "[$context,$intent]"
}
# Semantic memoization only. Every hit rechecks all referenced control files and
# immutable retained bytes; neither pathname metadata nor visibility is proof.
declare -Ag _publication_validation_cache=()

# Publication records are an append-only transaction-local chain. These readers
# prove immutable data, never the continued existence of a historical FAT inode.
validate_publication_record_json() {
  local transaction_id=$1 ordinal=$2 previous=$3 document=$4 directory
  directory=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  jq -e --arg id "$transaction_id" --argjson ordinal "$ordinal" --argjson previous "$previous" \
    --arg directory "$directory" --argjson uid "$(control_owner_uid)" --argjson schema "$PUBLICATION_RECORD_SCHEMA_VERSION" \
    --argjson start_schema "$PUBLICATION_INVOCATION_START_SCHEMA_VERSION" \
    --argjson recovery_schema "$PUBLICATION_RECOVERY_BASIS_SCHEMA_VERSION" "${OMASECBOOT_JQ_DEFS}${PUBLICATION_CONTEXT_JQ_DEFS}"'
    def resource_id: type == "string" and test("^[A-Za-z0-9_-]{1,64}$");
    def strict_resource_id: type == "string" and test("\\A[A-Za-z0-9_-]{1,64}\\z");
    def strict_digest: type == "string" and test("\\A[0-9a-f]{64}\\z");
    def canonical_path: absolute_path and (split("/")[1:] | all(.[]; . != "" and . != "." and . != ".."));
    def original_addition:
      type == "object" and keys == ["configuration","esp_path","operation","publication","resources"] and
      (.publication | type == "object" and keys == ["kind","model"] and .kind == "addition" and
        (.model | type == "string" and length > 0)) and
      (.esp_path | canonical_path) and (.operation == "add-uki" or .operation == "add-kernel") and
      (.configuration | type == "object" and keys == ["path","sha256"] and
        (.path | canonical_path) and (.sha256 | strict_digest)) and
      (.resources | type == "array" and length > 0 and length <= 4096 and
        (map(.id) | length == (unique | length)) and all(.[];
          type == "object" and keys == ["id","role","sha256","source","target"] and
          (.id | strict_resource_id) and .id != "configuration" and .id != "original-configuration" and
          (.role == "uki" or .role == "kernel" or .role == "initramfs") and
          (.sha256 | strict_digest) and (.source | canonical_path) and (.target | canonical_path))) and
      (. as $intent | (.configuration.path | startswith($intent.esp_path + "/")) and
        all(.resources[]; .target | startswith($intent.esp_path + "/")));
    def file_ref:
      type == "object" and keys == ["bytes","path","sha256"] and
      (.path | absolute_path and startswith($directory + "/publication-data-")) and
      (.sha256 | digest) and (.bytes | type == "number" and . >= 0 and floor == .);
    def state:
      type == "object" and keys == ["gid","identity","kind","link_target","mode","sha256","uid"] and
      .link_target == null and all(.mode,.uid,.gid; type == "number" and . >= 0 and floor == .) and
      (if .kind == "absent" then .identity == null and .sha256 == null and .mode == 0 and .uid == 0 and .gid == 0
       elif .kind == "file" then (.identity | identity) and (.sha256 | digest) and .mode >= 32768 and .mode < 36864
       elif .kind == "directory" then (.identity | identity) and .sha256 == null and .mode >= 16384 and .mode < 20480
       else false end);
    def parent:
      type == "object" and keys == ["components","dependencies","path"] and (.path | type == "string" and startswith("/")) and
      (.components | type == "array" and length > 0 and all(.[]; keys == ["directory","entry","path"] and
        (.entry | state) and .entry.kind == "directory" and .directory == .entry and (.path | type == "string"))) and
      (.dependencies | type == "array" and length > 0 and all(.[]; keys == ["entry","parent_identity","path"] and
        (.entry | state) and .entry.kind == "directory" and (.path | type == "string") and
        (.parent_identity == null or (.parent_identity | identity))));
    type == "object" and keys == ["body","invocation","kind","ordinal","previous","recorded_at",
      "schema_version","transaction_id","writer_version"] and
    .schema_version == (if .kind == "invocation-start" then $start_schema
      elif .kind == "recovery-basis" then $recovery_schema else $schema end) and
    .transaction_id == $id and (.invocation | uuid) and
    .ordinal == $ordinal and .previous == $previous and (.recorded_at | timestamp) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
     (if .kind == "recovery-basis" then
        .ordinal == 1 and .previous == null and (.invocation | length == 36) and
        (.body | type == "object" and keys == ["basis"] and
          (.basis | type == "object" and .scope == "original-invocation-basis")) and
        .body.basis.invocation == .invocation
      elif .kind == "intent" then
       (.body | type == "object" and keys == (["configuration","esp_path","operation","resources"] +
         (if has("publication") then ["publication"] else [] end) | sort) and
        (if has("publication") then (.publication | type == "object" and keys == ["kind","model"] and
           .kind == "addition" and (.model | type == "string" and length > 0)) and all(.resources[]; .id != "configuration") else true end) and
        (.esp_path | canonical_path) and (.operation == "add-uki" or .operation == "add-kernel") and
        (.configuration | type == "object" and keys == ["path","sha256"] and
          (.path | canonical_path) and (.sha256 | digest)) and
        (.resources | type == "array" and length > 0 and length <= 4096 and
          (map(.id) | length == (unique | length)) and all(.[];
          type == "object" and keys == ["id","role","sha256","source","target"] and
          (.id | resource_id) and (.role == "uki" or .role == "kernel" or .role == "initramfs") and
          (.sha256 | digest) and (.source | canonical_path) and (.target | canonical_path))) and
        (. as $intent | (.configuration.path | startswith($intent.esp_path + "/")) and
          all(.resources[]; .target | startswith($intent.esp_path + "/"))))
     elif .kind == "invocation-start" then
       .invocation as $invocation | (.invocation | length == 36) and
       (.body | type == "object" and keys == ["context","intent","original_configuration","recovery"] and
         (.intent | original_addition) and (.context | publication_context) and
         (.original_configuration | file_ref and (.sha256 | strict_digest) and
           .path == ($directory + "/publication-data-" + $invocation + "-original-configuration")) and
         .original_configuration.sha256 == .intent.configuration.sha256 and
         (.recovery | type == "object" and keys == ["recreate_missing"]) and
         .recovery.recreate_missing == ([.intent.resources[] | {id,target}] +
           [{id:"configuration",target:.intent.configuration.path}]))
     elif .kind == "context" then
       (.body | publication_context)
     elif .kind == "session" or .kind == "executor" then
       (.body | type == "object" and keys == ["boot_id","supervisor","worker"] and (.boot_id | uuid) and
         all(.supervisor,.worker; type == "object" and keys == ["pid","start_time","uid"] and
           (.pid | type == "number" and . > 0 and floor == .) and .uid == $uid and
           (.start_time | type == "string" and test("^[0-9]+$"))))
     elif .kind == "input-ready" or .kind == "retained" then
       .kind as $kind | (.body | type == "object" and
         keys == (["file","id","signing","source_sha256"] + (if $kind == "input-ready" then ["temporary"] else [] end) | sort) and
         (.id | resource_id) and (.file | file_ref) and (.source_sha256 | digest) and
         (.signing == "local-efi" or .signing == "bytes") and
         (if $kind == "input-ready" then (.temporary | absolute_path and startswith($directory + "/") and
           (ltrimstr($directory + "/") | test("^\\.publication-input\\.[A-Za-z0-9]{6}$"))) else true end))
      elif .kind == "configuration" then
        (.body | type == "object" and keys == ["file"] and (.file | file_ref))
      elif .kind == "directory-pending" then
        (.body | type == "object" and keys == ["id","mount_namespace","parent","path"] and
          (.id | digest) and (.path | canonical_path) and
          (.mount_namespace | type == "string" and test("^mnt:\\[[1-9][0-9]*\\]$")) and
          (.parent | type == "object" and keys == ["mount_id","path","state"] and
            (.path == "/" or (.path | canonical_path)) and (.state | state) and .state.kind == "directory" and
            (.mount_id | type == "string" and test("^[1-9][0-9]*$"))))
      elif .kind == "directory-created" then
        (.body | type == "object" and keys == ["id","mount_id","path","state"] and
          (.id | digest) and (.path | canonical_path) and (.state | state) and .state.kind == "directory" and
          (.mount_id | type == "string" and test("^[1-9][0-9]*$")))
      elif .kind == "boot-stage" then
        (.body | type == "object" and keys == ["before","id","mount_view","parent","retained","stage","target"] and
          (.id | resource_id) and (.target | canonical_path) and (.before | state) and (.before.kind == "absent" or .before.kind == "file") and
          (. as $body | .mount_view | type == "object" and keys == ["directories","namespace"] and
            (.namespace | type == "string" and test("^mnt:\\[[1-9][0-9]*\\]$")) and
            (.directories | type == "array" and length > 0 and
              all(.[]; keys == ["identity","mount_id","path"] and (.identity | identity) and
                (.mount_id | type == "string" and test("^[1-9][0-9]*$")) and (.path == "/" or (.path | canonical_path))) and
              (map({path,identity}) == ($body.parent.components | map({path,identity:.directory.identity}))))) and
         (.retained | file_ref) and (.parent | parent) and (.stage | type == "object" and keys == ["path","state"] and
           (.path | canonical_path) and (.state | state) and .state.kind == "file"))
     elif .kind == "plan" then
       (.body | type == "object" and keys == ["configuration","deletes","format","invocation","puts","references","schema"] and
         .format == "limine-prepared-publication" and .schema == 1 and (.invocation | uuid) and
         .deletes == [] and .references == [] and (.puts | type == "array") and
         all(.puts[],.configuration; keys == ["after","before","id","parent","retained","target"] and
           (.id | resource_id) and (.target | canonical_path) and (.retained | canonical_path) and
           (.before | state) and (.after | state) and .after.kind == "file" and (.parent | parent))) and .body.invocation == .invocation
     elif .kind == "effect-pending" then
       (.body | type == "object" and keys == ["id","observed","result"] and (.id | resource_id) and
         (.observed | state) and (.result | state) and .result.kind == "file")
     elif .kind == "effect-applied" then
       (.body | type == "object" and keys == ["id","state"] and (.id | resource_id) and (.state | state) and .state.kind == "file")
     elif .kind == "terminal" or .kind == "prepared-terminal" then
       (.body | type == "object" and keys == ["completion_acknowledged","decoder_status","invocation",
         "protocol_complete","supervision_status","worker_status"] and
         (.invocation | uuid) and (.completion_acknowledged | type == "boolean") and
         (.protocol_complete | type == "boolean") and all(.decoder_status,.worker_status,.supervision_status;
           type == "number" and . >= 0 and . <= 255 and floor == .)) and .body.invocation == .invocation
     else false end)
    ' <<<"$document" >/dev/null
}

validate_publication_records() {
  local transaction_id=$1 manifest=$2 pending=${3:-} references reference previous=null ordinal=0 path document retained total
  local directory invocation kind id resource rows ids body expected order cache_key cached hash schema parent_path cached_files='[]'
  local -A intents=() sessions=() terminals=() prepared=() retained_ids=() retained_files=() configs=() stages=() plans=() prepared_terminals=() executors=() pending_effects=() applied_effects=()
  local -A pending_directories=() created_directories=() contexts=()
  directory=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  references=$(jq -c '.publication_records // []' <<<"$manifest") || return 1
  total=$(jq -r 'length' <<<"$references") || return 1
  if json_is '.kind == "recovery-attempt" and .operation == "publication-recovery"' "$manifest"; then
    validate_publication_recovery_records "$transaction_id" "$manifest" "$pending"
    return "$?"
  fi
  (( total > 0 )) || return 0
  cache_key="$transaction_id:$(control_owner_uid):$(sha256_text "$references")"
  if [[ -z $pending && -n ${_publication_validation_cache[$cache_key]:-} ]]; then
    cached=${_publication_validation_cache[$cache_key]}
    rows=$(jq -r '.[] | [.path,.sha256,.schema_version] | @tsv' <<<"$references") || return 1
    while IFS=$'\t' read -r path hash schema; do
      ordinal=$((ordinal+1))
      [[ $path == "$directory/publication-$ordinal.json" && ( $schema == 1 || $schema == 2 ) ]] || return 1
      validate_private_control_file "$path" || return 1
      [[ $(sha256_file "$path") == "$hash" ]] || return 1
    done <<<"$rows"
    rows=$(jq -c '.[]' <<<"$cached") || return 1
    while IFS= read -r retained; do
      [[ -z $retained ]] || validate_publication_retained_file "$transaction_id" "$retained" || return 1
    done <<<"$rows"
    return 0
  fi
  rows=$(jq -c '.[]' <<<"$references") || return 1
  while IFS= read -r reference; do
    [[ -n $reference ]] || continue
    ordinal=$((ordinal+1))
    path=$(jq -er '.path' <<<"$reference") || return 1
    [[ $path == "$directory/publication-$ordinal.json" ]] || return 1
    if [[ -n $pending && $ordinal == "$total" ]]; then
      document=$pending
      [[ $(jq -r '.sha256' <<<"$reference") == "$(sha256_text "$document"$'\n')" ]] || return 1
    else
      validate_artifact_reference_file "$reference" "$directory" || return 1
      if json_is '.schema_version == 2' "$reference"; then
        document=$(publication_capture_hashed_document "$path" "$(jq -r '.sha256' <<<"$reference")") || return 1
      else document=$(read_control_document "$path") || return 1; fi
    fi
    validate_publication_record_json "$transaction_id" "$ordinal" "$previous" "$document" || return 1
    json_is '.[0].schema_version == .[1].schema_version and
      (.[0].schema_version != 2 or (.[0].sha256 | length == 64))' "[$reference,$document]" || return 1
    invocation=$(jq -r '.invocation' <<<"$document") || return 1
    kind=$(jq -r '.kind' <<<"$document") || return 1
    [[ -z ${terminals[$invocation]:-} ]] || return 1
    case $kind in
      recovery-basis) return 1 ;;
      invocation-start)
        [[ -z ${intents[$invocation]:-} && -z ${contexts[$invocation]:-} ]] || return 1
        intents[$invocation]=$(jq -c '.body.intent' <<<"$document") || return 1
        contexts[$invocation]=$(jq -c '.body.context' <<<"$document") || return 1
        publication_context_matches_intent "${contexts[$invocation]}" "${intents[$invocation]}" || return 1
        retained=$(jq -c '.body.original_configuration' <<<"$document") || return 1
        validate_publication_retained_file "$transaction_id" "$retained" || return 1
        cached_files=$(jq -c --argjson file "$retained" '. + [$file]' <<<"$cached_files") || return 1
        ;;
      intent)
        [[ -z ${intents[$invocation]:-} ]] || return 1
        intents[$invocation]=$(jq -c '.body' <<<"$document") || return 1
        ;;
      context)
        [[ -n ${intents[$invocation]:-} && -z ${sessions[$invocation]:-} && -z ${contexts[$invocation]:-} ]] || return 1
        body=$(jq -c '.body' <<<"$document") || return 1
        publication_context_matches_intent "$body" "${intents[$invocation]}" || return 1
        contexts[$invocation]=$body
        ;;
      session)
        [[ -n ${intents[$invocation]:-} && -z ${sessions[$invocation]:-} ]] || return 1
        sessions[$invocation]=true
        ;;
      input-ready|retained)
        [[ -n ${sessions[$invocation]:-} ]] || return 1
        id=$(jq -r '.body.id' <<<"$document") || return 1
        [[ -z ${retained_ids[$invocation:$id]:-} ]] || return 1
        resource=$(jq -ce --arg id "$id" '.resources[] | select(.id == $id)' <<<"${intents[$invocation]}") || return 1
        [[ $(jq -r '.body.source_sha256' <<<"$document") == "$(jq -r '.sha256' <<<"$resource")" ]] || return 1
        [[ $(jq -r '.body.file.path' <<<"$document") == "$directory/publication-data-$invocation-$id" ]] || return 1
        if json_is '.role == "uki"' "$resource"; then json_is '.body.signing == "local-efi"' "$document" || return 1; fi
        if [[ $kind == input-ready ]]; then
          [[ -z ${prepared[$invocation:$id]:-} ]] || return 1
          prepared[$invocation:$id]=$(jq -c '.body' <<<"$document") || return 1
        else
          [[ -n ${prepared[$invocation:$id]:-} ]] || return 1
          json_is '.[0].body == (.[1]|del(.temporary))' "[$document,${prepared[$invocation:$id]}]" || return 1
          retained_ids[$invocation:$id]=true
          retained_files[$invocation:$id]=$(jq -c '.body.file' <<<"$document") || return 1
        fi
        ;;
      configuration)
        [[ -n ${sessions[$invocation]:-} && -z ${configs[$invocation]:-} && -z ${plans[$invocation]:-} ]] || return 1
        json_is 'has("publication")' "${intents[$invocation]}" || return 1
        configs[$invocation]=$(jq -c '.body.file' <<<"$document") || return 1
        [[ $(jq -r '.path' <<<"${configs[$invocation]}") == "$directory/publication-data-$invocation-configuration" ]] || return 1
        validate_publication_retained_file "$transaction_id" "${configs[$invocation]}" || return 1
        cached_files=$(jq -c --argjson file "${configs[$invocation]}" '. + [$file]' <<<"$cached_files") || return 1
        ;;
      directory-pending|directory-created)
        [[ -n ${sessions[$invocation]:-} && -z ${plans[$invocation]:-} ]] || return 1
        json_is 'has("publication")' "${intents[$invocation]}" || return 1
        body=$(jq -c '.body' <<<"$document") || return 1
        path=$(jq -r '.path' <<<"$body") || return 1
        id=$(jq -r '.id' <<<"$body") || return 1
        [[ $id == "$(sha256_text "$path")" ]] || return 1
        expected=$(jq -cn --arg path "$path" --argjson intent "${intents[$invocation]}" '[$path,$intent]') || return 1
        # shellcheck disable=SC2016 # jq-local variables.
        json_is '.[0] as $path | .[1] as $intent | ($path | startswith($intent.esp_path + "/")) and
          any($intent.resources[].target,$intent.configuration.path; startswith($path + "/"))' "$expected" || return 1
        [[ -z ${created_directories[$invocation:$path]:-} ]] || return 1
        if [[ $kind == directory-pending ]]; then
          [[ -z ${pending_directories[$invocation:$path]:-} && $(jq -r '.parent.path' <<<"$body") == "$(dirname "$path")" ]] || return 1
          # Earlier descendants/stages already required this ancestor to exist;
          # a later declaration of original absence contradicts that authority.
          for parent_path in "${!pending_directories[@]}"; do
            [[ $parent_path != "$invocation:$path/"* ]] || return 1
            if [[ $parent_path == "$invocation:"* && $path == "${parent_path#*:}/"* ]]; then
              [[ -n ${created_directories[$parent_path]:-} ]] || return 1
              json_is '.[0].mount_namespace == .[1].mount_namespace' "[$body,${pending_directories[$parent_path]}]" || return 1
            fi
          done
          if [[ -n ${stages[$invocation]:-} ]]; then
            expected=$(jq -cn --arg path "$path" --argjson stages "${stages[$invocation]}" '[$path,$stages]') || return 1
            # shellcheck disable=SC2016 # jq-local path.
            json_is '.[0] as $path | all(.[1][].parent.components[]; .path != $path)' "$expected" || return 1
          fi
          parent_path=$(dirname "$path") || return 1
          if [[ -n ${pending_directories[$invocation:$parent_path]:-} ]]; then
            [[ -n ${created_directories[$invocation:$parent_path]:-} ]] || return 1
            expected=$(jq -cn --argjson child "$body" --argjson parent "${created_directories[$invocation:$parent_path]}" \
              --argjson pending "${pending_directories[$invocation:$parent_path]}" '[$child,$parent,$pending]') || return 1
            json_is '.[0].parent.state == .[1].state and .[0].parent.mount_id == .[1].mount_id and
              .[0].mount_namespace == .[2].mount_namespace' "$expected" || return 1
          fi
          pending_directories[$invocation:$path]=$body
        else
          [[ -n ${pending_directories[$invocation:$path]:-} ]] || return 1
          json_is '.[0].mount_id == .[1].parent.mount_id' "[$body,${pending_directories[$invocation:$path]}]" || return 1
          created_directories[$invocation:$path]=$body
        fi
        ;;
      boot-stage)
        [[ -n ${sessions[$invocation]:-} && -z ${plans[$invocation]:-} ]] || return 1
        json_is 'has("publication")' "${intents[$invocation]}" || return 1
        id=$(jq -r '.body.id' <<<"$document") || return 1
        body=$(jq -c '.body' <<<"$document") || return 1
        stages[$invocation]=${stages[$invocation]:-'{}'}
        json_is "has(\"$id\") | not" "${stages[$invocation]}" || return 1
        if [[ $id == configuration ]]; then
          [[ -n ${configs[$invocation]:-} ]] || return 1
          expected=${configs[$invocation]}
          resource=$(jq -c '.configuration' <<<"${intents[$invocation]}") || return 1
          [[ $(jq -r '.target' <<<"$body") == "$(jq -r '.path' <<<"$resource")" && $(jq -r '.before.sha256' <<<"$body") == "$(jq -r '.sha256' <<<"$resource")" ]] || return 1
        else
          [[ -n ${retained_files[$invocation:$id]:-} ]] || return 1
          expected=${retained_files[$invocation:$id]}
          resource=$(jq -ce --arg id "$id" '.resources[] | select(.id == $id)' <<<"${intents[$invocation]}") || return 1
          [[ $(jq -r '.target' <<<"$body") == "$(jq -r '.target' <<<"$resource")" ]] || return 1
        fi
        json_is '.[0].retained == .[1] and .[0].stage.state.sha256 == .[1].sha256' "[$body,$expected]" || return 1
        [[ $(dirname "$(jq -r '.stage.path' <<<"$body")") == "$(dirname "$(jq -r '.target' <<<"$body")")" ]] || return 1
        [[ $(basename "$(jq -r '.stage.path' <<<"$body")") =~ ^\.omasecboot-$invocation-$id\.[A-Za-z0-9]{6}\.stage$ ]] || return 1
        for path in "${!pending_directories[@]}"; do
          [[ $path == "$invocation:"* ]] || continue
          expected=$(jq -cn --argjson stage "$body" --argjson pending "${pending_directories[$path]}" '[$stage,$pending]') || return 1
          # shellcheck disable=SC2016 # jq-local path.
          if json_is '.[1].path as $path | any(.[0].parent.components[]; .path == $path)' "$expected"; then
            [[ -n ${created_directories[$path]:-} ]] || return 1
            expected=$(jq -cn --argjson stage "$body" --argjson created "${created_directories[$path]}" \
              --argjson pending "${pending_directories[$path]}" '[$stage,$created,$pending]') || return 1
            # shellcheck disable=SC2016 # jq-local variables.
            json_is '.[0] as $stage | .[1] as $created | .[2] as $pending |
              $stage.mount_view.namespace == $pending.mount_namespace and
              any($stage.parent.components[]; .path == $created.path and .directory == $created.state) and
              any($stage.mount_view.directories[]; .path == $created.path and .identity == $created.state.identity and .mount_id == $created.mount_id) and
              any($stage.parent.components[]; .path == $pending.parent.path and .directory == $pending.parent.state) and
              any($stage.mount_view.directories[]; .path == $pending.parent.path and .identity == $pending.parent.state.identity and .mount_id == $pending.parent.mount_id)' "$expected" || return 1
          fi
        done
        stages[$invocation]=$(jq -c --arg id "$id" --argjson body "$body" '.[$id]=$body' <<<"${stages[$invocation]}") || return 1
        ;;
      plan)
        [[ -n ${stages[$invocation]:-} && -z ${plans[$invocation]:-} ]] || return 1
        for path in "${!pending_directories[@]}"; do
          [[ $path != "$invocation:"* || -n ${created_directories[$path]:-} ]] || return 1
        done
        body=$(jq -c '.body' <<<"$document") || return 1
        validate_publication_plan_projection "${intents[$invocation]}" "${stages[$invocation]}" "$body" || return 1
        plans[$invocation]=$body
        ;;
      executor)
        [[ -n ${plans[$invocation]:-} && -n ${prepared_terminals[$invocation]:-} && -z ${executors[$invocation]:-} ]] || return 1
        json_is '.supervision_status == 0' "${prepared_terminals[$invocation]}" || return 1
        executors[$invocation]=true
        ;;
      effect-pending|effect-applied)
        [[ -n ${executors[$invocation]:-} ]] || return 1
        id=$(jq -r '.body.id' <<<"$document") || return 1
        body=$(jq -ce --arg id "$id" '.[$id]' <<<"${stages[$invocation]}") || return 1
        [[ -z ${applied_effects[$invocation:$id]:-} ]] || return 1
        if [[ $kind == effect-pending ]]; then
          [[ -z ${pending_effects[$invocation:$id]:-} ]] || return 1
          order=$(jq -r '.puts[].id, .configuration.id' <<<"${plans[$invocation]}") || return 1
          while IFS= read -r expected; do
            [[ $expected != "$id" ]] || break
            [[ -n ${applied_effects[$invocation:$expected]:-} ]] || return 1
          done <<<"$order"
          expected=$(jq -c 'if .before.kind == "file" and ((.before|del(.identity)) == (.stage.state|del(.identity))) then .before else .stage.state end' <<<"$body") || return 1
          json_is '.[0].body.result == .[1]' "[$document,$expected]" || return 1
          json_is '.[0].body.observed == .[1].before' "[$document,$body]" || return 1
          pending_effects[$invocation:$id]=$expected
        else
          [[ -n ${pending_effects[$invocation:$id]:-} ]] || return 1
          json_is '.[0].body.state == .[1]' "[$document,${pending_effects[$invocation:$id]}]" || return 1
          applied_effects[$invocation:$id]=true
        fi
        ;;
      prepared-terminal|terminal)
        [[ -n ${sessions[$invocation]:-} ]] || return 1
        if json_is '.body.supervision_status == 0' "$document"; then
          json_is '.body.completion_acknowledged and .body.protocol_complete and .body.worker_status == 0 and .body.decoder_status == 0' "$document" || return 1
          ids=$(jq -r '.resources[].id' <<<"${intents[$invocation]}") || return 1
          while IFS= read -r id; do [[ -n ${retained_ids[$invocation:$id]:-} ]] || return 1; done <<<"$ids"
          if json_is 'has("publication")' "${intents[$invocation]}"; then
            [[ -n ${plans[$invocation]:-} ]] || return 1
            if [[ $kind == terminal ]]; then
              [[ -n ${executors[$invocation]:-} ]] || return 1
              ids=$(jq -r '.puts[].id, .configuration.id' <<<"${plans[$invocation]}") || return 1
              while IFS= read -r id; do [[ -n ${applied_effects[$invocation:$id]:-} ]] || return 1; done <<<"$ids"
            fi
          fi
        fi
        if [[ $kind == prepared-terminal ]]; then
          [[ -z ${prepared_terminals[$invocation]:-} ]] || return 1
          prepared_terminals[$invocation]=$(jq -c '.body' <<<"$document") || return 1
        else terminals[$invocation]=true; fi
        ;;
    esac
    if json_is '.kind == "retained"' "$document"; then
      retained=$(jq -c '.body.file' <<<"$document") || return 1
      validate_publication_retained_file "$transaction_id" "$retained" || return 1
      cached_files=$(jq -c --argjson file "$retained" '. + [$file]' <<<"$cached_files") || return 1
    fi
    previous=$reference
  done <<<"$rows"
  [[ -n $pending ]] || _publication_validation_cache[$cache_key]=$cached_files
}

# The first record of a preparatory recovery attempt binds its actual original
# basis. Do not use the root journal's local-file-only cache for cross-root data.
# This validates historical data only, including a hash-bound prior selection;
# the constructor separately proves that selection is current under both locks.
validate_publication_recovery_records() {
  local transaction_id=$1 manifest=$2 pending=${3:-} reference document basis prior
  local _publication_original_basis='' _publication_member_record=''
  json_is '.publication_records | length == 1' "$manifest" || return 1
  reference=$(jq -c '.publication_records[0]' <<<"$manifest") || return 1
  if [[ -n $pending ]]; then
    document=$pending
    json_is '.[0].schema_version == .[1].schema_version' "[$reference,$document]" || return 1
    [[ $(jq -r '.path' <<<"$reference") == "$(dirname "$(lifecycle_manifest_path "$transaction_id")")/publication-1.json" &&
      $(jq -r '.sha256' <<<"$reference") == "$(sha256_text "$document"$'\n')" ]] || return 1
    validate_publication_record_json "$transaction_id" 1 null "$document" || return 1
  else
    publication_read_manifest_member "$transaction_id" "$manifest" "$reference" || return 1
    document=$_publication_member_record
  fi
  json_is '.kind == "recovery-basis" and .schema_version == 2' "$document" || return 1
  basis=$(jq -c '.body.basis' <<<"$document") || return 1
  publication_load_complete_original_basis "$(jq -c '.recovery.root_incident' <<<"$manifest")" \
    "$(jq -r '.invocation' <<<"$document")" || return 1
  json_is '.[0] == .[1]' "[$basis,$_publication_original_basis]" || return 1
  prior=$(publication_capture_hashed_document "$(jq -r '.backups[0].path' <<<"$manifest")" \
    "$(jq -r '.backups[0].sha256' <<<"$manifest")") || return 1
  validate_lifecycle_json "$prior" || return 1
  # Do not recursively validate the prior backup's entire chain here. The chain
  # reader validates every seal/evolution once; recursion would grow with retries.
  # shellcheck disable=SC2016 # jq-local prior/attempt/basis values.
  json_is '.[0] as $prior | .[1] as $attempt | .[2] as $basis |
    $prior.state == "recovery-required" and
    $prior.transaction.root_incident == $attempt.recovery.root_incident and
    $prior.transaction.last_recovery_attempt == $attempt.recovery.previous_attempt and
    $prior.transaction.attempt_count + 1 == $attempt.recovery.attempt_number and
    $prior.transaction.id == $basis.root.id and $prior.transaction.operation == $basis.root_operation and
    $prior.transaction.manifest == ($basis.root.path | sub("/incident.json$"; "/manifest.json"))' \
    "[$prior,$manifest,$basis]"
}

validate_publication_recovery_evolution() {
  local previous=$1 current=$2 previous_record current_record root
  local _publication_member_record=''
  json_is '.kind == "recovery-attempt" and .operation == "publication-recovery" and
    .prior_state == "recovery-required" and .target_state == "active" and
    .file_rollback_policy == "preserve" and .status != "completed" and
    .firmware_backup == null and .enrollment_plan == null and .firmware_writes == []' "$current" || return 1
  validate_publication_recovery_records "$(jq -r '.id' <<<"$current")" "$current" || return 1
  root=$(jq -c '.recovery.root_incident' <<<"$current") || return 1
  if json_is '.kind == "root"' "$previous"; then
    recovery_operation_for_lineage "$previous" publication-recovery >/dev/null || return 1
    json_is '.[0].id == .[1].id and .[0].operation == .[1].operation' "[$previous,$root]"
  else
    json_is '.kind == "recovery-attempt" and .operation == "publication-recovery" and
      .file_rollback_policy == "preserve"' "$previous" || return 1
    json_is '.[0].recovery.root_incident == .[1].recovery.root_incident' "[$previous,$current]" || return 1
    publication_read_manifest_member "$(jq -r '.id' <<<"$previous")" "$previous" \
      "$(jq -c '.publication_records[0]' <<<"$previous")" || return 1
    previous_record=$_publication_member_record
    publication_read_manifest_member "$(jq -r '.id' <<<"$current")" "$current" \
      "$(jq -c '.publication_records[0]' <<<"$current")" || return 1
    current_record=$_publication_member_record
    json_is '.[0].body == .[1].body and .[0].invocation == .[1].invocation' "[$previous_record,$current_record]"
  fi
}

validate_publication_retained_file() {
  local transaction_id=$1 reference=$2 directory path
  directory=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  path=$(jq -er '.path' <<<"$reference") || return 1
  [[ $(dirname "$path") == "$directory" && $(basename "$path") =~ ^publication-data-[0-9a-f-]+-[A-Za-z0-9_-]+$ ]] || return 1
  validate_private_control_file "$path" || return 1
  [[ $(stat -Lc %s "$path") == "$(jq -r '.bytes' <<<"$reference")" && $(sha256_file "$path") == "$(jq -r '.sha256' <<<"$reference")" ]]
}

validate_publication_plan_projection() {
  local intent=$1 stages=$2 plan=$3
  # Data is stdin, not argv: directory bindings can make valid plans sizeable.
  # shellcheck disable=SC2016 # jq-local variables.
  json_is '. as $triple | $triple[0] as $intent | $triple[1] as $stages | $triple[2] as $plan |
    ($intent | has("publication")) and $plan.deletes == [] and $plan.references == [] and
    ($plan.puts | map(.id)) == ($intent.resources | map(.id)) and
    $plan.configuration.id == "configuration" and
    ($stages | keys) == (($intent.resources | map(.id)) + ["configuration"] | sort) and
    ([$stages[].mount_view.namespace] | unique | length) == 1 and
    ([$stages[].mount_view.directories[]] | group_by(.path) | all(.[]; unique | length == 1)) and
    all($plan.puts[], $plan.configuration;
      . as $put | $stages[$put.id] as $stage |
      .target == $stage.target and .before == $stage.before and .after == $stage.stage.state and
      .retained == $stage.retained.path and .parent == $stage.parent)' "[$intent,$stages,$plan]"
}

append_publication_record() {
  local invocation=$1 kind=$2 body=$3 directory ordinal previous document path existing reference candidate timestamp schema
  _publication_record_reference=''
  schema=$PUBLICATION_RECORD_SCHEMA_VERSION
  [[ $kind != invocation-start ]] || schema=$PUBLICATION_INVOCATION_START_SCHEMA_VERSION
  [[ $kind != recovery-basis ]] || schema=$PUBLICATION_RECOVERY_BASIS_SCHEMA_VERSION
  producer_session_context_is_owned || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  json_is '.schema_version == 3 and .status == "transition"' "$_manifest_json" || return 1
  if ! json_is '.file_rollback_policy == "preserve"' "$_manifest_json"; then
    [[ $kind == invocation-start ]] || return 1
    json_is '.file_rollback_policy == "restore" and .publication_records == []' "$_manifest_json" || return 1
  fi
  directory=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  ordinal=$(jq -r '(.publication_records | length)+1' <<<"$_manifest_json") || return 1
  (( ordinal <= MAX_PUBLICATION_RECORDS )) || return 1
  previous=$(jq -c '.publication_records[-1] // null' <<<"$_manifest_json") || return 1
  if [[ $previous != null ]]; then
    path=$(jq -r '.path' <<<"$previous") || return 1
    if [[ $kind == invocation-start ]]; then
      existing=$(publication_capture_hashed_document "$path" "$(jq -r '.sha256' <<<"$previous")") || return 1
    else existing=$(read_control_document "$path") || return 1; fi
    if [[ $(jq -r '.invocation' <<<"$existing") == "$invocation" && $(jq -r '.kind' <<<"$existing") == "$kind" ]] &&
      json_is '.[0].body == .[1]' "[$existing,$body]"; then
      if [[ $kind == invocation-start ]]; then
        validate_publication_retained_file "$_transaction_id" "$(jq -c '.original_configuration' <<<"$body")" || return 1
        durable_sync "$(jq -r '.original_configuration.path' <<<"$body")" || return 1
      fi
      durable_sync "$path" && durable_sync "$directory" && durable_sync "$(lifecycle_manifest_path "$_transaction_id")" || return 1
      producer_session_context_is_owned || return 1
      _publication_record_reference=$previous
      return 0
    fi
  fi
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cse --arg id "$_transaction_id" --arg invocation "$invocation" --arg kind "$kind" \
    --argjson ordinal "$ordinal" --argjson previous "$previous" --argjson schema "$schema" \
    --arg timestamp "$timestamp" --arg version "$OMASECBOOT_VERSION" \
    'if length == 1 then {schema_version:$schema,transaction_id:$id,invocation:$invocation,ordinal:$ordinal,previous:$previous,
      kind:$kind,body:.[0],recorded_at:$timestamp,writer_version:$version} else error("multiple record bodies") end' <<<"$body") || return 1
  validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document" || return 1
  (( $(LC_ALL=C printf '%s\n' "$document" | wc -c) <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  path="$directory/publication-$ordinal.json"
  if [[ -e $path || -L $path ]]; then
    if [[ $kind == invocation-start ]]; then
      existing=$(publication_capture_hashed_document "$path" "$(sha256_file "$path")") || return 1
    else existing=$(read_control_document "$path") || return 1; fi
    validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$existing" || return 1
    json_is '(.[0]|del(.recorded_at)) == (.[1]|del(.recorded_at))' "[$existing,$document]" || return 1
    document=$existing
  fi
  reference=$(jq -cn --arg path "$path" --arg sha256 "$(sha256_text "$document"$'\n')" --argjson schema "$schema" \
    '{path:$path,schema_version:$schema,sha256:$sha256}') || return 1
  # Preflight the complete candidate before creating immutable evidence. Only a
  # schema-2 start may combine the first reference with restore -> preserve.
  candidate=$(jq -c --argjson reference "$reference" '.file_rollback_policy="preserve" | .publication_records += [$reference]' <<<"$_manifest_json") || return 1
  (( $(LC_ALL=C printf '%s\n' "$candidate" | wc -c) <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  validate_transaction_manifest_json "$_transaction_id" "$candidate" false || return 1
  validate_publication_records "$_transaction_id" "$candidate" "$document" || return 1
  if [[ $kind == invocation-start ]]; then
    durable_sync "$(jq -r '.original_configuration.path' <<<"$body")" && durable_sync "$directory" || return 1
    validate_publication_retained_file "$_transaction_id" "$(jq -c '.original_configuration' <<<"$body")" || return 1
  fi
  if [[ ! -e $path && ! -L $path ]]; then
    printf '%s\n' "$document" | atomic_create_control_file "$path" 600 || return 1
  fi
  durable_sync "$path" && durable_sync "$directory" || return 1
  reference=$(transaction_artifact_reference "$path" "$schema") || return 1
  if [[ $kind == invocation-start ]]; then
    existing=$(publication_capture_hashed_document "$path" "$(jq -r '.sha256' <<<"$reference")") || return 1
    json_is '.[0] == .[1]' "[$existing,$document]" || return 1
  fi
  read_transaction_manifest "$_transaction_id" || return 1
  json_is ".publication_records | length == $((ordinal-1))" "$_manifest_json" || return 1
  json_is '.[0].publication_records[-1] == .[1]' "[$_manifest_json,$previous]" || return 1
  candidate=$(jq -c --argjson reference "$reference" '.file_rollback_policy="preserve" | .publication_records += [$reference]' <<<"$_manifest_json") || return 1
  producer_session_context_is_owned || return 1
  write_transaction_manifest_json "$candidate" || return 1
  durable_sync "$(lifecycle_manifest_path "$_transaction_id")" && durable_sync "$directory" || return 1
  _publication_record_reference=$reference
}

# The Core caller retains/syncs the original byte copy. This writer validates
# that reference and binds all original authority with one manifest replacement.
append_publication_invocation_start() {
  _publication_record_reference=''
  [[ $# == 4 ]] || return 1
  local invocation=$1 intent=$2 context=$3 original_configuration=$4 body
  body=$(jq -cse 'if length == 1 and (.[0] | length) == 3 then
    .[0] | {intent:.[0],context:.[1],original_configuration:.[2],
      recovery:{recreate_missing:([.[0].resources[] | {id,target}] +
        [{id:"configuration",target:.[0].configuration.path}])}}
    else error("expected original invocation authority") end' <<<"[$intent,$context,$original_configuration]") || return 1
  append_publication_record "$invocation" invocation-start "$body"
}

find_publication_record() {
  local invocation=$1 kind=$2 id=${3:-} references reference document found_invocation found_kind found_id
  _publication_found_body=''
  _publication_found_reference=''
  read_transaction_manifest "$_transaction_id" || return 2
  references=$(jq -c '.publication_records[]' <<<"$_manifest_json") || return 2
  while IFS= read -r reference; do
    [[ -n $reference ]] || continue
    document=$(read_control_document "$(jq -r '.path' <<<"$reference")") || return 2
    found_invocation=$(jq -er '.invocation' <<<"$document") || return 2
    found_kind=$(jq -er '.kind' <<<"$document") || return 2
    [[ $found_invocation == "$invocation" && $found_kind == "$kind" ]] || continue
    if [[ -n $id ]]; then
      found_id=$(jq -er '.body.id' <<<"$document") || return 2
      [[ $found_id == "$id" ]] || continue
    fi
    _publication_found_body=$(jq -c '.body' <<<"$document") || return 2
    _publication_found_reference=$reference
    return 0
  done <<<"$references"
  return 1
}

# Status 0 exposes a typed view, its REAL containing record reference and exact
# projection. Legacy intent/context use .body; schema-2 starts use .body.PART.
# Status 1 is absent (legacy recovery/original bytes are never invented); status
# 2 is invalid evidence/input. All outputs are empty on either failure.
find_publication_authority_part() {
  local invocation part references reference document body container projection
  local _publication_member_record=''
  _publication_found_body='' _publication_found_reference=''
  _publication_found_container_kind='' _publication_found_projection=''
  [[ $# == 2 ]] || return 2
  invocation=$1 part=$2
  [[ $invocation =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 2
  case $part in intent|context|recovery|original_configuration) ;; *) return 2 ;; esac
  read_transaction_manifest "$_transaction_id" || return 2
  references=$(jq -c '.publication_records[]?' <<<"$_manifest_json") || return 2
  while IFS= read -r reference; do
    [[ -n $reference ]] || continue
    publication_read_manifest_member "$_transaction_id" "$_manifest_json" "$reference" || return 2
    document=$_publication_member_record
    json_is ".invocation == \"$invocation\"" "$document" || continue
    container=$(jq -r '.kind' <<<"$document") || return 2
    if [[ $container == invocation-start ]]; then projection=".body.$part"
    elif [[ $container == "$part" && ( $part == intent || $part == context ) ]]; then projection=.body
    else continue; fi
    body=$(jq -ce "$projection" <<<"$document") || return 2
    _publication_found_body=$body
    _publication_found_reference=$reference
    _publication_found_container_kind=$container
    _publication_found_projection=$projection
    return 0
  done <<<"$references"
  return 1
}

# A post-rename sync failure can leave the next canonical record unbound. It is
# only a candidate until append_publication_record validates and durably binds it.
find_pending_publication_record() {
  local invocation=$1 kind=$2 id=$3 ordinal previous path document
  read_transaction_manifest "$_transaction_id" || return 2
  ordinal=$(jq -r '(.publication_records|length)+1' <<<"$_manifest_json") || return 2
  previous=$(jq -c '.publication_records[-1] // null' <<<"$_manifest_json") || return 2
  path="$(dirname "$(lifecycle_manifest_path "$_transaction_id")")/publication-$ordinal.json"
  [[ -e $path || -L $path ]] || return 1
  validate_private_control_file "$path" || return 2
  document=$(read_control_document "$path") || return 2
  validate_publication_record_json "$_transaction_id" "$ordinal" "$previous" "$document" || return 2
  [[ $(jq -r '.invocation' <<<"$document") == "$invocation" && $(jq -r '.kind' <<<"$document") == "$kind" \
    && $(jq -r '.body.id // ""' <<<"$document") == "$id" ]] || return 2
  _publication_found_body=$(jq -c '.body' <<<"$document") || return 2
}

sync_publication_reference() {
  local reference=$1 path directory
  producer_session_context_is_owned || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  # shellcheck disable=SC2016 # jq-local variable, not a shell expansion.
  json_is '. as $pair | $pair[0].publication_records | index($pair[1]) != null' "[$_manifest_json,$reference]" || return 1
  directory=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  validate_artifact_reference_file "$reference" "$directory" || return 1
  path=$(jq -r '.path' <<<"$reference") || return 1
  durable_sync "$path" && durable_sync "$(lifecycle_manifest_path "$_transaction_id")" && durable_sync "$directory" || return 1
  producer_session_context_is_owned
}

transaction_artifact_reference() {
  local path="$1" schema_version="${2:-1}" hash
  [[ "$schema_version" =~ ^[1-9][0-9]*$ ]] || return 1
  validate_private_control_file "$path" || return 1
  hash=$(sha256_file "$path") || return 1
  jq -cn --arg path "$path" --arg hash "$hash" \
    --argjson schema "$schema_version" '{
      path: $path,
      schema_version: $schema,
      sha256: $hash
    }'
}

validate_artifact_reference_file() {
  local reference="$1" owner_dir="${2:-$(state_dir_path)}" path hash
  path=$(jq -r '.path' <<< "$reference") || return 1
  hash=$(jq -r '.sha256' <<< "$reference") || return 1
  [[ "$path" == "${owner_dir}/"* && "$path" != *'/../'* ]] || return 1
  path_has_no_symlink_components "$path" || return 1
  validate_private_control_file "$path" || return 1
  [[ "$(sha256_file "$path")" == "$hash" ]]
}

# Validates a transaction-local domain record reference: schema, canonical
# filename inside the transaction directory, file hash, then the document
# through the named validator, which receives any extra arguments.
validate_domain_reference() {
  local transaction_id="$1" reference="$2" schema="$3" filename="$4" validator="$5"
  shift 5
  local transaction_dir path document
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  [[ $(jq -r '.schema_version' <<< "$reference") == "$schema" \
    && "$path" == "${transaction_dir}/${filename}" ]] || return 1
  validate_artifact_reference_file "$reference" "$transaction_dir" || return 1
  document=$(read_control_document "$path") || return 1
  [[ $(document_schema_version "$document") == "$schema" ]] || return 1
  "$validator" "$transaction_id" "$document" "$@"
}

reference_transaction_id() {
  local reference="$1" filename="$2" path transaction_dir transaction_id
  path=$(jq -r '.path' <<< "$reference") || return 1
  transaction_dir=$(dirname "$path") || return 1
  [[ "$(dirname "$transaction_dir")" == "$(transactions_dir_path)" \
    && "$(basename "$path")" == "$filename" ]] || return 1
  transaction_id=$(basename "$transaction_dir") || return 1
  lifecycle_manifest_path "$transaction_id" >/dev/null || return 1
  printf '%s\n' "$transaction_id"
}

validate_lifecycle_ownership_pair() {
  local managed="$1" tracking="$2" managed_id tracking_id
  if [[ "$managed" == null || "$tracking" == null ]]; then
    [[ "$managed" == null && "$tracking" == null ]]
    return
  fi
  managed_id=$(reference_transaction_id "$managed" managed-settings.json) || return 1
  tracking_id=$(reference_transaction_id "$tracking" tracking-ownership.json) || return 1
  [[ "$managed_id" == "$tracking_id" ]] || return 1
  validate_managed_settings_record_reference "$managed_id" "$managed" || return 1
  validate_tracking_ownership_record_reference "$tracking_id" "$tracking"
}

validate_managed_settings_record_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson schema "$MANAGED_SETTINGS_SCHEMA_VERSION" "$OMASECBOOT_JQ_DEFS"'
    type == "object" and
    keys == ["recorded_at","schema_version","settings","source","transaction_id",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.recorded_at | timestamp) and
    (.source == "adoption" or .source == "repair" or .source == "setup") and
    (.settings | type == "array" and length == 4) and
    (.settings[0] |
      keys == ["key","managed","original","path"] and
      .path == "/etc/default/limine" and .key == "ENABLE_VERIFICATION" and
      (.managed == "yes" or .managed == "no" or .managed == "unset") and
      (.original == "yes" or .original == "no" or .original == "unset" or
        .original == "unknown")) and
    (.settings[1] |
      keys == ["key","managed","original","path"] and
      .path == "/etc/default/limine" and .key == "ENABLE_ENROLL_LIMINE_CONFIG" and
      (.managed == "yes" or .managed == "no" or .managed == "unset") and
      (.original == "yes" or .original == "no" or .original == "unset" or
        .original == "unknown")) and
    (.settings[2] |
      keys == ["key","managed","original","path","token"] and
      .path == "/etc/default/limine" and .key == "COMMANDS_BEFORE_SAVE" and
      .token == "limine-reset-enroll" and
      (.managed == "present" or .managed == "absent") and
      (.original == "present" or .original == "absent" or .original == "unknown")) and
    (.settings[3] |
      keys == ["key","managed","original","path","token"] and
      .path == "/etc/default/limine" and .key == "COMMANDS_AFTER_SAVE" and
      .token == "limine-enroll-config" and
      (.managed == "present" or .managed == "absent") and
      (.original == "present" or .original == "absent" or .original == "unknown"))
  ' <<< "$document" >/dev/null
}

validate_managed_settings_record_reference() {
  validate_domain_reference "$1" "$2" "$MANAGED_SETTINGS_SCHEMA_VERSION" managed-settings.json validate_managed_settings_record_json
}

validate_tracking_ownership_record_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson schema "$TRACKING_OWNERSHIP_SCHEMA_VERSION" \
    --argjson maximum "$MAX_EXPECTED_EFI_ARTIFACTS" "$OMASECBOOT_JQ_DEFS"'
    type == "object" and
    keys == ["paths","recorded_at","schema_version","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.recorded_at | timestamp) and
    (.paths | type == "array" and length <= $maximum and all(.[]; absolute_path) and
      . == sort and length == (unique | length) and
      (map(ascii_downcase) | length == (unique | length)))
  ' <<< "$document" >/dev/null
}

validate_tracking_ownership_record_reference() {
  validate_domain_reference "$1" "$2" "$TRACKING_OWNERSHIP_SCHEMA_VERSION" tracking-ownership.json validate_tracking_ownership_record_json
}

# The recorded tool version is historical evidence and is checked for shape
# only; whether the tools may run again is proved against the installed
# package when they are executed.
unconfigure_record_schema() {
  local schema
  schema=$(document_schema_version "$1") || return 1
  [[ "$schema" == 1 || "$schema" == 2 ]] || return 1
  printf '%s\n' "$schema"
}

# Call only after validating the intent. This interprets historical data in
# memory and never adds a field to the hash-bound schema-1 document.
unconfigure_intent_fallback_state() {
  local schema
  schema=$(unconfigure_record_schema "$1") || return 1
  if [[ "$schema" == 1 ]]; then
    printf 'managed\n'
  else
    jq -er '.limine_fallback | select(. == "managed" or . == "absent")' <<< "$1"
  fi
}

validate_unconfigure_intent_json() {
  local transaction_id="$1" document="$2" manifest="$3" prior_path prior_lifecycle
  local managed tracking schema
  schema=$(unconfigure_record_schema "$document") || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$schema" \
    --arg source "$(limine_unsigned_binary_path)" \
    --arg install "$(limine_install_path)" \
    --arg mkinitcpio "$(limine_mkinitcpio_path)" \
    --arg reset "$(limine_reset_enroll_path)" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS"'
    type == "object" and
    (if $schema == 1 then
      keys == ["limine_source","limine_tools","managed_settings","operation",
        "recorded_at","schema_version","tracking_ownership","transaction_id",
        "windows_state_identity","writer_version"]
     else
      keys == ["limine_fallback","limine_source","limine_tools","managed_settings","operation",
        "recorded_at","schema_version","tracking_ownership","transaction_id",
        "windows_state_identity","writer_version"] and
      (.limine_fallback == "managed" or .limine_fallback == "absent")
     end) and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "unconfigure" and (.recorded_at | timestamp) and
    (.managed_settings | artifact_reference) and
    (.tracking_ownership | artifact_reference) and
    (.limine_source | type == "object" and keys == ["identity","path","sha256"] and
      .path == $source and (.identity | identity) and (.sha256 | digest)) and
    (.limine_tools | type == "object" and
      keys == ["install","mkinitcpio","package","reset","version"] and
      .package == "limine-mkinitcpio-hook" and
      (.version | type == "string" and length > 0 and length <= 64 and
        test("^[0-9A-Za-z][0-9A-Za-z.+:~-]*$")) and
      (.install | type == "object" and keys == ["identity","path","sha256"] and
        .path == $install and (.identity | identity) and (.sha256 | digest)) and
      (.mkinitcpio | type == "object" and keys == ["identity","path","sha256"] and
        .path == $mkinitcpio and (.identity | identity) and (.sha256 | digest)) and
      (.reset | type == "object" and keys == ["identity","path","sha256"] and
        .path == $reset and (.identity | identity) and (.sha256 | digest))) and
    (.windows_state_identity == "absent" or
      (.windows_state_identity | test("^present:[0-9]+:[0-9]+:[0-9a-f]{64}$"))) and
    $manifest.kind == "root" and $manifest.operation == "unconfigure" and
    $manifest.prior_state == "active" and $manifest.target_state == "disabled"
  ' <<< "$document" >/dev/null || return 1
  prior_path=$(jq -r '.backups[0].path' <<< "$manifest") || return 1
  prior_lifecycle=$(read_control_document "$prior_path") || return 1
  validate_lifecycle_json "$prior_lifecycle" || return 1
  managed=$(jq -c '.managed_settings' <<< "$prior_lifecycle") || return 1
  tracking=$(jq -c '.tracking_ownership' <<< "$prior_lifecycle") || return 1
  [[ "$managed" != null && "$tracking" != null ]] || return 1
  validate_lifecycle_ownership_pair "$managed" "$tracking" || return 1
  jq -en --argjson intent "$document" --argjson managed "$managed" \
    --argjson tracking "$tracking" '
      $intent.managed_settings == $managed and $intent.tracking_ownership == $tracking
    ' >/dev/null
}

validate_unconfigure_intent_reference() {
  local schema
  schema=$(unconfigure_record_schema "$2") || return 1
  validate_domain_reference "$1" "$2" "$schema" unconfigure-intent.json validate_unconfigure_intent_json "$3"
}

validate_unconfigure_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" zero_checksum root intent
  local intent_document schema fallback_state
  schema=$(unconfigure_record_schema "$document") || return 1
  zero_checksum=$(printf '0%.0s' {1..128})
  if [[ $(jq -r '.kind' <<< "$manifest") == root ]]; then
    root="$manifest"
  else
    root=$(recovery_root_manifest_from_reference \
      "$(jq -c '.recovery.root_incident' <<< "$manifest")") || return 1
  fi
  intent=$(jq -c '.domain_records.unconfigure' <<< "$root") || return 1
  [[ "$intent" != null ]] || return 1
  intent_document=$(read_control_document "$(jq -r '.path' <<< "$intent")") || return 1
  validate_unconfigure_intent_json "$(jq -r '.id' <<< "$root")" "$intent_document" "$root" \
    || return 1
  fallback_state=$(unconfigure_intent_fallback_state "$intent_document") || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$schema" \
    --arg fallback_state "$fallback_state" \
    --arg zero "$zero_checksum" --arg primary "$(limine_primary_binary_path)" \
    --arg fallback "$(limine_fallback_binary_path)" \
    --arg source "$(limine_unsigned_binary_path)" --argjson manifest "$manifest" \
    --argjson intent "$intent" --argjson intent_document "$intent_document" "$OMASECBOOT_JQ_DEFS"'
    def target($path):
      type == "object" and keys == ["config_checksum","path","sha256"] and
      .path == $path and .config_checksum == $zero and (.sha256 | digest);
    def source:
      type == "object" and keys == ["path","sha256"] and
      .path == $source and (.sha256 | digest);
    type == "object" and
    keys == ["intent","limine","managed_settings","operation","proved_at","root_incident",
      "schema_version","secure_boot","settings","tracking_ownership","transaction_id",
      "windows","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    ($schema != 1 or $intent.schema_version == 1) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.operation == "unconfigure" or .operation == "unconfigure-recovery") and
    (.proved_at | timestamp) and .secure_boot == 0 and
    .settings == "original" and .windows == "managed-block-absent" and
    .intent == $intent and
    .managed_settings == $intent_document.managed_settings and
    .tracking_ownership == $intent_document.tracking_ownership and
    (.managed_settings | artifact_reference) and (.tracking_ownership | artifact_reference) and
    (.limine | type == "object" and keys == ["fallback","primary","source"] and
      (.source | source) and (.primary | target($primary)) and
      (if $fallback_state == "managed"
       then (.fallback | target($fallback)) and .fallback.sha256 == .source.sha256
       else .fallback == null end) and
      .source.sha256 == $intent_document.limine_source.sha256 and
      .primary.sha256 == .source.sha256) and
    (if $manifest.kind == "root" then
      .operation == "unconfigure" and .root_incident == null and
      $manifest.operation == "unconfigure" and $manifest.prior_state == "active" and
      $manifest.target_state == "disabled" and $manifest.file_rollback_policy == "preserve"
     else
      .operation == "unconfigure-recovery" and
      .root_incident == $manifest.recovery.root_incident and
      $manifest.kind == "recovery-attempt" and
      $manifest.operation == "unconfigure-recovery" and
      $manifest.target_state == "disabled" and
      $manifest.file_rollback_policy == "preserve"
     end)
  ' <<< "$document" >/dev/null
}

validate_unconfigure_proof_reference() {
  local schema
  schema=$(unconfigure_record_schema "$2") || return 1
  validate_domain_reference "$1" "$2" "$schema" final-proof.json validate_unconfigure_proof_json "$3"
}

validate_producer_record_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson owner_uid "$(control_owner_uid)" \
    --argjson schema "$PRODUCER_RECORD_SCHEMA_VERSION" "$OMASECBOOT_JQ_DEFS"'
    def process_identity:
      type == "object" and
      keys == ["boot_id","identity","identity_kind","pid","start_time","uid"] and
      (.boot_id | uuid) and (.identity | absolute_path) and
      (.identity_kind == "executable" or .identity_kind == "script") and
      (.pid | type == "number" and . > 0 and floor == .) and
      (.start_time | type == "string" and test("^[0-9]+$") and length <= 32) and
      .uid == $owner_uid;
    type == "object" and
    keys == ["caller","created_at","operation","owner","producer_class","schema_version",
      "subtype","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.created_at | timestamp) and (.operation | operation) and
    (.owner | process_identity) and
    (.caller | type == "string" and length > 0 and length <= 64 and
      test("^[a-z0-9][a-z0-9-]*$")) and
    if .producer_class == "package" then
      .operation == "producer-package" and .subtype == "package-transaction" and
      .owner.identity_kind == "executable" and .owner.identity == "/usr/bin/pacman" and
      .caller == "pacman"
    elif .producer_class == "limine" then
      ((.subtype == "entry-tool" and .owner.identity == "/usr/bin/limine-entry-tool" and
          .caller == "limine-entry-tool") or
       (.subtype == "uki-build" and
          .owner.identity == "/usr/share/libalpm/scripts/limine-mkinitcpio-install" and
          .caller == "limine-mkinitcpio-install")) and
      .operation == "producer-limine" and .owner.identity_kind == "script"
    elif .producer_class == "snapshot" then
      .operation == "producer-snapshot" and .subtype == "snapshot-sync" and
      .owner.identity_kind == "script" and
      .owner.identity == "/usr/bin/limine-snapper-sync" and .caller == "limine-snapper-sync"
    elif .producer_class == "restore" then
      .operation == "producer-restore" and .subtype == "full-restore" and
      .owner.identity_kind == "script" and
      .owner.identity == "/usr/bin/limine-snapper-sync" and
      (.caller == "limine-snapper-sync" or .caller == "limine-snapper-restore")
    else false end
  ' <<< "$document" >/dev/null
}

validate_producer_record_reference() {
  validate_domain_reference "$1" "$2" "$PRODUCER_RECORD_SCHEMA_VERSION" producer.json validate_producer_record_json
}

validate_final_proof_json() {
  local transaction_id="$1" document="$2"
  [[ $(document_schema_version "$document") == "$FINAL_PROOF_SCHEMA_VERSION" ]] || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$FINAL_PROOF_SCHEMA_VERSION" "$OMASECBOOT_JQ_DEFS"'
    type == "object" and
    keys == ["artifacts","config","proved_at","schema_version","transaction_id",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.proved_at | timestamp) and
    (.config | type == "object" and keys == ["checksum","identity","path","sha256"] and
      (.checksum | checksum) and (.identity | identity) and (.path | absolute_path) and
      (.sha256 | digest)) and
    (.artifacts | type == "array" and length > 0 and length <= 4096) and
    (all(.artifacts[];
      type == "object" and keys == ["identity","path","sha256","signature","tracking"] and
      (.identity | identity) and (.path | absolute_path) and (.sha256 | digest) and
      .signature == "local" and .tracking == "tracked")) and
    ([.artifacts[].path] == ([.artifacts[].path] | sort | unique))
  ' <<< "$document" >/dev/null
}

validate_final_proof_reference() {
  validate_domain_reference "$1" "$2" "$FINAL_PROOF_SCHEMA_VERSION" final-proof.json validate_final_proof_json
}

validate_firmware_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" writes writes_hash
  writes=$(jq -cS '.firmware_writes' <<< "$manifest") || return 1
  writes_hash=$(sha256_text "$writes") || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$FIRMWARE_PROOF_SCHEMA_VERSION" \
    --argjson final_schema "$FINAL_PROOF_SCHEMA_VERSION" \
    --arg writes_hash "$writes_hash" --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS"'
    def proof_reference:
      type == "object" and keys == ["path","schema_version","sha256"] and
      (.path | absolute_path) and .schema_version == $final_schema and (.sha256 | digest);
    type == "object" and
    keys == ["artifact_proof","enrollment_plan","firmware_backup","firmware_writes_sha256",
      "modes","proved_at","schema_version","transaction_id","variables","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.proved_at | timestamp) and
    (.firmware_backup | type == "object" and keys == ["id","manifest_sha256","path"] and
      (.id | uuid) and (.manifest_sha256 | digest) and (.path | absolute_path)) and
    (.enrollment_plan | type == "object" and
      keys == ["backup_id","manifest_sha256","path"] and
      (.backup_id | uuid) and (.manifest_sha256 | digest) and (.path | absolute_path)) and
    (.variables | type == "object" and keys == ["KEK","PK","db","dbx"] and
      (all(.PK,.KEK,.db;
        type == "object" and keys == ["entries_sha256"] and (.entries_sha256 | digest))) and
      (.dbx | type == "object" and keys == ["present","raw_sha256"] and
        (.present | type == "boolean") and
        (if .present then (.raw_sha256 | digest) else .raw_sha256 == null end))) and
    (.modes | type == "object" and
      keys == ["AuditMode","DeployedMode","SecureBoot","SetupMode"] and
      (.AuditMode == 0 or .AuditMode == null) and
      (.DeployedMode == 0 or .DeployedMode == null) and
      .SecureBoot == 0 and .SetupMode == 0) and
    .firmware_writes_sha256 == $writes_hash and
    (.artifact_proof | proof_reference) and
    .firmware_backup == {
      id: $manifest.firmware_backup.id,
      manifest_sha256: $manifest.firmware_backup.manifest_sha256,
      path: $manifest.firmware_backup.path
    } and
    .enrollment_plan == {
      backup_id: $manifest.enrollment_plan.backup_id,
      manifest_sha256: $manifest.enrollment_plan.manifest_sha256,
      path: $manifest.enrollment_plan.path
    } and
    .variables == {
      PK: {entries_sha256: $manifest.enrollment_plan.variables.PK.entries_sha256},
      KEK: {entries_sha256: $manifest.enrollment_plan.variables.KEK.entries_sha256},
      db: {entries_sha256: $manifest.enrollment_plan.variables.db.entries_sha256},
      dbx: $manifest.enrollment_plan.dbx
    } and
    .artifact_proof == $manifest.domain_records.final_proof
  ' <<< "$document" >/dev/null
}

validate_firmware_proof_reference() {
  validate_domain_reference "$1" "$2" "$FIRMWARE_PROOF_SCHEMA_VERSION" firmware-proof.json validate_firmware_proof_json "$3"
}

validate_bootnext_record_json() {
  local transaction_id="$1" document="$2" manifest="$3"
  jq -e --arg id "$transaction_id" \
    --argjson schema "$BOOTNEXT_RECORD_SCHEMA_VERSION" \
    --arg executable "$WINDOWS_EFIBOOTMGR_EXECUTABLE" \
    --arg loader "$WINDOWS_BOOTNEXT_LOADER_PATH" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS"'
    def safe_label:
      type == "string" and length >= 1 and length <= 127 and
      test("^[A-Za-z0-9][A-Za-z0-9 ._()+&-]{0,126}$") and
      (endswith(" ") | not) and (contains("${") | not);
    type == "object" and
    keys == ["boot_id","efibootmgr","operation","prior","recorded_at","schema_version",
      "target","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "windows-bootnext" and (.boot_id | uuid) and
    .boot_id == $manifest.boot_id and (.recorded_at | timestamp) and
    (.efibootmgr | type == "object" and
      keys == ["executable","executable_sha256","package"] and
      (.package | type == "string" and length > 0 and length <= 128) and
      .executable == $executable and (.executable_sha256 | digest)) and
    (.target | type == "object" and
      keys == ["boot_number","label","loader_path","partuuid"] and
      (.boot_number | boot_number) and (.label | safe_label) and
      (.partuuid | type == "string" and
        test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      .loader_path == $loader) and
    (.prior | type == "object" and keys == ["boot_number","present"] and
      (.present | type == "boolean") and
      (if .present then (.boot_number | boot_number) else .boot_number == null end))
  ' <<< "$document" >/dev/null
}

validate_bootnext_record_reference() {
  validate_domain_reference "$1" "$2" "$BOOTNEXT_RECORD_SCHEMA_VERSION" bootnext.json validate_bootnext_record_json "$3"
}

# Windows BootNext records: an observed variable state and a bound record.
readonly WINDOWS_STATE_JQ_DEFS='
  def state:
    type == "object" and keys == ["boot_number","present"] and
    (.present | type == "boolean") and
    (if .present then (.boot_number | boot_number) else .boot_number == null end);
  def reference:
    type == "object" and keys == ["path","schema_version","sha256"] and
    (.path | absolute_path) and .schema_version == 1 and (.sha256 | digest);
'

validate_windows_recovery_record_json() {
  local transaction_id="$1" document="$2" manifest="$3"
  local root_id root_manifest_path root_manifest bootnext_reference bootnext_path
  local bootnext_document
  jq -e --arg id "$transaction_id" \
    --argjson schema "$WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION" \
    --arg efibootmgr_executable "$WINDOWS_EFIBOOTMGR_EXECUTABLE" \
    --arg variable_path "$(windows_bootnext_variable_path)" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS$WINDOWS_STATE_JQ_DEFS"'
    def incident:
      type == "object" and
      keys == ["id","kind","operation","ordinal","path","sha256","status"] and
      (.id | uuid) and .kind == "root" and .operation == "windows-bootnext" and
      .ordinal == 0 and (.path | type == "string" and startswith("/")) and
      (.sha256 | digest) and
      (.status == "failed" or .status == "stale" or .status == "publication-uncertain");
    def tool:
      type == "object" and keys == ["executable","executable_sha256","package"] and
      (.executable_sha256 | digest);
    type == "object" and
    keys == ["action","bootnext_record","observed","operation","planned_outcome","prior",
      "recorded_at","recovery_boot_id","relation","root_boot_id","root_incident",
      "schema_version","target","tool","transaction_id","variable","write_frontier",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "windows-recovery" and (.recorded_at | timestamp) and
    (.recovery_boot_id | uuid) and .recovery_boot_id == $manifest.boot_id and
    (.root_incident | incident) and .root_incident == $manifest.recovery.root_incident and
    if .bootnext_record == null then
      .root_boot_id == null and .relation == null and .prior == null and .target == null and
      .observed == null and .action == "none" and
      .planned_outcome == "not-published" and .tool == null and .variable == null and
      .write_frontier == "not-published"
    else
      (.bootnext_record | reference) and (.root_boot_id | uuid) and
      (.relation == "same-boot" or .relation == "later-boot") and
      .relation == (if .root_boot_id == .recovery_boot_id then "same-boot" else "later-boot" end) and
      (.prior | state) and (.target | boot_number) and (.observed | state) and
      (.write_frontier == "not-reached" or .write_frontier == "write-possible") and
      (if .write_frontier == "not-reached" then
        .observed == .prior and .action == "none" and
        .planned_outcome == "prior-unchanged" and .tool == null and .variable == null
       elif .relation == "later-boot" and .observed.present == false then
        .action == "none" and .planned_outcome == "consumed-unknown" and
        .tool == null and .variable == null
       elif .observed == .prior then
        .action == "none" and .planned_outcome == "prior-unchanged" and
        .tool == null and .variable == null
       elif .observed.present and .observed.boot_number == .target and
           (.observed != .prior) then
        .planned_outcome == "prior-restored" and
        if .prior.present then
          .action == "set-prior" and .variable == null and (.tool | tool) and
          .tool.executable == $efibootmgr_executable
        else
          .action == "delete" and .tool == null and
          (.variable | type == "object" and keys == ["identity","path","sha256"] and
            .path == $variable_path and (.identity | identity) and (.sha256 | digest))
        end
       else false end)
    end
  ' <<< "$document" >/dev/null || return 1

  root_id=$(jq -r '.root_incident.id' <<< "$document") || return 1
  root_manifest_path=$(lifecycle_manifest_path "$root_id") || return 1
  root_manifest=$(read_control_document "$root_manifest_path") || return 1
  validate_transaction_manifest_json "$root_id" "$root_manifest" false || return 1
  jq -e '
    .kind == "root" and .operation == "windows-bootnext" and
    .target_state == "active" and .prior_state == "active" and
    .domain_records.producer == null
  ' <<< "$root_manifest" >/dev/null || return 1
  bootnext_reference=$(jq -c '.domain_records.bootnext' <<< "$root_manifest") || return 1
  jq -e --argjson reference "$bootnext_reference" --argjson root "$root_manifest" '
    .bootnext_record == $reference and
    .write_frontier ==
      (if $reference == null then "not-published"
       elif ($root.completed_phases | index("record-bootnext")) == null then "not-reached"
       else "write-possible" end)
  ' \
    <<< "$document" >/dev/null || return 1
  if [[ "$bootnext_reference" == null ]]; then
    return 0
  fi
  validate_bootnext_record_reference "$root_id" "$bootnext_reference" "$root_manifest" \
    || return 1
  bootnext_path=$(jq -r '.path' <<< "$bootnext_reference") || return 1
  bootnext_document=$(read_control_document "$bootnext_path") || return 1
  jq -e --argjson recovery "$document" '
    .boot_id == $recovery.root_boot_id and .prior == $recovery.prior and
    .target.boot_number == $recovery.target and
    (if $recovery.action == "set-prior" then
      .efibootmgr == $recovery.tool
     else true end)
  ' <<< "$bootnext_document" >/dev/null
}

validate_windows_recovery_record_reference() {
  validate_domain_reference "$1" "$2" "$WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION" windows-recovery.json validate_windows_recovery_record_json "$3"
}

validate_windows_recovery_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" reference path record
  jq -e --arg id "$transaction_id" \
    --argjson schema "$WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS$WINDOWS_STATE_JQ_DEFS"'
    type == "object" and
    keys == ["command_exit_code","final_state","operation","outcome","proved_at","record",
      "schema_version","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "windows-recovery" and (.proved_at | timestamp) and
    (.record | reference) and .record == $manifest.domain_records.windows and
    (.outcome == "not-published" or .outcome == "prior-unchanged" or
      .outcome == "prior-restored" or .outcome == "consumed-unknown") and
    (.final_state == null or (.final_state | state)) and
    (.command_exit_code == null or
      (.command_exit_code | type == "number" and . >= 0 and . <= 255 and floor == .))
  ' <<< "$document" >/dev/null || return 1
  reference=$(jq -c '.record' <<< "$document") || return 1
  validate_windows_recovery_record_reference "$transaction_id" "$reference" "$manifest" \
    || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  record=$(read_control_document "$path") || return 1
  jq -e --argjson record "$record" '
    .outcome == $record.planned_outcome and
    (if $record.action == "none" then .command_exit_code == null
     else .command_exit_code != null end) and
    (if .outcome == "not-published" then .final_state == null
     elif .outcome == "consumed-unknown" then
       .final_state == {boot_number:null,present:false}
     else .final_state == $record.prior end)
  ' <<< "$document" >/dev/null
}

validate_windows_recovery_proof_reference() {
  validate_domain_reference "$1" "$2" "$WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION" windows-recovery-proof.json validate_windows_recovery_proof_json "$3"
}

# Publishes one domain record of the current transaction exactly once: the
# document is validated, created if absent, compared with an existing copy
# ignoring the listed volatile keys, and bound into the manifest. Idempotent,
# so recovery phases may call it again.
persist_transaction_domain_record() {
  local name="$1" filename="$2" schema="$3" validator="$4" ignore="$5" document="$6"
  local path existing reference current_reference
  [[ "$_transaction_active" == true ]] || return 1
  path="$(dirname "$(lifecycle_manifest_path "$_transaction_id")")/${filename}"
  read_transaction_manifest "$_transaction_id" || return 1
  "$validator" "$_transaction_id" "$document" "$_manifest_json" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    existing=$(read_control_document "$path") || return 1
    "$validator" "$_transaction_id" "$existing" "$_manifest_json" || return 1
    jq -en --argjson existing "$existing" --argjson candidate "$document" \
      --argjson ignore "$ignore" '
      ($existing | delpaths($ignore | map([.]))) ==
        ($candidate | delpaths($ignore | map([.])))
    ' >/dev/null || return 1
  else
    printf '%s\n' "$document" | atomic_create_control_file "$path" 600 || return 1
  fi
  reference=$(transaction_artifact_reference "$path" "$schema") || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  current_reference=$(jq -c --arg name "$name" '.domain_records[$name]' \
    <<< "$_manifest_json") || return 1
  if [[ "$current_reference" == null ]]; then
    transaction_set_domain_record "$name" "$reference" || return 1
  else
    [[ "$(jq -Sc . <<< "$current_reference")" == "$(jq -Sc . <<< "$reference")" ]] \
      || return 1
  fi
  _persisted_record_reference="$reference"
}

persist_managed_settings_record() {
  local source="$1" settings="$2" timestamp document
  [[ "$source" == adoption || "$source" == repair || "$source" == setup ]] || return 1
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$MANAGED_SETTINGS_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg timestamp "$timestamp" \
    --arg source "$source" \
    --argjson settings "$settings" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      recorded_at: $timestamp,
      source: $source,
      settings: $settings
    }') || return 1
  persist_transaction_domain_record managed_settings managed-settings.json \
    "$MANAGED_SETTINGS_SCHEMA_VERSION" validate_managed_settings_record_json \
    '["writer_version","recorded_at"]' "$document"
}

persist_tracking_ownership_record() {
  local paths="$1" timestamp document
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$TRACKING_OWNERSHIP_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg timestamp "$timestamp" \
    --argjson paths "$paths" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      recorded_at: $timestamp,
      paths: $paths
    }') || return 1
  persist_transaction_domain_record tracking_ownership tracking-ownership.json \
    "$TRACKING_OWNERSHIP_SCHEMA_VERSION" validate_tracking_ownership_record_json \
    '["writer_version","recorded_at"]' "$document"
}

# Hash and parse the same bounded byte capture. Base64 keeps raw NUL and trailing
# newlines observable until jq parses them; data never becomes an external argv.
publication_capture_hashed_document() (
  set -o pipefail
  local path=$1 expected=$2 encoded size hash document LC_ALL=C
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || return 1
  validate_private_control_file "$path" || return 1
  encoded=$(/usr/bin/timeout --kill-after=1 5 /usr/bin/dd if="$path" bs=65536 \
    iflag=count_bytes,nonblock,nofollow count="$((MAX_CONTROL_DOCUMENT_BYTES+1))" status=none | base64 --wrap=0) || return 1
  size=$(printf '%s' "$encoded" | base64 --decode | wc -c) || return 1
  (( size > 0 && size <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  hash=$(printf '%s' "$encoded" | base64 --decode | sha256sum) || return 1
  [[ ${hash%% *} == "$expected" ]] || return 1
  document=$(printf '%s' "$encoded" | base64 --decode | jq -ces \
    'if length == 1 then .[0] else error("expected one captured JSON value") end') || return 1
  printf '%s\n' "$document"
)

# Internal historical reader. Uses the normal _incident_json/read_status and
# _manifest_json/id/sha256 reader globals; public data readers below shadow them.
# This proves the supplied sealed root, not its selection by today's lifecycle.
publication_read_sealed_root() {
  local reference=$1 LC_ALL=C seal manifest
  (( ${#reference} <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  reference=$(jq -cse 'if length == 1 then .[0] else error("expected one root reference") end' <<<"$reference") || return 1
  json_is '.kind == "root" and (.sha256 | length == 64)' "$reference" || return 1
  # This calls the actual read_incident_seal, including manifest/record validation.
  validate_incident_reference "$reference" || return 1
  seal=$(publication_capture_hashed_document "$(jq -r '.path' <<<"$reference")" "$(jq -r '.sha256' <<<"$reference")") || return 1
  json_is '.[0] == .[1]' "[$seal,$_incident_json]" || return 1
  manifest=$(publication_capture_hashed_document "$(jq -r '.manifest' <<<"$seal")" "$(jq -r '.manifest_sha256' <<<"$seal")") || return 1
  json_is '.[0] == .[1]' "[$manifest,$_manifest_json]" || return 1
  json_is '.kind == "root" and .recovery == null' "$_manifest_json" || return 1
  # Compare the JSON string itself, not command-substitution-normalized text.
  json_is '.[0].manifest_sha256 == .[1]' "[$_incident_json,\"$_manifest_sha256\"]" || return 1
  validate_artifact_reference_file "$(jq -c '{path:.manifest,sha256:.manifest_sha256}' <<<"$_incident_json")" \
    "$(dirname "$(lifecycle_manifest_path "$_manifest_id")")" || return 1
  [[ $(sha256_file "$(jq -r '.path' <<<"$reference")") == "$(jq -r '.sha256' <<<"$reference")" ]]
}

# Internal member reader for an already validated manifest. Publishes only
# _publication_member_record. Exact JSON reference equality selects the ordinal;
# a pathname, a matching file hash or an unbound next record is insufficient.
publication_read_manifest_member() {
  local transaction_id=$1 manifest=$2 reference=$3 LC_ALL=C
  local ordinal previous directory path document
  _publication_member_record=''
  (( ${#reference} <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  reference=$(jq -cse 'if length == 1 then .[0] else error("expected one record reference") end' <<<"$reference") || return 1
  json_is "${OMASECBOOT_JQ_DEFS}"'artifact_reference and (.schema_version == 1 or .schema_version == 2) and (.sha256 | length == 64)' "$reference" || return 1
  # Data on stdin avoids argv limits for a bounded but sizeable manifest.
  ordinal=$(jq -er '.[1] as $ref | .[0].publication_records | to_entries |
    map(select(.value == $ref)) | if length == 1 then .[0].key + 1 else error("not one member") end' \
    <<<"[$manifest,$reference]") || return 1
  (( ordinal >= 1 && ordinal <= MAX_PUBLICATION_RECORDS )) || return 1
  previous=$(jq -c --argjson ordinal "$ordinal" 'if $ordinal == 1 then null else .publication_records[$ordinal-2] end' <<<"$manifest") || return 1
  directory=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  path=$(jq -r '.path' <<<"$reference") || return 1
  [[ $path == "$directory/publication-$ordinal.json" ]] || return 1
  validate_artifact_reference_file "$reference" "$directory" || return 1
  document=$(publication_capture_hashed_document "$path" "$(jq -r '.sha256' <<<"$reference")") || return 1
  validate_publication_record_json "$transaction_id" "$ordinal" "$previous" "$document" || return 1
  json_is '.[0].schema_version == .[1].schema_version' "[$reference,$document]" || return 1
  validate_artifact_reference_file "$reference" "$directory" || return 1
  _publication_member_record=$document
}

# publication_resolve_sealed_record INCIDENT_REFERENCE RECORD_REFERENCE INVOCATION KIND
# Status 0 publishes the full envelope in _publication_resolved_record, the full
# sealed manifest in _publication_resolved_manifest, and the exact root incident
# reference (JSON-normalized) in _publication_resolved_root_reference. Status 2
# means invalid/unresolvable evidence; all three outputs are empty on failure.
# Ordinary manifest/incident globals, transaction/token/recovery context and the
# semantic cache are preserved. No lifecycle selection, adoption or mutation is
# performed: a later caller MUST bind this root to the selected actual incident
# lineage before deriving any new-attempt authority from these historical data.
publication_resolve_sealed_record() {
  local _manifest_json='' _manifest_id='' _manifest_sha256='' _incident_json='' _incident_read_status=''
  local _publication_member_record=''
  local -A _publication_validation_cache=()
  local root reference invocation kind resolved_root
  _publication_resolved_record=''
  _publication_resolved_manifest=''
  _publication_resolved_root_reference=''
  [[ $# == 4 ]] || return 2
  root=$1 reference=$2 invocation=$3 kind=$4
  [[ $invocation =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
    $kind =~ ^[a-z][a-z-]{0,63}$ ]] || return 2
  publication_read_sealed_root "$root" || return 2
  json_is '.publication_records | length > 0' "$_manifest_json" || return 2
  publication_read_manifest_member "$_manifest_id" "$_manifest_json" "$reference" || return 2
  # Both operands are locally restricted ASCII identifiers. Compare JSON values
  # directly: command substitution must not trim a different stored invocation.
  json_is ".invocation == \"$invocation\" and .kind == \"$kind\"" "$_publication_member_record" || return 2
  resolved_root=$(jq -c . <<<"$root") || return 2
  # Recheck the full external closure, including immutable retained bytes, before
  # exposing results. The local semantic cache never replaces these file checks.
  publication_read_sealed_root "$root" || return 2
  _publication_resolved_record=$_publication_member_record
  _publication_resolved_manifest=$_manifest_json
  _publication_resolved_root_reference=$resolved_root
}

# publication_load_complete_original_basis ROOT_REFERENCE INVOCATION
# Status 0 publishes _publication_original_basis, a bounded ref-only JSON value:
# {schema:1,scope:"original-invocation-basis",root:<incident reference>,invocation,
#  root_operation,root_target_state,intent:<record reference>,context:<reference>,
#  plan:<reference>,configuration:<reference>,resources:[{id,retained:<reference>}]}
# A schema-2 start produces schema:2 with start:<REAL reference> in place of
# intent/context references. Its recovery and original bytes remain in that start.
# Resource order comes from the original intent. Source hashes remain in intent
# and retained.source_sha256; final signed-byte hashes remain in retained.file.
# No hashes, desired targets or fresh observations are promoted into new claims.
# Status 1 means a valid but incomplete/ineligible selected invocation (including
# absent context/plan); status 2 means invalid evidence or a control/program limit.
# Output is empty on either. Reader/context/cache and resolver outputs are kept.
#
# This is ONE explicitly selected complete addition's original input basis. It
# does not close the enclosing root, schedule other invocations or prove recovery
# completion. Existing historical joins and retained bytes must all validate,
# but no old successful prepared-terminal or live stage/source inode is needed.
# Root-wide obligations, conflict classification and new-attempt authority belong
# to later callers, which must first prove the actual selected incident lineage.
publication_load_complete_original_basis() {
  local _manifest_json='' _manifest_id='' _manifest_sha256='' _incident_json='' _incident_read_status=''
  local _publication_member_record=''
  local -A _publication_validation_cache=()
  local root invocation references reference kind id intent='' basis resource retained LC_ALL=C
  local selected='{"start":null,"intent":null,"context":null,"plan":null,"configuration":null,"resources":{}}'
  _publication_original_basis=''
  [[ $# == 2 ]] || return 2
  root=$1 invocation=$2
  [[ $invocation =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 2
  publication_read_sealed_root "$root" || return 2
  references=$(jq -c '.publication_records[]?' <<<"$_manifest_json") || return 2
  while IFS= read -r reference; do
    [[ -n $reference ]] || continue
    publication_read_manifest_member "$_manifest_id" "$_manifest_json" "$reference" || return 2
    json_is ".invocation == \"$invocation\"" "$_publication_member_record" || continue
    kind=$(jq -r '.kind' <<<"$_publication_member_record") || return 2
    case $kind in
      invocation-start)
        selected=$(jq -c --argjson ref "$reference" '.start=$ref' <<<"$selected") || return 2
        intent=$(jq -c '.body.intent' <<<"$_publication_member_record") || return 2
        ;;
      intent|context|plan|configuration)
        selected=$(jq -c --arg kind "$kind" --argjson ref "$reference" '.[$kind]=$ref' <<<"$selected") || return 2
        if [[ $kind == intent ]]; then intent=$(jq -c '.body' <<<"$_publication_member_record") || return 2; fi
        ;;
      retained)
        id=$(jq -r '.body.id' <<<"$_publication_member_record") || return 2
        selected=$(jq -c --arg id "$id" --argjson ref "$reference" '.resources[$id]=$ref' <<<"$selected") || return 2
        ;;
    esac
  done <<<"$references"
  # The full manifest reader already proves uniqueness, completeness of any
  # bound plan, context/intent, source/ready/retained, config/stage/plan and effect
  # joins. A plan-shaped next file is never searched or made a journal member.
  json_is 'all(.plan,.configuration; . != null) and
    (if .start != null then .intent == null and .context == null else .intent != null and .context != null end)' "$selected" || return 1
  json_is '.publication.kind == "addition"' "$intent" || return 1
  # shellcheck disable=SC2016 # jq-local variables.
  json_is '.[0] as $selected | .[1] as $intent |
    ($selected.resources | keys) == ($intent.resources | map(.id) | sort)' "[$selected,$intent]" || return 1
  # Legacy readers normalize some strings through the shell. New authority must
  # join the stored JSON IDs and original source digests without that trimming.
  references=$(jq -c '.resources[]' <<<"$intent") || return 2
  while IFS= read -r resource; do
    json_is '.id | type == "string" and test("\\A[A-Za-z0-9_-]{1,64}\\z")' "$resource" || return 2
    id=$(jq -r '.id' <<<"$resource") || return 2
    reference=$(jq -ce --arg id "$id" '.resources[$id]' <<<"$selected") || return 2
    publication_read_manifest_member "$_manifest_id" "$_manifest_json" "$reference" || return 2
    retained=$_publication_member_record
    json_is '.[0].body.id == .[1].id and .[0].body.source_sha256 == .[1].sha256 and
      (.[0].body.source_sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z"))' "[$retained,$resource]" || return 2
  done <<<"$references"
  basis=$(jq -ce --arg invocation "$invocation" '
    .[0] as $root | .[1] as $manifest | .[2] as $selected | .[3] as $intent |
    {schema:1,scope:"original-invocation-basis",root:$root,invocation:$invocation,
     root_operation:$manifest.operation,root_target_state:$manifest.target_state,
      plan:$selected.plan,
      configuration:$selected.configuration,
      resources:[$intent.resources[] | {id,retained:$selected.resources[.id]}]} +
      (if $selected.start == null then {intent:$selected.intent,context:$selected.context}
       else {schema:2,start:$selected.start} end)' \
    <<<"[$root,$_manifest_json,$selected,$intent]") || return 2
  (( ${#basis} + 1 <= MAX_CONTROL_DOCUMENT_BYTES )) || return 2
  publication_read_sealed_root "$root" || return 2
  _publication_original_basis=$basis
}

# Private pure-data decoder for the two public readers below. Raw control JSON
# is decoded again without jq/binary64 or shell string normalization: the old
# schema readers deliberately retain their historical acceptance rules. Only
# sealed control documents and retained-file metadata are read here, never an
# intent source, historical stage, configuration target or observed target.
publication_original_data_decode() {
  /usr/bin/timeout --kill-after=1 30 /usr/bin/env -i PATH=/usr/bin LC_ALL=C HOME=/nonexistent \
    /usr/bin/python -I -S -B -c '
import hashlib, json, os, re, stat, sys
from decimal import Decimal

LIMIT = int(sys.argv[2])
OWNER = int(sys.argv[3])
SAFE_INTEGER = 9007199254740991

def require(value):
    if not value:
        raise ValueError("invalid original content data")

def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result)
        result[key] = value
    return result

def constant(value):
    raise ValueError("non-JSON number")

def integers(value):
    if isinstance(value, Decimal):
        require(value.is_finite() and abs(value) <= SAFE_INTEGER and value == value.to_integral_value())
        return int(value)
    if type(value) is int:
        require(abs(value) <= SAFE_INTEGER)
    elif isinstance(value, dict):
        return {key: integers(item) for key, item in value.items()}
    elif isinstance(value, list):
        return [integers(item) for item in value]
    return value

def decode(raw):
    return integers(json.loads(raw, object_pairs_hook=pairs, parse_float=Decimal, parse_constant=constant))

def keys(value, expected):
    require(type(value) is dict and set(value) == set(expected.split()))

def grammar(value, pattern):
    require(type(value) is str and re.fullmatch(pattern, value) is not None)

def digest(value):
    grammar(value, r"[0-9a-f]{64}")

def identifier(value):
    grammar(value, r"[A-Za-z0-9_-]{1,64}")

def path(value):
    require(type(value) is str and 1 < len(value) <= 4096 and value.startswith("/"))
    require(all(ord(c) >= 32 and ord(c) != 127 for c in value))
    require(all(part not in ("", ".", "..") for part in value.split("/")[1:]))

def number(value, maximum):
    require(type(value) is int and 0 <= value <= maximum)

def state(value, fresh=False):
    keys(value, "kind identity sha256 link_target mode uid gid")
    require(value["link_target"] is None)
    number(value["mode"], 65535)
    number(value["uid"], 4294967295)
    number(value["gid"], 4294967295)
    if value["kind"] == "absent":
        require(value == dict(kind="absent", identity=None, sha256=None, link_target=None, mode=0, uid=0, gid=0))
    else:
        require(value["kind"] == "file" and stat.S_ISREG(value["mode"]))
        grammar(value["identity"], r"[0-9]{1,20}:[0-9]{1,20}")
        require(all(int(part) <= 18446744073709551615 for part in value["identity"].split(":")))
        digest(value["sha256"])
        if fresh:
            require(value["uid"] == OWNER and value["mode"] & 0o022 == 0)

def capture(filename, expected):
    path(filename)
    digest(expected)
    fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == OWNER and before.st_mode & 0o077 == 0)
        require(0 < before.st_size <= LIMIT)
        chunks, remaining = [], LIMIT + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns))
        require(len(raw) == before.st_size and len(raw) <= LIMIT and hashlib.sha256(raw).hexdigest() == expected)
        return decode(raw)
    finally:
        os.close(fd)

def resolve(basis, effect_id):
    identifier(effect_id)
    require(basis["scope"] == "original-invocation-basis" and basis["schema"] in (1, 2))
    root, invocation = basis["root"], basis["invocation"]
    seal = capture(root["path"], root["sha256"])
    manifest = capture(seal["manifest"], seal["manifest_sha256"])
    require(seal["id"] == root["id"] == manifest["id"])
    directory = os.path.dirname(seal["manifest"])

    def member(reference, kind=None):
        keys(reference, "path sha256 schema_version")
        matches = [i for i, ref in enumerate(manifest["publication_records"]) if ref == reference]
        require(len(matches) == 1)
        ordinal = matches[0] + 1
        require(reference["path"] == directory + "/publication-" + str(ordinal) + ".json")
        record = capture(reference["path"], reference["sha256"])
        require(record["transaction_id"] == root["id"])
        if kind is not None:
            require(record["invocation"] == invocation and record["kind"] == kind)
        require(record["ordinal"] == ordinal and record["schema_version"] == reference["schema_version"])
        require(record["previous"] == (None if ordinal == 1 else manifest["publication_records"][ordinal - 2]))
        return record["body"] if kind is not None else record

    def authority(reference, projection):
        return dict(reference=reference, projection=projection)

    def retained_file(value, suffix):
        keys(value, "path sha256 bytes")
        digest(value["sha256"])
        number(value["bytes"], SAFE_INTEGER)
        require(value["path"] == directory + "/publication-data-" + invocation + "-" + suffix)
        info = os.stat(value["path"], follow_symlinks=False)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == OWNER and info.st_mode & 0o077 == 0)
        require(info.st_size == value["bytes"])

    start = None
    if basis["schema"] == 2:
        start = member(basis["start"], "invocation-start")
        intent, context = start["intent"], start["context"]
        intent_authority = authority(basis["start"], ".body.intent")
        context_authority = authority(basis["start"], ".body.context")
        retained_file(start["original_configuration"], "original-configuration")
        require(start["original_configuration"]["sha256"] == intent["configuration"]["sha256"])
    else:
        intent, context = member(basis["intent"], "intent"), member(basis["context"], "context")
        intent_authority = authority(basis["intent"], ".body")
        context_authority = authority(basis["context"], ".body")
    plan = member(basis["plan"], "plan")
    configuration = member(basis["configuration"], "configuration")
    retained_file(configuration["file"], "configuration")
    require(context["configuration_path"] == intent["configuration"]["path"])
    require(plan["invocation"] == invocation)
    resources = intent["resources"]
    for resource in resources:
        identifier(resource["id"])
        require(resource["id"] != "configuration")
        path(resource["target"])
        path(resource["source"])
        digest(resource["sha256"])
    path(intent["configuration"]["path"])
    digest(intent["configuration"]["sha256"])
    require([p["id"] for p in plan["puts"]] == [r["id"] for r in resources])
    require(plan["configuration"]["id"] == "configuration")
    effects = plan["puts"] + [plan["configuration"]]
    selected = [(i, value) for i, value in enumerate(effects) if value["id"] == effect_id]
    require(len(selected) == 1)
    index, effect = selected[0]
    path(effect["target"])
    require(sum(value["target"] == effect["target"] for value in effects) == 1)
    state(effect["before"])
    state(effect["after"])
    require(effect["after"]["kind"] == "file")
    if effect_id == "configuration":
        file = configuration["file"]
        require(effect["target"] == intent["configuration"]["path"] and effect["before"]["kind"] == "file")
        require(effect["before"]["sha256"] == intent["configuration"]["sha256"])
        source = dict(path=intent["configuration"]["path"], sha256=intent["configuration"]["sha256"])
        signing, kind = "bytes", "configuration"
        retained_authority = authority(basis["configuration"], ".body.file")
        projection = ".body.configuration"
    else:
        matched = [r for r in resources if r["id"] == effect_id]
        refs = [r["retained"] for r in basis["resources"] if r["id"] == effect_id]
        require(len(matched) == len(refs) == 1)
        resource, reference = matched[0], refs[0]
        retained = member(reference, "retained")
        require(retained["id"] == resource["id"] == effect_id and effect["target"] == resource["target"])
        digest(retained["source_sha256"])
        require(retained["source_sha256"] == resource["sha256"])
        file = retained["file"]
        retained_file(file, effect_id)
        signing, kind = retained["signing"], "put"
        require(signing in ("bytes", "local-efi") and (resource["role"] != "uki" or signing == "local-efi"))
        source = dict(path=resource["source"], sha256=resource["sha256"])
        retained_authority = authority(reference, ".body.file")
        projection = ".body.puts[" + str(index) + "]"
    require(effect["retained"] == file["path"] and effect["after"]["sha256"] == file["sha256"])
    # Rejoin the raw preparation evidence too. Historical jq equality can alias
    # fractional byte counts and metadata, or shell extraction can trim an ID.
    # Stream the bounded journal; do not accumulate peer documents in memory.
    stages, ready = [], []
    for reference in manifest["publication_records"]:
        record = member(reference)
        if record["invocation"] != invocation:
            continue
        body = record["body"]
        if record["kind"] == "boot-stage" and body["id"] == effect_id:
            stages.append((reference, body))
        if record["kind"] == "input-ready" and body["id"] == effect_id:
            ready.append(body)
    require(len(stages) == 1)
    stage_reference, stage = stages[0]
    require(stage["id"] == effect_id and stage["target"] == effect["target"] and stage["retained"] == file)
    require(stage["before"] == effect["before"] and stage["stage"]["state"] == effect["after"] and stage["parent"] == effect["parent"])
    if effect_id != "configuration":
        require(len(ready) == 1 and {k: v for k, v in ready[0].items() if k != "temporary"} == retained)
    plan_authority = authority(basis["plan"], projection)
    if start is None:
        absence = dict(allowed=effect["before"]["kind"] == "absent", reason="original-before",
                       authority=authority(basis["plan"], projection + ".before"))
    else:
        keys(start["recovery"], "recreate_missing")
        expected = [dict(id=r["id"], target=r["target"]) for r in resources]
        expected.append(dict(id="configuration", target=intent["configuration"]["path"]))
        require(start["recovery"]["recreate_missing"] == expected)
        pair = dict(id=effect_id, target=effect["target"])
        require(expected.count(pair) == 1)
        absence = dict(allowed=True, reason="original-recreate-missing", pair=pair,
                       authority=authority(basis["start"], ".body.recovery.recreate_missing[" + str(expected.index(pair)) + "]"))
    return dict(schema=1, scope="original-effect-data", basis=basis, id=effect_id, target=effect["target"],
                effect_kind=kind, before=dict(kind=effect["before"]["kind"], sha256=effect["before"]["sha256"]),
                desired=dict(kind="file", sha256=file["sha256"], bytes=file["bytes"]),
                original_source=source, signing=signing, retained=file, absence=absence,
                authority=dict(intent=intent_authority, context=context_authority, plan=plan_authority,
                               stage=authority(stage_reference, ".body"), retained=retained_authority))

def classify(effect, observation):
    keys(observation, "path state")
    require(observation["path"] == effect["target"])
    observed = observation["state"]
    state(observed, fresh=True)
    if observed["kind"] == "absent":
        outcome = "allowed-absence" if effect["absence"]["allowed"] else "conflict-absence"
    elif observed["sha256"] == effect["desired"]["sha256"]:
        outcome = "desired"
    elif effect["before"]["kind"] == "file" and observed["sha256"] == effect["before"]["sha256"]:
        outcome = "prior"
    else:
        outcome = "conflict-content"
    return dict(schema=1, scope="original-content-classification", outcome=outcome,
                observation=observation, original_effect=effect)

try:
    raw = sys.stdin.buffer.read(2 * LIMIT + 4097)
    require(len(raw) <= 2 * LIMIT + 4096)
    data = decode(raw)
    require(type(data) is list and len(data) == 2)
    result = resolve(*data) if sys.argv[1] == "resolve" else classify(*data)
    output = json.dumps(result, ensure_ascii=True, separators=(",", ":"))
    require(len(output) + 1 <= LIMIT)
    print(output)
except (ValueError, TypeError, KeyError, IndexError, OSError, ArithmeticError, RecursionError):
    sys.exit(2)
' "$1" "$MAX_CONTROL_DOCUMENT_BYTES" "$(control_owner_uid)"
}

# publication_resolve_original_effect ROOT_REFERENCE INVOCATION EFFECT_ID
# 0: _publication_original_effect is bounded JSON, scope original-effect-data.
# It contains the actual rebuilt basis, id/target/effect_kind, content-only before
# and desired, original_source (NOT the retained signed hash), signing, retained
# file reference, exact authority references/projections and absence authority.
# 1: valid but ineligible/incomplete invocation. 2: invalid evidence, unknown ID
# or control limit. Output is empty on either failure. Other reader outputs and
# runtime globals are preserved. This does not prove root-wide completeness,
# selected incident lineage, current context/signatures or any write permission.
publication_resolve_original_effect() {
  local _publication_original_basis='' _manifest_json='' _manifest_id='' _manifest_sha256=''
  local _incident_json='' _incident_read_status=''
  local -A _publication_validation_cache=()
  local root invocation id result status=0 LC_ALL=C
  _publication_original_effect=''
  [[ $# == 3 ]] || return 2
  root=$1 invocation=$2 id=$3
  [[ $id =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 2
  publication_load_complete_original_basis "$root" "$invocation" || status=$?
  (( status == 0 )) || return "$status"
  result=$(publication_original_data_decode resolve <<<"[$_publication_original_basis,\"$id\"]") || return 2
  # Revalidate the entire external closure after reading the actual members.
  publication_read_sealed_root "$root" || return 2
  _publication_original_effect=$result
}

# publication_classify_original_content ROOT_REFERENCE INVOCATION EFFECT_ID OBS
# OBS is exactly {path,state:FileState}, one JSON value. 0 classifies desired,
# prior or permitted absence; 1 returns an explicit conflict-content/absence;
# 2 means invalid/unavailable authority or unsafe/unknown observation, output
# empty. _publication_content_classification includes the complete derived
# original_effect and fresh caller-supplied observation under the distinct scope
# original-content-classification. Desired wins equal prior/desired hashes.
# No old inode/mount/receipt is attributed. Caller MUST obtain OBS through fresh
# held objects and separately prove selected lineage, context, signatures and
# whole-root obligations. This function never observes or changes a target.
publication_classify_original_content() {
  local _publication_original_effect=''
  local result observation LC_ALL=C
  _publication_content_classification=''
  [[ $# == 4 ]] || return 2
  observation=$4
  (( ${#observation} <= MAX_CONTROL_DOCUMENT_BYTES )) || return 2
  publication_resolve_original_effect "$1" "$2" "$3" || return 2
  result=$(publication_original_data_decode classify <<<"[$_publication_original_effect,$observation]") || return 2
  _publication_content_classification=$result
  json_is '.outcome == "prior" or .outcome == "desired" or .outcome == "allowed-absence"' "$result"
}
