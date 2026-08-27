#!/bin/bash
# OmaSecBoot: key creation, EFI signing, database cleanup

readonly LIMINE_DEFAULT_CONF="/etc/default/limine"

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
  done < <(list_limine_default_entries "$LIMINE_DEFAULT_CONF" "$key" || true)

  _limine_default_raw="$raw"
}

replace_limine_default_entry() {
  replace_limine_default_entry_in_file "$LIMINE_DEFAULT_CONF" "$@"
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
  [[ -f "$LIMINE_DEFAULT_CONF" ]] || {
    fail "${LIMINE_DEFAULT_CONF} not found"
    return 1
  }

  local backup
  local changed=1
  local rc

  backup=$(backup_file "$LIMINE_DEFAULT_CONF") || {
    fail "Could not back up ${LIMINE_DEFAULT_CONF}"
    return 1
  }

  set_limine_default_value "ENABLE_VERIFICATION" "no"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    changed=0
  elif [[ $rc -ne 1 ]]; then
    restore_file_backup "$backup" "$LIMINE_DEFAULT_CONF" || true
    discard_file_backup "$backup"
    fail "Could not update ENABLE_VERIFICATION in ${LIMINE_DEFAULT_CONF}"
    return 1
  fi

  set_limine_default_value "ENABLE_ENROLL_LIMINE_CONFIG" "yes"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    changed=0
  elif [[ $rc -ne 1 ]]; then
    restore_file_backup "$backup" "$LIMINE_DEFAULT_CONF" || true
    discard_file_backup "$backup"
    fail "Could not update ENABLE_ENROLL_LIMINE_CONFIG in ${LIMINE_DEFAULT_CONF}"
    return 1
  fi

  if limine_enrollment_hooks_present; then
    remove_limine_default_command "COMMANDS_BEFORE_SAVE" "limine-reset-enroll"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      restore_file_backup "$backup" "$LIMINE_DEFAULT_CONF" || true
      discard_file_backup "$backup"
      fail "Could not remove deprecated COMMANDS_BEFORE_SAVE entry in ${LIMINE_DEFAULT_CONF}"
      return 1
    fi

    remove_limine_default_command "COMMANDS_AFTER_SAVE" "limine-enroll-config"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      restore_file_backup "$backup" "$LIMINE_DEFAULT_CONF" || true
      discard_file_backup "$backup"
      fail "Could not remove deprecated COMMANDS_AFTER_SAVE entry in ${LIMINE_DEFAULT_CONF}"
      return 1
    fi
  else
    ensure_limine_default_command "COMMANDS_BEFORE_SAVE" "limine-reset-enroll"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      restore_file_backup "$backup" "$LIMINE_DEFAULT_CONF" || true
      discard_file_backup "$backup"
      fail "Could not update COMMANDS_BEFORE_SAVE in ${LIMINE_DEFAULT_CONF}"
      return 1
    fi

    ensure_limine_default_command "COMMANDS_AFTER_SAVE" "limine-enroll-config"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      changed=0
    elif [[ $rc -ne 1 ]]; then
      restore_file_backup "$backup" "$LIMINE_DEFAULT_CONF" || true
      discard_file_backup "$backup"
      fail "Could not update COMMANDS_AFTER_SAVE in ${LIMINE_DEFAULT_CONF}"
      return 1
    fi
  fi

  discard_file_backup "$backup"

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

# Capture the current limine.conf checksum for later change detection.
snapshot_limine_conf_hash() {
  [[ -f "$LIMINE_CONF" ]] || return 0
  _limine_conf_hash=$(md5sum "$LIMINE_CONF" | cut -d' ' -f1) || _limine_conf_hash=""
}

# Enroll the current limine.conf checksum into the Limine EFI binary.
enroll_limine_config() {
  command -v limine-enroll-config >/dev/null 2>&1 || return 1
  qact "Enrolling Limine config checksum"
  if [[ "$QUIET" == true ]]; then
    limine-enroll-config >/dev/null || return 1
  else
    limine-enroll-config || return 1
  fi
}

# Re-enroll the limine.conf checksum only if the config file has changed
# since the last recorded checksum.
reenroll_limine_config_if_changed() {
  command -v limine-enroll-config >/dev/null 2>&1 || return 1
  [[ -f "$LIMINE_CONF" ]] || return 1

  local current_hash
  current_hash=$(md5sum "$LIMINE_CONF" | cut -d' ' -f1) || return 1

  if [[ "${_limine_conf_hash:-}" == "$current_hash" ]]; then
    qpass "Limine config unchanged, skipping re-enrollment"
    return 0
  fi

  enroll_limine_config
}

# Create sbctl signing keys if they do not already exist.
create_keys() {
  local installed
  installed=$(sbctl status --json 2>/dev/null | jq -r '.installed // false') || true

  if [[ "$installed" == "true" ]]; then
    qpass "Signing keys already exist"
    return 0
  fi

  if ! gum confirm "Create new sbctl signing keys?"; then
    warn "Aborted"
    return 1
  fi

  sbctl create-keys || die "Key creation failed"
  qpass "Signing keys created"
}

sbctl_entry_should_be_removed() {
  local file="$1" output="${2:-$1}"

  [[ ! -e "$file" || ! -e "$output" \
    || "$file" == */Microsoft/* || "$output" == */Microsoft/* \
    || "$file" == *BOOTIA32.EFI || "$output" == *BOOTIA32.EFI ]]
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
  local stale rc=0
  stale=$(list_stale_sbctl_entries) || rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Could not read sbctl tracking state; skipping stale entry cleanup"
    return 0
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
    fi
  done
}

# sbctl 0.18 ignores --save for already-signed files. Persist the SigningEntry
# directly so zz-sbctl.hook can track snapshot UKIs on current Arch packages.
save_sbctl_file_entry() {
  local file="$1"
  local files_db backup="" tmp db_json

  files_db=$(resolve_sbctl_files_db_path) || { warn "Could not resolve sbctl files database path"; return 1; }
  mkdir -p "$(dirname "$files_db")" || { warn "Could not create directory for ${files_db}"; return 1; }

  if [[ -f "$files_db" ]]; then
    backup=$(backup_file "$files_db") || return 1
    db_json=$(<"$files_db") || db_json="{}"
  else
    db_json="{}"
  fi

  [[ -n "$db_json" && "$db_json" != "null" ]] || db_json="{}"

  local db_dir
  db_dir=$(dirname "$files_db")
  tmp=$(mktemp "${db_dir}/.omasecboot.sbctl-files.XXXXXX") || {
    [[ -z "$backup" ]] || discard_file_backup "$backup"
    return 1
  }

  if ! printf '%s\n' "$db_json" | jq --arg file "$file" '
    (if type == "object" then . else {} end)
    | .[$file] = {file: $file, output_file: $file}
  ' > "$tmp"; then
    warn "Could not update sbctl database entry for ${file}"
    rm -f "$tmp"
    [[ -z "$backup" ]] || discard_file_backup "$backup"
    return 1
  fi

  # Preserve original permissions, or set default for first-create
  if [[ -f "$files_db" ]]; then
    chmod --reference="$files_db" "$tmp" 2>/dev/null || true
  else
    chmod 0644 "$tmp"
  fi

  if ! mv "$tmp" "$files_db"; then
    warn "Could not write ${files_db}"
    [[ -z "$backup" ]] || restore_file_backup "$backup" "$files_db" || true
    rm -f "$tmp"
    [[ -z "$backup" ]] || discard_file_backup "$backup"
    return 1
  fi

  [[ -z "$backup" ]] || discard_file_backup "$backup"
  return 0
}

# Discover all EFI files and sign any that are not yet signed.
# Uses -s flag to register files in sbctl's database for zz-sbctl.hook.
sign_all_efi() {
  local -a efi_files
  local -a enrolled=()
  local enrolled_raw rc=0
  mapfile -t efi_files < <(discover_efi_files)
  enrolled_raw=$(list_enrolled_paths) || rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Could not read sbctl tracking state; treating all files as untracked"
  elif [[ -n "$enrolled_raw" ]]; then
    mapfile -t enrolled <<< "$enrolled_raw"
  fi
  [[ ${#efi_files[@]} -eq 0 ]] && die "No EFI files found in ${ESP}"

  local -A enrolled_map=()
  local signed=0 skipped=0 failed=0
  local file is_signed

  for file in "${enrolled[@]}"; do
    enrolled_map["$file"]=1
  done

  for file in "${efi_files[@]}"; do
    # sbctl verify exits 0 regardless of result; parse JSON for actual status
    is_signed=$(sbctl verify --json "$file" 2>/dev/null \
      | jq -r '.[0].is_signed // empty') || true

    if [[ "$is_signed" == "1" && -n "${enrolled_map[$file]:-}" ]]; then
      qpass "${file#"${ESP}"/} ${DIM}already signed${NC}"
      skipped=$((skipped + 1))
    elif [[ "$is_signed" == "1" ]]; then
      if save_sbctl_file_entry "$file"; then
        qact "${file#"${ESP}"/} ${DIM}registered${NC}"
        enrolled_map["$file"]=1
        signed=$((signed + 1))
      else
        warn "Failed to register: ${file#"${ESP}"/}"
        failed=$((failed + 1))
      fi
    else
      local _sign_rc=0
      if [[ "$QUIET" == true ]]; then
        sbctl sign -s "$file" >/dev/null || _sign_rc=$?
      else
        sbctl sign -s "$file" || _sign_rc=$?
      fi
      if [[ $_sign_rc -eq 0 ]]; then
        qact "${file#"${ESP}"/} ${DIM}signed${NC}"
        enrolled_map["$file"]=1
        signed=$((signed + 1))
      else
        warn "Failed to sign: ${file#"${ESP}"/}"
        failed=$((failed + 1))
      fi
    fi
  done

  if [[ "$QUIET" != true ]]; then
    echo
    if [[ $failed -gt 0 ]]; then
      warn "Signed ${signed}, skipped ${skipped}, failed ${failed}"
    else
      pass "Signed ${signed}, skipped ${skipped} (already signed)"
    fi
  elif [[ $failed -gt 0 ]]; then
    warn "Failed to sign ${failed} file(s)"
  fi

  [[ $failed -eq 0 ]]
}
