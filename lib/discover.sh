#!/bin/bash
# OmaSecBoot: EFI file discovery and sbctl database queries

# Find all signable EFI files under the ESP.
# Excludes Microsoft files (trusted via -m enrollment), 32-bit bootloader, backups.
discover_efi_files() {
  local root="${1:-$(esp_path)}" discovered
  [[ -d "$root" && ! -L "$root" ]] || return 1
  discovered=$(find "$root" -xdev -type f \( \
    -iname "*.efi" -o \
    -iname "*.efi_sha1_*" -o \
    -iname "*.efi_sha256_*" -o \
    -iname "*.efi_b3_*" -o \
    -iname "*.efi_blake3_*" -o \
    -iname "*.efi_xxh_*" -o \
    -iname "*.efi_xxhash_*" \
  \) \
    ! -ipath "*/Microsoft/*" \
    ! -iname "BOOTIA32.EFI" \
    ! -iname "*.bak" \
    -print 2>/dev/null) || return 1
  [[ -z "$discovered" ]] || printf '%s\n' "$discovered" | LC_ALL=C sort
}

sbctl_config_path() {
  printf '%s\n' /etc/sbctl/sbctl.conf
}

sbctl_config_files_db_path() {
  local config="$1" line trimmed key last_top_key="" value="" candidate count=0
  local document_marker_seen=false content_seen=false
  validate_control_file "$config" || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    if [[ "$line" == --- ]]; then
      [[ "$document_marker_seen" == false && "$content_seen" == false ]] || return 1
      document_marker_seen=true
      continue
    fi
    [[ "$line" != ... ]] || return 1

    if [[ "$line" != [[:space:]]* ]]; then
      [[ "$line" =~ ^([a-z_][a-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]] \
        || return 1
      key=${BASH_REMATCH[1]}
      last_top_key=$key
      content_seen=true
      [[ "$key" == files_db ]] || continue
      count=$((count + 1))
      [[ $count -eq 1 ]] || return 1
      candidate=${BASH_REMATCH[2]}
      candidate=${candidate#"${candidate%%[![:space:]]*}"}
      candidate=${candidate%"${candidate##*[![:space:]]}"}

      if [[ "$candidate" =~ ^\"([^\"\\]*)\"([[:space:]]+#.*)?$ ]]; then
        value=${BASH_REMATCH[1]}
      elif [[ "$candidate" =~ ^\'([^\']*)\'([[:space:]]+#.*)?$ ]]; then
        value=${BASH_REMATCH[1]}
      elif [[ "$candidate" =~ ^(/[^[:space:]#]*)([[:space:]]+#.*)?$ ]]; then
        value=${BASH_REMATCH[1]}
      else
        return 1
      fi
      continue
    fi
    [[ "$last_top_key" != files_db ]] || return 1
    content_seen=true
  done < "$config"

  [[ $count -eq 1 ]] || return 1
  [[ "$value" =~ ^/[^[:cntrl:]]+$ ]] || return 1
  printf '%s\n' "$value"
}

# Resolve the sbctl file database path using the same configured field as
# sbctl. Unsupported YAML scalar forms fail closed instead of guessing.
resolve_sbctl_files_db_path() {
  local config files_db=""
  config=$(sbctl_config_path) || return 1

  if [[ -e "$config" || -L "$config" ]]; then
    files_db=$(sbctl_config_files_db_path "$config") || return 1
    printf '%s\n' "$files_db"
    return 0
  fi

  if [[ -d /usr/share/secureboot ]]; then
    printf '%s\n' /usr/share/secureboot/files.db
  else
    printf '%s\n' /var/lib/sbctl/files.json
  fi
}

resolve_sbctl_files_db() {
  local files_db
  files_db=$(resolve_sbctl_files_db_path) || return 1
  [[ -f "$files_db" ]] || return 1
  printf '%s\n' "$files_db"
}

sbctl_database_candidate_paths() {
  local resolved candidate
  resolved=$(resolve_sbctl_files_db_path) || return 1
  printf '%s\n' "$resolved"
  for candidate in \
    /var/lib/sbctl/files.db \
    /var/lib/sbctl/files.json \
    /usr/share/secureboot/files.db \
    /usr/share/secureboot/files.json; do
    [[ "$candidate" != "$resolved" && -d "$(dirname "$candidate")" ]] \
      || continue
    printf '%s\n' "$candidate"
  done | LC_ALL=C sort -u
}

# Query tracked files through sbctl's public CLI.
# Returns 0 on success (including empty), 1 on lookup failure.
list_enrolled_entries_from_cli() {
  command -v sbctl >/dev/null 2>&1 || return 1

  local files_db json
  files_db=$(resolve_sbctl_files_db_path) || return 1
  [[ -e "$files_db" || -L "$files_db" ]] || return 0
  validate_control_file "$files_db" || return 1
  json=$(sbctl list-files --json 2>/dev/null) || return 1
  [[ -n "$json" && "$json" != "null" ]] || return 0

  printf '%s\n' "$json" | jq -r '
    def row($file; $output):
      select(($file // "") != "")
      | [($file), ($output // $file)]
      | @tsv;

    if type == "array" then
      .[]
      | if type == "object" then
          row((.file // .path // .source // ""); (.output_file // .output // .file // .path // .source // ""))
        elif type == "string" then
          row(.; .)
        else
          empty
        end
    elif type == "object" then
      to_entries[]
      | if (.value | type) == "object" then
          row((.value.file // .key); (.value.output_file // .value.output // .value.file // .key))
        elif (.value | type) == "string" then
          row(.key; .value)
        else
          row(.key; .key)
        end
    else
      empty
    end
  ' 2>/dev/null
}

# Query tracked files from sbctl's on-disk database: a fallback path for
# stale-entry cleanup and sbctl compatibility logic.
list_enrolled_entries_from_db() {
  local files_db db_rc=0 json
  files_db=$(resolve_sbctl_files_db) || db_rc=$?
  if [[ $db_rc -ne 0 ]]; then
    return 1
  fi

  json=$(<"$files_db") || return 1

  if [[ "$json" == "null" || -z "$json" ]]; then
    return 0
  fi

  # sbctl stores signing entries as a JSON object keyed by source file path.
  # Normalize it to tab-separated "file<TAB>output_file" rows.
  echo "$json" | jq -r '
    if type == "object" then .[] else [] end
    | select((.file // .output_file // "") != "")
    | [(.file // .output_file), (.output_file // .file)]
    | @tsv
  ' 2>/dev/null
}

# List file paths currently registered in sbctl's database.
# Returns 0 on success (including empty), 1 on lookup failure.
# CLI success with empty output is authoritative.
# DB fallback only triggers when CLI fails.
list_enrolled_entries() {
  local cli_entries cli_rc=0
  cli_entries=$(list_enrolled_entries_from_cli) || cli_rc=$?

  if [[ $cli_rc -eq 0 ]]; then
    # CLI succeeded; result is authoritative even if empty
    [[ -n "$cli_entries" ]] && printf '%s\n' "$cli_entries"
    return 0
  fi

  # CLI failed; fall back to on-disk database
  list_enrolled_entries_from_db
}

# Cleanup must catch stale entries even if sbctl's CLI view is incomplete.
# Prefer CLI rows, but merge in database rows when the database is readable.
list_enrolled_entries_for_cleanup() {
  local cli_entries="" db_entries=""
  local cli_rc=0 db_rc=0

  cli_entries=$(list_enrolled_entries_from_cli) || cli_rc=$?
  db_entries=$(list_enrolled_entries_from_db) || db_rc=$?

  if [[ $cli_rc -ne 0 && $db_rc -ne 0 ]]; then
    return 1
  fi

  {
    [[ $cli_rc -ne 0 || -z "$cli_entries" ]] || printf '%s\n' "$cli_entries"
    [[ $db_rc -ne 0 || -z "$db_entries" ]] || printf '%s\n' "$db_entries"
  } | sort -u
}

# Extract output file paths from enrolled entries.
# Returns 0 on success (including empty), 1 on lookup failure.
list_enrolled_paths() {
  local entries rc=0
  entries=$(list_enrolled_entries) || rc=$?
  if [[ $rc -ne 0 ]]; then
    return 1
  fi
  [[ -z "$entries" ]] && return 0

  local file output
  while IFS=$'\t' read -r file output; do
    printf '%s\n' "${output:-$file}"
  done <<< "$entries"
}
