#!/usr/bin/env bash
# Real package catalog -> shell step mapping -> actual native query composition.
set -euo pipefail
umask 077
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 && -d $1 && -x $2/bin/javac ]] || die 'usage: output-expectations.sh SOURCE_ROOT JDK25_HOME'
for tool in bwrap jq patch sha256sum bash realpath mktemp mkdir cp rm chmod cc bsdtar \
  pacman pacman-conf cat cmp stat readlink iconv find findmnt sort xargs awk base64 ln; do
  command -v "$tool" >/dev/null || die "required command: $tool"
done
repo=$(realpath -- "${BASH_SOURCE[0]%/*}/../..")
source_root=$(realpath -- "$1")
java_home=$(realpath -- "$2")
parent=${TMPDIR:-/tmp}
[[ -d $parent && ! -L $parent ]] || die 'TMPDIR must be a real directory'
scratch=$(mktemp -d "$parent/output-expectations.XXXXXX")
finish() {
  local rc=$?
  if [[ ${OUTPUT_EXPECTATIONS_KEEP:-0} == 1 ]]; then
    printf 'Retained output-expectation evidence: %s (status %s)\n' "$scratch" "$rc"
  else
    rm -rf -- "$scratch"
  fi
}
trap finish EXIT
# shellcheck source=tests/integration/lib/limine-sources.sh
source "$repo/tests/integration/lib/limine-sources.sh"
cp "$repo/integrations/limine-entry-tool/source.json" "$scratch/source.json"
sha256sum "$scratch/source.json" >"$scratch/source.sha256"
limine_prepare_sources "$source_root" "$scratch" "$scratch/source.json" "$repo/integrations/limine-entry-tool"
limine_prepare_java_dependencies "$scratch" "$scratch/source.json" "${LIMINE_NATIVE_JSON_JAR:-}"
mkdir -p "$scratch/fixtures/packages" "$scratch/fixtures/runtime" "$scratch/compiler" "$scratch/fake-bin"
# shellcheck source=tests/integration/lib/pacman-fixtures.sh
source "$repo/tests/integration/lib/pacman-fixtures.sh"
pacman_fixture_package linux 1-1 v1
pacman_fixture_package linux-lts 2-1 v2
pacman_fixture_package unrelated 1-1 none
for tool in pacman pacman-conf; do cp "$(realpath "$(command -v "$tool")")" "$scratch/fixtures/runtime/$tool"; done
cat >"$scratch/fixtures/native" <<'EOF'
#!/usr/bin/bash
exec /jdk/bin/java -Xmx256m -XX:ActiveProcessorCount=4 -XX:-UsePerfData -Duser.home=/work/home \
  -cp "/classes${LIMINE_JAVA_CLASSPATH:+:$LIMINE_JAVA_CLASSPATH}" org.limine.entry.tool.Main "$@"
EOF
cat >"$scratch/fake-bin/forbidden" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$0 $*" >>/work/forbidden
exit 98
EOF
cat >"$scratch/fixtures/fault-query" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
/usr/bin/bash /fixtures/entry-wrapper "$@" > /work/native-reply
if [[ ${QUERY_FAULT:-} == decoded-* ]]; then
  /usr/bin/jq --arg fault "$QUERY_FAULT" '
    (if $fault | endswith("-nul") then "\u0000" elif $fault | endswith("-tab") then "\t"
     elif $fault | endswith("-del") then "\u007f" else "\n" end) as $bad |
    if $fault | startswith("decoded-config-path-") then
      .context.config_path += $bad
    elif $fault | startswith("decoded-observation-path-") then
      .observed.configuration.path as $path |
      walk(if type == "object" and .path? == $path then .path += $bad else . end) |
      .context.config_path += $bad
    elif $fault | startswith("decoded-resolved-") then
      walk(if type == "object" and has("resolved_path") then .resolved_path += $bad else . end)
    elif $fault | startswith("decoded-link-path-") then
      walk(if type == "object" and has("links") then .links |= map(.path += $bad) else . end)
    elif $fault | startswith("decoded-link-target-") then
      walk(if type == "object" and has("links") then .links |= map(.target += $bad) else . end)
    elif $fault | startswith("decoded-input-") then
      (.inputs[] | select(.status == "absent") | .missing_at) += $bad
    elif $fault | startswith("decoded-entry-") then
      walk(if type == "object" and .path? == "/etc/limine-entry-tool.d/fixture.conf"
        then .resolved_path += $bad else . end)
    elif .operation.kind == "context" then .
    elif $fault | startswith("decoded-destination-") then
      .expected.resources[0] |= (.destination += $bad | .destination_observation.path = .destination | .prospective_uri += $bad)
    elif $fault | startswith("decoded-missing-") then
      .expected.resources[0].source_observation.missing_at += $bad
    elif $fault | startswith("decoded-uri-") then
      .expected.resources[0].prospective_uri += $bad
    elif $fault | startswith("decoded-source-") then
      .expected.resources[0] |= (.source += $bad | .destination = .source |
        .source_observation.path = .source | .destination_observation.path = .destination | .prospective_uri += $bad)
    else error("unknown decoded fault") end
  ' /work/native-reply >/work/native-fault-reply
  # Preserve operand/resource and observation-path bindings. A rejected mutant
  # must exercise decoded-value validation, not an unrelated join mismatch.
  /usr/bin/jq -e 'if .operation.kind == "context" then true else
    all(.expected.resources[]; .source == .source_observation.path and .destination == .destination_observation.path) and
    ([.expected.resources[] | select(.disposition == "copied") | .source] == .operation.sources) and
    all(.expected.resources[] | select(.disposition == "referenced"); .source == .destination) end' \
    /work/native-fault-reply >/dev/null
  exec /usr/bin/cat /work/native-fault-reply
fi
if [[ ${2:-} != context ]]; then
  case ${QUERY_FAULT:-} in
    operation) /usr/bin/jq '.operation.sources += ["/unexpected"]' /work/native-reply ;;
    resource-null) /usr/bin/jq '.expected.resources = [null]' /work/native-reply ;;
    resource-missing) /usr/bin/jq '.expected.resources |= map(select(.role != "initramfs"))' /work/native-reply ;;
    resource-field) /usr/bin/jq '.expected.resources[0].destination = 7' /work/native-reply ;;
    resource-source) /usr/bin/jq '.expected.resources[0].source = "/unexpected"' /work/native-reply ;;
    *) /usr/bin/cat /work/native-reply ;;
  esac
else
  /usr/bin/cat /work/native-reply
fi
case ${QUERY_FAULT:-} in
  stderr-text) printf 'fixture diagnostic\n' >&2 ;;
  stderr-newline) printf '\n' >&2 ;;
  stderr-nul) printf '\000' >&2 ;;
  stdout-nul) printf '\000' ;;
  stdout-encoding) printf '\377' ;;
  exit) exit 41 ;;
esac
if [[ ${2:-} != context && ${QUERY_FAULT:-} == generation ]]; then
  printf 'KERNEL_CMDLINE[default]=root=changed\n' >>/etc/default/limine
fi
EOF
cat >"$scratch/fixtures/fault-build-query" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
/usr/bin/bash /fixtures/build-wrapper "$@" > /work/build-reply
case $QUERY_FAULT in
  native-name-nul) /usr/bin/jq '.kernels[0].publication_steps[0].native_name = "li\u0000nux"' /work/build-reply ;;
  native-name-newline) /usr/bin/jq '.kernels[0].publication_steps[0].native_name = "linux\n"' /work/build-reply ;;
  kernel-source-nul) /usr/bin/jq '.kernels[0].publication_steps[0].kernel_source = "/usr/lib/modules/v1/vmlinuz\u0000"' /work/build-reply ;;
  kernel-source-newline) /usr/bin/jq '.kernels[0].publication_steps[0].kernel_source = "/usr/lib/modules/v1/vmlinuz\n"' /work/build-reply ;;
  suffix-nul) /usr/bin/jq '.kernels[0].publication_steps[0].suffix = "\u0000"' /work/build-reply ;;
  suffix-newline) /usr/bin/jq '.kernels[0].publication_steps[0].suffix = "\n"' /work/build-reply ;;
  *) exit 97 ;;
esac
EOF
chmod 755 "$scratch/fixtures/native" "$scratch/fake-bin/forbidden" "$scratch/fixtures/fault-query"
chmod 755 "$scratch/fixtures/fault-build-query"
for command in tput logger sbctl mount umount flock mkinitcpio; do cp "$scratch/fake-bin/forbidden" "$scratch/fake-bin/$command"; done
common_path=install/arch-linux/limine-entry-tool/usr/lib/limine
wrapper_path=install/arch-linux/limine-entry-tool/usr/bin/limine-entry-tool
build_wrapper=install/arch-linux/limine-mkinitcpio-hook/usr/bin/limine-mkinitcpio
cp "$scratch/patched/$wrapper_path" "$scratch/fixtures/entry-wrapper"
cp "$scratch/patched/$build_wrapper" "$scratch/fixtures/build-wrapper"
cat >"$scratch/fixtures/driver" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
[[ $EUID == 0 && -f /fixtures/entry-wrapper ]] || exit 99
# shellcheck source=/dev/null
source /core/common.sh
# shellcheck source=/dev/null
source /core/outputs.sh
name=$1
mkdir -p /etc/default /etc/limine-entry-tool.d /etc/pacman.d/hooks /var/lib/pacman/local \
  /var/cache/pacman/pkg /work/keyring /work/catalog /work/expectations /work/home /work/runtime /boot
chmod 755 /usr
chmod 700 /work/catalog /work/expectations
cat >/etc/pacman.conf <<'CONFIG'
[options]
Architecture = auto
DBPath = /var/lib/pacman
GPGDir = /work/keyring
LogFile = /work/pacman.log
SigLevel = Never
CONFIG
if [[ $name == empty ]]; then
  /usr/bin/pacman --noconfirm -U /fixtures/packages/unrelated-1-1-any.pkg.tar
else
  /usr/bin/pacman --noconfirm -U /fixtures/packages/linux-1-1-any.pkg.tar /fixtures/packages/linux-lts-2-1-any.pkg.tar
fi
printf '11111111111111111111111111111111\n' >/etc/machine-id
mode=yes
fallback=no
prefix=contract
[[ $name != regular && $name != regular-fallback && $name != missing-payload && $name != extra-initrd && $name != fault-resource-missing && $name != fault-decoded-source-* ]] || mode=no
[[ $name != shell-kernel-* && $name != shell-suffix-* ]] || mode=no
[[ $name != uki-fallback && $name != regular-fallback ]] || fallback=yes
[[ $name != prefix-overlap ]] || prefix=linux
printf 'TARGET_OS_NAME=Contract Linux\nESP_PATH=/boot\nENABLE_VERIFICATION=no\nENABLE_UKI=%s\nMKINITCPIO_FALLBACK=%s\nCUSTOM_UKI_NAME=%s\nKERNEL_CMDLINE[default]=root=fixture\n' \
  "$mode" "$fallback" "$prefix" >/etc/default/limine
printf '/+Contract Linux\n  comment: machine-id=11111111111111111111111111111111\n' >/boot/limine.conf
if [[ $name == extra-initrd || $name == fault-decoded-source-* ]]; then
  printf 'KERNEL_CMDLINE[default]+=initrd=/ucode\n' >>/etc/default/limine
  printf 'fixture microcode\n' >/boot/ucode
elif [[ $name == missing-payload ]]; then
  rm -r /usr/lib/modules/v1
fi
if [[ $name == native-links || $name == fault-decoded-link-* ]]; then
  mv /boot/limine.conf '/boot/actual config'
  ln -s 'actual config' /boot/limine.conf
fi
if [[ $name == fault-decoded-entry-* ]]; then
  printf 'CUSTOM_UKI_NAME=contract\n' >/etc/limine-entry-tool.d/fixture.conf
fi
collect_package_kernel_catalog /work/catalog /etc/pacman.conf >/work/catalog.json
expected=0
capture=/work/expectations
case $name in
  root-mismatch)
    jq '.context.root.inode = "0"' /work/catalog.json >/work/altered.json
    mv /work/altered.json /work/catalog.json
    expected=1
    ;;
  esp-overlap) capture=/boot/capture; mkdir -m 700 "$capture"; expected=1 ;;
  esp-bind-parent) capture=/work/boot/capture; mkdir -m 700 "$capture"; expected=1 ;;
  esp-bind-source) capture=/work/boot/source/capture; mkdir -m 700 "$capture"; expected=1 ;;
  esp-bind-subtree|esp-bind-child) capture=/work/alias; expected=1 ;;
  database-bind-overlap) capture=/work/database/capture; mkdir -m 700 "$capture"; expected=1 ;;
  local-bind-overlap) capture=/work/local/capture; mkdir -m 700 "$capture"; expected=1 ;;
  missing-id) rm /etc/machine-id; expected=1 ;;
  bad-operation|generation-drift|fault-*|shell-*) expected=1 ;;
esac
case $name in
  *bind*|same-filesystem)
    [[ $(stat -c %d "$capture") == "$(stat -c %d /boot)" ]] || exit 1
    [[ $(stat -c %i "$capture") != "$(stat -c %i /boot)" ]] || exit 1
    ;;
esac
cp /boot/limine.conf /work/config.before
rc=0
collect_producer_output_expectations /work/catalog.json "$capture" >/work/expectations.json 2>/work/expectations.err || rc=$?
[[ $rc == "$expected" ]] || {
  printf 'expected %s got %s\n' "$expected" "$rc"
  cat /work/expectations.err
  /usr/bin/limine-entry-tool --describe context || :
  exit 1
}
cmp /work/config.before /boot/limine.conf
[[ ! -e /work/forbidden ]] || exit 1
if [[ $expected != 0 ]]; then
  [[ ! -s /work/expectations.json ]] || exit 1
  case $name in
    esp-overlap|esp-bind-*|database-bind-overlap|local-bind-overlap)
      [[ -z $(find "$capture" -mindepth 1 -print -quit) ]] || exit 1
      grep -Fq 'Expectation capture overlaps' /work/expectations.err || exit 1
      ;;
    fault-decoded-*) grep -Fq 'unsupported or incomplete native description' /work/expectations.err || exit 1 ;;
  esac
  exit 0
fi
[[ ! -s /work/expectations.err ]] || { cat /work/expectations.err; exit 1; }
jq -e '.format == "omasecboot-output-expectations" and .schema == 1
  and .policy_scope == "potential-publications" and .native_context.complete and .build_description.complete' /work/expectations.json >/dev/null
count=2
[[ $fallback != yes ]] || count=4
[[ $name != empty ]] || count=0
jq -e --argjson count "$count" '(.slots | length) == $count' /work/expectations.json >/dev/null
case $name in
  uki)
    jq -e '.slots[0].description.expected.resources[0].destination == "/boot/EFI/Linux/contract_linux.efi"' /work/expectations.json >/dev/null
    ;;
  prefix-overlap)
    jq -e '.slots[0].description.expected.resources[0].destination == "/boot/EFI/Linux/linux.efi"' /work/expectations.json >/dev/null
    ;;
  regular-fallback)
    jq -e '.slots[0].description.expected.resources[-1].destination == .slots[1].description.expected.resources[-1].destination
      and .slots[1].description.expected.kernel_id == "linux-fallback"
      and (.slots[1].description.expected.resources[0].destination | endswith("/initramfs-fallback"))' /work/expectations.json >/dev/null
    ;;
  missing-payload)
    jq -e '.slots[0].description.expected.resources[-1].source_observation.status == "absent"' /work/expectations.json >/dev/null
    ;;
  extra-initrd)
    jq -e '.slots[0].description.expected.resources[0].role == "extra-initrd"
      and .slots[0].description.expected.resources[0].disposition == "referenced"' /work/expectations.json >/dev/null
    ;;
esac
EOF
for script in native fault-query fault-build-query driver; do shellcheck "$scratch/fixtures/$script"; done
sandbox=(bwrap --unshare-all --die-with-parent --new-session --uid 0 --gid 0 --cap-add CAP_SYS_CHROOT --clearenv
  --ro-bind /usr/lib /usr/lib --tmpfs /usr/lib/modules --tmpfs /usr/lib/limine --dir /usr/bin
  --symlink usr/bin /bin --symlink usr/lib /lib --symlink lib /usr/lib64 --symlink usr/lib64 /lib64
  --proc /proc --dev /dev --tmpfs /tmp --dir /sys/firmware/efi --dir /etc --dir /var --dir /run
  --dir /usr/share/libalpm/hooks --dir /usr/share/limine-entry-tool.d
  --ro-bind "$java_home" /jdk --ro-bind "$scratch/fixtures" /fixtures --ro-bind "$scratch/fake-bin" /fake-bin
  "${LIMINE_JAVA_MOUNTS[@]}" --setenv LIMINE_JAVA_CLASSPATH "$LIMINE_JAVA_CLASSPATH"
  --setenv PATH /fake-bin:/usr/bin --setenv LC_ALL C.UTF-8 --setenv TERM dumb
  --setenv HOME /work/home --setenv XDG_CONFIG_HOME /work/home/config --setenv XDG_DATA_HOME /work/home/data
  --setenv XDG_CACHE_HOME /work/home/cache --setenv XDG_STATE_HOME /work/home/state
  --setenv XDG_RUNTIME_DIR /work/runtime --setenv HISTFILE /dev/null --chdir /work)
for tool in bash env cat cp mv mkdir rm chmod ln cmp grep stat readlink realpath jq iconv find findmnt sort xargs awk base64 sha256sum; do
  sandbox+=(--ro-bind "$(realpath "$(command -v "$tool")")" "/usr/bin/$tool")
done
sources=()
for path in "${LIMINE_PATCHED_JAVA[@]}"; do sources+=("/source/$path"); done
"${sandbox[@]}" --ro-bind "$scratch/patched" /source --bind "$scratch/compiler" /work \
  /jdk/bin/javac -J-Xmx1g -J-XX:ActiveProcessorCount=4 -J-Duser.home=/work/home \
  -cp "${LIMINE_JAVA_CLASSPATH:-.}" -d /work/classes "${sources[@]}" >"$scratch/compiler.log" 2>&1 \
  || { cat "$scratch/compiler.log"; die 'native query compilation failed'; }
sandbox+=(--ro-bind "$scratch/compiler/classes" /classes
  --ro-bind "$repo/lib/common.sh" /core/common.sh --ro-bind "$repo/lib/outputs.sh" /core/outputs.sh
  --ro-bind "$scratch/patched/$wrapper_path" /usr/bin/limine-entry-tool
  --ro-bind "$scratch/patched/$build_wrapper" /usr/bin/limine-mkinitcpio
  --ro-bind "$scratch/patched/$common_path/limine-config-functions" /usr/lib/limine/limine-config-functions
  --ro-bind "$scratch/patched/$common_path/limine-build-settings" /usr/lib/limine/limine-build-settings
  --ro-bind "$scratch/fixtures/native" /usr/lib/limine/limine-entry-tool)
for tool in pacman pacman-conf; do sandbox+=(--ro-bind "$scratch/fixtures/runtime/$tool" "/usr/bin/$tool"); done
count=0
for name in uki uki-fallback regular regular-fallback prefix-overlap missing-payload extra-initrd empty \
  root-mismatch esp-overlap esp-bind-parent esp-bind-source esp-bind-source-disjoint esp-bind-subtree esp-bind-child \
  database-bind-overlap local-bind-overlap same-filesystem native-links missing-id bad-operation generation-drift fault-resource-null fault-resource-missing \
  fault-resource-field fault-resource-source fault-stderr-text fault-stderr-newline fault-stderr-nul \
  fault-stdout-nul fault-stdout-encoding fault-exit shell-native-name-nul shell-native-name-newline \
  shell-kernel-source-nul shell-kernel-source-newline shell-suffix-nul shell-suffix-newline \
  fault-decoded-destination-nul fault-decoded-destination-newline fault-decoded-destination-tab fault-decoded-destination-del \
  fault-decoded-source-nul fault-decoded-uri-nul fault-decoded-uri-newline fault-decoded-missing-nul \
  fault-decoded-config-path-nul fault-decoded-observation-path-nul fault-decoded-resolved-nul \
  fault-decoded-link-path-nul fault-decoded-link-target-nul fault-decoded-input-nul fault-decoded-entry-nul; do
  mkdir -p "$scratch/$name/boot"
  extra=()
  case $name in
    esp-bind-source|esp-bind-source-disjoint)
      # A source subdirectory is mounted as the ESP; capture reaches its original
      # ancestry. The inverse cases mount the source/capture ancestor elsewhere.
      mkdir -p "$scratch/$name/boot/source"
      extra+=(--bind "$scratch/$name/boot/source" /boot)
      ;;
    esp-bind-subtree)
      mkdir -m 700 "$scratch/$name/boot/capture"
      extra+=(--bind "$scratch/$name/boot/capture" /work/alias)
      ;;
    esp-bind-child)
      mkdir -m 700 "$scratch/$name/alias"
      extra+=(--bind "$scratch/$name/alias" /boot/alias)
      ;;
    database-bind-overlap)
      mkdir "$scratch/$name/database"
      extra+=(--bind "$scratch/$name/database" /var/lib/pacman)
      ;;
    local-bind-overlap)
      mkdir "$scratch/$name/local"
      extra+=(--bind "$scratch/$name/local" /var/lib/pacman/local)
      ;;
  esac
  if [[ $name == bad-operation || $name == generation-drift ]]; then
    fault=operation
    [[ $name != generation-drift ]] || fault=generation
    extra=(--ro-bind "$scratch/fixtures/fault-query" /usr/bin/limine-entry-tool --setenv QUERY_FAULT "$fault")
  fi
  if [[ $name == fault-* ]]; then
    extra=(--ro-bind "$scratch/fixtures/fault-query" /usr/bin/limine-entry-tool --setenv QUERY_FAULT "${name#fault-}")
  fi
  if [[ $name == shell-* ]]; then
    extra=(--ro-bind "$scratch/fixtures/fault-build-query" /usr/bin/limine-mkinitcpio --setenv QUERY_FAULT "${name#shell-}")
  fi
  if ! "${sandbox[@]}" --bind "$scratch/$name" /work --bind "$scratch/$name/boot" /boot "${extra[@]}" \
    /usr/bin/bash /fixtures/driver "$name" >"$scratch/$name/transcript" 2>&1; then
    cat "$scratch/$name/transcript"
    die "output expectation case: $name"
  fi
  printf 'PASS: expectations/%s\n' "$name"
  count=$((count + 1))
done
printf 'Passed %s joined core/shell/native expectation contracts.\n' "$count"
