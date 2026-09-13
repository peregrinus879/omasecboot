#!/usr/bin/env bash
# Full ordered source composition shared by shell and Java integration suites.
# shellcheck disable=SC2034 # The invoking suite consumes the source arrays.

limine_source_hash() {
  local digest
  [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "invalid source digest: $1"
  digest=$(sha256sum -- "$1")
  [[ ${digest%% *} == "$2" ]] || die "SHA-256 mismatch: $1"
}

limine_prepare_sources() {
  local input=$1 destination=$2 metadata=$3 integration=$4 path expected patch_name revision relative_parent contract
  local -a source_paths
  jq -e '.schema == 1 and .native.schema == 1 and .description.schema == 1 and .build_settings.schema == 1' \
    "$metadata" >/dev/null || die 'unsupported source contract'
  mapfile -t source_paths < <(jq -er '[.files[], .native.files[], .description.files[], .build_settings.files[]]
    | unique_by(.path)[] | select(.sha256 != null) | .path' "$metadata")
  for path in "${source_paths[@]}"; do
    [[ ( $path == README.md || $path == src/main/java/org/limine/entry/tool/*.java \
      || $path == install/arch-linux/limine-entry-tool/usr/bin/limine-entry-tool \
      || $path == install/arch-linux/limine-entry-tool/usr/lib/limine/limine-*-functions \
      || $path == install/arch-linux/limine-mkinitcpio-hook/usr/bin/limine-mkinitcpio \
      || $path == install/arch-linux/limine-mkinitcpio-hook/usr/share/libalpm/scripts/limine-mkinitcpio-install ) && $path != *..* ]] \
      || die "unexpected source path: $path"
    expected=$(jq -er --arg path "$path" '[.files[], .native.files[], .description.files[], .build_settings.files[]]
      | map(select(.path == $path)) | .[0].sha256' "$metadata")
    relative_parent=${path%/*}
    [[ $relative_parent != "$path" ]] || relative_parent=.
    for revision in original patched; do
      mkdir -p "$destination/$revision/$relative_parent"
      cp -- "$input/$path" "$destination/$revision/$path"
    done
    limine_source_hash "$destination/original/$path" "$expected"
  done
  : >"$destination/patch.log"
  for contract in . .native .description .build_settings; do
    while IFS=$'\t' read -r path expected; do
      limine_source_hash "$destination/patched/$path" "$expected"
    done < <(jq -er "$contract"' | .files[] | select(.base_sha256 != null) | [.path, .base_sha256] | @tsv' "$metadata")
    patch_name=$(jq -er "$contract | .patch.file" "$metadata")
    case $contract:$patch_name in
      .:0001-propagate-mkinitcpio-failures.patch | .native:0002-propagate-native-failures.patch | \
        .description:0003-describe-native-outputs.patch | .build_settings:0004-describe-build-settings.patch) ;;
      *) die 'unexpected ordered patch' ;;
    esac
    limine_source_hash "$integration/$patch_name" "$(jq -er "$contract | .patch.sha256" "$metadata")"
    patch --batch --forward --fuzz=0 -p1 -d "$destination/patched" -i "$integration/$patch_name" >>"$destination/patch.log"
    while IFS=$'\t' read -r path expected; do
      limine_source_hash "$destination/patched/$path" "$expected"
    done < <(jq -er "$contract"' | .files[] | [.path, .patched_sha256] | @tsv' "$metadata")
  done
  while IFS=$'\t' read -r path expected; do
    limine_source_hash "$destination/patched/$path" "$expected"
  done < <(jq -er '[.files[], .native.files[], .description.files[], .build_settings.files[]]
    | reduce .[] as $row ({}; .[$row.path] = $row) | to_entries[] | [.key, .value.patched_sha256] | @tsv' "$metadata")
  mapfile -t LIMINE_ORIGINAL_JAVA < <(jq -er '.native.files[].path | select(endswith(".java"))' "$metadata")
  mapfile -t LIMINE_PATCHED_JAVA < <(jq -er '[.native.files[], .description.files[], .build_settings.files[]]
    | map(.path) | unique[] | select(endswith(".java"))' "$metadata")
}
