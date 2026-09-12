#!/usr/bin/env bash
# Real wrapper/native query contracts in fixture-only namespaces.
set -euo pipefail
umask 077
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ ( $# == 2 || $# == 3 ) && -d $1 && -x $2/bin/java && -x $2/bin/javac ]] || die 'usage: limine-description.sh SOURCE_ROOT JDK25_HOME [NATIVE_EXECUTABLE]'
native_executable=${3:-}
[[ -z $native_executable || -x $native_executable ]] || die 'native executable is not executable'
for tool in bwrap jq patch sha256sum bash realpath mktemp mkdir cp mv rm rmdir chmod cmp grep find sort ln cat b2sum sync shellcheck; do
  command -v "$tool" >/dev/null || die "required command: $tool"
done
repo=$(realpath -- "${BASH_SOURCE[0]%/*}/../..")
source_root=$(realpath -- "$1")
java_home=$(realpath -- "$2")
integration=$repo/integrations/limine-entry-tool
metadata=$integration/source.json
parent=${TMPDIR:-/tmp}
[[ -d $parent && ! -L $parent ]] || die 'TMPDIR must be an existing real directory'
scratch=$(mktemp -d "$parent/limine-description.XXXXXX")
[[ -O $scratch && ! -L $scratch ]] || die 'scratch ownership check failed'
finish() {
  local rc=$?
  if [[ ${LIMINE_DESCRIPTION_KEEP:-0} == 1 ]]; then
    printf 'Retained description evidence: %s (status %s)\n' "$scratch" "$rc"
  else
    rm -rf -- "$scratch"
  fi
}
trap finish EXIT
# shellcheck source=tests/integration/lib/limine-sources.sh
source "$repo/tests/integration/lib/limine-sources.sh"
limine_prepare_sources "$source_root" "$scratch" "$metadata" "$integration"
jq -e '.description.schema == 1' "$metadata" >/dev/null || die 'description contract required'

mkdir -p "$scratch/fixtures" "$scratch/fake-bin" "$scratch/compiler"
cp "$repo/tests/integration/fixtures/DescriptionContract.java" "$repo/tests/integration/fixtures/NativeContract.java" "$scratch/fixtures/"
cat >"$scratch/fixtures/entry-tool" <<'EOF'
#!/bin/bash
exec /jdk/bin/java -Xmx256m -XX:ActiveProcessorCount=4 -XX:-UsePerfData \
  -Duser.home=/work/home -cp /classes org.limine.entry.tool.Main "$@"
EOF
cat >"$scratch/fake-bin/forbidden" <<'EOF'
#!/bin/bash
printf '%s\n' "$0 $*" >>/work/forbidden
exit 98
EOF
chmod 755 "$scratch/fixtures/entry-tool" "$scratch/fake-bin/forbidden"
entry_program=$scratch/fixtures/entry-tool
if [[ -n $native_executable ]]; then
  entry_program=$(realpath -- "$native_executable")
  printf 'Query executable: '
  sha256sum "$entry_program"
fi
for tool in tput logger sbctl mount umount flock mkdir b2sum; do
  cp "$scratch/fake-bin/forbidden" "$scratch/fake-bin/$tool"
done
for script in "$scratch/fixtures/entry-tool" "$scratch/fake-bin/forbidden"; do
  bash -n "$script"
  shellcheck "$script"
done

common=(
  bwrap --unshare-all --die-with-parent --new-session --uid 1000 --gid 1000 --clearenv
  --ro-bind /usr/lib /usr/lib --dir /usr/bin --symlink usr/bin /bin --symlink usr/lib /lib
  --tmpfs /usr/lib/modules --tmpfs /usr/lib/limine --proc /proc --dev /dev --tmpfs /tmp --dir /sys
  --ro-bind "$java_home" /jdk --ro-bind "$scratch/fixtures" /fixtures
  --ro-bind "$scratch/fake-bin" /fake-bin --ro-bind /usr/bin/bash /usr/bin/bash
  --setenv PATH /fake-bin:/jdk/bin:/usr/bin --setenv HOME /work/home
  --setenv XDG_CONFIG_HOME /work/home/config --setenv XDG_DATA_HOME /work/home/data
  --setenv XDG_CACHE_HOME /work/home/cache --setenv XDG_STATE_HOME /work/home/state
  --setenv XDG_RUNTIME_DIR /work/runtime --setenv HISTFILE /dev/null
  --setenv LC_ALL C.UTF-8 --setenv TERM dumb --chdir /work
)
if [[ -d /usr/lib64 ]]; then
  [[ $(realpath /usr/lib64) == "$(realpath /usr/lib)" ]] || die 'requires the merged-/usr lib64 alias'
  common+=(--symlink lib /usr/lib64 --symlink usr/lib64 /lib64)
fi
compile_sources=()
for path in "${LIMINE_PATCHED_JAVA[@]}"; do compile_sources+=("/source/$path"); done
"${common[@]}" --dir /etc --dir /run --dir /var --dir /usr/share/limine-entry-tool.d \
  --ro-bind "$scratch/patched" /source --bind "$scratch/compiler" /work /jdk/bin/javac \
  -J-Xmx1g -J-XX:ActiveProcessorCount=4 -J-Duser.home=/work/home -d /work/classes \
  "${compile_sources[@]}" /fixtures/DescriptionContract.java /fixtures/NativeContract.java \
  >"$scratch/compiler.log" 2>&1 || { cat "$scratch/compiler.log" >&2; die 'description compilation failed'; }

wrapper=$scratch/patched/install/arch-linux/limine-entry-tool/usr/bin/limine-entry-tool
inventory() {
  local work=$1 output=$2 path
  {
    for path in etc boot run var share home dropins; do
      find "$work/$path" -printf '%p %y %m %s %T@ %l\n'
    done
  } | sort >"$output"
  while IFS= read -r -d '' path; do
    if [[ -r $path ]]; then sha256sum "$path"; else printf 'unreadable %s\n' "$path"; fi
  done < <(find "$work/etc" "$work/boot" "$work/run" "$work/var" "$work/share" "$work/home" "$work/dropins" -type f -print0 | sort -z) >>"$output"
}

count=0
query_case() {
  local name=$1 expected=$2
  shift 2
  local work=$scratch/$name rc=0 bind=--bind
  mkdir -p "$work"/{etc/default,etc/limine-entry-tool.d,etc/boot/hooks/pre.d,etc/boot/hooks/post.d,boot,run,var,share,home,runtime,dropins}
  printf '11111111111111111111111111111111\n' >"$work/etc/machine-id"
  cat >"$work/etc/default/limine" <<'EOF'
TARGET_OS_NAME="Contract Linux"
ESP_PATH=/boot
CUSTOM_UKI_NAME=contract
KERNEL_CMDLINE="root=fixture quiet"
EOF
  cp "$scratch/fake-bin/forbidden" "$work/etc/boot/hooks/pre.d/sentinel"
  cp "$scratch/fake-bin/forbidden" "$work/etc/boot/hooks/post.d/sentinel"
  extra=()
  case $name in
    readonly) bind=--ro-bind ;;
    missing-id) rm "$work/etc/machine-id" ;;
    invalid-id) printf 'short\n' >"$work/etc/machine-id" ;;
    unreadable-config) chmod 000 "$work/etc/default/limine" ;;
    dangling-config) rm "$work/etc/default/limine"; ln -s /absent-config "$work/etc/default/limine" ;;
    looping-config) rm "$work/etc/default/limine"; ln -s limine "$work/etc/default/limine" ;;
    invalid-utf8) printf '\377\n' >>"$work/etc/default/limine" ;;
    distro|distro-symlink|unreadable-distro)
      printf 'TARGET_OS_NAME=\n' >>"$work/etc/default/limine"
      printf 'PRETTY_NAME="Fixture Distribution"\n' >"$work/etc/os-release"
      if [[ $name == distro-symlink ]]; then
        mv "$work/etc/os-release" "$work/os-release"
        ln -s /usr/lib/os-release "$work/etc/os-release"
        extra+=(--ro-bind "$work/os-release" /usr/lib/os-release)
      elif [[ $name == unreadable-distro ]]; then
        chmod 000 "$work/etc/os-release"
      fi
      ;;
    cmdline-file)
      printf 'KERNEL_CMDLINE=\n' >>"$work/etc/default/limine"
      mkdir "$work/etc/kernel"
      printf 'root=from-file\nro\n' >"$work/etc/kernel/cmdline"
      ;;
    extra-initrd) printf 'KERNEL_CMDLINE="root=fixture initrd=/ucode"\n' >>"$work/etc/default/limine" ;;
    config-symlink) mv "$work/etc/default/limine" "$work/etc/settings"; ln -s ../settings "$work/etc/default/limine" ;;
    config-directory-symlink)
      rmdir "$work/etc/limine-entry-tool.d"
      ln -s /work/dropins "$work/etc/limine-entry-tool.d"
      printf 'CUSTOM_UKI_NAME=overridden\n' >"$work/dropins/value.conf"
      ;;
    null-config)
      cp "$work/etc/default/limine" "$work/etc/limine-entry-tool.conf"
      rm "$work/etc/default/limine"
      ln -s /dev/null "$work/etc/default/limine"
      ;;
    layers)
      printf 'CUSTOM_UKI_NAME=lowest\nKERNEL_CMDLINE="root=lowest"\n' >"$work/share/a.conf"
      printf 'CUSTOM_UKI_NAME=middle\n' >"$work/etc/limine-entry-tool.conf"
      printf 'CUSTOM_UKI_NAME=dropin\n' >"$work/etc/limine-entry-tool.d/a.conf"
      ;;
    indexed-append)
      printf 'KERNEL_CMDLINE[linux]="old=value"\nKERNEL_CMDLINE[linux]+="new=value"\n' >>"$work/etc/default/limine"
      ;;
    ignored-syntax) printf 'ignored native syntax\nKERNEL_CMDLINE[broken=ignored\n' >>"$work/etc/default/limine" ;;
    default-prefix) printf 'CUSTOM_UKI_NAME=INVALID\n' >>"$work/etc/default/limine" ;;
    prefix-overlap) printf 'CUSTOM_UKI_NAME=linux\n' >>"$work/etc/default/limine" ;;
    missing-esp) printf 'ESP_PATH=/unmade\n' >>"$work/etc/default/limine" ;;
    automatic-no-esp) printf 'ESP_PATH=\n' >>"$work/etc/default/limine" ;;
    hash-enabled|hash-tool-absent)
      printf 'ENABLE_VERIFICATION=yes\n' >>"$work/etc/default/limine"
      if [[ $name == hash-tool-absent ]]; then
        mkdir "$work/no-hash"
        for tool in tput logger sbctl mount umount flock mkdir; do cp "$scratch/fake-bin/$tool" "$work/no-hash/"; done
        extra+=(--setenv PATH /work/no-hash:/jdk/bin:/usr/bin)
      fi
      ;;
    source-symlink)
      printf 'data\n' >"$work/real-kernel"
      ln -s real-kernel "$work/lexical-kernel"
      ;;
    renamed-os|custom-kernel-name|duplicate-kernel|sibling-only|snapshot-only|duplicate-os|macro|undefined-macro)
      printf '/Renamed OS\n  comment: machine-id=11111111111111111111111111111111\n' >"$work/boot/limine.conf"
      case $name in
        custom-kernel-name|duplicate-kernel)
          printf '//Displayed kernel\n  comment: kernel-id=linux\n  protocol: efi\n  path: boot():/old.efi\n' >>"$work/boot/limine.conf"
          [[ $name != duplicate-kernel ]] || printf '//Other display\n  comment: kernel-id=linux\n' >>"$work/boot/limine.conf"
          ;;
        sibling-only)
          printf '/Other OS\n  comment: machine-id=22222222222222222222222222222222\n//linux\n' >>"$work/boot/limine.conf"
          ;;
        snapshot-only) printf '//Snapshots\n///linux\n' >>"$work/boot/limine.conf" ;;
        duplicate-os) printf '/Duplicate OS\n  comment: machine-id=11111111111111111111111111111111\n' >>"$work/boot/limine.conf" ;;
        macro) printf "\${os}=Contract Linux\n/\${os}\n//linux\n" >"$work/boot/limine.conf" ;;
        undefined-macro) printf "/\${missing}\n" >"$work/boot/limine.conf" ;;
      esac
      ;;
    name-fallback) printf '/Contract Linux\n//linux\n' >"$work/boot/limine.conf" ;;
    other-machine-name) printf '/Contract Linux\n  comment: machine-id=22222222222222222222222222222222\n//linux\n' >"$work/boot/limine.conf" ;;
    parity-custom-uki|parity-custom-kernel)
      printf '/Contract Linux\n  comment: machine-id=11111111111111111111111111111111\n//Custom display\n  comment: kernel-id=linux\n' >"$work/boot/limine.conf"
      ;;
  esac
  inventory "$work" "$work/before"
  "${common[@]}" --bind "$work" /work "$bind" "$work/etc" /etc "$bind" "$work/boot" /boot \
    "$bind" "$work/run" /run "$bind" "$work/var" /var "$bind" "$work/share" /usr/share/limine-entry-tool.d \
    --ro-bind "$scratch/compiler/classes" /classes --ro-bind "$wrapper" /usr/bin/limine-entry-tool \
    --ro-bind "$entry_program" /usr/lib/limine/limine-entry-tool \
    --ro-bind "$scratch/fake-bin/forbidden" /usr/lib/limine/auth-helper \
    "${extra[@]}" /usr/bin/bash /usr/bin/limine-entry-tool --describe "$@" >"$work/stdout" 2>"$work/stderr" || rc=$?
  [[ $rc == "$expected" ]] || { cat "$work/stdout" "$work/stderr" >&2; die "$name: expected $expected, got $rc"; }
  jq -es 'length == 1 and .[0].format == "limine-native-description" and .[0].schema == 1
    and .[0].scope == "native-operation" and (.[0].complete | type == "boolean")' "$work/stdout" >/dev/null || die "$name: not one typed JSON document"
  if [[ $expected == 0 ]]; then
    jq -e '.complete and (.errors | length == 0)' "$work/stdout" >/dev/null || die "$name: incomplete success"
  else
    jq -e '(.complete | not) and (.errors | length > 0)' "$work/stdout" >/dev/null || die "$name: failure lost its diagnostic"
  fi
  [[ ! -e $work/forbidden ]] || { cat "$work/forbidden" >&2; die "$name: mutation-capable helper invoked"; }
  inventory "$work" "$work/after"
  cmp "$work/before" "$work/after" || die "$name: query changed a watched domain"
  if [[ $expected == 0 ]]; then
    jq -e '.observed.configuration as $config | any(.inputs[]; . == $config)' "$work/stdout" >/dev/null \
      || die "$name: configuration metadata is not its parsed input"
  fi
  case $name in
    missing-id) [[ ! -e $work/etc/machine-id ]] || die 'missing machine ID was created' ;;
    missing-config|readonly|layers|config-symlink|null-config|ignored-syntax)
      [[ ! -e $work/boot/limine.conf ]] || die 'missing configuration was initialized'
      ;;
  esac
  printf 'PASS: describe/%s\n' "$name"
  ((count += 1))
}

for name in missing-config readonly layers config-symlink config-directory-symlink null-config distro distro-symlink cmdline-file \
  indexed-append ignored-syntax default-prefix prefix-overlap missing-esp hash-enabled hash-tool-absent \
  renamed-os custom-kernel-name sibling-only snapshot-only name-fallback other-machine-name macro; do
  query_case "$name" 0 add-uki linux /missing/input.efi
done
for name in missing-id invalid-id unreadable-config unreadable-distro dangling-config looping-config invalid-utf8 \
  automatic-no-esp duplicate-kernel duplicate-os undefined-macro; do
  query_case "$name" 1 add-uki linux /missing/input.efi
done
query_case context 0 context
query_case regular 0 add-kernel linux /missing/initramfs /missing/vmlinuz
query_case fallback 0 add-kernel linux /missing/initramfs-fallback /missing/vmlinuz -fallback
query_case source-symlink 0 add-kernel linux /missing/initramfs /work/lexical-kernel
query_case extra-initrd 0 add-kernel linux /missing/initramfs /missing/vmlinuz
jq -e '.context.uki_prefix == "contract" and .expected.cmdline == "root=fixture quiet"' "$scratch/layers/stdout" >/dev/null || die 'native configuration precedence changed'
for name in config-symlink config-directory-symlink distro-symlink; do
  jq -e 'any(.inputs[]; (.links | length) > 0)' "$scratch/$name/stdout" >/dev/null || die "$name: input symlink identity omitted"
done
for name in distro distro-symlink; do
  jq -e '.context.target_os == "Fixture Distribution"' "$scratch/$name/stdout" >/dev/null || die 'native distro resolution changed'
done
jq -e '.expected.cmdline == "root=from-file ro"' "$scratch/cmdline-file/stdout" >/dev/null || die 'file command-line normalization changed'
jq -e '.expected.resources[0].role == "extra-initrd" and .expected.resources[0].disposition == "referenced"
  and .expected.resources[0].destination == "/boot/ucode" and .expected.cmdline == "root=fixture"' "$scratch/extra-initrd/stdout" >/dev/null || die 'extra initrd description changed'
jq -e '.expected.cmdline == "new=value old=value"' "$scratch/indexed-append/stdout" >/dev/null || die 'native += order changed'
jq -e '.expected.resources[0].destination == "/boot/EFI/Linux/linux.efi"' "$scratch/prefix-overlap/stdout" >/dev/null || die 'native prefix suppression changed'
jq -e '.expected.resources[0].destination == "/boot/EFI/Linux/11111111111111111111111111111111_linux.efi"' "$scratch/default-prefix/stdout" >/dev/null || die 'default prefix changed'
jq -e '.expected.resources[-1].destination | endswith("/linux/lexical-kernel")' "$scratch/source-symlink/stdout" >/dev/null || die 'source symlink was canonicalized before basename selection'
jq -e '.expected.kernel_id == "linux-fallback" and (.expected.resources[-1].destination | endswith("/linux/vmlinuz"))' "$scratch/fallback/stdout" >/dev/null || die 'fallback resource directory changed'
jq -e '.observed.os_basis == "machine-id"' "$scratch/renamed-os/stdout" >/dev/null || die 'machine-ID association lost'
jq -e '.observed.os_candidates[0].kernel_candidates[0].clean_name == "Displayed kernel"
  and .expected.new_entry_default_name == "linux" and (.expected | has("entry_name") | not)' "$scratch/custom-kernel-name/stdout" >/dev/null || die 'description claimed an existing display-name rename'
for name in sibling-only snapshot-only; do
  jq -e '.observed.os_candidates[0].kernel_candidates | length == 0' "$scratch/$name/stdout" >/dev/null || die "$name: unrelated kernel discharged the operation"
done
jq -e '.observed.os_candidates | length == 0' "$scratch/other-machine-name/stdout" >/dev/null || die 'another machine matched by name'
jq -e '.context.verification_enabled and .context.verification_basis.requires_fresh_availability_check' "$scratch/hash-enabled/stdout" >/dev/null || die 'verification basis missing'
jq -e '(.context.verification_enabled | not) and (.context.verification_basis.path_environment | contains("no-hash"))' "$scratch/hash-tool-absent/stdout" >/dev/null || die 'PATH-dependent policy was hidden'

for option in --quiet --help --version --comment --keep-files --priority --overwrite \
  --no-mutex --mutex --no-hooks --hooks --get-cmdline; do
  query_case "control-source-${option#--}" 2 add-uki linux "$option"
  query_case "control-suffix-${option#--}" 2 add-kernel linux /missing/init /missing/kernel "$option"
done
query_case lexical-control-name 0 add-uki linux ./--quiet

# Compare a real description made before inputs exist with subsequent actual
# publication. Both new entries and retained custom display names are covered.
for name in parity-new-uki parity-custom-uki parity-new-kernel parity-custom-kernel; do
  operation=uki
  request=(add-uki linux /work/input.efi)
  if [[ $name == *kernel ]]; then operation=regular; request=(add-kernel linux /work/initramfs /work/vmlinuz); fi
  query_case "$name" 0 "${request[@]}"
  work=$scratch/$name
  printf 'prospective source now exists\n' >"$work/input.efi"
  printf 'kernel\n' >"$work/vmlinuz"
  printf 'initramfs\n' >"$work/initramfs"
  "${common[@]}" --bind "$work" /work --bind "$work/etc" /etc --bind "$work/boot" /boot \
    --bind "$work/run" /run --bind "$work/var" /var --bind "$work/share" /usr/share/limine-entry-tool.d \
    --ro-bind "$scratch/compiler/classes" /classes --ro-bind /usr/bin/b2sum /usr/bin/b2sum --ro-bind /usr/bin/sync /usr/bin/sync \
    --setenv PATH /jdk/bin:/usr/bin /jdk/bin/java -Xmx256m -XX:-UsePerfData -Duser.home=/work/home \
    -cp /classes org.limine.entry.tool.NativeContract "$operation" /boot linux contract no \
    >"$work/publication.stdout" 2>"$work/publication.stderr" || { cat "$work/publication.stderr" >&2; die "$name: actual publication failed"; }
  "${common[@]}" --bind "$work" /work --bind "$work/etc" /etc --bind "$work/boot" /boot \
    --bind "$work/run" /run --bind "$work/var" /var --bind "$work/share" /usr/share/limine-entry-tool.d \
    --ro-bind "$scratch/compiler/classes" /classes --ro-bind "$wrapper" /usr/bin/limine-entry-tool \
    --ro-bind "$entry_program" /usr/lib/limine/limine-entry-tool \
    /usr/bin/bash /usr/bin/limine-entry-tool --describe "${request[@]}" >"$work/after-publication.json"
  display=linux
  [[ $name != parity-custom-* ]] || display='Custom display'
  jq -e --arg display "$display" '.complete and .observed.os_candidates[0].kernel_candidates[0].clean_name == $display' \
    "$work/after-publication.json" >/dev/null || die "$name: publication renamed or lost its matching entry"
  while IFS=$'\t' read -r source target; do
    [[ $source == /work/* && $target == /boot/* ]] || die 'fixture path escaped its expected root'
    cmp "$work/${source#/work/}" "$work/boot/${target#/boot/}" || die "$name: publication differed from described destination"
  done < <(jq -r '.expected.resources[] | [.source, .destination] | @tsv' "$work/stdout")
done

for name in json pure-clean interleaved as-read-replace as-read-delete as-read-create; do
  work=$scratch/helper-$name
  mkdir -p "$work"/{etc,run,var,share,home,runtime}
  "${common[@]}" --bind "$work" /work --bind "$work/etc" /etc --bind "$work/run" /run \
    --bind "$work/var" /var --bind "$work/share" /usr/share/limine-entry-tool.d \
    --ro-bind "$scratch/compiler/classes" /classes /jdk/bin/java -Xmx256m -XX:-UsePerfData \
    -Duser.home=/work/home -cp /classes org.limine.entry.tool.DescriptionContract "$name" \
    >"$work/stdout" 2>"$work/stderr" || { cat "$work/stderr" >&2; die "description helper: $name"; }
  [[ ! -e $work/forbidden ]] || die "$name: hidden helper side effect"
  if [[ $name == json ]]; then
    jq -e '.text == "quote\" slash\\ tab\t newline\n control\u0001 emoji😀"' "$work/stdout" >/dev/null || die 'JSON round-trip failed'
  elif [[ $name == pure-clean ]]; then
    jq -e '.cmdline == "root=fixture" and .initrds == ["/microcode"]' "$work/stdout" >/dev/null || die 'pure cleaning changed'
  else
    jq -e --arg name "$name" '.validated == $name' "$work/stdout" >/dev/null || die 'reader-generation validation failed'
  fi
  printf 'PASS: describe/%s\n' "$name"
  ((count += 1))
done
printf 'Passed %s full-query and reader-generation contracts.\n' "$count"
