#!/bin/bash
# OmaSecBoot: key creation, EFI signing, database cleanup

readonly LIMINE_DEFAULT_CONF="/etc/default/limine"
readonly LIMINE_CONFIG_MARKER='++CONFIG_B2SUM_SIGNATURE++'

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
  ' "$file" 2>/dev/null
}

load_limine_default_entry() {
  local key="$1" line raw=""
  _limine_default_raw=""
  _limine_default_count=0

  while IFS= read -r line; do
    _limine_default_count=$((_limine_default_count + 1))
    raw=${line#*=}
  done < <(list_limine_default_entries "$(limine_default_config_path)" "$key" || true)

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

# Ensure a space-delimited command is present in COMMANDS_* without
# overwriting other upstream-managed commands.
# Returns 0 if the file changed, 1 if already correct, 2 on failure.
ensure_limine_default_command() {
  local key="$1" command="$2"
  local raw current desired

  load_limine_default_entry "$key" || return 2
  raw=${_limine_default_raw:-}

  if [[ -z "$raw" ]]; then
    replace_limine_default_entry "$key" "${key}=\"${command}\""
    return $?
  fi

  current="$raw"
  if [[ "$current" == \"*\" && "$current" == *\" ]]; then
    current=${current:1:${#current}-2}
  fi

  if [[ " $current " == *" $command "* ]]; then
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
  local raw current word desired="" changed=1

  load_limine_default_entry "$key" || return 2
  raw=${_limine_default_raw:-}
  [[ ${_limine_default_count:-0} -gt 0 ]] || return 1

  current="$raw"
  if [[ "$current" == \"*\" && "$current" == *\" ]]; then
    current=${current:1:${#current}-2}
  fi

  for word in $current; do
    if [[ "$word" == "$command" ]]; then
      changed=0
      continue
    fi
    if [[ -n "$desired" ]]; then
      desired="${desired} ${word}"
    else
      desired="$word"
    fi
  done

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

  local changed=1
  local rc

  transaction_backup_file "$config" || {
    fail "Could not record ${config} before repair"
    return 1
  }

  set_limine_default_value "ENABLE_VERIFICATION" "no"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    changed=0
  elif [[ $rc -ne 1 ]]; then
    fail "Could not update ENABLE_VERIFICATION in ${config}"
    return 1
  fi

  set_limine_default_value "ENABLE_ENROLL_LIMINE_CONFIG" "yes"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    changed=0
  elif [[ $rc -ne 1 ]]; then
    fail "Could not update ENABLE_ENROLL_LIMINE_CONFIG in ${config}"
    return 1
  fi

  if limine_enrollment_hooks_present; then
    remove_limine_default_command "COMMANDS_BEFORE_SAVE" "limine-reset-enroll"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      fail "Could not remove deprecated COMMANDS_BEFORE_SAVE entry in ${config}"
      return 1
    fi

    remove_limine_default_command "COMMANDS_AFTER_SAVE" "limine-enroll-config"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      fail "Could not remove deprecated COMMANDS_AFTER_SAVE entry in ${config}"
      return 1
    fi
  else
    ensure_limine_default_command "COMMANDS_BEFORE_SAVE" "limine-reset-enroll"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      fail "Could not update COMMANDS_BEFORE_SAVE in ${config}"
      return 1
    fi

    ensure_limine_default_command "COMMANDS_AFTER_SAVE" "limine-enroll-config"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      fail "Could not update COMMANDS_AFTER_SAVE in ${config}"
      return 1
    fi
  fi

  if [[ $changed -eq 0 ]]; then
    qact "Updated Limine Secure Boot settings"
    return 0
  fi

  qpass "Limine Secure Boot settings already configured"
  return 0
}

# Regenerate Limine entries during setup or explicit rebuild flows.
refresh_limine_config() {
  command -v limine-update >/dev/null 2>&1 || return 1
  qact "Regenerating Limine boot entries"
  if [[ "$QUIET" == true ]]; then
    limine-update >/dev/null || return 1
  else
    limine-update || return 1
  fi

  if command -v limine-snapper-sync >/dev/null 2>&1; then
    qact "Refreshing Limine snapshot entries"
    if [[ "$QUIET" == true ]]; then
      limine-snapper-sync >/dev/null || return 1
    else
      limine-snapper-sync || return 1
    fi
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
  if [[ "$QUIET" == true ]]; then
    limine enroll-config --quiet "$temporary" "$checksum" >/dev/null || {
      rm -f "$temporary"
      return 1
    }
    sbctl sign "$temporary" >/dev/null || {
      rm -f "$temporary"
      return 1
    }
  else
    limine enroll-config "$temporary" "$checksum" || {
      rm -f "$temporary"
      return 1
    }
    sbctl sign "$temporary" || {
      rm -f "$temporary"
      return 1
    }
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

artifact_repair_preflight() {
  local file embedded source primary_found=false fallback_found=false
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
  _repair_config_checksum=$(current_limine_config_checksum) || return 1
  for file in "$(limine_primary_binary_path)" "$(limine_fallback_binary_path)"; do
    embedded=$(read_limine_embedded_checksum "$file") || {
      fail "Could not find one valid Limine config checksum slot in ${file}"
      return 1
    }
    [[ "$embedded" =~ ^[0-9a-f]{128}$ ]] || return 1
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
  sbctl_tracking_preflight || {
    fail "sbctl tracking state is unavailable or unsafe"
    return 1
  }
  validate_discovered_sbctl_mappings || {
    fail "sbctl source and output mappings are ambiguous for EFI repair"
    return 1
  }
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
        if [[ "$QUIET" == true ]]; then
          sbctl sign -s "$file" >/dev/null || {
            fail "Failed to sign ${file#"$(esp_path)"/}"
            return 1
          }
        else
          sbctl sign -s "$file" || return 1
        fi
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
  local expected="$1" enrolled_raw file signature_rc
  local -a enrolled=() proved_files=()
  local -A enrolled_map=() proved_hash=() proved_identity=()

  verify_limine_config_targets "$expected" || return 1
  collect_discovered_efi_files || return 1
  validate_discovered_sbctl_mappings || return 1
  proved_files=("${_discovered_efi_files[@]}")
  enrolled_raw=$(list_enrolled_paths) || {
    fail "Could not read final sbctl tracking state"
    return 1
  }
  [[ -z "$enrolled_raw" ]] || mapfile -t enrolled <<< "$enrolled_raw"
  for file in "${enrolled[@]}"; do
    enrolled_map["$file"]=1
  done

  for file in "${proved_files[@]}"; do
    [[ -n "${enrolled_map[$file]:-}" ]] || {
      fail "EFI artifact is not tracked by sbctl: ${file}"
      return 1
    }
    signature_rc=0
    sbctl_file_signature_state "$file" || signature_rc=$?
    [[ $signature_rc -eq 0 ]] || {
      fail "EFI artifact lacks the local signature: ${file}"
      return 1
    }
    proved_hash["$file"]=$(sha256_file "$file") || return 1
    proved_identity["$file"]=$(control_file_identity "$file") || return 1
    qpass "${file#"$(esp_path)"/} ${DIM}proved${NC}"
  done

  collect_discovered_efi_files || return 1
  [[ ${#proved_files[@]} -eq ${#_discovered_efi_files[@]} ]] || return 1
  for file in "${!proved_files[@]}"; do
    [[ "${proved_files[$file]}" == "${_discovered_efi_files[$file]}" ]] || return 1
  done
  verify_limine_config_targets "$expected" || return 1
  enrolled=()
  enrolled_map=()
  enrolled_raw=$(list_enrolled_paths) || return 1
  [[ -z "$enrolled_raw" ]] || mapfile -t enrolled <<< "$enrolled_raw"
  for file in "${enrolled[@]}"; do
    enrolled_map["$file"]=1
  done
  for file in "${proved_files[@]}"; do
    [[ "$(sha256_file "$file")" == "${proved_hash[$file]}" \
      && "$(control_file_identity "$file")" == "${proved_identity[$file]}" \
      && -n "${enrolled_map[$file]:-}" ]] || return 1
    signature_rc=0
    sbctl_file_signature_state "$file" || signature_rc=$?
    [[ $signature_rc -eq 0 ]] || return 1
  done
  qpass "All discovered EFI artifacts are locally signed and tracked"
}

repair_boot_artifacts() {
  transaction_phase_start "backup-artifacts" || return 1
  transaction_backup_file "$(limine_default_config_path)" || return 1
  transaction_backup_file "$(limine_primary_binary_path)" || return 1
  transaction_backup_file "$(limine_fallback_binary_path)" || return 1
  backup_sbctl_tracking_stores || return 1
  transaction_phase_complete "backup-artifacts" || return 1

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
  verify_all_efi_artifacts "$_repair_config_checksum" || return 1
  transaction_phase_complete "prove-artifacts"
}

run_artifact_repair() {
  local operation="$1"
  run_lifecycle_transaction_with_preflight "$operation" "active" "active" \
    artifact_repair_preflight repair_boot_artifacts
}
