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

# Reads the plain top-level scalars OmaSecBoot understands in sbctl.conf
# (keydir, guid, files_db, bundles_db) into _sbctl_* and fails closed on YAML
# it cannot read literally: flow syntax, anchors, multi-line values, duplicate
# keys, and multiple documents. Strict mode additionally rejects anything that
# changes what sbctl would enroll or sign: nested content, unknown keys, custom
# key backends, and nonempty db_additions or files lists.
parse_sbctl_config() {
  local config="$1" strict="${2:-false}" line trimmed key candidate value last_key=""
  local -A seen=()
  local marker_seen=false content_seen=false
  _sbctl_keydir=/var/lib/sbctl/keys
  _sbctl_guid_path=/var/lib/sbctl/GUID
  _sbctl_files_db=""
  validate_control_file "$config" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    if [[ "$line" == --- ]]; then
      [[ "$marker_seen" == false && "$content_seen" == false ]] || return 1
      marker_seen=true
      continue
    fi
    [[ "$line" != ... ]] || return 1
    content_seen=true
    if [[ "$line" == [[:space:]]* ]]; then
      [[ "$strict" == false && "$last_key" != files_db ]] || return 1
      continue
    fi
    [[ "$line" =~ ^([a-z_][a-z0-9_]*)[[:space:]]*:[[:space:]]*(.*)$ ]] || return 1
    key=${BASH_REMATCH[1]}
    candidate=${BASH_REMATCH[2]}
    candidate=${candidate%"${candidate##*[![:space:]]}"}
    last_key=$key
    [[ -z "${seen[$key]:-}" ]] || return 1
    seen["$key"]=1
    case "$key" in
      keydir|guid|files_db|bundles_db)
        if [[ "$candidate" =~ ^\"([^\"\\]*)\"([[:space:]]+#.*)?$ ]] \
          || [[ "$candidate" =~ ^\'([^\']*)\'([[:space:]]+#.*)?$ ]] \
          || [[ "$candidate" =~ ^(/[^[:space:]#]*)([[:space:]]+#.*)?$ ]]; then
          value=${BASH_REMATCH[1]}
        else
          return 1
        fi
        [[ "$value" =~ ^/[^[:cntrl:]]+$ ]] || return 1
        case "$key" in
          keydir) _sbctl_keydir=$value ;;
          guid) _sbctl_guid_path=$value ;;
          files_db) _sbctl_files_db=$value ;;
        esac
        ;;
      db_additions|files)
        [[ "$strict" == false || "$candidate" =~ ^\[\][[:space:]]*(#.*)?$ ]] || return 1
        ;;
      landlock)
        [[ "$strict" == false \
          || "${candidate%%[[:space:]]#*}" =~ ^(true|false)[[:space:]]*$ ]] || return 1
        ;;
      *) [[ "$strict" == false ]] || return 1 ;;
    esac
  done < "$config"
}

# Resolve the sbctl file database path using the same configured field as
# sbctl. Unsupported YAML scalar forms fail closed instead of guessing.
# Prefers the explicit files_db of an existing config; without a config file,
# matches sbctl 0.18's legacy selection or its default.
resolve_sbctl_files_db_path() {
  local config
  config=$(sbctl_config_path) || return 1
  if [[ -e "$config" || -L "$config" ]]; then
    parse_sbctl_config "$config" || return 1
    [[ -n "$_sbctl_files_db" ]] || return 1
    printf '%s\n' "$_sbctl_files_db"
  elif [[ -d /usr/share/secureboot ]]; then
    printf '%s\n' /usr/share/secureboot/files.db
  else
    printf '%s\n' /var/lib/sbctl/files.json
  fi
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
  local files_db json
  files_db=$(resolve_sbctl_files_db_path) || return 1
  [[ -f "$files_db" ]] || return 1
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
