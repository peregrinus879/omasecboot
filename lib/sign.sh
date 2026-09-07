#!/bin/bash
# shellcheck disable=SC2154 # Transaction globals come from the sourced lifecycle module.
# OmaSecBoot: key creation, EFI signing, database cleanup

readonly LIMINE_DEFAULT_CONF="/etc/default/limine"
readonly LIMINE_CONFIG_MARKER='++CONFIG_B2SUM_SIGNATURE++'
LIMINE_ZERO_CHECKSUM=$(printf '0%.0s' {1..128})
readonly LIMINE_ZERO_CHECKSUM
_limine_settings_changed=false

# Runs a command, discarding its standard output in quiet mode.
run_visible() {
  if [[ "$QUIET" == true ]]; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

limine_default_config_path() {
  printf '%s\n' "$LIMINE_DEFAULT_CONF"
}

limine_primary_binary_path() {
  printf '%s/EFI/limine/limine_x64.efi\n' "$(esp_path)"
}

limine_fallback_binary_path() {
  printf '%s/EFI/BOOT/BOOTX64.EFI\n' "$(esp_path)"
}

limine_unsigned_binary_path() {
  printf '%s\n' /usr/share/limine/BOOTX64.EFI
}

limine_install_path() {
  printf '%s\n' /usr/bin/limine-install
}

limine_mkinitcpio_path() {
  printf '%s\n' /usr/bin/limine-mkinitcpio
}

limine_reset_enroll_path() {
  printf '%s\n' /usr/bin/limine-reset-enroll
}

list_limine_default_entries() {
  local file="$1" key="$2"
  awk -v key="$key" '
    BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*=" }
    $0 ~ pattern {
      line = $0
      sub(pattern, "", line)
      sub(/^[[:space:]]*/, "", line)
      print key "=" line
    }
  ' "$file"
}

# Reads every assignment of one key. An absent file has no entries; a file
# that exists but cannot be read is a failure, never an empty result.
load_limine_default_entry() {
  local key="$1" file line raw="" entries
  _limine_default_raw=""
  _limine_default_count=0
  file=$(limine_default_config_path)
  if [[ -e "$file" || -L "$file" ]]; then
    entries=$(list_limine_default_entries "$file" "$key") || return 1
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      _limine_default_count=$((_limine_default_count + 1))
      raw=${line#*=}
    done <<< "$entries"
  fi
  _limine_default_raw="$raw"
}

replace_limine_default_entry() {
  replace_limine_default_entry_in_file "$(limine_default_config_path)" "$@"
}

replace_limine_default_entry_in_file() {
  local file="$1" key="$2" desired="${3:-}" tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 2

  if ! awk -v key="$key" -v desired="$desired" '
    BEGIN {
      written = 0
      pattern = "^[[:space:]]*" key "[[:space:]]*="
    }
    $0 ~ pattern {
      if (desired != "" && !written) {
        print desired
        written = 1
      }
      next
    }
    { print }
    END {
      if (desired != "" && !written) {
        print desired
      }
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 2
  fi

  chmod --reference="$file" "$tmp" 2>/dev/null || true
  mv "$tmp" "$file" || {
    rm -f "$tmp"
    return 2
  }
  durable_sync "$file" || return 2
  durable_sync "$(dirname "$file")" || return 2
}

# Set or replace a simple key=value entry in /etc/default/limine.
# Returns 0 if the file changed, 1 if it was already correct, 2 on failure.
set_limine_default_value() {
  local key="$1" value="$2" raw desired
  desired="${key}=${value}"

  load_limine_default_entry "$key" || return 2
  raw=${_limine_default_raw:-}
  if [[ ${_limine_default_count:-0} -eq 1 && "$raw" == "$value" ]]; then
    return 1
  fi

  replace_limine_default_entry "$key" "$desired"
}

parse_limine_default_commands() {
  local raw="$1" current word
  _limine_command_words=()
  current="$raw"
  if [[ "$current" == \"* || "$current" == *\" ]]; then
    [[ "$current" == \"*\" && ${#current} -ge 2 ]] || return 1
    current=${current:1:${#current}-2}
  fi
  [[ "$current" != *$'\n'* && "$current" != *$'\r'* ]] || return 1
  [[ -z "$current" ]] && return 0
  read -r -a _limine_command_words <<< "$current" || return 1
  for word in "${_limine_command_words[@]}"; do
    [[ "$word" =~ ^[A-Za-z0-9_./:+,@%=-]+$ ]] || return 1
  done
}

# Ensure a whitespace-delimited command is present in COMMANDS_* without
# overwriting other upstream-managed commands.
# Returns 0 if the file changed, 1 if already correct, 2 on failure.
ensure_limine_default_command() {
  local key="$1" command="$2"
  local raw current desired word found=0

  load_limine_default_entry "$key" || return 2
  raw=${_limine_default_raw:-}

  if [[ -z "$raw" ]]; then
    replace_limine_default_entry "$key" "${key}=\"${command}\""
    return $?
  fi

  parse_limine_default_commands "$raw" || return 2
  current="${_limine_command_words[*]}"
  for word in "${_limine_command_words[@]}"; do
    [[ "$word" == "$command" ]] && found=$((found + 1))
  done
  (( found <= 1 )) || return 2

  if (( found == 1 )); then
    [[ ${_limine_default_count:-0} -eq 1 ]] && return 1
    desired="${key}=\"${current}\""
  elif [[ -n "$current" ]]; then
    desired="${key}=\"${current} ${command}\""
  else
    desired="${key}=\"${command}\""
  fi

  replace_limine_default_entry "$key" "$desired"
}

# Remove a repo-managed command token from COMMANDS_* when Limine's hook
# mechanism is available. Returns 0 if changed, 1 if already clean, 2 on failure.
remove_limine_default_command() {
  local key="$1" command="$2"
  local raw word desired="" changed=1 found=0

  load_limine_default_entry "$key" || return 2
  raw=${_limine_default_raw:-}
  [[ ${_limine_default_count:-0} -gt 0 ]] || return 1

  parse_limine_default_commands "$raw" || return 2
  for word in "${_limine_command_words[@]}"; do
    if [[ "$word" == "$command" ]]; then
      found=$((found + 1))
      changed=0
      continue
    fi
    if [[ -n "$desired" ]]; then
      desired="${desired} ${word}"
    else
      desired="$word"
    fi
  done
  (( found <= 1 )) || return 2

  if [[ $changed -ne 0 && ${_limine_default_count:-0} -eq 1 ]]; then
    return 1
  fi

  if [[ -n "$desired" ]]; then
    replace_limine_default_entry "$key" "${key}=\"${desired}\""
  else
    replace_limine_default_entry "$key"
  fi
}

limine_enrollment_hooks_present() {
  [[ -x /etc/boot/hooks/pre.d/10-limine-reset-enroll \
    && -x /etc/boot/hooks/post.d/90-limine-enroll-config ]]
}

# Applies one settings mutation that returns 0 when it changed the file, 1 when
# the file was already correct, and 2 on failure.
apply_limine_setting() {
  local message="$1" rc=0
  shift
  "$@" || rc=$?
  case "$rc" in
    0) _limine_settings_changed=true ;;
    1) ;;
    *)
      fail "$message"
      return 1
      ;;
  esac
}

# Ensure Limine is configured for Omarchy's current Secure Boot model:
# signed EFI binaries, enrolled limine.conf checksum, and disabled Limine
# path-hash generation. Limine >= 12 may still enforce path hashes
# when Secure Boot and config enrollment are both active; status reports that.
ensure_limine_secure_boot_settings() {
  local config
  config=$(limine_default_config_path)
  [[ -f "$config" ]] || {
    fail "${config} not found"
    return 1
  }
  transaction_backup_file "$config" || {
    fail "Could not record ${config} before repair"
    return 1
  }
  _limine_settings_changed=false
  apply_limine_setting "Could not update ENABLE_VERIFICATION in ${config}" \
    set_limine_default_value ENABLE_VERIFICATION no || return 1
  apply_limine_setting "Could not update ENABLE_ENROLL_LIMINE_CONFIG in ${config}" \
    set_limine_default_value ENABLE_ENROLL_LIMINE_CONFIG yes || return 1
  if limine_enrollment_hooks_present; then
    apply_limine_setting "Could not remove deprecated COMMANDS_BEFORE_SAVE entry in ${config}" \
      remove_limine_default_command COMMANDS_BEFORE_SAVE limine-reset-enroll || return 1
    apply_limine_setting "Could not remove deprecated COMMANDS_AFTER_SAVE entry in ${config}" \
      remove_limine_default_command COMMANDS_AFTER_SAVE limine-enroll-config || return 1
  else
    apply_limine_setting "Could not update COMMANDS_BEFORE_SAVE in ${config}" \
      ensure_limine_default_command COMMANDS_BEFORE_SAVE limine-reset-enroll || return 1
    apply_limine_setting "Could not update COMMANDS_AFTER_SAVE in ${config}" \
      ensure_limine_default_command COMMANDS_AFTER_SAVE limine-enroll-config || return 1
  fi
  if [[ "$_limine_settings_changed" == true ]]; then
    qact "Updated Limine Secure Boot settings"
  else
    qpass "Limine Secure Boot settings already configured"
  fi
}

current_limine_config_checksum() {
  local config checksum remainder
  config=$(limine_config_path)
  validate_control_file "$config" || return 1
  read -r checksum remainder < <(b2sum "$config" 2>/dev/null) || return 1
  [[ -z "$remainder" || "$remainder" == "${config}" ]] || return 1
  [[ "$checksum" =~ ^[0-9a-f]{128}$ ]] || return 1
  printf '%s\n' "$checksum"
}

read_limine_embedded_checksum() {
  local binary="$1" marker_offset checksum_offset embedded
  local -a marker_rows=()
  validate_control_file "$binary" || return 1
  mapfile -t marker_rows < <(LC_ALL=C grep -aobF "$LIMINE_CONFIG_MARKER" \
    "$binary" 2>/dev/null || true)
  [[ ${#marker_rows[@]} -eq 1 ]] || return 1
  marker_offset=${marker_rows[0]%%:*}
  [[ "$marker_offset" =~ ^[0-9]+$ ]] || return 1
  checksum_offset=$((marker_offset + ${#LIMINE_CONFIG_MARKER}))
  [[ $(stat -Lc '%s' "$binary" 2>/dev/null) -ge $((checksum_offset + 128)) ]] \
    || return 1
  embedded=$(dd if="$binary" bs=1 skip="$checksum_offset" count=128 \
    status=none 2>/dev/null) || return 1
  [[ "$embedded" =~ ^[0-9a-fA-F]{128}$ ]] || return 1
  printf '%s\n' "${embedded,,}"
}

verify_limine_embedded_checksum() {
  local binary="$1" expected="$2" embedded
  [[ "$expected" =~ ^[0-9a-f]{128}$ ]] || return 1
  embedded=$(read_limine_embedded_checksum "$binary") || {
    fail "Could not read a unique Limine config checksum from ${binary}"
    return 1
  }
  [[ "$embedded" == "$expected" ]] || {
    fail "Limine config checksum does not match in ${binary}"
    return 1
  }
}

install_enrolled_limine_binary() {
  local target="$1" checksum="$2" source parent temporary mode uid gid old_umask
  local signature_rc=0
  [[ "$checksum" =~ ^[0-9a-f]{128}$ ]] || return 1
  source=$(limine_unsigned_binary_path) || return 1
  validate_control_file "$source" || return 1
  validate_control_file "$target" || return 1
  parent=$(dirname "$target")
  validate_control_directory "$parent" || return 1
  read -r uid gid mode < <(stat -Lc '%u %g %a' "$target" 2>/dev/null) || return 1

  old_umask=$(umask)
  umask 077
  temporary=$(mktemp "${parent}/.omasecboot-limine.XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! cp "$source" "$temporary" \
    || ! chown "${uid}:${gid}" "$temporary" \
    || ! chmod "$mode" "$temporary"; then
    rm -f "$temporary"
    return 1
  fi

  qact "Enrolling Limine config checksum in ${target#"$(esp_path)"/}"
  if ! run_visible limine enroll-config "$temporary" "$checksum" \
    || ! run_visible sbctl sign "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  durable_sync "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  verify_limine_embedded_checksum "$temporary" "$checksum" || {
    rm -f "$temporary"
    return 1
  }
  sbctl_file_signature_state "$temporary" || signature_rc=$?
  [[ $signature_rc -eq 0 ]] || {
    rm -f "$temporary"
    return 1
  }
  if ! mv -f "$temporary" "$target" \
    || ! durable_sync "$parent" \
    || ! validate_control_file "$target" \
    || ! verify_limine_embedded_checksum "$target" "$checksum"; then
    rm -f "$temporary"
    return 1
  fi
  signature_rc=0
  sbctl_file_signature_state "$target" || signature_rc=$?
  [[ $signature_rc -eq 0 ]]
}

enroll_limine_config_targets() {
  local checksum="$1" binary
  [[ "$checksum" =~ ^[0-9a-f]{128}$ ]] || return 1
  for binary in "$(limine_primary_binary_path)" "$(limine_fallback_binary_path)"; do
    transaction_backup_file "$binary" || return 1
    install_enrolled_limine_binary "$binary" "$checksum" || return 1
  done
}

verify_limine_config_targets() {
  local expected="$1" current
  current=$(current_limine_config_checksum) || return 1
  [[ "$current" == "$expected" ]] || {
    fail "${LIMINE_CONF} changed during artifact repair"
    return 1
  }
  verify_limine_embedded_checksum "$(limine_primary_binary_path)" "$expected" \
    || return 1
  verify_limine_embedded_checksum "$(limine_fallback_binary_path)" "$expected"
}

sbctl_entry_should_be_removed() {
  local file="$1" output="${2:-$1}" file_lower output_lower
  file_lower=${file,,}
  output_lower=${output,,}

  [[ ! -e "$file" || ! -e "$output" \
    || "$file_lower" == */microsoft/* || "$output_lower" == */microsoft/* \
    || "$file_lower" == */bootia32.efi || "$output_lower" == */bootia32.efi ]]
}

list_stale_sbctl_entries() {
  local entries rc=0
  entries=$(list_enrolled_entries_for_cleanup) || rc=$?
  if [[ $rc -ne 0 ]]; then
    return 1
  fi

  if [[ -n "$entries" ]]; then
    printf '%s\n' "$entries" | while IFS=$'\t' read -r file output; do
      output="${output:-$file}"
      if sbctl_entry_should_be_removed "$file" "$output"; then
        printf '%s\t%s\n' "$file" "$output"
      fi
    done | sort -u
  fi
}

# Remove stale entries from sbctl's database:
#   - files missing from disk
#   - Microsoft paths (trusted via -m enrollment flag)
#   - BOOTIA32.EFI (32-bit, irrelevant on x86_64)
clean_stale_entries() {
  local stale files_db rc=0 failed=0
  files_db=$(resolve_sbctl_files_db_path) || return 1
  backup_sbctl_tracking_stores || {
    fail "Could not record sbctl tracking state before cleanup"
    return 1
  }
  stale=$(list_stale_sbctl_entries) || rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "Could not read sbctl tracking state"
    return 1
  fi

  local -a removable=()
  local file output
  if [[ -n "$stale" ]]; then
    while IFS=$'\t' read -r file output; do
      removable+=("$file")
    done <<< "$stale"
  fi

  [[ ${#removable[@]} -eq 0 ]] && return 0

  qact "Cleaning ${#removable[@]} stale database entries"
  for file in "${removable[@]}"; do
    if sbctl remove-file "$file" >/dev/null 2>&1; then
      qpass "${file#"${ESP}"/}"
    else
      warn "Could not remove: ${file#"${ESP}"/}"
      failed=$((failed + 1))
    fi
  done
  [[ ! -f "$files_db" ]] || durable_sync "$files_db" || return 1
  [[ $failed -eq 0 ]]
}

# sbctl 0.18 ignores --save for already-signed files. Persist the SigningEntry
# directly so zz-sbctl.hook can track snapshot UKIs on current Arch packages.
save_sbctl_file_entry() {
  local file="$1"
  local files_db tmp db_json db_identity="" db_hash="" db_dir database_existed=false

  files_db=$(resolve_sbctl_files_db_path) || { warn "Could not resolve sbctl files database path"; return 1; }
  validate_control_directory "$(dirname "$files_db")" \
    || { warn "Unsafe sbctl database directory"; return 1; }
  backup_sbctl_tracking_stores || return 1
  if [[ -e "$files_db" || -L "$files_db" ]]; then
    validate_control_file "$files_db" || return 1
    database_existed=true
    db_identity=$(control_file_identity "$files_db") || return 1
    db_hash=$(sha256_file "$files_db") || return 1
    db_json=$(<"$files_db") || return 1
    [[ -n "$db_json" ]] || db_json="{}"
  else
    db_json="{}"
  fi
  jq -e 'type == "object"' <<< "$db_json" >/dev/null || return 1

  db_dir=$(dirname "$files_db")
  tmp=$(mktemp "${db_dir}/.omasecboot.sbctl-files.XXXXXX") || {
    return 1
  }

  if ! printf '%s\n' "$db_json" | jq --arg file "$file" '
    (if type == "object" then . else {} end)
    | .[$file] = {file: $file, output_file: $file}
  ' > "$tmp"; then
    warn "Could not update sbctl database entry for ${file}"
    rm -f "$tmp"
    return 1
  fi

  if [[ "$database_existed" == true ]]; then
    chmod --reference="$files_db" "$tmp" || {
      rm -f "$tmp"
      return 1
    }
  elif ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  durable_sync "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  if [[ "$database_existed" == true ]]; then
    [[ "$(control_file_identity "$files_db")" == "$db_identity" \
      && "$(sha256_file "$files_db")" == "$db_hash" ]] || {
      warn "sbctl tracking state changed during direct registration"
      rm -f "$tmp"
      return 1
    }
    if ! mv "$tmp" "$files_db"; then
      warn "Could not write ${files_db}"
      rm -f "$tmp"
      return 1
    fi
  else
    if ! ln "$tmp" "$files_db"; then
      warn "sbctl tracking state appeared during direct registration"
      rm -f "$tmp"
      return 1
    fi
    rm -f "$tmp" || return 1
  fi

  validate_control_file "$files_db" || return 1
  durable_sync "$files_db" || return 1
  durable_sync "$db_dir"
}

artifact_esp_is_mounted() {
  local root fstype
  root=$(esp_path)
  mountpoint -q "$root" || return 1
  fstype=$(findmnt -n -T "$root" -o FSTYPE 2>/dev/null) || return 1
  [[ "$fstype" == vfat ]]
}

validate_sbctl_tracking_store() {
  local files_db db_json
  files_db=$(resolve_sbctl_files_db_path) || return 1
  validate_control_directory "$(dirname "$files_db")" || return 1
  if [[ -e "$files_db" || -L "$files_db" ]]; then
    validate_control_file "$files_db" || return 1
    db_json=$(<"$files_db") || return 1
    [[ -z "$db_json" ]] || jq -e 'type == "object"' <<< "$db_json" >/dev/null
  fi
}

validate_discovered_sbctl_mappings() {
  local files_db rows key source output file identity source_identity output_identity
  local output_key discovered_path
  local -A outputs=() discovered_identities=()
  files_db=$(resolve_sbctl_files_db_path) || return 1
  [[ -f "$files_db" ]] || return 0
  validate_control_file "$files_db" || return 1
  [[ -s "$files_db" ]] || return 0
  jq -e '
    type == "object" and all(to_entries[];
      ((.key | type) == "string") and
      (.key | startswith("/")) and
      (.key | explode | all(. >= 32 and . != 127)) and
      ((.value | type) == "object") and
      (((.value.file // .key) | type) == "string") and
      ((.value.file // .key) | startswith("/")) and
      ((.value.file // .key) | explode | all(. >= 32 and . != 127)) and
      (((.value.output_file // .value.output // .value.file // .key) | type) == "string") and
      ((.value.output_file // .value.output // .value.file // .key) | startswith("/")) and
      ((.value.output_file // .value.output // .value.file // .key) |
        explode | all(. >= 32 and . != 127))
    )
  ' "$files_db" >/dev/null || return 1
  rows=$(jq -r '
    to_entries[] |
    [.key, (.value.file // .key),
      (.value.output_file // .value.output // .value.file // .key)] | @tsv
  ' "$files_db") || return 1
  [[ -n "$rows" ]] || return 0

  for file in "${_discovered_efi_files[@]}"; do
    identity=$(control_file_identity "$file") || return 1
    [[ -z "${discovered_identities[$identity]:-}" ]] || return 1
    discovered_identities["$identity"]="$file"
  done

  while IFS=$'\t' read -r key source output; do
    [[ "$key" == "$source" ]] || return 1
    source_identity=$(control_file_identity "$source" 2>/dev/null || true)
    output_identity=$(control_file_identity "$output" 2>/dev/null || true)
    output_key="path:${output}"
    [[ -z "$output_identity" ]] || output_key="file:${output_identity}"
    [[ -z "${outputs[$output_key]:-}" ]] || return 1
    outputs["$output_key"]="$source"

    discovered_path=""
    [[ -z "$source_identity" ]] \
      || discovered_path=${discovered_identities[$source_identity]:-}
    if [[ -n "$discovered_path" \
      && ( "$source" != "$discovered_path" || "$output" != "$discovered_path" ) ]]; then
      fail "Discovered EFI artifact has an ambiguous sbctl mapping: ${discovered_path}"
      return 1
    fi
    discovered_path=""
    [[ -z "$output_identity" ]] \
      || discovered_path=${discovered_identities[$output_identity]:-}
    if [[ -n "$discovered_path" \
      && ( "$source" != "$discovered_path" || "$output" != "$discovered_path" ) ]]; then
      fail "Discovered EFI artifact has an ambiguous sbctl mapping: ${discovered_path}"
      return 1
    fi
  done <<< "$rows"
}

backup_sbctl_tracking_stores() {
  local candidates path
  candidates=$(sbctl_database_candidate_paths) || return 1
  [[ -n "$candidates" ]] || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    validate_control_directory "$(dirname "$path")" || return 1
    transaction_backup_file "$path" true || return 1
  done <<< "$candidates"
}

collect_discovered_efi_files() {
  local discovered file
  _discovered_efi_files=()
  discovered=$(discover_efi_files) || return 1
  [[ -n "$discovered" ]] || return 1
  mapfile -t _discovered_efi_files <<< "$discovered"
  for file in "${_discovered_efi_files[@]}"; do
    validate_control_file "$file" || return 1
  done
}

limine_shadow_config_paths() {
  printf '%s\n' \
    "$(esp_path)/EFI/limine/limine.conf" \
    "$(esp_path)/EFI/BOOT/limine.conf" \
    "$(esp_path)/EFI/arch-limine/limine.conf" \
    "$(esp_path)/boot/limine/limine.conf" \
    "$(esp_path)/boot/limine.conf" \
    "$(esp_path)/limine/limine.conf"
}

validate_no_limine_shadow_configs() {
  local path
  while IFS= read -r path; do
    if [[ -e "$path" || -L "$path" ]]; then
      fail "Possible Limine config shadowing file blocks proof: ${path}"
      return 1
    fi
  done < <(limine_shadow_config_paths)
}

sbctl_file_signature_state() {
  local file="$1" output state
  output=$(sbctl verify --json "$file" 2>/dev/null) || return 2
  state=$(jq -er --arg file "$file" '
    if type == "array" and length == 1 and
      .[0].file_name == $file and
      (.[0].is_signed == 1 or .[0].is_signed == 0 or .[0].is_signed == -1)
    then .[0].is_signed else empty end
  ' <<< "$output") || return 2
  [[ "$state" == 1 ]] && return 0
  return 1
}

sbctl_tracking_preflight() {
  command -v sbctl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  validate_sbctl_tracking_store
}

limine_managed_setting_state() {
  local key="$1" raw
  load_limine_default_entry "$key" || return 1
  [[ ${_limine_default_count:-0} -le 1 ]] || return 1
  if [[ ${_limine_default_count:-0} -eq 0 ]]; then
    printf 'unset\n'
    return 0
  fi
  raw=${_limine_default_raw:-}
  if [[ "$raw" == \"*\" && "$raw" == *\" ]]; then
    raw=${raw:1:${#raw}-2}
  fi
  [[ "$raw" == yes || "$raw" == no ]] || return 1
  printf '%s\n' "$raw"
}

limine_managed_token_state() {
  local key="$1" token="$2" raw word found=0
  load_limine_default_entry "$key" || return 1
  [[ ${_limine_default_count:-0} -le 1 ]] || return 1
  raw=${_limine_default_raw:-}
  parse_limine_default_commands "$raw" || return 1
  for word in "${_limine_command_words[@]}"; do
    [[ "$word" == "$token" ]] && found=$((found + 1))
  done
  (( found <= 1 )) || return 1
  if (( found == 1 )); then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

# Current state of one managed setting: yes, no, or unset for a value key,
# present or absent for a command token.
limine_managed_setting_current() {
  local key="$1" token="${2:-}"
  if [[ -n "$token" ]]; then
    limine_managed_token_state "$key" "$token"
  else
    limine_managed_setting_state "$key"
  fi
}

# Emits a settings record as "key managed original token" rows; the token
# column is last because it may be empty.
managed_settings_rows() {
  jq -r '.[] | [.key, .managed, .original, (.token // "")] | @tsv' <<< "$1"
}

current_limine_managed_settings_record() {
  local verification enrollment before_save after_save
  local managed_before=present managed_after=present
  verification=$(limine_managed_setting_state ENABLE_VERIFICATION) || return 1
  enrollment=$(limine_managed_setting_state ENABLE_ENROLL_LIMINE_CONFIG) || return 1
  before_save=$(limine_managed_token_state COMMANDS_BEFORE_SAVE limine-reset-enroll) \
    || return 1
  after_save=$(limine_managed_token_state COMMANDS_AFTER_SAVE limine-enroll-config) \
    || return 1
  if limine_enrollment_hooks_present; then
    managed_before=absent
    managed_after=absent
  fi
  jq -cn \
    --arg verification "$verification" --arg enrollment "$enrollment" \
    --arg before_save "$before_save" --arg after_save "$after_save" \
    --arg managed_before "$managed_before" --arg managed_after "$managed_after" \
    --arg before_token limine-reset-enroll \
    --arg after_token limine-enroll-config '[
      {
        path: "/etc/default/limine", key: "ENABLE_VERIFICATION",
        managed: "no", original: $verification
      },
      {
        path: "/etc/default/limine", key: "ENABLE_ENROLL_LIMINE_CONFIG",
        managed: "yes", original: $enrollment
      },
      {
        path: "/etc/default/limine", key: "COMMANDS_BEFORE_SAVE",
        token: $before_token, managed: $managed_before,
        original: $before_save
      },
      {
        path: "/etc/default/limine", key: "COMMANDS_AFTER_SAVE",
        token: $after_token, managed: $managed_after,
        original: $after_save
      }
    ]'
}

load_latest_recovery_ownership_records() {
  local manifest="$_recovery_previous_manifest_json" kind previous owner_id
  local managed_reference tracking_reference managed_path tracking_path
  _recovery_ownership_found=false
  _recovery_managed_reference_json=null
  _recovery_tracking_reference_json=null
  while [[ -n "$manifest" ]]; do
    managed_reference=$(jq -c '.domain_records.managed_settings' <<< "$manifest") || return 1
    tracking_reference=$(jq -c '.domain_records.tracking_ownership' <<< "$manifest") \
      || return 1
    [[ "$tracking_reference" == null || "$managed_reference" != null ]] || return 1
    if [[ "$managed_reference" != null && "$tracking_reference" != null ]]; then
      owner_id=$(jq -r '.id' <<< "$manifest") || return 1
      validate_managed_settings_record_reference "$owner_id" "$managed_reference" || return 1
      validate_tracking_ownership_record_reference "$owner_id" "$tracking_reference" \
        || return 1
      managed_path=$(jq -r '.path' <<< "$managed_reference") || return 1
      tracking_path=$(jq -r '.path' <<< "$tracking_reference") || return 1
      _managed_settings_record_json=$(read_control_document "$managed_path") || return 1
      _tracking_ownership_record_json=$(read_control_document "$tracking_path") || return 1
      _recovery_managed_reference_json="$managed_reference"
      _recovery_tracking_reference_json="$tracking_reference"
      _recovery_ownership_found=true
      return 0
    fi
    kind=$(jq -r '.kind' <<< "$manifest") || return 1
    [[ "$kind" == recovery-attempt ]] || {
      [[ "$kind" == root ]] || return 1
      return 0
    }
    previous=$(jq -c '.recovery.previous_attempt' <<< "$manifest") || return 1
    if [[ "$previous" == null ]]; then
      manifest="$_recovery_root_manifest_json"
    else
      validate_incident_reference "$previous" || return 1
      manifest="$_manifest_json"
    fi
  done
}

prepare_artifact_ownership() {
  local managed_reference tracking_reference tracked_raw file settings paths
  local previous_ownership=false
  local managed_before=present managed_after=present
  local -A tracked=()
  read_lifecycle || return 1
  managed_reference=$(jq -c '.managed_settings' <<< "$_lifecycle_json") || return 1
  tracking_reference=$(jq -c '.tracking_ownership' <<< "$_lifecycle_json") || return 1
  if [[ ( "$_lifecycle_state" == recovery-required \
      || ( "$_lifecycle_state" == transition \
        && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == recovery-attempt ) ) \
    && -n "${_recovery_previous_manifest_json:-}" ]]; then
    load_latest_recovery_ownership_records || return 1
    if [[ "$_recovery_ownership_found" == true ]]; then
      managed_reference="$_recovery_managed_reference_json"
      tracking_reference="$_recovery_tracking_reference_json"
      previous_ownership=true
    fi
  fi
  if [[ "$managed_reference" != null || "$tracking_reference" != null ]]; then
    [[ "$managed_reference" != null && "$tracking_reference" != null ]] || return 1
    [[ "$previous_ownership" == true ]] || load_lifecycle_ownership_records || return 1
    settings=$(jq -c '.settings' <<< "$_managed_settings_record_json") || return 1
    limine_managed_settings_are_repairable "$settings" || {
      fail "Managed Limine settings conflict with recorded OmaSecBoot ownership"
      return 1
    }
    if limine_enrollment_hooks_present; then
      managed_before=absent
      managed_after=absent
    fi
    settings=$(jq -c \
      --arg managed_before "$managed_before" --arg managed_after "$managed_after" '
        .[0].managed = "no" |
        .[1].managed = "yes" |
        .[2].managed = $managed_before |
        .[3].managed = $managed_after
      ' <<< "$settings") || return 1
    paths=$(jq -c '.paths' <<< "$_tracking_ownership_record_json") || return 1
    _repair_ownership_source=repair
  else
    [[ "$_lifecycle_state" == unmanaged || "$_lifecycle_state" == disabled \
      || ( "$_lifecycle_state" == transition \
        && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == root \
        && $(jq -r '.transaction.operation' <<< "$_lifecycle_json") == \
          activate-secure-boot-plan ) ]] || return 1
    settings=$(current_limine_managed_settings_record) || return 1
    paths='[]'
    _repair_ownership_source=setup
  fi

  tracked_raw=$(list_enrolled_paths) || return 1
  while IFS= read -r file; do
    [[ -n "$file" ]] && tracked["$file"]=1
  done <<< "$tracked_raw"
  for file in "${_discovered_efi_files[@]}"; do
    [[ -n "${tracked[$file]:-}" ]] && continue
    paths=$(jq -c --arg path "$file" '. + [$path] | unique | sort' <<< "$paths") || return 1
  done
  validate_managed_settings_record_json "00000000-0000-0000-0000-000000000000" \
    "$(jq -cn --argjson schema "$MANAGED_SETTINGS_SCHEMA_VERSION" \
      --arg version "$OMASECBOOT_VERSION" \
      --arg id '00000000-0000-0000-0000-000000000000' \
      --arg timestamp '2000-01-01T00:00:00Z' --arg source "$_repair_ownership_source" \
      --argjson settings "$settings" '{schema_version:$schema,writer_version:$version,
        transaction_id:$id,recorded_at:$timestamp,source:$source,settings:$settings}')" \
    || return 1
  jq -e 'length == (unique | length)' <<< "$paths" >/dev/null || return 1
  _repair_managed_settings_json="$settings"
  _repair_tracking_paths_json="$paths"
}

managed_settings_have_known_originals() {
  local settings="$1"
  jq -e 'type == "array" and length == 4 and all(.[]; .original != "unknown")' \
    <<< "$settings" >/dev/null
}

# Every setting is either at its managed value or at its known original.
limine_managed_settings_are_restorable() {
  local key managed original token current
  managed_settings_have_known_originals "$1" || return 1
  while IFS=$'\t' read -r key managed original token; do
    current=$(limine_managed_setting_current "$key" "$token") || return 1
    [[ "$current" == "$managed" || "$current" == "$original" ]] || return 1
  done < <(managed_settings_rows "$1")
}

# Every setting is at its managed value or, when the original is known, at
# that original; repair may then re-apply the managed value.
limine_managed_settings_are_repairable() {
  local key managed original token current
  while IFS=$'\t' read -r key managed original token; do
    current=$(limine_managed_setting_current "$key" "$token") || return 1
    [[ "$current" == "$managed" \
      || ( "$original" != unknown && "$current" == "$original" ) ]] || return 1
  done < <(managed_settings_rows "$1")
}

restore_limine_managed_settings() {
  local settings="$1" key managed original token current rc
  limine_managed_settings_are_restorable "$settings" || return 1
  while IFS=$'\t' read -r key managed original token; do
    current=$(limine_managed_setting_current "$key" "$token") || return 1
    [[ "$current" == "$original" ]] && continue
    [[ "$current" == "$managed" ]] || return 1
    rc=0
    if [[ -n "$token" && "$original" == present ]]; then
      ensure_limine_default_command "$key" "$token" || rc=$?
    elif [[ -n "$token" ]]; then
      remove_limine_default_command "$key" "$token" || rc=$?
    elif [[ "$original" == unset ]]; then
      replace_limine_default_entry "$key" || rc=$?
    else
      set_limine_default_value "$key" "$original" || rc=$?
    fi
    [[ $rc -eq 0 || $rc -eq 1 ]] || return 1
  done < <(managed_settings_rows "$settings")
  limine_managed_settings_are_original "$settings"
}

limine_managed_settings_are_original() {
  local key managed original token current
  managed_settings_have_known_originals "$1" || return 1
  while IFS=$'\t' read -r key managed original token; do
    current=$(limine_managed_setting_current "$key" "$token") || return 1
    [[ "$current" == "$original" ]] || return 1
  done < <(managed_settings_rows "$1")
}

# Tracked entries as a JSON array of {file, output}, read once.
tracked_entries_json() {
  local rows
  rows=$(list_enrolled_entries_for_cleanup) || return 1
  jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") |
      {file: .[0], output: (if (.[1] // "") == "" then .[0] else .[1] end)})
  ' <<< "$rows"
}

# Each owned path is tracked at most once, and only as its own output.
owned_tracking_state_is_safe() {
  local entries
  entries=$(tracked_entries_json) || return 1
  jq -en --argjson paths "$1" --argjson entries "$entries" '
    all($paths[]; . as $path |
      [$entries[] | select(.file == $path or .output == $path)] |
      length <= 1 and all(.[]; .file == $path and .output == $path))
  ' >/dev/null
}

owned_tracking_is_absent() {
  local entries
  entries=$(tracked_entries_json) || return 1
  jq -en --argjson paths "$1" --argjson entries "$entries" '
    all($paths[]; . as $path | all($entries[]; .file != $path and .output != $path))
  ' >/dev/null
}

remove_owned_tracking_entries() {
  local paths="$1" entries path files_db
  owned_tracking_state_is_safe "$paths" || return 1
  entries=$(tracked_entries_json) || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    sbctl remove-file "$path" >/dev/null || return 1
  done < <(jq -r --argjson entries "$entries" \
    '.[] | select(. as $path | any($entries[]; .file == $path and .output == $path))' \
    <<< "$paths")
  files_db=$(resolve_sbctl_files_db_path) || return 1
  [[ ! -f "$files_db" ]] || durable_sync "$files_db" || return 1
  owned_tracking_is_absent "$paths"
}

capture_unconfigure_limine_source() {
  local source
  source=$(limine_unsigned_binary_path) || return 1
  validate_control_file "$source" || return 1
  [[ $(read_limine_embedded_checksum "$source") == "$LIMINE_ZERO_CHECKSUM" ]] || return 1
  _unconfigure_limine_source_identity=$(control_file_identity "$source") || return 1
  _unconfigure_limine_source_hash=$(sha256_file "$source") || return 1
}

unconfigure_limine_source_is_unchanged() {
  local source
  source=$(limine_unsigned_binary_path) || return 1
  validate_control_file "$source" || return 1
  [[ "$(control_file_identity "$source")" == "$_unconfigure_limine_source_identity" \
    && "$(sha256_file "$source")" == "$_unconfigure_limine_source_hash" ]]
}

unconfigured_limine_targets_match_source() {
  local target hash
  unconfigure_limine_source_is_unchanged || return 1
  for target in "$(limine_primary_binary_path)" "$(limine_fallback_binary_path)"; do
    validate_control_file "$target" || return 1
    [[ $(read_limine_embedded_checksum "$target") == "$LIMINE_ZERO_CHECKSUM" ]] || return 1
    hash=$(sha256_file "$target") || return 1
    [[ "$hash" == "$_unconfigure_limine_source_hash" ]] || return 1
    if [[ "$target" == "$(limine_primary_binary_path)" ]]; then
      _unconfigure_primary_hash="$hash"
    else
      _unconfigure_fallback_hash="$hash"
    fi
  done
}

unconfigure_windows_state_identity() {
  local path
  path=$(windows_target_state_path) || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    validate_control_file "$path" || return 1
    printf 'present:%s:%s\n' "$(control_file_identity "$path")" "$(sha256_file "$path")"
  else
    printf 'absent\n'
  fi
}

# Everything an unconfiguration mutates must still match what its intent
# captured. Shared by the root transaction and by recovery.
unconfigure_inputs_are_current() {
  unconfigure_limine_tools_match_intent || return 1
  artifact_esp_is_mounted || return 1
  validate_control_file "$(limine_default_config_path)" || return 1
  validate_control_file "$(limine_config_path)" || return 1
  unconfigure_limine_source_is_unchanged || return 1
  read_current_firmware_modes || return 1
  [[ "$_secure_boot_mode" == 0 ]] || return 1
  limine_managed_settings_are_restorable "$_unconfigure_managed_settings_json" || return 1
  owned_tracking_state_is_safe "$_unconfigure_tracking_paths_json" || return 1
  windows_unconfigure_preflight || return 1
  [[ "$(unconfigure_windows_state_identity)" == "$_unconfigure_windows_identity" ]]
}

# The root transaction also requires the lifecycle's ownership records to be
# exactly the ones the preflight captured.
unconfigure_validate_all_conflicts() {
  load_lifecycle_ownership_records || return 1
  jq -en --argjson settings "$(jq -c '.settings' <<< "$_managed_settings_record_json")" \
    --argjson paths "$(jq -c '.paths' <<< "$_tracking_ownership_record_json")" \
    --argjson lifecycle "$_lifecycle_json" \
    --argjson expected_settings "$_unconfigure_managed_settings_json" \
    --argjson expected_paths "$_unconfigure_tracking_paths_json" \
    --argjson expected_managed "$_unconfigure_managed_reference_json" \
    --argjson expected_tracking "$_unconfigure_tracking_reference_json" '
      $settings == $expected_settings and $paths == $expected_paths and
      $lifecycle.managed_settings == $expected_managed and
      $lifecycle.tracking_ownership == $expected_tracking
    ' >/dev/null || return 1
  unconfigure_inputs_are_current
}

unconfigure_limine_tools_are_pinned() {
  local path version
  version=$(producer_package_version limine-mkinitcpio-hook) || return 1
  [[ "$version" == "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" ]] || return 1
  for path in "$(limine_install_path)" "$(limine_mkinitcpio_path)" \
    "$(limine_reset_enroll_path)"; do
    validate_control_file "$path" || return 1
    [[ -x "$path" ]] || return 1
    [[ $(producer_file_owner_package "$path") == limine-mkinitcpio-hook ]] || return 1
  done
}

# Path, device/inode identity, and hash of one pinned tool; the identity is
# read again after hashing so a replacement during the read is rejected.
pinned_tool_evidence_json() {
  local path="$1" identity hash
  identity=$(control_file_identity "$path") || return 1
  hash=$(sha256_file "$path") || return 1
  [[ $(control_file_identity "$path") == "$identity" ]] || return 1
  jq -cn --arg path "$path" --arg identity "$identity" --arg hash "$hash" \
    '{path: $path, identity: $identity, sha256: $hash}'
}

capture_unconfigure_limine_tools() {
  local version entry key evidence document
  unconfigure_limine_tools_are_pinned || return 1
  version=$(producer_package_version limine-mkinitcpio-hook) || return 1
  document=$(jq -cn --arg version "$version" \
    '{package: "limine-mkinitcpio-hook", version: $version}') || return 1
  for entry in install:limine_install_path mkinitcpio:limine_mkinitcpio_path \
    reset:limine_reset_enroll_path; do
    key=${entry%%:*}
    evidence=$(pinned_tool_evidence_json "$("${entry#*:}")") || return 1
    document=$(jq -c --arg key "$key" --argjson evidence "$evidence" \
      '.[$key] = $evidence' <<< "$document") || return 1
  done
  printf '%s\n' "$document"
}

unconfigure_limine_tools_match_intent() {
  local current
  current=$(capture_unconfigure_limine_tools) || return 1
  [[ "$(jq -Sc . <<< "$current")" == \
    "$(jq -Sc . <<< "$_unconfigure_limine_tools_json")" ]]
}

run_bound_unconfigure_limine_tool() {
  local key="$1" handoff="$2" path expected_identity expected_hash
  local tool_fd fd_path rc=0
  shift 2
  [[ "$key" == install || "$key" == mkinitcpio || "$key" == reset ]] || return 1
  [[ "$handoff" == true || "$handoff" == false ]] || return 1
  unconfigure_limine_tools_match_intent || return 1
  path=$(jq -r --arg key "$key" '.[$key].path' \
    <<< "$_unconfigure_limine_tools_json") || return 1
  expected_identity=$(jq -r --arg key "$key" '.[$key].identity' \
    <<< "$_unconfigure_limine_tools_json") || return 1
  expected_hash=$(jq -r --arg key "$key" '.[$key].sha256' \
    <<< "$_unconfigure_limine_tools_json") || return 1
  exec {tool_fd}< "$path" || return 1
  fd_path="/proc/self/fd/${tool_fd}"
  if [[ $(control_file_identity "$fd_path") != "$expected_identity" \
    || $(sha256_file "$fd_path") != "$expected_hash" ]]; then
    exec {tool_fd}<&-
    return 1
  fi
  if [[ "$handoff" == true ]]; then
    with_limine_lock_handoff "$fd_path" "$@" || rc=$?
  else
    "$fd_path" "$@" || rc=$?
  fi
  exec {tool_fd}<&-
  return "$rc"
}

unconfigure_preflight() {
  local command
  for command in b2sum find findmnt jq mountpoint sbctl sha256sum; do
    command -v "$command" >/dev/null 2>&1 || {
      fail "Required unconfiguration command not found: ${command}"
      return 1
    }
  done
  unconfigure_limine_tools_are_pinned || {
    fail "Required Limine tools do not match the supported package"
    return 1
  }
  _unconfigure_limine_tools_json=$(capture_unconfigure_limine_tools) || return 1
  artifact_esp_is_mounted || return 1
  validate_control_file "$(limine_default_config_path)" || return 1
  validate_control_file "$(limine_config_path)" || return 1
  validate_control_file "$(limine_primary_binary_path)" || return 1
  validate_control_file "$(limine_fallback_binary_path)" || return 1
  read_limine_embedded_checksum "$(limine_primary_binary_path)" >/dev/null || return 1
  read_limine_embedded_checksum "$(limine_fallback_binary_path)" >/dev/null || return 1
  capture_unconfigure_limine_source || return 1
  collect_discovered_efi_files || return 1
  sbctl_tracking_preflight || return 1
  validate_discovered_sbctl_mappings || return 1
  load_lifecycle_ownership_records || return 1
  _unconfigure_managed_settings_json=$(jq -c '.settings' \
    <<< "$_managed_settings_record_json") || return 1
  _unconfigure_tracking_paths_json=$(jq -c '.paths' \
    <<< "$_tracking_ownership_record_json") || return 1
  _unconfigure_managed_reference_json=$(jq -c '.managed_settings' \
    <<< "$_lifecycle_json") || return 1
  _unconfigure_tracking_reference_json=$(jq -c '.tracking_ownership' \
    <<< "$_lifecycle_json") || return 1
  _unconfigure_windows_identity=$(unconfigure_windows_state_identity) || return 1
  unconfigure_validate_all_conflicts || {
    fail "Unconfiguration found an unknown original value or a managed-state conflict"
    return 1
  }
}

# Publishes a transaction-local domain record create-once, accepts an existing
# record that equals the candidate apart from ignore_key, and binds its
# reference into the manifest exactly once. The validator receives the
# transaction id, the document, and the current manifest.
persist_transaction_domain_record() {
  local name="$1" schema="$2" validator="$3" ignore_key="$4" document="$5"
  local filename transaction_dir path existing reference current_reference
  case "$name" in
    unconfigure) filename=unconfigure-intent.json ;;
    final_proof) filename=final-proof.json ;;
    *) return 1 ;;
  esac
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  path="${transaction_dir}/${filename}"
  read_transaction_manifest "$_transaction_id" || return 1
  "$validator" "$_transaction_id" "$document" "$_manifest_json" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    existing=$(read_control_document "$path") || return 1
    "$validator" "$_transaction_id" "$existing" "$_manifest_json" || return 1
    jq -en --argjson existing "$existing" --argjson candidate "$document" \
      --arg key "$ignore_key" \
      '($existing | del(.[$key])) == ($candidate | del(.[$key]))' >/dev/null || return 1
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

persist_unconfigure_intent() {
  local document
  unconfigure_validate_all_conflicts || return 1
  document=$(jq -cn \
    --argjson schema "$UNCONFIGURE_INTENT_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg id "$_transaction_id" \
    --arg timestamp "$(utc_timestamp)" --arg source "$(limine_unsigned_binary_path)" \
    --arg source_identity "$_unconfigure_limine_source_identity" \
    --arg source_hash "$_unconfigure_limine_source_hash" \
    --arg windows_identity "$_unconfigure_windows_identity" \
    --argjson managed "$_unconfigure_managed_reference_json" \
    --argjson tracking "$_unconfigure_tracking_reference_json" \
    --argjson tools "$_unconfigure_limine_tools_json" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      operation: "unconfigure",
      recorded_at: $timestamp,
      managed_settings: $managed,
      tracking_ownership: $tracking,
      windows_state_identity: $windows_identity,
      limine_source: {path: $source, identity: $source_identity, sha256: $source_hash},
      limine_tools: $tools
    }') || return 1
  persist_transaction_domain_record unconfigure "$UNCONFIGURE_INTENT_SCHEMA_VERSION" \
    validate_unconfigure_intent_json recorded_at "$document" || return 1
  _unconfigure_intent_reference_json="$_persisted_record_reference"
}

run_checked_stock_limine_rebuild() {
  run_visible run_bound_unconfigure_limine_tool install true \
    --no-efi-register --fallback || return 1
  run_visible run_bound_unconfigure_limine_tool mkinitcpio true || return 1
  run_visible run_bound_unconfigure_limine_tool reset false || return 1
  durable_sync "$(esp_path)" || return 1
  unconfigured_limine_targets_match_source
}

persist_unconfigure_proof() {
  local document root_incident operation="$_transaction_operation"
  [[ "$operation" == unconfigure || "$operation" == unconfigure-recovery ]] || return 1
  unconfigured_limine_targets_match_source || return 1
  root_incident=null
  [[ "$operation" == unconfigure ]] || root_incident="$_recovery_root_reference"
  document=$(jq -cn \
    --argjson schema "$UNCONFIGURE_PROOF_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg id "$_transaction_id" \
    --arg timestamp "$(utc_timestamp)" --arg operation "$operation" \
    --arg primary "$(limine_primary_binary_path)" --arg primary_hash "$_unconfigure_primary_hash" \
    --arg fallback "$(limine_fallback_binary_path)" \
    --arg fallback_hash "$_unconfigure_fallback_hash" \
    --arg source "$(limine_unsigned_binary_path)" \
    --arg source_hash "$_unconfigure_limine_source_hash" \
    --arg zero_checksum "$LIMINE_ZERO_CHECKSUM" \
    --argjson intent "$_unconfigure_intent_reference_json" \
    --argjson root_incident "$root_incident" \
    --argjson managed_settings "$_unconfigure_managed_reference_json" \
    --argjson tracking_ownership "$_unconfigure_tracking_reference_json" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      operation: $operation,
      proved_at: $timestamp,
      intent: $intent,
      root_incident: $root_incident,
      secure_boot: 0,
      settings: "original",
      windows: "managed-block-absent",
      managed_settings: $managed_settings,
      tracking_ownership: $tracking_ownership,
      limine: {
        source: {path: $source, sha256: $source_hash},
        primary: {path: $primary, config_checksum: $zero_checksum, sha256: $primary_hash},
        fallback: {path: $fallback, config_checksum: $zero_checksum, sha256: $fallback_hash}
      }
    }') || return 1
  persist_transaction_domain_record final_proof "$UNCONFIGURE_PROOF_SCHEMA_VERSION" \
    validate_unconfigure_proof_json proved_at "$document"
}

unconfigure_recovery_failpoint() {
  :
}

load_unconfigure_recovery_context() {
  local recovery_operation root_id intent_path intent_document managed_path tracking_path
  local managed_document tracking_document
  load_recovery_context || return $?
  recovery_operation=$(recovery_operation_for_root_manifest \
    "$_recovery_root_manifest_json") || return 1
  [[ "$recovery_operation" == unconfigure-recovery ]] || return 1
  _recovery_terminal_state=$(recovery_terminal_state_for_root_manifest \
    "$_recovery_root_manifest_json" "$recovery_operation") || return 1
  [[ "$_recovery_terminal_state" == disabled ]] || return 1
  root_id=$(jq -r '.id' <<< "$_recovery_root_reference") || return 1
  _unconfigure_intent_reference_json=$(jq -c '.domain_records.unconfigure' \
    <<< "$_recovery_root_manifest_json") || return 1
  validate_unconfigure_intent_reference "$root_id" \
    "$_unconfigure_intent_reference_json" "$_recovery_root_manifest_json" || return 1
  intent_path=$(jq -r '.path' <<< "$_unconfigure_intent_reference_json") || return 1
  intent_document=$(read_control_document "$intent_path") || return 1

  _unconfigure_managed_reference_json=$(jq -c '.managed_settings' \
    <<< "$intent_document") || return 1
  _unconfigure_tracking_reference_json=$(jq -c '.tracking_ownership' \
    <<< "$intent_document") || return 1
  _unconfigure_windows_identity=$(jq -r '.windows_state_identity' \
    <<< "$intent_document") || return 1
  _unconfigure_limine_source_identity=$(jq -r '.limine_source.identity' \
    <<< "$intent_document") || return 1
  _unconfigure_limine_source_hash=$(jq -r '.limine_source.sha256' \
    <<< "$intent_document") || return 1
  _unconfigure_limine_tools_json=$(jq -c '.limine_tools' \
    <<< "$intent_document") || return 1

  managed_path=$(jq -r '.path' <<< "$_unconfigure_managed_reference_json") || return 1
  tracking_path=$(jq -r '.path' <<< "$_unconfigure_tracking_reference_json") || return 1
  managed_document=$(read_control_document "$managed_path") || return 1
  tracking_document=$(read_control_document "$tracking_path") || return 1
  _unconfigure_managed_settings_json=$(jq -c '.settings' <<< "$managed_document") || return 1
  _unconfigure_tracking_paths_json=$(jq -c '.paths' <<< "$tracking_document") || return 1
  unconfigure_inputs_are_current
}

# Restores the recorded settings and stock Limine state phase by phase. Every
# phase is idempotent, so a recovery attempt can run the whole sequence again.
unconfigure_apply_phases() {
  transaction_phase_start restore-managed-settings || return 1
  restore_limine_managed_settings "$_unconfigure_managed_settings_json" || return 1
  unconfigure_recovery_failpoint after-restore-managed-settings || return 1
  transaction_phase_complete restore-managed-settings || return 1

  transaction_phase_start remove-windows-entry || return 1
  remove_windows_managed_block_for_unconfigure || return 1
  unconfigure_recovery_failpoint after-remove-windows-entry || return 1
  transaction_phase_complete remove-windows-entry || return 1

  transaction_phase_start remove-owned-tracking || return 1
  remove_owned_tracking_entries "$_unconfigure_tracking_paths_json" || return 1
  unconfigure_recovery_failpoint after-remove-owned-tracking || return 1
  transaction_phase_complete remove-owned-tracking || return 1

  transaction_phase_start reset-config-enrollment || return 1
  preserve_transaction_files_on_failure || return 1
  run_visible run_bound_unconfigure_limine_tool reset false || return 1
  unconfigure_recovery_failpoint after-reset-config-enrollment || return 1
  transaction_phase_complete reset-config-enrollment || return 1

  transaction_phase_start rebuild-stock-limine || return 1
  run_checked_stock_limine_rebuild || return 1
  unconfigure_recovery_failpoint after-rebuild-stock-limine || return 1
  transaction_phase_complete rebuild-stock-limine || return 1

  transaction_phase_start prove-unconfigured || return 1
  read_current_firmware_modes || return 1
  [[ "$_secure_boot_mode" == 0 ]] || return 1
  limine_managed_settings_are_original "$_unconfigure_managed_settings_json" || return 1
  owned_tracking_is_absent "$_unconfigure_tracking_paths_json" || return 1
  windows_unconfigure_preflight || return 1
  [[ "$_windows_block_state" == absent \
    && "$(unconfigure_windows_state_identity)" == "$_unconfigure_windows_identity" ]] \
    || return 1
  persist_unconfigure_proof || return 1
  unconfigure_recovery_failpoint after-prove-unconfigured || return 1
  transaction_phase_complete prove-unconfigured
}

unconfigure_recovery_transaction() {
  unconfigure_inputs_are_current || return 1
  unconfigure_apply_phases
}

run_unconfigure_recovery_locked() {
  boot_locks_are_held || return 1
  load_unconfigure_recovery_context || return $?
  run_recovery_attempt_locked unconfigure-recovery unconfigure_recovery_transaction \
    "unconfigure recovery"
}

unconfigure_software_state() {
  local file
  transaction_phase_start record-unconfigure || return 1
  persist_unconfigure_intent || return 1
  transaction_phase_complete record-unconfigure || return 1

  transaction_phase_start backup-software-state || return 1
  transaction_backup_file "$(limine_default_config_path)" || return 1
  transaction_backup_file "$(limine_config_path)" || return 1
  transaction_backup_file "$(limine_primary_binary_path)" || return 1
  transaction_backup_file "$(limine_fallback_binary_path)" || return 1
  for file in "${_discovered_efi_files[@]}"; do
    transaction_backup_file "$file" || return 1
  done
  backup_sbctl_tracking_stores || return 1
  transaction_phase_complete backup-software-state || return 1

  unconfigure_validate_all_conflicts || return 1
  unconfigure_apply_phases
}

run_dormant_unconfigure() {
  run_lifecycle_transaction_with_preflight unconfigure disabled active \
    unconfigure_preflight unconfigure_software_state
}

# Checks shared by every artifact mutation: tools, the mounted ESP, no
# shadowing Limine config, the managed defaults file, the unsigned Limine
# package binary with its checksum slot, and a usable sbctl tracking store.
artifact_environment_preflight() {
  local command source
  for command in b2sum chmod chown cp dd find grep limine ln mktemp mountpoint \
    findmnt mv sbctl sync jq; do
    command -v "$command" >/dev/null 2>&1 || {
      fail "Required artifact repair command not found: ${command}"
      return 1
    }
  done
  artifact_esp_is_mounted || {
    fail "$(esp_path) is not the mounted FAT32 ESP"
    return 1
  }
  validate_no_limine_shadow_configs || return 1
  validate_control_file "$(limine_default_config_path)" || return 1
  source=$(limine_unsigned_binary_path) || return 1
  validate_control_file "$source" || {
    fail "Unsigned Limine package binary is unavailable or unsafe: ${source}"
    return 1
  }
  read_limine_embedded_checksum "$source" >/dev/null || {
    fail "Unsigned Limine package binary has no unique config checksum slot"
    return 1
  }
  sbctl_tracking_preflight || {
    fail "sbctl tracking state is unavailable or unsafe"
    return 1
  }
}

artifact_repair_preflight() {
  local file primary_found=false fallback_found=false
  artifact_environment_preflight || return 1
  _repair_config_checksum=$(current_limine_config_checksum) || return 1
  for file in "$(limine_primary_binary_path)" "$(limine_fallback_binary_path)"; do
    read_limine_embedded_checksum "$file" >/dev/null || {
      fail "Could not find one valid Limine config checksum slot in ${file}"
      return 1
    }
  done
  collect_discovered_efi_files || {
    fail "Could not discover a complete EFI artifact set under $(esp_path)"
    return 1
  }
  for file in "${_discovered_efi_files[@]}"; do
    [[ "$file" == "$(limine_primary_binary_path)" ]] && primary_found=true
    [[ "$file" == "$(limine_fallback_binary_path)" ]] && fallback_found=true
  done
  [[ "$primary_found" == true && "$fallback_found" == true ]] || {
    fail "Both bootable Limine x64 binaries must be present in EFI discovery"
    return 1
  }
  validate_discovered_sbctl_mappings || {
    fail "sbctl source and output mappings are ambiguous for EFI repair"
    return 1
  }
  prepare_artifact_ownership || {
    fail "Could not establish managed-setting and sbctl ownership for artifact repair"
    return 1
  }
}

producer_reconstruction_preflight() {
  artifact_environment_preflight || return 1
  validate_control_file "$(limine_config_path)" || return 1
  current_limine_config_checksum >/dev/null
}

cleanup_tracking_transaction() {
  transaction_phase_start "clean-tracking" || return 1
  clean_stale_entries || return 1
  transaction_phase_complete "clean-tracking"
}

run_tracking_cleanup() {
  local operation="$1"
  run_lifecycle_transaction_with_preflight "$operation" "active" "active" \
    sbctl_tracking_preflight cleanup_tracking_transaction
}

sign_all_efi() {
  local -a enrolled=()
  local enrolled_raw file files_db signature_rc signed=0 registered=0 skipped=0
  local -A enrolled_map=()

  collect_discovered_efi_files || {
    fail "Could not discover EFI files under $(esp_path)"
    return 1
  }
  backup_sbctl_tracking_stores || return 1
  validate_discovered_sbctl_mappings || return 1
  enrolled_raw=$(list_enrolled_paths) || {
    fail "Could not read sbctl tracking state"
    return 1
  }
  [[ -z "$enrolled_raw" ]] || mapfile -t enrolled <<< "$enrolled_raw"
  for file in "${enrolled[@]}"; do
    enrolled_map["$file"]=1
  done

  for file in "${_discovered_efi_files[@]}"; do
    signature_rc=0
    sbctl_file_signature_state "$file" || signature_rc=$?
    case "$signature_rc" in
      0)
        if [[ -n "${enrolled_map[$file]:-}" ]]; then
          qpass "${file#"$(esp_path)"/} ${DIM}already signed${NC}"
          skipped=$((skipped + 1))
        elif save_sbctl_file_entry "$file"; then
          qact "${file#"$(esp_path)"/} ${DIM}registered${NC}"
          enrolled_map["$file"]=1
          registered=$((registered + 1))
        else
          fail "Failed to register ${file#"$(esp_path)"/}"
          return 1
        fi
        ;;
      1)
        transaction_backup_file "$file" || return 1
        run_visible sbctl sign -s "$file" || {
          fail "Failed to sign ${file#"$(esp_path)"/}"
          return 1
        }
        durable_sync "$file" || return 1
        files_db=$(resolve_sbctl_files_db_path) || return 1
        [[ ! -f "$files_db" ]] || durable_sync "$files_db" || return 1
        qact "${file#"$(esp_path)"/} ${DIM}signed${NC}"
        signed=$((signed + 1))
        ;;
      *)
        fail "Could not verify local signature state for ${file#"$(esp_path)"/}"
        return 1
        ;;
    esac
  done
  [[ "$QUIET" == true ]] \
    || pass "Signed ${signed}, registered ${registered}, skipped ${skipped}"
}

verify_all_efi_artifacts() {
  local expected="$1" persist_proof="${2:-false}"
  local enrolled_raw file config config_hash config_identity hash identity
  local proved_artifacts='[]'
  local -A enrolled_map=()

  [[ "$persist_proof" == true || "$persist_proof" == false ]] || return 1
  verify_limine_config_targets "$expected" || return 1
  collect_discovered_efi_files || return 1
  validate_discovered_sbctl_mappings || return 1
  enrolled_raw=$(list_enrolled_paths) || {
    fail "Could not read final sbctl tracking state"
    return 1
  }
  while IFS= read -r file; do
    [[ -n "$file" ]] && enrolled_map["$file"]=1
  done <<< "$enrolled_raw"

  for file in "${_discovered_efi_files[@]}"; do
    [[ -n "${enrolled_map[$file]:-}" ]] || {
      fail "EFI artifact is not tracked by sbctl: ${file}"
      return 1
    }
    sbctl_file_signature_state "$file" || {
      fail "EFI artifact lacks the local signature: ${file}"
      return 1
    }
    hash=$(sha256_file "$file") || return 1
    identity=$(control_file_identity "$file") || return 1
    proved_artifacts=$(jq -c --arg path "$file" --arg hash "$hash" --arg identity "$identity" \
      '. + [{identity: $identity, path: $path, sha256: $hash, signature: "local",
        tracking: "tracked"}]' <<< "$proved_artifacts") || return 1
    qpass "${file#"$(esp_path)"/} ${DIM}proved${NC}"
  done
  if [[ "$persist_proof" == true ]]; then
    config=$(limine_config_path) || return 1
    validate_control_file "$config" || return 1
    config_hash=$(sha256_file "$config") || return 1
    config_identity=$(control_file_identity "$config") || return 1
    persist_final_artifact_proof "$expected" "$config" "$config_hash" \
      "$config_identity" "$proved_artifacts" || return 1
  fi
  qpass "All discovered EFI artifacts are locally signed and tracked"
}

# Re-reads every proved artifact and the config once more at the persistence
# boundary, then publishes the proof create-once.
persist_final_artifact_proof() {
  local expected="$1" config="$2" config_hash="$3" config_identity="$4" artifacts="$5"
  local artifact file document
  [[ "$_transaction_active" == true && "$expected" =~ ^[0-9a-f]{128}$ \
    && "$config_hash" =~ ^[0-9a-f]{64}$ \
    && "$config_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  jq -e 'type == "array" and length > 0' <<< "$artifacts" >/dev/null || return 1
  [[ "$config" == "$(limine_config_path)" ]] || return 1
  validate_control_file "$config" || return 1
  [[ $(sha256_file "$config") == "$config_hash" \
    && $(control_file_identity "$config") == "$config_identity" ]] || return 1
  while IFS= read -r artifact; do
    file=$(jq -r '.path' <<< "$artifact") || return 1
    validate_control_file "$file" || return 1
    [[ $(sha256_file "$file") == "$(jq -r '.sha256' <<< "$artifact")" \
      && $(control_file_identity "$file") == "$(jq -r '.identity' <<< "$artifact")" ]] \
      || return 1
  done < <(jq -c '.[]' <<< "$artifacts")
  document=$(jq -cn \
    --argjson schema "$FINAL_PROOF_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg id "$_transaction_id" \
    --arg timestamp "$(utc_timestamp)" --arg config "$config" --arg checksum "$expected" \
    --arg config_hash "$config_hash" --arg config_identity "$config_identity" \
    --argjson artifacts "$artifacts" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      proved_at: $timestamp,
      config: {path: $config, checksum: $checksum, sha256: $config_hash,
        identity: $config_identity},
      artifacts: $artifacts
    }') || return 1
  persist_transaction_domain_record final_proof "$FINAL_PROOF_SCHEMA_VERSION" \
    validate_final_proof_json proved_at "$document"
}

repair_boot_artifacts() {
  transaction_phase_start "backup-artifacts" || return 1
  transaction_backup_file "$(limine_default_config_path)" || return 1
  transaction_backup_file "$(limine_primary_binary_path)" || return 1
  transaction_backup_file "$(limine_fallback_binary_path)" || return 1
  backup_sbctl_tracking_stores || return 1
  transaction_phase_complete "backup-artifacts" || return 1

  persist_managed_settings_record "$_repair_ownership_source" \
    "$_repair_managed_settings_json" || return 1
  persist_tracking_ownership_record "$_repair_tracking_paths_json" || return 1

  transaction_phase_start "configure-limine" || return 1
  ensure_limine_secure_boot_settings || return 1
  transaction_phase_complete "configure-limine" || return 1

  transaction_phase_start "enroll-config" || return 1
  enroll_limine_config_targets "$_repair_config_checksum" || return 1
  transaction_phase_complete "enroll-config" || return 1

  transaction_phase_start "verify-config" || return 1
  verify_limine_config_targets "$_repair_config_checksum" || return 1
  transaction_phase_complete "verify-config" || return 1

  transaction_phase_start "clean-tracking" || return 1
  clean_stale_entries || return 1
  transaction_phase_complete "clean-tracking" || return 1

  transaction_phase_start "sign-efi" || return 1
  sign_all_efi || return 1
  transaction_phase_complete "sign-efi" || return 1

  transaction_phase_start "prove-artifacts" || return 1
  verify_all_efi_artifacts "$_repair_config_checksum" true || return 1
  transaction_phase_complete "prove-artifacts"
}

run_artifact_repair() {
  run_lifecycle_transaction_with_preflight "$1" "active" "active" \
    artifact_repair_preflight repair_boot_artifacts
}
