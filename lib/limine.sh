#!/bin/bash
# OmaSecBoot: Limine settings, limine.conf facts, the primary loader proof,
# the fallback loader, the limine.conf watcher and the way back to stock.

readonly LIMINE_CONFIG_MARKER='++CONFIG_B2SUM_SIGNATURE++'

# Written to /etc/default/limine, the only layer that honours enrollment.
# Without path hashes a later signature repair cannot make an entry stale, and
# under Secure Boot the firmware verifies the UKI itself (upstream-contracts C1).
readonly -a MANAGED_SETTINGS=(ENABLE_VERIFICATION=no ENABLE_ENROLL_LIMINE_CONFIG=yes)

run_visible() {
  if [[ $QUIET == true ]]; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

# --- Managed settings and their originals ----------------------------------------

settings_originals_file() { printf '%s/settings-originals\n' "$(state_dir)"; }

# The last line of /etc/default/limine that assigns KEY, verbatim.
default_setting_line() {
  local key=$1 file line found=''
  file=$(limine_default_config)
  [[ -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*${key}[[:space:]]*= ]] && found=$line
  done <"$file"
  [[ -n $found ]] || return 1
  printf '%s\n' "$found"
}

# Replaces every assignment of KEY with LINE at the first one's position, or
# appends it; an empty LINE removes the key. The new content is complete before
# the file is touched, LINE travels through the environment because awk would
# interpret backslashes in a -v assignment, and the trailing "x" keeps the
# blank lines at the end that a command substitution would drop.
write_default_setting() {
  local key=$1 line=$2 file mode=644 content
  file=$(limine_default_config)
  if [[ -e $file ]]; then
    is_safe_file "$file" || return 1
    mode=$(stat -Lc '%a' "$file") || return 1
  else
    : | atomic_write "$file" "$mode" || return 1
  fi
  content=$(LINE=$line awk -v key="$key" '
    BEGIN { pattern = "^[[:space:]]*" key "[[:space:]]*="; line = ENVIRON["LINE"] }
    $0 ~ pattern { if (line != "" && !written) { print line; written = 1 }; next }
    { print }
    END { if (line != "" && !written) print line }
  ' "$file" && printf x) || return 1
  printf '%s' "${content%x}" | atomic_write "$file" "$mode"
}

# Records, once, what /etc/default/limine said before the first change: one
# line per key, "KEY<TAB>absent" or "KEY<TAB>present<TAB><original line>".
save_settings_originals() {
  local originals setting key line record=''
  originals=$(settings_originals_file)
  [[ ! -e $originals ]] || return 0
  for setting in "${MANAGED_SETTINGS[@]}"; do
    key=${setting%%=*}
    if line=$(default_setting_line "$key"); then
      record+="${key}"$'\t'"present"$'\t'"${line}"$'\n'
    else
      record+="${key}"$'\t'"absent"$'\n'
    fi
  done
  ensure_state_dir || return 1
  printf '%s' "$record" | atomic_write "$originals" 644
}

apply_managed_settings() {
  local setting key
  for setting in "${MANAGED_SETTINGS[@]}"; do
    key=${setting%%=*}
    if [[ $(setting_in_file "$(limine_default_config)" "$key" 2>/dev/null) != "${setting#*=}" ]]; then
      qact "Setting ${setting} in $(limine_default_config)"
      write_default_setting "$key" "$setting" || return 1
    fi
  done
}

# Tab is whitespace to read, which would trim a recorded line, so the fields
# are cut by hand.
restore_settings_originals() {
  local originals record key rest
  originals=$(settings_originals_file)
  is_safe_file "$originals" || return 1
  while IFS= read -r record; do
    key=${record%%$'\t'*}
    rest=${record#*$'\t'}
    case $rest in
      absent) write_default_setting "$key" '' || return 1 ;;
      present$'\t'*) write_default_setting "$key" "${rest#*$'\t'}" || return 1 ;;
      *) return 1 ;;
    esac
  done <"$originals"
}

# --- limine.conf facts ------------------------------------------------------------

# Prints "line: key: value" for every path in limine.conf that carries a
# "#hash" suffix. Limine strips leading whitespace and generated sub-entries
# are indented, so lines are trimmed.
list_hashed_paths() {
  local config
  config=$(limine_config_path)
  [[ -f $config ]] || return 1
  awk '
    BEGIN {
      split("path kernel_path module_path image_path dtb_path global_dtb", names, " ")
      for (i in names) path_key[names[i]] = 1
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      colon = index(line, ":")
      if (line ~ /^[#\/]/ || colon == 0) next
      key = tolower(substr(line, 1, colon - 1))
      value = substr(line, colon + 1)
      sub(/^[[:space:]]+/, "", value)
      if (key in path_key && index(value, "#") > 0) print NR ": " key ": " value
    }
  ' "$config"
}

# A hashed path that belongs to a snapshot entry: upstream's stored hash of a
# history file (spec D1).
path_is_snapshot() { [[ ${1,,} == */limine_history/* ]]; }

# Hashed paths of OS entries whose file no longer matches its hash, or that
# cannot be resolved (only boot():/ resolves, against the ESP), in the same
# format. Snapshot entries are left out before anything is hashed: their
# hashes are upstream's, their images are large, and the Limine hook must
# stay quick.
list_stale_os_hashes() {
  local paths line value hash path file esp actual
  paths=$(list_hashed_paths) || return 1
  [[ -n $paths ]] || return 0
  esp=$(realpath -e -- "$(esp_path)") || return 1
  while IFS= read -r line; do
    ! path_is_snapshot "$line" || continue
    value=${line#*: }
    value=${value#*: }
    hash=${value##*#}
    path=${value%#*}
    file=''
    [[ $path != 'boot():/'* ]] || file="${esp}/${path#boot():/}"
    if [[ $hash =~ ^[0-9A-Fa-f]{128}$ && -n $file && -f $file ]] &&
      file=$(realpath -e -- "$file") && [[ $file == "${esp}/"* ]] &&
      actual=$(b2sum_file "$file") && [[ $actual == "${hash,,}" ]]; then
      continue
    fi
    printf '%s\n' "$line"
  done <<<"$paths"
}

# Limine reads the first limine.conf it finds in this order; a stray copy in
# a higher-priority place would shadow the one that gets enrolled.
list_shadowing_configs() {
  local esp candidate
  esp=$(esp_path) || return 1
  for candidate in "${esp}/EFI/limine/limine.conf" "${esp}/boot/limine/limine.conf" \
    "${esp}/boot/limine.conf" "${esp}/limine/limine.conf"; do
    [[ ! -e $candidate && ! -L $candidate ]] || printf '%s\n' "$candidate"
  done
}

# --- The primary loader ------------------------------------------------------------

config_checksum() { b2sum_file "$(limine_config_path)"; }

# The 128 hex digits after Limine's marker; all zero means nothing enrolled.
embedded_checksum() {
  local binary=$1 offset embedded
  local -a markers=()
  mapfile -t markers < <(LC_ALL=C grep -aobF -- "$LIMINE_CONFIG_MARKER" "$binary" 2>/dev/null)
  (( ${#markers[@]} == 1 )) || return 1
  offset=$(( ${markers[0]%%:*} + ${#LIMINE_CONFIG_MARKER} ))
  embedded=$(dd if="$binary" bs=1 skip="$offset" count=128 status=none 2>/dev/null) || return 1
  [[ $embedded =~ ^[0-9a-fA-F]{128}$ ]] || return 1
  printf '%s\n' "${embedded,,}"
}

checksum_is_zero() { [[ $1 =~ ^0{128}$ ]]; }

# Sealed with the current limine.conf and signed. Upstream's hook does both
# but hides its failures, so this is checked after every Limine operation.
primary_is_proved() {
  local primary checksum
  primary=$(primary_loader_path)
  [[ -f $primary ]] || return 1
  checksum=$(config_checksum) || return 1
  [[ $(embedded_checksum "$primary") == "$checksum" ]] && signature_state "$primary"
}

readonly LOADER_STAGING_PREFIX='.omasecboot-loader.'

# A pass that was killed leaves its staging file on the ESP, where space is
# scarce. Called under the boot lock, so no live pass owns one.
remove_stale_staging() {
  local esp
  esp=$(esp_path) || return 1
  rm -f -- "${esp}/EFI/limine/${LOADER_STAGING_PREFIX}"* "${esp}/EFI/BOOT/${LOADER_STAGING_PREFIX}"*
}

# Builds a loader from the raw executable in a staging file beside the target:
# enroll, then sign (a signed executable cannot be changed afterwards, sbctl
# issue 408), verify, and only then replace the target.
install_sealed_loader() {
  local target=$1 checksum=$2 parent staging
  parent=$(dirname "$target")
  [[ -d $parent ]] || return 1
  esp_has_room || return 1
  staging=$(mktemp "${parent}/${LOADER_STAGING_PREFIX}XXXXXX") || return 1
  if raw_loader >"$staging" &&
    run_visible limine enroll-config "$staging" "$checksum" &&
    run_visible run_sbctl sign "$staging" &&
    durable_sync "$staging" &&
    [[ $(embedded_checksum "$staging") == "$checksum" ]] &&
    signature_state "$staging" &&
    mv -f -- "$staging" "$target" &&
    durable_sync "$parent"; then
    return 0
  fi
  rm -f -- "$staging"
  return 1
}

ensure_primary_loader() {
  local checksum
  if primary_is_proved; then
    return 0
  fi
  checksum=$(config_checksum) || return 1
  qact "Sealing and signing the Limine loader"
  install_sealed_loader "$(primary_loader_path)" "$checksum" && primary_is_proved
}

# systemd merges changes that arrive while the watcher's service runs
# (upstream-contracts C5), so the proof is repeated until limine.conf held
# still across it. Only the last round counts.
converge_primary_loader() {
  local before after sealed
  for _ in 1 2 3; do
    before=$(config_checksum) || return 1
    sealed=true
    ensure_primary_loader || sealed=false
    after=$(config_checksum) || return 1
    [[ $before != "$after" ]] || break
  done
  [[ $sealed == true && $before == "$after" ]]
}

# --- The fallback loader -------------------------------------------------------------

# absent, raw (Limine's executable, neither sealed nor locally signed: what
# upstream deploys and spec D2 wants), altered (Limine's executable, sealed or
# locally signed) or foreign (someone else's BOOTX64.EFI, never touched). A
# signature that cannot be read counts as raw: nothing is rewritten on a guess.
fallback_state() {
  local fallback embedded
  fallback=$(fallback_loader_path)
  if [[ ! -e $fallback ]]; then
    printf 'absent\n'
  elif ! embedded=$(embedded_checksum "$fallback"); then
    printf 'foreign\n'
  elif checksum_is_zero "$embedded" && ! signature_state "$fallback"; then
    printf 'raw\n'
  else
    printf 'altered\n'
  fi
}

# Puts upstream's raw copy back. A signed fallback that is not sealed would
# boot under Secure Boot without enforcing limine.conf; a sealed one would
# panic together with the primary and leave no rescue loader.
restore_raw_fallback() {
  local fallback parent staging
  esp_has_room || return 1
  fallback=$(fallback_loader_path)
  parent=$(dirname "$fallback")
  staging=$(mktemp "${parent}/${LOADER_STAGING_PREFIX}XXXXXX") || return 1
  if raw_loader >"$staging" && durable_sync "$staging" &&
    mv -f -- "$staging" "$fallback" && durable_sync "$parent"; then
    return 0
  fi
  rm -f -- "$staging"
  return 1
}

# --- The limine.conf watcher -----------------------------------------------------------

watch_unit() { systemd-escape --template=omasecboot-watch@.path -p "$(limine_config_path)"; }

enable_watch() {
  local unit
  unit=$(watch_unit) || return 1
  systemctl enable --now --quiet "$unit"
}

disable_watch() {
  local unit
  unit=$(watch_unit) || return 1
  systemctl disable --now --quiet "$unit" 2>/dev/null || true
}

watch_is_active() {
  local unit
  unit=$(watch_unit) || return 1
  systemctl is-enabled --quiet "$unit" 2>/dev/null && systemctl is-active --quiet "$unit" 2>/dev/null
}

# --- Upstream's tools ----------------------------------------------------------------------

# OS entries that still carry path hashes were generated before the managed
# settings applied and must be regenerated before anything is signed in place:
# signing a hashed file makes its entry stale.
os_entries_carry_hashes() {
  local line paths
  paths=$(list_hashed_paths) || return 1
  while IFS= read -r line; do
    [[ -z $line ]] || path_is_snapshot "$line" || return 0
  done <<<"$paths"
  return 1
}

# Rebuilds the UKIs and their menu entries under the current settings.
# limine-mkinitcpio takes the boot lock itself, so ours is released around
# it, and it reports success after a failed build (C2), so the result is
# judged by the entries.
regenerate_os_entries() {
  qact "Regenerating the boot entries through limine-mkinitcpio"
  run_unlocked run_visible limine-mkinitcpio || return 1
  ! os_entries_carry_hashes
}

# The way back to stock boot files: upstream's install and entry generation
# under the restored settings, then upstream's reset last, because the
# install's own post-hook signs the loader while sbctl keys exist.
restore_stock_boot_files() {
  local primary
  primary=$(primary_loader_path)
  run_unlocked run_visible limine-install --no-efi-register || return 1
  run_unlocked run_visible limine-mkinitcpio || return 1
  run_visible limine-reset-enroll || return 1
  durable_sync "$primary" || return 1
  raw_loader | cmp -s -- - "$primary" || {
    fail "The Limine loader is not back to upstream's raw executable"
    return 1
  }
}
