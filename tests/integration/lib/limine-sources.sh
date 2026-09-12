#!/usr/bin/env bash
# Shared pinned source composition for Java integration suites.
# shellcheck disable=SC2034 # The invoking suite consumes the source arrays.

limine_source_hash() {
  local digest
  [[ $2 =~ ^[0-9a-f]{64}$ ]] || die "invalid source digest: $1"
  digest=$(sha256sum -- "$1")
  [[ ${digest%% *} == "$2" ]] || die "SHA-256 mismatch: $1"
}

limine_prepare_sources() {
  local input=$1 destination=$2 metadata=$3 integration=$4 path expected patch_name revision relative_parent
  local -a source_paths
  jq -e '.native.schema == 1 and (.native.files | length > 0)
    and ((.description // null) == null or .description.schema == 1)' "$metadata" >/dev/null \
    || die 'unsupported native source contract'
  mapfile -t source_paths < <(jq -er '[.native.files[], (.description.files // [])[]]
    | unique_by(.path)[] | select(.sha256 != null) | .path' "$metadata")
  for path in "${source_paths[@]}"; do
    [[ ( $path == README.md || $path == src/main/java/org/limine/entry/tool/*.java \
      || $path == install/arch-linux/limine-entry-tool/usr/bin/limine-entry-tool ) && $path != *..* ]] \
      || die "unexpected source path: $path"
    expected=$(jq -er --arg path "$path" '[.native.files[], (.description.files // [])[]]
      | map(select(.path == $path)) | .[0].sha256' "$metadata")
    relative_parent=${path%/*}
    [[ $relative_parent != "$path" ]] || relative_parent=.
    for revision in original patched; do
      mkdir -p "$destination/$revision/$relative_parent"
      cp -- "$input/$path" "$destination/$revision/$path"
    done
    limine_source_hash "$destination/original/$path" "$expected"
  done
  patch_name=$(jq -er '.native.patch.file' "$metadata")
  [[ $patch_name == 0002-propagate-native-failures.patch ]] || die 'unexpected native patch'
  limine_source_hash "$integration/$patch_name" "$(jq -er '.native.patch.sha256' "$metadata")"
  patch --batch --forward --fuzz=0 -p1 -d "$destination/patched" -i "$integration/$patch_name" >"$destination/patch.log"
  while IFS= read -r path; do
    limine_source_hash "$destination/patched/$path" \
      "$(jq -er --arg path "$path" '.native.files[] | select(.path == $path) | .patched_sha256' "$metadata")"
  done < <(jq -er '.native.files[].path' "$metadata")

  if jq -e '.description != null' "$metadata" >/dev/null; then
    while IFS= read -r path; do
      limine_source_hash "$destination/patched/$path" \
        "$(jq -er --arg path "$path" '.description.files[] | select(.path == $path) | .base_sha256' "$metadata")"
    done < <(jq -er '.description.files[] | select(.base_sha256 != null) | .path' "$metadata")
    patch_name=$(jq -er '.description.patch.file' "$metadata")
    [[ $patch_name == 0003-describe-native-outputs.patch ]] || die 'unexpected description patch'
    limine_source_hash "$integration/$patch_name" "$(jq -er '.description.patch.sha256' "$metadata")"
    patch --batch --forward --fuzz=0 -p1 -d "$destination/patched" -i "$integration/$patch_name" >>"$destination/patch.log"
  fi
  while IFS= read -r path; do
    limine_source_hash "$destination/patched/$path" \
      "$(jq -er --arg path "$path" '[.native.files[], (.description.files // [])[]]
        | reduce .[] as $row ({}; .[$row.path] = $row) | .[$path].patched_sha256' "$metadata")"
  done < <(jq -er '[.native.files[], (.description.files // [])[]] | map(.path) | unique[]' "$metadata")
  mapfile -t LIMINE_ORIGINAL_JAVA < <(jq -er '.native.files[].path | select(endswith(".java"))' "$metadata")
  mapfile -t LIMINE_PATCHED_JAVA < <(jq -er '[.native.files[], (.description.files // [])[]]
    | map(.path) | unique[] | select(endswith(".java"))' "$metadata")
}
