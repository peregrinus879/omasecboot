#!/usr/bin/env bash
# Real read-only shell settings and producer argv contracts, fixture-only.
set -euo pipefail
umask 077
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && -d $1 ]] || die 'usage: limine-build-settings.sh PINNED_SOURCE_ROOT'
for tool in bwrap jq patch sha256sum shellcheck realpath mktemp cp cmp diff mkdir rm chmod ln \
  bash env base64 iconv find sort xargs awk tail tr uname flock mv; do
  command -v "$tool" >/dev/null || die "required command: $tool"
done
repo=$(realpath -- "${BASH_SOURCE[0]%/*}/../..")
source_root=$(realpath -- "$1")
parent=${TMPDIR:-/tmp}
[[ -d $parent && ! -L $parent ]] || die 'TMPDIR must be a real directory'
scratch=$(mktemp -d "$parent/limine-build-settings.XXXXXX")
finish() {
  local rc=$?
  if [[ ${LIMINE_BUILD_SETTINGS_KEEP:-0} == 1 ]]; then
    printf 'Retained build-settings evidence: %s (status %s)\n' "$scratch" "$rc"
  else
    rm -rf -- "$scratch"
  fi
}
trap finish EXIT
# shellcheck source=tests/integration/lib/limine-sources.sh
source "$repo/tests/integration/lib/limine-sources.sh"
limine_prepare_sources "$source_root" "$scratch" "$repo/integrations/limine-entry-tool/source.json" "$repo/integrations/limine-entry-tool"
common=install/arch-linux/limine-entry-tool/usr/lib/limine
wrapper=install/arch-linux/limine-mkinitcpio-hook/usr/bin/limine-mkinitcpio
producer=install/arch-linux/limine-mkinitcpio-hook/usr/share/libalpm/scripts/limine-mkinitcpio-install
for file in limine-config-functions limine-build-settings; do
  bash -n "$scratch/patched/$common/$file"
  shellcheck --shell=bash "$scratch/patched/$common/$file"
done
mkdir "$scratch/bin"
cat >"$scratch/bin/forbidden" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$0 $*" >>/work/forbidden
exit 99
EOF
cat >"$scratch/bin/producer-helper" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
case ${0##*/} in
  tput) exit 1 ;;
  mountpoint) [[ $* == '-q /boot' ]] ;;
  findmnt)
    if [[ $* == '-n -o FSTYPE /' ]]; then
      printf 'btrfs\n'
      exit "${PROBE_RC:-0}"
    fi
    printf 'vfat\n'
    ;;
  snapper) exit 99 ;;
  sbctl) printf '{"installed": true}\n'; exit "${PROBE_RC:-0}" ;;
  pacman)
    [[ ${1:-} == -Qqo ]] || exit 1
    printf 'linux\n'
    ;;
  mkinitcpio)
    count=0
    [[ ! -f /work/count ]] || read -r count </work/count
    count=$((count + 1))
    printf '%s\n' "$count" >/work/count
    printf '%s\0' "$@" >"/work/args-$count"
    # Record literal argv before controlled output creation. This does not
    # model mkinitcpio's interpretation of overrides or claim real build proof.
    while (( $# )); do
      if [[ $1 == --uki || $1 == --generate ]]; then
        printf fixture >"$2"
        exit 0
      fi
      shift
    done
    exit 98
    ;;
  limine-entry-tool)
    case $1 in
      --get-cmdline) printf 'root=fixture\n' ;;
      --add-uki | --add-kernel) printf '%s\0' "$@" >>/work/publications ;;
      *) exit 97 ;;
    esac
    ;;
  *) exit 96 ;;
esac
EOF
cat >"$scratch/bin/find-fault" <<'EOF'
#!/usr/bin/bash
if [[ $1 == -H && $2 == /etc/limine-entry-tool.d && ${FIND_FAULT:-} == *enumeration ]]; then
  [[ $FIND_FAULT != partial-enumeration ]] || printf '10-first.conf\0'
  exit 43
fi
if [[ $1 == -L && $2 == /etc/default/limine && ${FIND_FAULT:-} == metadata ]]; then exit 44; fi
exec /usr/bin/find-real "$@"
EOF
cat >"$scratch/bin/base64-generation" <<'EOF'
#!/usr/bin/bash
if [[ ${3:-} == /etc/default/limine ]]; then
  /usr/bin/base64-real "$@" || exit
  printf 'ENABLE_UKI=no\nESP_PATH=/boot\n' >/etc/default/limine
else
  exec /usr/bin/base64-real "$@"
fi
EOF
chmod 755 "$scratch/bin/forbidden" "$scratch/bin/producer-helper" "$scratch/bin/find-fault" "$scratch/bin/base64-generation"
shellcheck "$scratch/bin/forbidden" "$scratch/bin/producer-helper" "$scratch/bin/find-fault" "$scratch/bin/base64-generation"
mkdir "$scratch/mutation-bin"
for cmd in tput mountpoint findmnt snapper sbctl pacman limine-entry-tool; do
  cp "$scratch/bin/producer-helper" "$scratch/mutation-bin/$cmd"
done
for cmd in tput mountpoint findmnt snapper sbctl pacman mkinitcpio limine-entry-tool \
  sudo doas pkexec run0 logger uuidgen chmod chown limine-install limine-enroll-config; do
  ln -s forbidden "$scratch/bin/$cmd"
done

sandbox=(bwrap --unshare-all --die-with-parent --new-session --clearenv
  --ro-bind /usr/lib /usr/lib --tmpfs /usr/lib/modules --tmpfs /usr/lib/limine
  --dir /usr/bin --symlink usr/bin /bin --symlink usr/lib /lib
  --proc /proc --dev /dev --tmpfs /tmp --dir /sys --dir /run/lock --dir /var/lib/limine
  --dir /usr/share/libalpm/scripts --ro-bind "$scratch/bin" /fake-bin
  --setenv PATH /fake-bin:/usr/bin --setenv LC_ALL C --setenv TERM dumb
  --setenv HOME /work/home --setenv XDG_CONFIG_HOME /work/home/config
  --setenv XDG_DATA_HOME /work/home/data --setenv XDG_CACHE_HOME /work/home/cache
  --setenv XDG_STATE_HOME /work/home/state --setenv XDG_RUNTIME_DIR /work/runtime
  --setenv HISTFILE /dev/null --chdir /work)
if [[ -d /usr/lib64 ]]; then
  [[ $(realpath /usr/lib64) == "$(realpath /usr/lib)" ]] || die 'unsupported separate lib64 runtime'
  sandbox+=(--symlink lib /usr/lib64 --symlink usr/lib64 /lib64)
fi
for cmd in bash base64 iconv sha256sum find; do
  sandbox+=(--ro-bind "$(realpath -- "$(command -v "$cmd")")" "/usr/bin/$cmd")
done

count=0
new_case() {
  id=$1
  work=$scratch/$id
  mkdir -p "$work/domain"/{etc/default,etc/limine-entry-tool.d,etc/boot/hooks/pre.d,etc/boot/hooks/post.d,usr-conf,boot,home,runtime,modules/v1,run,var,tmp} "$work/results"
  printf '11111111111111111111111111111111\n' >"$work/domain/etc/machine-id"
  printf 'ENABLE_UKI=yes\nESP_PATH=/boot\n' >"$work/domain/etc/default/limine"
  : >"$work/domain/modules/v1/modules.builtin"
  : >"$work/domain/modules/v1/vmlinuz"
  ln -s /fake-bin/forbidden "$work/domain/etc/boot/hooks/pre.d/sentinel"
  ln -s /fake-bin/forbidden "$work/domain/etc/boot/hooks/post.d/sentinel"
  extra_env=()
  observation_tools=()
  efi=(--dir /sys/firmware/efi)
}
inventory() {
  (cd "$work/domain" && find . -printf '%P %y %m %U %G %D %i %l\n' | sort && find . -type f -print0 | sort -z | xargs -0 -r sha256sum) >"$1"
}
query() {
  local expected=$1 access=$2 rc=0
  shift 2
  local binding=--bind
  [[ $access != readonly ]] || binding=--ro-bind
  chmod -R a+rX "$work/domain"
  chmod -R a+w "$work/domain"
  case $id in
    unreadable) chmod 000 "$work/domain/etc/default/limine" ;;
    unsearchable) chmod 000 "$work/domain/etc/limine-entry-tool.d" ;;
    opaque-link) chmod 000 "$work/domain/etc/locked" ;;
  esac
  # Permission-denied cases cannot be hashed through their final permissions;
  # inventory is done by the fixture owner, before/after only ordinary queries.
  if [[ $id != unreadable && $id != unsearchable && $id != opaque-link ]]; then inventory "$work/results/before"; fi
  "${sandbox[@]}" --uid 1000 --gid 1000 "$binding" "$work/domain" /work \
    "$binding" "$work/domain/etc" /etc "$binding" "$work/domain/usr-conf" /usr/share/limine-entry-tool.d \
    "$binding" "$work/domain/boot" /boot "$binding" "$work/domain/modules" /usr/lib/modules \
    "$binding" "$work/domain/run" /run "$binding" "$work/domain/var" /var "$binding" "$work/domain/tmp" /tmp \
    --ro-bind "$scratch/bin/forbidden" /usr/lib/limine/auth-helper \
    --ro-bind "$scratch/patched/$common/limine-build-settings" /usr/lib/limine/limine-build-settings \
    --ro-bind "$scratch/patched/$common/limine-config-functions" /usr/lib/limine/limine-config-functions \
    --ro-bind "$scratch/patched/$wrapper" /usr/bin/limine-mkinitcpio \
    "${efi[@]}" "${extra_env[@]}" "${observation_tools[@]}" /usr/bin/bash /usr/bin/limine-mkinitcpio "$@" \
    >"$work/results/stdout" 2>"$work/results/stderr" || rc=$?
  [[ $rc == "$expected" ]] || die "$id: expected $expected, got $rc ($work/results)"
  jq -es --argjson rc "$rc" 'length == 1 and .[0].format == "limine-build-description" and .[0].schema == 1
    and .[0].scope == "shell-settings" and (.[0].complete | type == "boolean")
    and .[0].complete == ($rc == 0) and (.[0].errors | type == "array")' "$work/results/stdout" >/dev/null \
    || die "$id: invalid JSON/result contract"
  [[ ! -s $work/results/stderr && ! -e $work/domain/forbidden ]] || die "$id: query invoked a helper or emitted diagnostics"
  if [[ $id != unreadable && $id != unsearchable && $id != opaque-link ]]; then
    inventory "$work/results/after"
    if [[ $id == read-generation ]]; then
      # The injected reader deliberately changes just this input after reading.
      # Every other domain identity, mode, path and byte must remain unchanged.
      local changed_hash
      changed_hash=$(sha256sum "$work/domain/etc/default/limine")
      awk -v hash="${changed_hash%% *}" '$2 == "./etc/default/limine" {printf "%s  %s\n", hash, $2; next} {print}' \
        "$work/results/before" >"$work/results/expected-after"
      cmp "$work/results/expected-after" "$work/results/after" || die "$id: unexpected domain change"
    else
      cmp "$work/results/before" "$work/results/after" || die "$id: query changed a fixture domain"
    fi
  fi
  count=$((count + 1))
}
assert_query() { jq -e "$1" "$work/results/stdout" >/dev/null || die "$id: $1"; }

run_producer() {
  local revision=$1 probe_rc=$2 directory=$work/$1 rc=0 cmd
  local -a tools=() helpers=()
  cp -a "$work/domain" "$directory"
  rm "$directory/etc/boot/hooks/pre.d/sentinel" "$directory/etc/boot/hooks/post.d/sentinel"
  for cmd in mktemp rm mkdir flock awk tail tr uname; do
    tools+=(--ro-bind "$(realpath -- "$(command -v "$cmd")")" "/usr/bin/$cmd")
  done
  if [[ $revision == patched ]]; then
    helpers=(--ro-bind "$scratch/patched/$common/limine-config-functions" /usr/lib/limine/limine-config-functions
      --ro-bind "$scratch/patched/$common/limine-build-settings" /usr/lib/limine/limine-build-settings)
  fi
  printf 'rebuild\n' | "${sandbox[@]}" --uid 0 --gid 0 --bind "$directory" /work \
    --ro-bind "$directory/etc" /etc --ro-bind "$directory/usr-conf" /usr/share/limine-entry-tool.d \
    --bind "$directory/boot" /boot --ro-bind "$directory/modules" /usr/lib/modules \
    --ro-bind "$scratch/mutation-bin" /fake-bin --setenv PROBE_RC "$probe_rc" \
    --ro-bind "$scratch/bin/producer-helper" /usr/bin/mkinitcpio \
    --ro-bind "$scratch/$revision/$common/limine-common-functions" /usr/lib/limine/limine-common-functions \
    --ro-bind "$scratch/$revision/$producer" /usr/share/libalpm/scripts/limine-mkinitcpio-install \
    "${helpers[@]}" "${tools[@]}" "${efi[@]}" "${extra_env[@]}" \
    /usr/bin/bash /usr/share/libalpm/scripts/limine-mkinitcpio-install \
    >"$work/results/$revision.stdout" 2>"$work/results/$revision.stderr" || rc=$?
  [[ $rc == 0 ]] || die "$id/$revision producer returned $rc"
  [[ -f $directory/count ]] || die "$id/$revision did not run the builder"
  count=$((count + 1))
}
producer_parity() {
  local probe_rc=${1:-0} mode fallback expected_count number revision arg
  local -a actual=() baseline=() expected=() options=()
  mode=$(jq -er '.mode' "$work/results/stdout")
  fallback=$(jq -r '.kernels[0].fallback' "$work/results/stdout")
  expected_count=1
  [[ $fallback != true ]] || expected_count=2
  mapfile -d '' -t options < <(jq -jr '.extra_uki_argv[] | ., "\u0000"' "$work/results/stdout")
  for revision in original patched; do run_producer "$revision" "$probe_rc"; done
  cmp "$work/original/count" "$work/patched/count" || die "$id: changed builder count"
  [[ $(<"$work/patched/count") == "$expected_count" ]] || die "$id: wrong normal/fallback count"
  for ((number=1; number<=expected_count; number++)); do
    baseline=()
    for revision in original patched; do
      mapfile -d '' -t actual <"$work/$revision/args-$number"
      for arg in "${!actual[@]}"; do
        [[ ${actual[arg]} != /tmp/limine-mkinitcpio.*/* ]] || actual[arg]="<tmp>/${actual[arg]##*/}"
      done
      if [[ $revision == original ]]; then
        baseline=("${actual[@]}")
      else
        [[ ${#actual[@]} == "${#baseline[@]}" ]] || die "$id: changed argv count"
        for arg in "${!actual[@]}"; do [[ ${actual[arg]} == "${baseline[arg]}" ]] || die "$id: changed argv[$arg]"; done
      fi
    done
    expected=(--kernel v1 --no-cmdline)
    if [[ $mode == uki ]]; then
      if (( number == 1 )); then expected+=(--uki '<tmp>/linux.efi'); else expected+=(--uki '<tmp>/linux-fallback.efi'); fi
    else
      if (( number == 1 )); then expected+=(--generate '<tmp>/initramfs'); else expected+=(--generate '<tmp>/initramfs-fallback'); fi
    fi
    (( number != 2 )) || expected+=(-S autodetect)
    [[ $mode != uki ]] || expected+=("${options[@]}")
    [[ ${#actual[@]} == "${#expected[@]}" ]] || die "$id: description argv count differs"
    for arg in "${!actual[@]}"; do [[ ${actual[arg]} == "${expected[arg]}" ]] || die "$id: description argv[$arg] differs"; done
  done
}

for access in writable readonly; do
  new_case "absent-$access"
  rm -r "$work/domain/etc/default" "$work/domain/modules"
  mkdir "$work/domain/modules"
  query 0 "$access" --describe-build linux missing linux missing
  assert_query '.mode == "regular" and (.kernels | length == 2) and .kernels[0].version == "missing" and (.settings.ENABLE_UKI.set | not)'
done
new_case invalid-empty; query 2 readonly --describe-build
new_case invalid-odd; query 2 readonly --describe-build linux
new_case invalid-path; query 2 readonly --describe-build linux ../v1
new_case invalid-control; query 2 readonly --describe-build $'linux\n' v1
new_case invalid-encoding; query 2 readonly --describe-build $'linux\xff' v1

new_case layers
printf 'ENABLE_UKI=no\nMKINITCPIO_FALLBACK=no\n' >"$work/domain/usr-conf/10-base.conf"
printf 'ENABLE_UKI=yes\nMKINITCPIO_FALLBACK=yes\n' >"$work/domain/usr-conf/20-last.conf"
printf 'ENABLE_UKI=no\nMKINITCPIO_FALLBACK=no\n' >"$work/domain/etc/limine-entry-tool.conf"
printf 'ENABLE_UKI=no\nMKINITCPIO_FALLBACK=yes\n' >"$work/domain/etc/limine-entry-tool.d/10-base.conf"
printf 'ENABLE_UKI=yes\nMKINITCPIO_FALLBACK=linuxlts\nMKINITCPIO_UKI_OPTIONS="--compress zstd"\n' >"$work/domain/etc/limine-entry-tool.d/90-last.conf"
printf 'ESP_PATH=/boot\n' >"$work/domain/etc/default/limine"
query 0 readonly --describe-build 'linux lts' v1 linux v2
assert_query '.mode == "uki" and .kernels[0].name == "linuxlts" and .kernels[0].fallback and (.kernels[1].fallback | not) and .extra_uki_argv == ["--compress","zstd"] and .settings.ENABLE_UKI.source == "/etc/limine-entry-tool.d/90-last.conf"'
expected_hash=$(sha256sum "$work/domain/etc/limine-entry-tool.d/90-last.conf")
assert_query "any(.inputs[]; .path == \"/etc/limine-entry-tool.d/90-last.conf\" and .sha256 == \"${expected_hash%% *}\")"
printf 'ENABLE_UKI=no\n' >>"$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query '.mode == "regular" and .settings.ENABLE_UKI.source == "/etc/default/limine"'

new_case literal
# shellcheck disable=SC2016 # Configuration and expected JSON must stay literal.
printf '%s\n' 'ENABLE_UKI="yes" ' 'MKINITCPIO_FALLBACK="yes"' 'MKINITCPIO_UKI_OPTIONS=--compress "two words" $(touch /work/pwned)' 'MKINITCPIO_UKI_OPTIONS+=ignored' 'KERNEL_CMDLINE[default]+=ignored' >"$work/domain/etc/default/limine"
query 0 writable --describe-build linux v1
# shellcheck disable=SC2016
assert_query '.mode == "regular" and .settings.ENABLE_UKI.value == "yes\" " and .kernels[0].fallback and .extra_uki_argv == ["--compress","\"two","words\"","$(touch","/work/pwned)"]'

new_case inherited
printf 'ESP_PATH=/boot\n' >"$work/domain/etc/default/limine"
extra_env=(--setenv ENABLE_UKI yes --setenv MKINITCPIO_FALLBACK linux --setenv MKINITCPIO_UKI_OPTIONS $'--compress zstd\n--kernel other')
query 0 readonly --describe-build linux v1
assert_query '.mode == "uki" and .kernels[0].fallback and .settings.ENABLE_UKI.source == "environment" and .extra_uki_argv == ["--compress","zstd"]'

new_case ifs
printf '%s\n' 'ENABLE_UKI=yes' 'IFS=,' 'MKINITCPIO_UKI_OPTIONS=--compress,zstd,,--kernel,other' >"$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query '.extra_uki_argv == ["--compress","zstd","","--kernel","other"] and .builder_option_effects == "unresolved"'

new_case unicode
printf '%s\n' 'ENABLE_UKI=yes' 'MKINITCPIO_UKI_OPTIONS=--splash /splash/écran.bmp' >"$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query '.extra_uki_argv[1] == "/splash/écran.bmp"'

new_case read-generation
expected_hash=$(sha256sum "$work/domain/etc/default/limine")
observation_tools=(--ro-bind "$(realpath "$(command -v base64)")" /usr/bin/base64-real
  --ro-bind "$scratch/bin/base64-generation" /usr/bin/base64)
query 0 writable --describe-build linux v1
assert_query ".mode == \"uki\" and any(.inputs[]; .path == \"/etc/default/limine\" and .sha256 == \"${expected_hash%% *}\")"
[[ $(<"$work/domain/etc/default/limine") == $'ENABLE_UKI=no\nESP_PATH=/boot' ]] || die 'generation fault did not run'

new_case split-encoding
printf '%s\n' 'ENABLE_UKI=yes' 'IFS=é' 'MKINITCPIO_UKI_OPTIONS=--splash /æ.bmp' >"$work/domain/etc/default/limine"
query 1 readonly --describe-build linux v1
assert_query '.extra_uki_argv == null and any(.errors[]; . == "option-token-encoding")'

new_case large-readonly
printf 'ENABLE_UKI=yes\nMKINITCPIO_UKI_OPTIONS=' >"$work/domain/etc/default/limine"
printf '%020000d\n' 0 >>"$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query '(.extra_uki_argv[0] | length) == 20000'

new_case non-uefi; efi=(); query 0 readonly --describe-build linux v1
assert_query '(.uefi | not) and .mode == "regular"'
new_case symlink
mv "$work/domain/etc/default/limine" "$work/domain/etc/actual.conf"
ln -s ../actual.conf "$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query '.mode == "uki" and any(.inputs[]; .path == "/etc/default/limine" and .state == "read")'
new_case dangling
rm "$work/domain/etc/default/limine"; ln -s missing "$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query 'any(.inputs[]; .path == "/etc/default/limine" and .state == "skipped-nonregular")'
new_case null-link
rm "$work/domain/etc/default/limine"; ln -s /dev/null "$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query 'any(.inputs[]; .path == "/etc/default/limine" and .state == "skipped-nonregular")'
new_case directory-link
rm "$work/domain/etc/default/limine"; ln -s /boot "$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
assert_query 'any(.inputs[]; .path == "/etc/default/limine" and .state == "skipped-nonregular")'
new_case unreadable; query 1 readonly --describe-build linux v1
chmod 644 "$work/domain/etc/default/limine"
new_case unsearchable; query 1 readonly --describe-build linux v1
chmod 755 "$work/domain/etc/limine-entry-tool.d"
new_case opaque-link
mkdir "$work/domain/etc/locked"
mv "$work/domain/etc/default/limine" "$work/domain/etc/locked/limine"
ln -s ../locked/limine "$work/domain/etc/default/limine"
query 1 readonly --describe-build linux v1
chmod 755 "$work/domain/etc/locked"
new_case looping-link
rm "$work/domain/etc/default/limine"
ln -s limine "$work/domain/etc/default/limine"
query 1 readonly --describe-build linux v1
new_case invalid-config-encoding
printf '\xff\n' >>"$work/domain/etc/default/limine"
query 1 readonly --describe-build linux v1
for assignment in 'etc_d_dir=/etc/redirected' 'file=/etc/redirected' '_lb_origin=/wrong' 'PATH=/work' 'LC_ALL=C.UTF-8' 'GLOBIGNORE=*.conf' 'TMOUT=1' 'FUNCNEST=1'; do
  new_case "control-$count"
  printf '%s\n' "$assignment" >>"$work/domain/etc/default/limine"
  query 1 readonly --describe-build linux v1
  assert_query 'any(.errors[]; startswith("configuration-shell-effect:"))'
done
for limit in 1 ' 1 ' ' +1 ' $'\t+001\t'; do
  new_case "inherited-funcnest-$count"
  # Establish the real Bash grammar/limit effect, not merely our own predicate.
  probe_rc=0
  "${sandbox[@]}" --uid 1000 --gid 1000 --dir /work --setenv FUNCNEST "$limit" \
    /usr/bin/bash -c 'outer() { inner; }; inner() { :; }; outer' \
    >"$work/results/probe.stdout" 2>"$work/results/probe.stderr" || probe_rc=$?
  [[ $probe_rc != 0 && ! -s $work/results/probe.stdout ]] || die 'FUNCNEST fixture did not constrain actual Bash'
  extra_env=(--setenv FUNCNEST "$limit")
  query 1 readonly --describe-build linux v1
  assert_query '.errors == ["environment-FUNCNEST"]'
done
new_case skipped-glob
printf 'ENABLE_UKI=no\n' >"$work/domain/etc/limine-entry-tool.d/10-first.conf"
extra_env=(--setenv SHELLOPTS noglob)
query 1 readonly --describe-build linux v1
assert_query 'any(.errors[]; . == "configuration-enumeration-incomplete")'
for fault in enumeration partial-enumeration metadata; do
  new_case "fault-$fault"
  printf 'ENABLE_UKI=no\n' >"$work/domain/etc/limine-entry-tool.d/10-first.conf"
  printf 'ENABLE_UKI=yes\n' >"$work/domain/etc/limine-entry-tool.d/90-last.conf"
  extra_env=(--setenv FIND_FAULT "$fault")
  observation_tools=(--ro-bind "$(realpath "$(command -v find)")" /usr/bin/find-real
    --ro-bind "$scratch/bin/find-fault" /usr/bin/find)
  query 1 readonly --describe-build linux v1
done

for inherited in no yes; do
  new_case "globsort-$inherited"
  printf 'ENABLE_UKI=no\nMKINITCPIO_FALLBACK=no\n' >"$work/domain/etc/limine-entry-tool.d/10-first.conf"
  printf 'ENABLE_UKI=yes\nMKINITCPIO_FALLBACK=yes\n' >"$work/domain/etc/limine-entry-tool.d/90-last.conf"
  printf 'ESP_PATH=/boot\n' >"$work/domain/etc/default/limine"
  if [[ $inherited == yes ]]; then
    extra_env=(--setenv GLOBSORT -name)
    query 0 readonly --describe-build linux v1
    producer_parity
    # A fresh Bash may initialize special variables differently from an export
    # during configuration. Actual original/composed argv is the oracle here.
  else
    printf 'GLOBSORT=-name\n' >"$work/domain/etc/limine-entry-tool.conf"
    query 1 readonly --describe-build linux v1
    for revision in original patched; do
      run_producer "$revision" 0
      [[ $(<"$work/$revision/count") == 1 ]] || die "$id/$revision: GLOBSORT order changed"
      mapfile -d '' -t ordered <"$work/$revision/args-1"
      [[ ${ordered[3]} == --generate ]] || die "$id/$revision: descending settings were not used"
    done
  fi
done

# Actual original/composed producer argv must match the query's mode, fallback,
# first-line tokenization and append order, with controlled external commands.
for mode in yes no; do
  for fallback in no yes linux other; do
    new_case "parity-$mode-$fallback"
    printf 'ENABLE_UKI=%s\nMKINITCPIO_FALLBACK=%s\nESP_PATH=/boot\nMKINITCPIO_UKI_OPTIONS=--compress "two words" --kernel other\n' \
      "$mode" "$fallback" >"$work/domain/etc/default/limine"
    query 0 readonly --describe-build linux v1
    producer_parity
  done
done
new_case parity-ifs
printf '%s\n' 'ENABLE_UKI=yes' 'ESP_PATH=/boot' 'IFS=,' 'MKINITCPIO_UKI_OPTIONS=--compress,zstd,,--kernel,other' >"$work/domain/etc/default/limine"
query 0 readonly --describe-build linux v1
producer_parity

new_case parity-non-uefi; efi=()
query 0 readonly --describe-build linux v1
producer_parity

new_case predicate-failed-exit
query 0 readonly --describe-build linux v1
producer_parity 41
assert_query '.cmdline_policy.observation == "not-performed" and (.cmdline_policy.probe_results_validated | not)'

# Preserve unusual dynamically scoped runtime traversal, but never certify a
# query that did not apply that control assignment to its own environment.
new_case runtime-redirect
mkdir "$work/domain/etc/redirected"
printf 'etc_d_dir=/etc/redirected\n' >"$work/domain/etc/limine-entry-tool.conf"
printf 'ENABLE_UKI=yes\nMKINITCPIO_FALLBACK=yes\n' >"$work/domain/etc/redirected/defaults.conf"
printf 'ESP_PATH=/boot\n' >"$work/domain/etc/default/limine"
query 1 readonly --describe-build linux v1
for revision in original patched; do
  run_producer "$revision" 0
  [[ $(<"$work/$revision/count") == 2 ]] || die "$id/$revision: loader redirection was not preserved"
  mapfile -d '' -t redirected <"$work/$revision/args-1"
  [[ ${redirected[3]} == --uki ]] || die "$id/$revision: redirected settings were not used"
done

printf 'PASS: %s real shell build-settings/query/producer contracts\n' "$count"
