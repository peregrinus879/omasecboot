#!/bin/bash
# Core supervision of one synchronous, caller-bound native producer invocation.
# Callers own package/operation admission and durable request/result records.
# shellcheck disable=SC2154 # Lifecycle and signing modules own transaction/input results.

_producer_session_active=false
_producer_session_owner_pid=''
_producer_session_worker_pid=''
_producer_session_worker_start=''
_producer_session_decoder_pid=''
_producer_session_decoder_start=''
_producer_session_responses=''
_producer_session_requests=''
_producer_session_reply=''
_producer_session_result=''
_producer_session_protocol_complete=false
_producer_session_completion_acknowledged=false
_producer_session_worker_status=null
_producer_session_decoder_status=null
_producer_session_wait_status=null
_producer_session_io_timeout=300
_publication_invocation=''
_publication_intent=''
_publication_pin_owner=''
_publication_pin_transaction=''
declare -ag _publication_pins=()
declare -Ag _publication_retained=()

# A privileged, fixed caller supplies the producer-selected input intent. This
# layer records and retains it; public native selection/admission is separate.
publication_authority_begin() {
  local invocation=$1 intent=$2 probe config expected
  producer_session_context_is_owned || return 1
  [[ $_producer_session_active == false ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  json_is "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'.schema_version == 3 and publication_root_operation' "$_manifest_json" || return 1
  probe=$(jq -cse --arg id "$_transaction_id" --arg invocation "$invocation" --arg timestamp "$(utc_timestamp)" \
    --arg version "$OMASECBOOT_VERSION" 'if length == 1 then
      {schema_version:1,transaction_id:$id,invocation:$invocation,ordinal:1,previous:null,
       kind:"intent",body:.[0],recorded_at:$timestamp,writer_version:$version} else error("invalid intent") end' <<<"$intent") || return 1
  validate_publication_record_json "$_transaction_id" 1 null "$probe" || return 1
  config=$(jq -r '.configuration.path' <<<"$intent") || return 1
  expected=$(jq -r '.configuration.sha256' <<<"$intent") || return 1
  validate_control_directory "$(jq -r '.esp_path' <<<"$intent")" && validate_control_file "$config" || return 1
  [[ $(sha256_file "$config") == "$expected" ]] || return 1
  if [[ ${#_publication_pins[@]} -gt 0 ]]; then
    [[ $_publication_pin_owner == "$BASHPID" && $_publication_pin_transaction == "$_transaction_id" ]] || return 1
  fi
  _publication_invocation=$invocation
  _publication_intent=$intent
  _publication_retained=()
  if json_is 'has("publication")' "$intent"; then
    publication_reset_attempt
    _publication_mount_namespace=$(publication_namespace_value) || return 1
    publication_parent_binding "$(dirname "$config")" || return 1
    publication_collect_stable_context || return 1
    publication_context_matches_intent "$_publication_collected_context" "$intent" || return 1
    _publication_stable_context=$_publication_collected_context
    _publication_signing_policy=${_publication_collected_signing_policy:-}
    publication_retain_original_configuration "$invocation" "$intent" || return 1
    append_publication_invocation_start "$invocation" "$intent" "$_publication_stable_context" \
      "$_publication_original_configuration" || return 1
  else
    # Context-free input-retention prerequisites retain their schema-1 contract;
    # they do not authorize canonical publication or context-based recovery.
    preserve_transaction_files_on_failure || return 1
    append_publication_record "$invocation" intent "$intent" || return 1
  fi
}

release_publication_pins() {
  local fd
  [[ $_publication_pin_owner == "$BASHPID" ]] || return 0
  for fd in "${_publication_pins[@]}"; do exec {fd}<&-; done
  _publication_pins=()
  _publication_pin_owner=''
  _publication_pin_transaction=''
}

publication_authority_handler() {
  local event=$1 document=$2 body operation id resource intent_ids candidate self=$BASHPID
  producer_session_context_is_owned || return 1
  case $event in
    launch)
      [[ $(jq -r '.invocation' <<<"$document") == "$_publication_invocation" ]] || return 1
      # A rejected same-invocation retry may have changed preparation variables.
      # Only the exact durable original intent can authorize either worker.
      find_publication_authority_part "$_publication_invocation" intent || return 1
      json_is '.[0] == .[1]' "[$_publication_intent,$_publication_found_body]" || return 1
      sync_publication_reference "$_publication_found_reference" || return 1
      if json_is 'has("publication")' "$_publication_intent"; then
        [[ -n $_publication_stable_context ]] || return 1
        find_publication_authority_part "$_publication_invocation" context || return 1
        publication_compare_stable_context "$_publication_stable_context" "$_publication_found_body" || return 1
        sync_publication_reference "$_publication_found_reference" || return 1
      fi
      body=$(jq -cn --argjson worker "$(jq -c '.worker' <<<"$document")" \
        --argjson owner "$(manifest_owner_json "$self")" --arg boot "$(boot_id_value)" \
        '{worker:$worker,supervisor:$owner,boot_id:$boot}') || return 1
      if [[ ${_publication_apply_phase:-false} == true ]]; then
        append_publication_record "$_publication_invocation" executor "$body"
      else append_publication_record "$_publication_invocation" session "$body"; fi
      ;;
    request)
      [[ $(jq -r '.invocation' <<<"$document") == "$_publication_invocation" ]] || return 1
      operation=$(jq -er '.payload.operation' <<<"$document") || return 1
      case $operation in
        retain)
          if json_is 'has("publication")' "$_publication_intent"; then
            [[ $_publication_apply_phase == false && $_publication_intent_matched == true ]] || return 1
          fi
          json_is '.payload | keys == ["id","operation"] and (.id | type == "string" and test("^[A-Za-z0-9_-]{1,64}$"))' "$document" || return 1
          id=$(jq -r '.payload.id' <<<"$document") || return 1
          resource=$(jq -ce --arg id "$id" '.resources[] | select(.id == $id)' <<<"$_publication_intent") || return 1
          if [[ -z ${_publication_retained[$id]:-} ]]; then
            retain_publication_input "$_publication_invocation" "$resource" || return 1
            _publication_retained[$id]=$_publication_input_record
          fi
          _producer_session_reply=${_publication_retained[$id]}
          ;;
        complete)
          json_is '.payload | keys == ["operation"]' "$document" || return 1
          intent_ids=$(jq -r '.resources[].id' <<<"$_publication_intent") || return 1
          while IFS= read -r id; do
            [[ -n ${_publication_retained[$id]:-} ]] || return 1
            candidate=$(jq -c '.file' <<<"${_publication_retained[$id]}") || return 1
            validate_publication_retained_file "$_transaction_id" "$candidate" || return 1
          done <<<"$intent_ids"
          if json_is 'has("publication")' "$_publication_intent"; then
            [[ -n $_publication_plan ]] || return 1
            if [[ $_publication_apply_phase == true ]]; then publication_all_effects_applied || return 1; fi
          fi
          _producer_session_reply='{"accepted":true}'
          ;;
        *)
          json_is 'has("publication")' "$_publication_intent" || return 1
          publication_handle_request "$document"
          ;;
      esac
      ;;
    terminal)
      if json_is 'has("publication")' "$_publication_intent"; then
        if [[ $_publication_apply_phase == false ]]; then
          append_publication_record "$_publication_invocation" prepared-terminal "$document"
        else
          if json_is '.supervision_status == 0' "$document" && ! { publication_all_effects_applied && publication_verify_stable_context; }; then
            document=$(jq -c '.supervision_status=1' <<<"$document") || return 1
            append_publication_record "$_publication_invocation" terminal "$document" || return 1
            return 1
          fi
          append_publication_record "$_publication_invocation" terminal "$document"
        fi
      else append_publication_record "$_publication_invocation" terminal "$document"; fi
      ;;
    *) return 1 ;;
  esac
}

producer_session_validate_lock_bindings() {
  # Lost pathname/descriptor bindings must not leave true flags that a later
  # rollback could mistake for serialization on the current locks.
  if ! validate_control_file "$(limine_lock_path)" || ! fd_matches_path 200 "$(limine_lock_path)"; then
    _OMASECBOOT_LIMINE_LOCK_OWNED=false
    return 1
  fi
  if ! validate_control_file "$(state_dir_path)/repair.lock" || ! fd_matches_path 201 "$(state_dir_path)/repair.lock"; then
    _OMASECBOOT_REPAIR_LOCK_OWNED=false
    return 1
  fi
}

producer_session_context_is_owned() {
  producer_session_validate_lock_bindings || return 1
  [[ ${_transaction_active:-false} == true ]] && current_transition_is_owned || return 1
  boot_locks_are_held && producer_runtime_is_clear || return 1
  producer_session_validate_lock_bindings || return 1
  # Reassert actual ownership, rather than trusting the bookkeeping flags alone.
  flock -n 200 || { _OMASECBOOT_LIMINE_LOCK_OWNED=false; return 1; }
  flock -n 201 || { _OMASECBOOT_REPAIR_LOCK_OWNED=false; return 1; }
  producer_session_validate_lock_bindings
}

producer_session_worker_is_bound() {
  local pid=$1 tool=$2
  [[ -f /proc/$pid/exe && -f $tool ]] || return 1
  [[ $(control_file_identity "/proc/$pid/exe") == "$(control_file_identity "$tool")" ]]
}

producer_session_process_matches() {
  local pid=$1 start=$2
  [[ $pid =~ ^[0-9]+$ && $pid -gt 1 && $start =~ ^[0-9]+$ ]] || return 1
  [[ $(process_start_time "$pid") == "$start" && $(process_effective_uid "$pid") == "$(control_owner_uid)" \
    && $(process_parent_pid "$pid") == "$_producer_session_owner_pid" ]]
}

producer_session_close_channels() {
  local fd
  if [[ -n $_producer_session_responses ]]; then
    fd=$_producer_session_responses
    exec {fd}>&-
    _producer_session_responses=''
  fi
  if [[ -n $_producer_session_requests ]]; then
    fd=$_producer_session_requests
    exec {fd}<&-
    _producer_session_requests=''
  fi
}

# Procfs observations are provisional: a child can exit between any two reads.
# A failed observation gets one fresh terminal check, not a live-child exemption.
producer_session_observe_child() {
  local pid=$1 start=$2 state attempt
  _producer_session_child_state=unknown
  [[ $pid =~ ^[0-9]+$ && $pid -gt 1 && $_producer_session_owner_pid == "$BASHPID" ]] || return 1
  for ((attempt=0; attempt<2; attempt++)); do
    if [[ ! -e /proc/$pid ]]; then
      _producer_session_child_state=terminal
      return 0
    fi
    if producer_session_process_matches "$pid" "$start" && state=$(process_state "$pid") && [[ -n $state ]]; then
      if [[ $state == Z ]]; then
        # Recheck identity after the separate state read, including PID reuse.
        if producer_session_process_matches "$pid" "$start"; then
          _producer_session_child_state=terminal
          return 0
        fi
      elif (( attempt == 0 )); then
        _producer_session_child_state=live
        return 0
      fi
    fi
  done
  if [[ ! -e /proc/$pid ]]; then
    _producer_session_child_state=terminal
    return 0
  fi
  return 1
}

producer_session_collect_child() {
  local pid=$1 start=$2
  # In particular, absence seen earlier is not proof if that PID appears again.
  # Only the owning Bash collects its child status; procfs never supplies it.
  producer_session_observe_child "$pid" "$start" && [[ $_producer_session_child_state == terminal ]] || return 1
  _producer_session_wait_status=0
  wait "$pid" 2>/dev/null || _producer_session_wait_status=$?
  return 0
}

producer_session_wait_child() {
  local pid=$1 start=$2 timeout=$3 tick
  _producer_session_wait_status=null
  for ((tick=0; tick<timeout*20; tick++)); do
    producer_session_observe_child "$pid" "$start" || return 1
    if [[ $_producer_session_child_state == terminal ]]; then
      producer_session_collect_child "$pid" "$start"
      return "$?"
    fi
    sleep 0.05
  done
  producer_session_collect_child "$pid" "$start"
}

producer_session_stop_child() {
  local pid=$1 start=$2 index signal
  _producer_session_wait_status=null
  [[ -n $pid ]] || return 0
  for signal in TERM KILL; do
    producer_session_observe_child "$pid" "$start" || return 1
    if [[ $_producer_session_child_state == terminal ]]; then
      producer_session_collect_child "$pid" "$start"
      return "$?"
    fi
    # No earlier observation, nor a failed signal, authorizes an unknown PID.
    if ! producer_session_process_matches "$pid" "$start" || ! kill -"$signal" "$pid" 2>/dev/null; then
      producer_session_collect_child "$pid" "$start"
      return "$?"
    fi
    for ((index=0; index<20; index++)); do
      producer_session_observe_child "$pid" "$start" || return 1
      if [[ $_producer_session_child_state == terminal ]]; then
        producer_session_collect_child "$pid" "$start"
        return "$?"
      fi
      sleep 0.05
    done
    # Preserve the TERM grace; bound terminal observation after KILL as well.
  done
  producer_session_collect_child "$pid" "$start"
}

# Lifecycle failure paths call this before rollback or stable/recovery writes.
producer_session_abort() {
  local result=0
  [[ $_producer_session_active == true ]] || return 0
  [[ $_producer_session_owner_pid == "$BASHPID" ]] || return 1
  producer_session_close_channels
  if [[ -n $_producer_session_worker_pid ]]; then
    if producer_session_stop_child "$_producer_session_worker_pid" "$_producer_session_worker_start"; then
      _producer_session_worker_status=$_producer_session_wait_status
      _producer_session_worker_pid=''
    else result=1; fi
  fi
  if [[ -n $_producer_session_decoder_pid ]]; then
    if producer_session_stop_child "$_producer_session_decoder_pid" "$_producer_session_decoder_start"; then
      _producer_session_decoder_status=$_producer_session_wait_status
      _producer_session_decoder_pid=''
    else result=1; fi
  fi
  if (( result == 0 )); then
    _producer_session_active=false
    _producer_session_worker_pid=''
    _producer_session_decoder_pid=''
  fi
  return "$result"
}

# The callback executes in this shell. It sets _producer_session_reply to one
# JSON object; command substitution here would lose its newly opened object FDs.
producer_session_exchange() {
  local handler=$1 invocation=$2 tool=$3 timeout=$4 request sequence=1 complete=false response reader_rc=0
  local LC_ALL=C
  while :; do
    IFS= read -r -t "$timeout" request <&"$_producer_session_requests" || { reader_rc=$?; break; }
    [[ $complete == false ]] || return 1
    producer_session_context_is_owned || return 1
    producer_session_process_matches "$_producer_session_worker_pid" "$_producer_session_worker_start" || return 1
    producer_session_worker_is_bound "$_producer_session_worker_pid" "$tool" || return 1
    json_is '
      type == "object" and keys == ["format","invocation","payload","schema","sequence"] and
      .format == "omasecboot-producer-request" and .schema == 1 and
      (.sequence | type == "number" and floor == . and . >= 1) and (.payload | type == "object")' "$request" || return 1
    # Both interpolated values are locally generated/validated numeric or hex data.
    json_is ".invocation == \"${invocation}\" and .sequence == ${sequence}" "$request" || return 1
    _producer_session_reply=''
    "$handler" request "$request" || return 1
    response=$(jq -cse --arg invocation "$invocation" --argjson sequence "$sequence" '
      if length == 1 and (.[0] | type == "object") then
        {format:"omasecboot-producer-response",schema:1,invocation:$invocation,sequence:$sequence,ok:true,payload:.[0]}
      else error("invalid session handler response") end' <<<"$_producer_session_reply") || return 1
    (( ${#response} <= 2 * 1024 * 1024 )) || return 1
    producer_session_context_is_owned || return 1
    # The callback remains in Core, but a deadline-scoped writer prevents a
    # peer that stops reading responses from blocking the lock custodian.
    (set -o pipefail; printf '%s\n' "$response" | /usr/bin/timeout --kill-after=1 "$timeout" /usr/bin/cat >&"$_producer_session_responses") || return 1
    if json_is '.payload.operation == "complete"' "$request"; then complete=true; _producer_session_completion_acknowledged=true; fi
    sequence=$((sequence + 1))
  done
  # EOF is provisional. A decoder can fail after emitting earlier valid frames,
  # and a worker can fail after a successfully acknowledged complete message.
  [[ $reader_rc == 1 && $complete == true ]] || return 1
  _producer_session_protocol_complete=true
}

# Both FD arguments are already opened and bound by the fixed production caller.
# The timeout bounds an unresponsive protocol, not lock acquisition (status75).
# This helper is for the synchronous native worker, not a daemon/job-tree runner.
run_bound_producer_session() {
  local worker_fd=$1 decoder_fd=$2 invocation=$3 handler=$4 timeout=$5
  shift 5
  local owner=$BASHPID tool decoder input output error raw original responses requests gate_rc=0 result=0 launch
  [[ $_producer_session_active == false && $worker_fd =~ ^[0-9]+$ && $decoder_fd =~ ^[0-9]+$ \
    && $invocation =~ ^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$ && $timeout =~ ^[1-9][0-9]{0,5}$ ]] || return 1
  declare -F "$handler" >/dev/null || return 1
  producer_session_context_is_owned || return 1
  tool=/proc/$owner/fd/$worker_fd
  decoder=/proc/$owner/fd/$decoder_fd
  _producer_session_decoder_tool=$decoder
  [[ -f $tool && -x $tool && -f $decoder && -x $decoder ]] || return 1
  exec {input}<&0 {output}>&1 {error}>&2
  _producer_session_active=true
  _producer_session_owner_pid=$owner
  _producer_session_result=''
  _producer_session_protocol_complete=false
  _producer_session_completion_acknowledged=false
  _producer_session_worker_status=null
  _producer_session_decoder_status=null
  _producer_session_io_timeout=$timeout
  coproc OMASECBOOT_WORKER {
    IFS= read -r gate || exit 90
    [[ $gate == "$invocation" ]] || exit 90
    exec 198>&1 199<&0
    exec 0<&"$input" 1>&"$output" 2>&"$error"
    exec "$tool" "$@"
  }
  _producer_session_worker_pid=$OMASECBOOT_WORKER_PID
  original=${OMASECBOOT_WORKER[0]}
  exec {raw}<&"$original"
  exec {original}<&-
  responses=${OMASECBOOT_WORKER[1]}
  exec {_producer_session_responses}>&"$responses"
  exec {responses}>&-
  _producer_session_worker_start=$(process_start_time "$_producer_session_worker_pid") || gate_rc=1
  # The decoder has no response-writer copy, so it cannot hide Core death/EOF
  # from a producer waiting for its next authorization.
  exec {requests}< <(
    exec {_producer_session_responses}>&-
    exec 0<&"$raw"
    exec "$decoder" --decode-managed-stream
  )
  _producer_session_decoder_pid=$!
  _producer_session_requests=$requests
  exec {raw}<&-
  _producer_session_decoder_start=$(process_start_time "$_producer_session_decoder_pid") || gate_rc=1
  exec {input}<&- {output}>&- {error}>&-
  if (( gate_rc == 0 )); then
    launch=$(jq -cn --arg invocation "$invocation" --argjson pid "$_producer_session_worker_pid" \
      --arg start "$_producer_session_worker_start" --argjson uid "$(control_owner_uid)" \
      '{invocation:$invocation,worker:{pid:$pid,start_time:$start,uid:$uid}}') || gate_rc=1
  fi
  if (( gate_rc == 0 )); then "$handler" launch "$launch" || gate_rc=1; fi
  if (( gate_rc == 0 )); then
    producer_session_context_is_owned && printf '%s\n' "$invocation" >&"$_producer_session_responses" || gate_rc=1
  fi
  if (( gate_rc == 0 )); then
    producer_session_exchange "$handler" "$invocation" "$tool" "$timeout" || result=$?
  else
    result=1
  fi
  if (( result == 0 )); then
    if producer_session_wait_child "$_producer_session_worker_pid" "$_producer_session_worker_start" "$timeout"; then
      _producer_session_worker_status=$_producer_session_wait_status
      _producer_session_worker_pid=''
    else result=1; fi
    if producer_session_wait_child "$_producer_session_decoder_pid" "$_producer_session_decoder_start" "$timeout"; then
      _producer_session_decoder_status=$_producer_session_wait_status
      _producer_session_decoder_pid=''
    else result=1; fi
  fi
  producer_session_abort || {
    fail 'Producer shutdown could not be proved; retaining its transition'
    return 1
  }
  [[ $_producer_session_worker_status == 0 && $_producer_session_decoder_status == 0 ]] || result=1
  [[ $_producer_session_decoder_status == 0 ]] || _producer_session_protocol_complete=false
  _producer_session_result=$(jq -cn --arg invocation "$invocation" --argjson worker "$_producer_session_worker_status" \
    --argjson decoder "$_producer_session_decoder_status" --argjson complete "$_producer_session_protocol_complete" \
    --argjson acknowledged "$_producer_session_completion_acknowledged" --argjson status "$result" \
    '{invocation:$invocation,completion_acknowledged:$acknowledged,protocol_complete:$complete,
      supervision_status:$status,worker_status:$worker,decoder_status:$decoder}') || return 1
  if (( gate_rc == 0 )); then
    producer_session_context_is_owned && "$handler" terminal "$_producer_session_result" || result=1
  fi
  return "$result"
}
