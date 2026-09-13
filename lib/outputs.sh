#!/bin/bash
# The complete installed-kernel catalog is not itself a mandatory menu set.
# Producer policy and explicit recorded native intent govern required entries.

# Internal, fixed read-only tool routes. Status and stderr are checked while
# stdout stays a byte stream for the caller's parser; no capture file is needed.
output_readonly_query() (
  set -o pipefail
  case ${1:-}:${2:-} in
    /usr/bin/pacman-conf:--config|/usr/bin/limine-entry-tool:--describe|/usr/bin/limine-mkinitcpio:--describe-build|/usr/bin/findmnt:--kernel) ;;
    *) exit 1 ;;
  esac
  exec 3>&1
  # Encode stderr before it reaches a Bash variable: raw NUL bytes must not
  # disappear through command substitution and become an empty diagnostic.
  errors=$("$@" 2>&1 1>&3 | /usr/bin/base64 --wrap=0) || exit 1
  [[ -z $errors ]]
)

package_catalog_input_identity() {
  local path=$1 kind=$2 resolved metadata uid mode device inode
  [[ $path == /* && $path != *[[:cntrl:]]* ]] || return 1
  printf '%s' "$path" | iconv -f UTF-8 -t UTF-8 >/dev/null || return 1
  # Keep realpath's record terminator distinct from any newline in the target.
  resolved=$(realpath -e -- "$path" && printf '\037') || return 1
  resolved=${resolved%$'\037'}
  [[ $resolved == *$'\n' ]] || return 1
  resolved=${resolved%$'\n'}
  [[ $resolved == /* && $resolved != *[[:cntrl:]]* ]] || return 1
  printf '%s' "$resolved" | iconv -f UTF-8 -t UTF-8 >/dev/null || return 1
  case $kind in
    file) [[ -f $resolved ]] || return 1 ;;
    directory) [[ -d $resolved ]] || return 1 ;;
    *) return 1 ;;
  esac
  metadata=$(stat -Lc '%u %a %d %i' -- "$path") || return 1
  read -r uid mode device inode <<<"$metadata"
  [[ $uid == "$(control_owner_uid)" ]] && mode_is_control_safe "$mode" || return 1
  jq -cn --arg path "$path" --arg resolved "$resolved" --arg device "$device" --arg inode "$inode" \
    '{path:$path,resolved:$resolved,device:$device,inode:$inode}'
}

# Describe the backing ranges reached through a directory, including submounts.
# realpath alone cannot expose bind aliases: FSROOT plus the path below TARGET
# locates each range inside its filesystem. Filesystem identity alone is not an
# overlap. Keep this bootstrap in memory, before either collector writes files.
output_namespace_ranges() (
  local identity resolved directory_fd key value mount_id=''
  identity=$(package_catalog_input_identity "$1" directory) || return 1
  resolved=$(jq -er '.resolved' <<<"$identity") || return 1
  # An opened directory identifies the visible mount even with stacked binds.
  # A pathname-only findmnt query can also return the covered mount at TARGET.
  exec {directory_fd}<"$resolved" || return 1
  while read -r key value; do
    [[ $key == mnt_id: ]] || continue
    [[ -z $mount_id && $value =~ ^[0-9]+$ ]] || return 1
    mount_id=$value
  done <"/proc/self/fdinfo/$directory_fd"
  [[ -n $mount_id && $resolved -ef /proc/self/fd/$directory_fd ]] || return 1
  output_readonly_query /usr/bin/findmnt --kernel --json --list --submounts --id "$mount_id" \
    --output ID,TARGET,FSROOT,MAJ:MIN | iconv -f UTF-8 -t UTF-8 | jq -ce --arg path "$resolved" --argjson id "$mount_id" '
      def within($path; $root): $path == $root or ($path | startswith(($root | rtrimstr("/")) + "/"));
      def absolute: type == "string" and startswith("/") and (test("[[:cntrl:]]") | not);
      .filesystems | if type == "array" and length > 0 and all(.[];
        (.target | absolute) and (.fsroot | absolute) and (."maj:min" | type == "string" and test("^[0-9]+:[0-9]+$")))
      then . else error("incomplete mount observation") end |
      . as $mounts | map(select(.id == $id and within($path; .target))) |
      if length == 1 then .[0] else error("unresolved containing mount") end | . as $parent |
      [{device:$parent."maj:min",root:(($parent.fsroot | rtrimstr("/")) +
        (if $parent.target == "/" then $path else $path | ltrimstr($parent.target) end))}] +
      [$mounts[] | select(.target != $parent.target and within(.target; $path)) | {device:."maj:min",root:.fsroot}] |
      map(.root |= if . == "" then "/" else . end)'
)

output_capture_is_separate() {
  local capture=$1 source capture_ranges source_ranges
  shift
  capture_ranges=$(output_namespace_ranges "$capture") || return 1
  for source in "$@"; do
    source_ranges=$(output_namespace_ranges "$source") || return 1
    # These are jq variables, not shell expansions.
    # shellcheck disable=SC2016
    json_is 'def within($path; $root): $path == $root or ($path | startswith(($root | rtrimstr("/")) + "/"));
      .[0] as $capture | .[1] as $source |
      all($capture[]; . as $c | all($source[];
        .device != $c.device or ((within(.root; $c.root) or within($c.root; .root)) | not)))' \
      "[$capture_ranges,$source_ranges]" || return 1
  done
}

package_catalog_context() {
  local config=$1 root_override=${2:-} db_override=${3:-} result root db root_identity db_identity
  local -a args=(--config "$config" --verbose)
  [[ -z $root_override ]] || args+=(--rootdir "$root_override")
  # Parse the byte stream before putting values in Bash variables. This keeps
  # NULs and trailing-newline framing observable during the no-file bootstrap.
  if ! result=$(LC_ALL=C output_readonly_query /usr/bin/pacman-conf "${args[@]}" RootDir DBPath \
    | iconv -f UTF-8 -t UTF-8 | jq -Rs '
      def lines: if . == "" then [] elif endswith("\n") then split("\n")[:-1] else error("unterminated context") end;
      [lines[] | if test("^(RootDir|DBPath) = /[^[:cntrl:]]*$")
        then capture("^(?<key>RootDir|DBPath) = (?<value>/[^[:cntrl:]]*)$") else error("unexpected context line") end]
      | if length == 2 and (map(.key) | sort) == ["DBPath","RootDir"] then from_entries
        else error("incomplete package context") end'); then
    fail 'Could not completely resolve the package database configuration'
    return 1
  fi
  root=$(printf '%s' "$result" | jq -er '.RootDir') || return 1
  db=$(printf '%s' "$result" | jq -er '.DBPath') || return 1
  [[ -z $db_override ]] || db=$db_override
  root_identity=$(package_catalog_input_identity "$root" directory) || return 1
  db_identity=$(package_catalog_input_identity "$db" directory) || return 1
  jq -cn --argjson root "$root_identity" --argjson database "$db_identity" '{root:$root,database:$database}'
}

parse_native_output_description() {
  iconv -f UTF-8 -t UTF-8 | jq -RcSse --arg expected_kind "${1:-}" '
    # Validate decoded strings too: JSON escapes survive the raw-byte filter.
    # Sources and link targets can be relative; URI syntax remains producer-owned.
    def pathname: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
    def absolute_string: pathname and startswith("/");
    def identity: type == "object" and all(.dev,.ino,.uid,.gid,.mode,.size,.lastModifiedTime; type == "string" and length > 0);
    def observation:
      type == "object" and (.path | pathname) and
      (.links | type == "array" and all(.[]; type == "object" and (.path | absolute_string)
        and (.target | pathname) and (.identity | identity))) and
      (if .status == "absent" then (.missing_at | absolute_string)
       elif .status == "present" then (.type == "file" or .type == "directory" or .type == "other")
         and (.resolved_path | absolute_string) and (.identity | identity)
        else false end) and
      (if has("entries") then (.entries | type == "array" and all(.[]; observation)) else true end);
    def resource:
      type == "object" and (.role == "uki" or .role == "kernel" or .role == "initramfs" or .role == "extra-initrd")
      and (.source | pathname) and (.destination | absolute_string)
      and (.prospective_uri | pathname)
      and (.disposition == "copied" or .disposition == "referenced")
      and (.source_observation | observation) and (.destination_observation | observation)
      and .source_observation.path == .source and .destination_observation.path == .destination;
    def expected:
      . as $document | .expected as $expected |
      ($expected | type == "object" and
        all(.kernel_id,.new_entry_default_name,.protocol,.cmdline; type == "string") and
        (.kernel_id | length > 0) and (.native_hash_policy == "present" or .native_hash_policy == "absent")
        and (.resources | type == "array" and all(.[]; resource))) and
      (if .operation.kind == "add-uki" then
         (.operation.sources | length == 1) and $expected.protocol == "efi" and
         ($expected.resources | length == 1 and .[0].role == "uki" and .[0].disposition == "copied"
           and .[0].source == $document.operation.sources[0])
       elif .operation.kind == "add-kernel" then
         (.operation.sources | length == 2) and $expected.protocol == "linux" and
         ($expected.resources | map(select(.role == "initramfs")) | length == 1 and .[0].disposition == "copied"
           and .[0].source == $document.operation.sources[0]) and
         ($expected.resources | map(select(.role == "kernel")) | length == 1 and .[0].disposition == "copied"
           and .[0].source == $document.operation.sources[1]) and
         all($expected.resources[]; if .role == "extra-initrd" then .disposition == "referenced" and .source == .destination
           else .role == "kernel" or .role == "initramfs" end)
       else false end);
    if test("[\u0000-\u0008\u000b\u000c\u000e-\u001f]") then error("invalid JSON control byte") else fromjson end |
    if type == "object" and .format == "limine-native-description"
      and .schema == 1 and .scope == "native-operation" and .complete == true and .errors == []
      and (.context | type == "object") and (.inputs | type == "array" and all(.[]; observation))
      and (.operation.sources | type == "array" and all(.[]; pathname))
      and ($expected_kind == "" or .operation.kind == $expected_kind)
      and (.observed.configuration | observation)
      and (.context.esp_path | absolute_string) and (.context.config_path | absolute_string)
      and (.context.filesystem.path | observation)
      and (.context.esp_candidates | type == "array" and all(.[]; .path | observation))
      and (if .operation.kind == "context" then true else expected end)
    then . else error("unsupported or incomplete native description") end'
}

parse_shell_build_description() {
  iconv -f UTF-8 -t UTF-8 | jq -RcSse '
    def argument: type == "string" and (test("[[:cntrl:]]") | not);
    def step:
      type == "object" and (.variant == "normal" or .variant == "fallback")
      and (.native_operation == "add-uki" or .native_operation == "add-kernel")
      and (.native_name | argument and length > 0)
      and (.source_basename | argument and length > 0 and (contains("/") | not))
      and (.kernel_source == null or (.kernel_source | argument and startswith("/")))
      and (.suffix | argument) and (.comment | argument);
    if test("[\u0000-\u0008\u000b\u000c\u000e-\u001f]") then error("invalid JSON control byte") else fromjson end |
    if type == "object" and .format == "limine-build-description"
      and .schema == 2 and .scope == "shell-build" and .complete == true and .errors == []
      and (.settings | type == "object") and (.inputs | type == "array")
      and (.kernels | type == "array" and all(.[];
        type == "object" and (.publication_steps | type == "array" and all(.[]; step))))
      and (.mode == "uki" or .mode == "regular")
    then . else error("unsupported or incomplete shell build description") end'
}

# Compose potential publication slots from the actual producer interfaces.
# This does not select the required set: explicit recorded retirements and new
# scheduled work are applied by the owning lifecycle transaction afterwards.
collect_producer_output_expectations() {
  local catalog=$1 capture=$2 native_context final_context esp_identity esp catalog_root current_root
  local catalog_hash final_catalog_hash contents reader_pid row step index=0 source kind suffix
  local root_db root_local map_status=0 native_name kernel_source expected_operation
  local -a build_args=() native_args=()
  validate_control_file "$catalog" && validate_control_directory "$capture" || return 1
  mode_is_private "$(stat -Lc '%a' "$capture")" || return 1
  contents=$(find "$capture" -mindepth 1 -maxdepth 1 -print -quit) || return 1
  [[ -z $contents ]] || return 1
  validate_control_file /usr/bin/limine-entry-tool && validate_control_file /usr/bin/limine-mkinitcpio || return 1
  jq -e 'if .format == "omasecboot-package-catalog" and .schema == 1 and .database_version == 9
    and (.kernels | type == "array") and all(.kernels[];
      (.package | type == "string" and test("^[A-Za-z0-9@+_.-]+$")) and
      (.package_version | type == "string" and length > 0) and
      (.kernel_version | type == "string" and length > 0 and (test("[/[:cntrl:]]") | not)))
    then . else error("unsupported package catalog") end' "$catalog" >/dev/null || return 1
  catalog_hash=$(sha256sum -- "$catalog") || return 1
  catalog_root=$(jq -er '.context.root | .device + ":" + .inode' "$catalog") || return 1
  current_root=$(package_catalog_input_identity / directory | jq -er '.device + ":" + .inode') || return 1
  [[ $catalog_root == "$current_root" ]] || { fail 'Package catalog and producer root differ'; return 1; }
  native_context=$(output_readonly_query /usr/bin/limine-entry-tool --describe context | parse_native_output_description context) || return 1
  esp=$(printf '%s' "$native_context" | jq -er '.context.esp_path') || return 1
  esp_identity=$(package_catalog_input_identity "$esp" directory) || return 1
  esp=$(printf '%s' "$esp_identity" | jq -er '.resolved') || return 1
  root_db=$(jq -er '.context.database.resolved' "$catalog") || return 1
  root_local=$(jq -er '.context.local_database.resolved' "$catalog") || return 1
  output_capture_is_separate "$capture" "$esp" "$root_db" "$root_local" || {
    fail 'Expectation capture overlaps a producer input namespace or separation is unproved'
    return 1
  }

  printf '%s\n' "$native_context" >"$capture/native-context.json" || return 1
  mapfile -d '' -t build_args < <(jq -jr '.kernels[] | .package,"\u0000",.kernel_version,"\u0000"' "$catalog") || map_status=$?
  reader_pid=$!
  wait "$reader_pid" || return 1
  (( map_status == 0 )) || return 1
  output_readonly_query /usr/bin/limine-mkinitcpio --describe-build "${build_args[@]}" \
    | parse_shell_build_description >"$capture/build.json" || return 1
  jq -e --slurpfile catalog "$catalog" '
    if (.kernels | map([.package,.version])) == ($catalog[0].kernels | map([.package,.kernel_version]))
      and all(.kernels[]; (.fallback | type == "boolean") and
        (.publication_steps | map(.variant)) == (if .fallback then ["normal","fallback"] else ["normal"] end))
    then . else error("producer declaration/step coverage differs") end' "$capture/build.json" >/dev/null || return 1
  jq -c --slurpfile catalog "$catalog" '
    .kernels | to_entries[] | .key as $i | .value.publication_steps[]
    | {catalog:$catalog[0].kernels[$i],step:.}' "$capture/build.json" >"$capture/steps.jsonl" || return 1
  : >"$capture/slots.jsonl"
  # jq creates the finite records above; checked cat feeds a memory pipe and its
  # result is waited for, so a read failure is not an ordinary end of records.
  while IFS= read -r row; do
    step=$(jq -c '.step' <<<"$row") || return 1
    kind=$(jq -er '.native_operation' <<<"$step") || return 1
    source=$(jq -er '.source_basename | select(length > 0 and (test("[/[:cntrl:]]") | not))' <<<"$step") || return 1
    source="$capture/prospective/$index/$source"
    native_name=$(jq -er '.native_name | select(type == "string" and length > 0)' <<<"$step") || return 1
    native_args=(/usr/bin/limine-entry-tool --describe "$kind" "$native_name" "$source")
    kernel_source=''
    suffix=''
    case $kind in
      add-uki)
        json_is '.kernel_source == null and .suffix == ""' "$step" || return 1
        ;;
      add-kernel)
        kernel_source=$(jq -er '.kernel_source | select(type == "string" and startswith("/"))' <<<"$step") || return 1
        native_args+=("$kernel_source")
        suffix=$(jq -er '.suffix | select(type == "string")' <<<"$step") || return 1
        [[ -z $suffix ]] || native_args+=("$suffix")
        ;;
      *) return 1 ;;
    esac
    expected_operation=$(jq -cn --arg kind "$kind" --arg name "$native_name" --arg source "$source" \
      --arg kernel "$kernel_source" --arg suffix "$suffix" \
      '{kind:$kind,name:$name,suffix:$suffix,sources:([$source] + (if $kernel == "" then [] else [$kernel] end))}') || return 1
    output_readonly_query "${native_args[@]}" | parse_native_output_description "$kind" >"$capture/slot-$index.json" || return 1
    jq -ce --argjson row "$row" --argjson operation "$expected_operation" --slurpfile context "$capture/native-context.json" '
      if .context == $context[0].context and .inputs == $context[0].inputs
        and .observed.configuration == $context[0].observed.configuration
        and .operation == $operation
        and (.expected.resources | type == "array" and length > 0)
      then {catalog:$row.catalog,step:$row.step,description:.}
      else error("native context or operation changed") end' "$capture/slot-$index.json" >>"$capture/slots.jsonl" || return 1
    index=$((index + 1))
  done < <(cat -- "$capture/steps.jsonl")
  reader_pid=$!
  wait "$reader_pid" || return 1

  output_readonly_query /usr/bin/limine-mkinitcpio --describe-build "${build_args[@]}" \
    | parse_shell_build_description >"$capture/build.after.json" || return 1
  cmp -s "$capture/build.json" "$capture/build.after.json" || return 1
  final_context=$(output_readonly_query /usr/bin/limine-entry-tool --describe context | parse_native_output_description context) || return 1
  [[ $native_context == "$final_context" ]] || return 1
  final_catalog_hash=$(sha256sum -- "$catalog") || return 1
  [[ ${catalog_hash%% *} == "${final_catalog_hash%% *}" ]] || return 1
  jq -s --slurpfile context "$capture/native-context.json" --slurpfile build "$capture/build.json" \
    --arg catalog_sha256 "${catalog_hash%% *}" '
    {format:"omasecboot-output-expectations",schema:1,policy_scope:"potential-publications",
     catalog_sha256:$catalog_sha256,native_context:$context[0],build_description:$build[0],slots:.}' "$capture/slots.jsonl"
}

# Independently checked enumeration, metadata and complete input reads. The
# version-9 writer supplies real package directories; libalpm's treatment of
# directory-entry symlinks varies with d_type availability and remains unknown
# to this witness. Configured database/local path aliases resolve normally.
package_catalog_measure() {
  local local_db=$1 target=$2 links owner kind
  links=$(find "$local_db" -mindepth 1 -maxdepth 1 -type l -xtype d -print) || return 1
  [[ -z $links ]] || { fail 'Package database entry-link semantics are unresolved'; return 1; }
  find "$local_db" -mindepth 1 -maxdepth 1 -type d -printf '%f\0' >"$target.entries.unsorted" || return 1
  LC_ALL=C sort -z -- "$target.entries.unsorted" >"$target.entries" || return 1
  iconv -f UTF-8 -t UTF-8 <"$target.entries" >/dev/null || return 1
  for kind in all files; do
    CATALOG_LOCAL_DB="$local_db" CATALOG_KIND="$kind" LC_ALL=C awk '
      BEGIN { RS="\0"; db=ENVIRON["CATALOG_LOCAL_DB"]; printf "%s%c", db "/ALPM_DB_VERSION", 0 }
      /[[:cntrl:]\/]/ { exit 1 }
      {
        if (ENVIRON["CATALOG_KIND"] == "all") printf "%s%c", db "/" $0, 0;
        printf "%s%c%s%c", db "/" $0 "/desc", 0, db "/" $0 "/files", 0;
      }
    ' "$target.entries" >"$target.$kind.paths" || return 1
  done
  xargs -0 -r -- stat -L --printf='%f:%u:%g:%d:%i:%s:%Y:%Z\0%n\0' -- \
    <"$target.all.paths" >"$target.stats" || return 1
  owner=$(control_owner_uid) || return 1
  CATALOG_OWNER="$owner" LC_ALL=C awk '
    BEGIN { RS="\0" }
    NR % 2 == 1 {
      if (split($0,a,":") != 8) exit 1;
      mode=strtonum("0x" a[1]); type=int(mode/4096);
      if ((type != 4 && type != 8) || a[2] != ENVIRON["CATALOG_OWNER"] || and(mode,18) != 0) exit 1;
    }
    END { if (NR % 2 != 0) exit 1 }
  ' "$target.stats" || return 1
  xargs -0 -r -- sha256sum --zero -- <"$target.files.paths" >"$target.hashes" || return 1
}

package_catalog_parse_packages() {
  jq -Rs '
    def lines: if . == "" then [] elif endswith("\n") then split("\n")[:-1] else error("unterminated package line") end;
    [lines[] | if test("^[A-Za-z0-9@+_.-]+ [^[:space:][:cntrl:]]+$")
      then capture("^(?<name>[A-Za-z0-9@+_.-]+) (?<version>[^[:space:][:cntrl:]]+)$") else error("unexpected package line") end]
    | if (map(.name) | unique | length) != length then error("duplicate package")
      else sort_by(.name) end' <"$1"
}

# A writer-format coverage witness, not a fallback catalog. GNU awk checks each
# getline result. libalpm's file-list reader can silently stop on an I/O error,
# so successful CLI output and empty diagnostics alone cannot certify coverage.
package_catalog_expected_files() {
  local capture=$1 local_db=$2 root=$3
  jq -j '.[] | .name,"\u0000",.version,"\u0000"' "$capture/packages.json" >"$capture/package-pairs" || return 1
  CATALOG_LOCAL_DB="$local_db" CATALOG_ROOT="${root%/}/" LC_ALL=C awk '
    BEGIN { RS="\0"; db=ENVIRON["CATALOG_LOCAL_DB"]; root=ENVIRON["CATALOG_ROOT"] }
    NR % 2 == 1 { package=$0; next }
    {
      file=db "/" package "-" $0 "/files";
      RS="\n"; inside=0; seen=0; backup=0;
      while ((result=(getline line < file)) > 0) {
        if (line == "") { inside=0; backup=0; continue }
        if (!inside && !backup && line == "%FILES%") { if (++seen > 1) exit 1; inside=1; continue }
        if (!inside && !backup && line == "%BACKUP%") { backup=1; continue }
        if (inside) {
          if (line ~ /^\// || line ~ /(^|\/)\.\.?(\/|$)/) exit 1;
          printf "%s %s%s\n", package, root, line;
        } else if (!backup) exit 1;
      }
      if (result < 0 || close(file) != 0) exit 1;
      RS="\0";
    }
    END { if (NR % 2 != 0) exit 1 }
  ' "$capture/package-pairs" >"$capture/files.expected" || return 1
}

# The caller supplies an empty root-owned private capture directory and owns its
# disposition. No source database is initialized or changed. Context agreement
# and package-writer/boot-lock authority belong to the enclosing transaction.
collect_package_kernel_catalog() {
  local capture=$1 config=${2:-/etc/pacman.conf} root_override=${3:-} db_override=${4:-}
  local context final_context root db local_db local_identity contents version kind
  local source_digest metadata_digest packages_digest files_digest packages_status=0 files_status=0
  local -a query
  validate_control_directory "$capture" && mode_is_private "$(stat -Lc '%a' "$capture")" || return 1
  contents=$(find "$capture" -mindepth 1 -maxdepth 1 -print -quit) || return 1
  [[ -z $contents ]] || return 1
  validate_control_file /usr/bin/pacman && validate_control_file /usr/bin/pacman-conf || return 1
  context=$(package_catalog_context "$config" "$root_override" "$db_override") || return 1
  root=$(printf '%s' "$context" | jq -er '.root.resolved') || return 1
  db=$(printf '%s' "$context" | jq -er '.database.resolved') || return 1
  local_identity=$(package_catalog_input_identity "$db/local" directory) || return 1
  local_db=$(printf '%s' "$local_identity" | jq -er '.resolved') || return 1
  output_capture_is_separate "$capture" "$db" "$local_db" || {
    fail 'Capture directory overlaps the package database or separation is unproved'
    return 1
  }
  package_catalog_measure "$local_db" "$capture/before" || return 1
  version=$(cat -- "$local_db/ALPM_DB_VERSION") || return 1
  [[ $version == 9 ]] || { fail 'Unsupported package database version'; return 1; }

  query=(/usr/bin/pacman --config "$config" --root "$root" --dbpath "$db" --color never)
  LC_ALL=C "${query[@]}" -Q >"$capture/packages.raw" 2>"$capture/packages.err" || packages_status=$?
  # Native -Q returns 1 when no package matched. Admit that response only for
  # a positively observed empty database, never for partial/error output.
  if [[ -s $capture/packages.err ]] || { (( packages_status != 0 )) && \
    { (( packages_status != 1 )) || [[ -s $capture/before.entries || -s $capture/packages.raw ]]; }; }; then
    fail 'Could not completely observe installed package versions'
    return 1
  fi
  LC_ALL=C "${query[@]}" -Ql >"$capture/files.raw" 2>"$capture/files.err" || files_status=$?
  if [[ -s $capture/files.err ]] || { (( files_status != 0 )) && \
    { (( files_status != 1 )) || [[ -s $capture/before.entries || -s $capture/files.raw ]]; }; }; then
    fail 'Could not completely observe installed package declarations'
    return 1
  fi
  iconv -f UTF-8 -t UTF-8 <"$capture/packages.raw" >/dev/null || return 1
  iconv -f UTF-8 -t UTF-8 <"$capture/files.raw" >/dev/null || return 1
  package_catalog_parse_packages "$capture/packages.raw" >"$capture/packages.json" || return 1
  jq -j '.[] | .name + "-" + .version + "\u0000"' "$capture/packages.json" >"$capture/entries.cli.unsorted" || return 1
  LC_ALL=C sort -z "$capture/entries.cli.unsorted" >"$capture/entries.cli" || return 1
  cmp -s "$capture/before.entries" "$capture/entries.cli" || {
    fail 'Package query omitted or changed a database entry'
    return 1
  }
  package_catalog_expected_files "$capture" "$local_db" "$root" || return 1
  LC_ALL=C sort "$capture/files.expected" >"$capture/files.expected.sorted" || return 1
  LC_ALL=C sort "$capture/files.raw" >"$capture/files.sorted" || return 1
  cmp -s "$capture/files.expected.sorted" "$capture/files.sorted" || {
    fail 'Package query is not a complete view of its source declarations'
    return 1
  }

  jq -Rsn --arg root "${root%/}/" --slurpfile packages "$capture/packages.json" '
    ($packages[0] | map({key:.name,value:.version}) | from_entries) as $versions
    | [inputs | split("\n")[] | select(length > 0)
       | if test("^[A-Za-z0-9@+_.-]+ /.*$")
         then capture("^(?<package>[A-Za-z0-9@+_.-]+) (?<path>/.*)$") else error("unexpected file-list row") end | . as $row
       | if ($versions | has($row.package)) then . else error("unknown package row") end
       | select(.path | startswith($root + "usr/lib/modules/"))
       | . + {relative:(.path | ltrimstr($root))}
       | select(.relative | test("^usr/lib/modules/[^/]+/modules\\.builtin$"))
       | {package:.package,package_version:$versions[.package],
          kernel_version:(.relative | split("/")[3]),declaration:("/" + .relative)}]
    | unique_by([.package,.package_version,.kernel_version,.declaration])
    | sort_by(.package,.kernel_version)' <"$capture/files.raw" >"$capture/kernels.json" || return 1
  package_catalog_measure "$local_db" "$capture/after" || return 1
  for kind in entries all.paths files.paths stats hashes; do
    cmp -s "$capture/before.$kind" "$capture/after.$kind" || {
      fail "Package catalog source changed during observation: $kind"
      return 1
    }
  done
  [[ $(package_catalog_input_identity "$db/local" directory) == "$local_identity" ]] || {
    fail 'Package database local binding changed during observation'
    return 1
  }
  final_context=$(package_catalog_context "$config" "$root_override" "$db_override") || return 1
  [[ $context == "$final_context" ]] || return 1
  source_digest=$(sha256sum "$capture/before.hashes") || return 1
  metadata_digest=$(sha256sum "$capture/before.stats") || return 1
  packages_digest=$(sha256sum "$capture/packages.raw") || return 1
  files_digest=$(sha256sum "$capture/files.raw") || return 1
  jq -cn --argjson context "$context" --argjson local_database "$local_identity" --slurpfile packages "$capture/packages.json" \
    --slurpfile kernels "$capture/kernels.json" --arg sources "${source_digest%% *}" \
    --argjson packages_status "$packages_status" --argjson files_status "$files_status" \
    --arg metadata "${metadata_digest%% *}" --arg package_hash "${packages_digest%% *}" --arg files_hash "${files_digest%% *}" '
    {format:"omasecboot-package-catalog",schema:1,context:($context + {local_database:$local_database}),database_version:9,
     packages:$packages[0],kernels:$kernels[0],query_status:{packages:$packages_status,files:$files_status},view:{source_sha256:$sources,
     metadata_sha256:$metadata,packages_sha256:$package_hash,files_sha256:$files_hash}}'
}
