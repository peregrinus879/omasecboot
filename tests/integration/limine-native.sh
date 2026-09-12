#!/usr/bin/env bash
# Actual Java publication contracts against bound original and patched sources.
# Usage: limine-native.sh SOURCE_ROOT JAVA_HOME
# Native fixtures construct Config directly; they do not waive production FAT
# validation or establish packaged Main/firmware/boot acceptance.
set -euo pipefail
umask 077

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 && -d $1 && -x $2/bin/java && -x $2/bin/javac ]] \
  || die 'usage: limine-native.sh PINNED_SOURCE_ROOT JDK25_HOME'
for tool in bwrap jq patch sha256sum bash env realpath mktemp mkdir cp rm chmod \
  cmp grep b2sum sync flock cat shellcheck; do
  command -v "$tool" >/dev/null || die "required command: $tool"
done
source_root=$(realpath -- "$1")
java_home=$(realpath -- "$2")
repo=$(realpath -- "${BASH_SOURCE[0]%/*}/../..")
integration=$repo/integrations/limine-entry-tool
metadata=$integration/source.json
parent=${TMPDIR:-/tmp}
[[ -d $parent && ! -L $parent ]] || die 'TMPDIR must be an existing real directory'
scratch=$(mktemp -d "$parent/limine-native.XXXXXX")
[[ -O $scratch && ! -L $scratch ]] || die 'scratch ownership check failed'
chmod 700 "$scratch"
finish() {
  local rc=$?
  if [[ ${LIMINE_NATIVE_KEEP:-0} == 1 ]]; then
    printf 'Retained Java contract evidence: %s (status %s)\n' "$scratch" "$rc"
  else
    rm -rf -- "$scratch"
  fi
}
trap finish EXIT
# shellcheck source=tests/integration/lib/limine-sources.sh
source "$repo/tests/integration/lib/limine-sources.sh"
limine_prepare_sources "$source_root" "$scratch" "$metadata" "$integration"

mkdir -p "$scratch/fixtures" "$scratch/fake-bin" "$scratch/compiler"
cp "$repo/tests/integration/fixtures/NativeContract.java" \
  "$repo/tests/integration/fixtures/NativeScannerContract.java" "$scratch/fixtures/"
cat >"$scratch/fake-bin/command" <<'EOF'
#!/bin/bash
set -euo pipefail
case ${0##*/} in
  logger)
    printf '%s\n' "$*" >>/work/logger-arguments
    ;;
  tput) exit 1 ;;
  sync)
    [[ $(</work/sync-mode) != fail ]] || exit 52
    exec /real-bin/sync "$@"
    ;;
  umount)
    printf '%s\n' "$*" >>/work/unmount-arguments
    [[ $(</work/unmount-mode) != fail ]] || exit 53
    ;;
  b2sum)
    case $(</work/hash-mode) in
      pass) exec /real-bin/b2sum "$@" ;;
      fail) exit 51 ;;
      blank) printf '\n' ;;
      malformed) printf 'not-a-hash  fixture\n' ;;
      extra-output) printf '%0128x  fixture\nunexpected diagnostic\n' 1 ;;
      mismatch)
        exec 9>/work/hash-lock
        flock 9
        count=0
        [[ ! -f /work/hash-count ]] || count=$(</work/hash-count)
        ((count += 1))
        printf '%s\n' "$count" >/work/hash-count
        printf '%0128x  fixture\n' "$count"
        ;;
      *) exit 95 ;;
    esac
    ;;
  *) exit 96 ;;
esac
EOF
chmod 755 "$scratch/fake-bin/command"
for tool in logger tput sync umount b2sum; do
  cp "$scratch/fake-bin/command" "$scratch/fake-bin/$tool"
done
bash -n "$scratch/fake-bin/command"
shellcheck "$scratch/fake-bin/command"

sandbox=(
  bwrap --unshare-all --die-with-parent --new-session --uid 0 --gid 0 --clearenv
  --ro-bind /usr/lib /usr/lib --dir /usr/bin
  --symlink usr/bin /bin --symlink usr/lib /lib
  --tmpfs /usr/lib/modules --proc /proc --dev /dev --tmpfs /tmp --dir /run
  --dir /var --dir /sys --dir /usr/share/limine-entry-tool.d
  --ro-bind "$java_home" /jdk --ro-bind "$scratch/fixtures" /fixtures
  --ro-bind "$scratch/fake-bin" /fake-bin
  --setenv JAVA_HOME /jdk --setenv PATH /fake-bin:/jdk/bin:/usr/bin
  --setenv HOME /work/home --setenv XDG_CONFIG_HOME /work/home/config
  --setenv XDG_DATA_HOME /work/home/data --setenv XDG_CACHE_HOME /work/home/cache
  --setenv XDG_STATE_HOME /work/home/state --setenv XDG_RUNTIME_DIR /work/runtime
  --setenv HISTFILE /dev/null --setenv TMPDIR /tmp --setenv LC_ALL C.UTF-8 --setenv TERM dumb
  --chdir /work
)
if [[ -d /usr/lib64 ]]; then
  [[ $(realpath /usr/lib64) == "$(realpath /usr/lib)" ]] || die 'requires the merged-/usr lib64 alias'
  sandbox+=(--symlink lib /usr/lib64 --symlink usr/lib64 /lib64)
fi
for tool in bash flock cat; do
  sandbox+=(--ro-bind "$(realpath -- "$(command -v "$tool")")" "/usr/bin/$tool")
done
for tool in b2sum sync; do
  sandbox+=(--ro-bind "$(realpath -- "$(command -v "$tool")")" "/real-bin/$tool")
done
java_options=(-Xmx256m -XX:ActiveProcessorCount=4 -Duser.home=/work/home -Djava.io.tmpdir=/tmp)
"${sandbox[@]}" --dir /etc --bind "$scratch/compiler" /work /jdk/bin/java "${java_options[@]}" --version >"$scratch/java-version"
cat "$scratch/java-version"
grep -Eq '^(openjdk|java) 25([.[:space:]]|$)' "$scratch/java-version" || die 'requires Java 25'
for revision in original patched; do
  compile_sources=()
  sources=("${LIMINE_ORIGINAL_JAVA[@]}")
  [[ $revision != patched ]] || sources=("${LIMINE_PATCHED_JAVA[@]}")
  for path in "${sources[@]}"; do compile_sources+=("/source/$path"); done
  mkdir -p "$scratch/classes-$revision"
  extra=()
  [[ $revision != patched ]] || extra+=(/fixtures/NativeScannerContract.java)
  "${sandbox[@]}" --dir /etc --ro-bind "$scratch/$revision" /source \
    --bind "$scratch/classes-$revision" /work /jdk/bin/javac \
    -J-Xmx1g -J-XX:ActiveProcessorCount=4 -J-Duser.home=/work/home \
    -d /work/classes "${compile_sources[@]}" /fixtures/NativeContract.java "${extra[@]}" \
    >"$scratch/compile-$revision.log" 2>&1 || {
      cat "$scratch/compile-$revision.log" >&2
      die "actual source compilation: $revision"
    }
done

count=0
run_case() {
  local revision=$1 name=$2 operation=$3 expected=$4 kernel=${5:-linux} prefix=${6:-contract} verification=${7:-no}
  local work=$scratch/$name-$revision rc=0 esp=/boot
  mkdir -p "$work/etc/default" "$work/boot/EFI/Linux" "$work/home" "$work/runtime"
  printf 'KERNEL_CMDLINE="root=fixture quiet"\n' >"$work/etc/default/limine"
  printf '11111111111111111111111111111111\n' >"$work/etc/machine-id"
  printf '# preserved original configuration\ntimeout: 3\n' >"$work/boot/limine.conf"
  cp "$work/boot/limine.conf" "$work/config.before"
  printf 'new fixture UKI\n' >"$work/input.efi"
  cp "$work/input.efi" "$work/input \$(>pwned).efi"
  cp "$work/input.efi" "$work/"$'input\nline.efi'
  printf 'fixture kernel\n' >"$work/vmlinuz"
  printf 'fixture initramfs\n' >"$work/initramfs"
  printf 'fixture fallback\n' >"$work/initramfs-fallback"
  printf 'old fixture UKI\n' >"$work/boot/EFI/Linux/contract_linux.efi"
  cp "$work/boot/EFI/Linux/contract_linux.efi" "$work/output.before"
  printf 'pass\n' >"$work/hash-mode"
  printf 'pass\n' >"$work/sync-mode"
  printf 'pass\n' >"$work/unmount-mode"
  local -a mounts=()
  case $name in
    missing-uki|missing-efi) rm "$work/input.efi" ;;
    missing-initramfs) rm "$work/initramfs" ;;
    missing-kernel) rm "$work/vmlinuz" ;;
    missing-extra-initrd) printf 'KERNEL_CMDLINE="root=fixture initrd=/missing"\n' >"$work/etc/default/limine" ;;
    mkdir-file) printf 'not a directory\n' >"$work/boot/directory" ;;
    mkdir-readonly) mounts+=(--ro-bind "$work/boot" /boot) ;;
    copy-readonly) mounts+=(--ro-bind "$work/boot/EFI/Linux/contract_linux.efi" /boot/EFI/Linux/contract_linux.efi) ;;
    hash-failure) printf 'fail\n' >"$work/hash-mode" ;;
    hash-blank) printf 'blank\n' >"$work/hash-mode" ;;
    hash-malformed) printf 'malformed\n' >"$work/hash-mode" ;;
    hash-extra-output) printf 'extra-output\n' >"$work/hash-mode" ;;
    hash-mismatch) printf 'mismatch\n' >"$work/hash-mode" ;;
    backup-failure) mkdir "$work/boot/limine.conf.old"; printf 'keep\n' >"$work/boot/limine.conf.old/keep" ;;
    write-failure) mkdir "$work/boot/limine.conf.tmp" ;;
    sync-failure) printf 'fail\n' >"$work/sync-mode" ;;
    rename-failure) mounts+=(--ro-bind "$work/boot/limine.conf" /boot/limine.conf) ;;
    equal-content) cp "$work/input.efi" "$work/boot/EFI/Linux/contract_linux.efi" ;;
    spaced-esp) esp='/boot volume'; mounts+=(--bind "$work/boot" "$esp") ;;
    recent-backup) printf 'recent backup\n' >"$work/boot/limine.conf.old" ;;
    no-hash-tool)
      mkdir "$work/no-hash-bin"
      for tool in logger tput sync umount; do cp "$scratch/fake-bin/$tool" "$work/no-hash-bin/"; done
      mounts+=(--setenv PATH /work/no-hash-bin:/jdk/bin:/usr/bin)
      ;;
    shell-error-path) printf 'fail\n' >"$work/hash-mode" ;;
    scanner-cleanup-failure|scanner-both-fail) printf 'fail\n' >"$work/unmount-mode" ;;
  esac
  entry=org.limine.entry.tool.NativeContract
  arguments=("$operation" "$esp" "$kernel" "$prefix" "$verification")
  if [[ $name == scanner-* ]]; then
    entry=org.limine.entry.tool.NativeScannerContract
    arguments=("${name#scanner-}")
  fi
  "${sandbox[@]}" --bind "$work" /work --ro-bind "$work/etc" /etc \
    --bind "$work/boot" /boot --ro-bind "$scratch/classes-$revision/classes" /classes \
    "${mounts[@]}" /jdk/bin/java "${java_options[@]}" -cp /classes "$entry" "${arguments[@]}" \
    >"$work/stdout" 2>"$work/stderr" || rc=$?
  printf '%s\n' "$rc" >"$work/exit-status"
  if [[ $expected == zero && $rc != 0 || $expected == nonzero && $rc == 0 ]]; then
    cat "$work/stdout" "$work/stderr" >&2
    die "$name/$revision: expected $expected, got $rc"
  fi
  if [[ $revision == patched && $expected == nonzero && $operation != cli-missing ]]; then
    cmp "$work/config.before" "$work/boot/limine.conf" || die "$name: failure published configuration"
    if grep -q 'Updated:' "$work/stdout"; then die "$name: failure reported Updated"; fi
  fi
  case $name in
    copy-readonly|hash-failure|hash-blank|hash-malformed|hash-extra-output|shell-error-path)
      cmp "$work/output.before" "$work/boot/EFI/Linux/contract_linux.efi" || die "$name: old output changed"
      if [[ $name == shell-error-path && $revision == patched ]]; then
        [[ ! -e $work/pwned ]] || die 'error diagnostic interpreted filename as shell code'
        grep -Fq "\$(>pwned)" "$work/logger-arguments" || die 'error diagnostic lost the literal path'
      fi
      ;;
    hash-mismatch) [[ $(<"$work/hash-count") == 6 ]] || die 'hash disagreement retry count changed' ;;
    hash-interrupted)
      if [[ $revision == patched ]]; then
        [[ $(<"$work/interrupted") == true ]] || die 'interrupt status was lost'
      fi
      ;;
    shell-path)
      if [[ $revision == patched && -e $work/pwned ]]; then die 'filename was interpreted as shell code'; fi
      ;;
    recent-backup) [[ $(<"$work/boot/limine.conf.old") == 'recent backup' ]] || die 'recent backup was replaced' ;;
    scanner-*)
      [[ $(<"$work/unmount-arguments") == '-- /run/let' ]] || die 'owned mount cleanup was skipped or changed'
      [[ -f $work/scanner-validated ]] || die 'scanner assertion failed instead of validating its expected outcome'
      outcome='expected-failure'
      [[ $expected != zero ]] || outcome=success
      [[ $(<"$work/scanner-validated") == "$outcome" ]] || die 'unexpected scanner validation outcome'
      ;;
  esac
  if [[ $expected == zero ]]; then
    case $name in
      uki-success|uki-hash|equal-content|recent-backup|no-hash-tool|spaced-esp|shell-path|escaped-source|efi-suffix)
        cmp "$work/input.efi" "$work/boot/EFI/Linux/contract_linux.efi" || die "$name: selected UKI was not copied"
        ;;
      prefix-overlap) cmp "$work/input.efi" "$work/boot/EFI/Linux/linux.efi" || die 'prefix overlap changed output name' ;;
      efi-uppercase) cmp "$work/input.efi" "$work/boot/EFI/Linux/contract_Linux.EFI" || die 'EFI name case changed' ;;
      default-prefix) cmp "$work/input.efi" "$work/boot/EFI/Linux/11111111111111111111111111111111_linux.efi" || die 'default prefix changed' ;;
      same-path) cmp "$work/output.before" "$work/boot/EFI/Linux/contract_linux.efi" || die 'same-path no-op changed data' ;;
      regular-success|regular-fallback)
        cmp "$work/vmlinuz" "$work/boot/11111111111111111111111111111111/linux/vmlinuz" || die 'kernel resource was not copied'
        resource=initramfs
        [[ $name != regular-fallback ]] || resource=initramfs-fallback
        cmp "$work/$resource" "$work/boot/11111111111111111111111111111111/linux/$resource" || die 'initramfs resource was not copied'
        ;;
    esac
  fi
  printf 'PASS: %s/%s\n' "$name" "$revision"
  ((count += 1))
}

for spec in 'missing-uki uki' 'missing-initramfs regular' 'missing-kernel regular' \
  'missing-extra-initrd regular' 'missing-efi efi' 'mkdir-file mkdir' 'mkdir-readonly mkdir' \
  'copy-readonly uki' 'hash-failure uki' 'hash-blank uki' 'hash-malformed uki' \
  'hash-extra-output uki' 'shell-error-path uki-special' \
  'backup-failure writer' 'sync-failure writer' 'rename-failure writer' 'copy-missing copy-missing' \
  'hash-mismatch hash'; do
  read -r name operation <<<"$spec"
  run_case original "$name" "$operation" zero
  run_case patched "$name" "$operation" nonzero
done
for revision in original patched; do
  run_case "$revision" write-failure writer nonzero
  run_case "$revision" hash-interrupted hash-interrupted nonzero
  for flag in --add-kernel --add-uki --add-efi; do
    expected=zero
    [[ $revision != patched ]] || expected=nonzero
    run_case "$revision" "missing-operands-$flag" cli-missing "$expected" "$flag"
  done
  for spec in 'uki-success uki linux contract no' 'uki-hash uki linux contract yes' \
    'regular-success regular linux contract yes' 'regular-fallback regular-fallback linux contract yes' \
    'prefix-overlap uki linux linux no' 'efi-suffix uki linux.efi contract no' \
    'efi-uppercase uki Linux.EFI contract no' 'default-prefix uki linux default no' \
    'equal-content uki linux contract no' 'same-path uki-same-path linux contract no' \
    'recent-backup uki linux contract no' 'no-hash-tool uki linux contract no'; do
    read -r name operation kernel prefix verification <<<"$spec"
    run_case "$revision" "$name" "$operation" zero "$kernel" "$prefix" "$verification"
  done
done
for name in uki-success uki-hash regular-success regular-fallback prefix-overlap efi-suffix \
  efi-uppercase default-prefix equal-content same-path recent-backup no-hash-tool; do
  cmp "$scratch/$name-original/boot/limine.conf" "$scratch/$name-patched/boot/limine.conf" \
    || die "successful serialization changed: $name"
done
run_case patched spaced-esp uki zero
run_case patched shell-path uki-special zero
run_case patched escaped-source uki-escaped zero
for name in success publication-failure cleanup-failure both-fail; do
  expected=nonzero
  [[ $name != success ]] || expected=zero
  run_case patched "scanner-$name" scanner "$expected"
done
printf 'Passed %s actual-Java publication contracts.\n' "$count"
