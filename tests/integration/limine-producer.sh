#!/usr/bin/env bash
# Offline contract test for integrations/limine-entry-tool/source.json.
# Usage: TMPDIR=/private/scratch bash tests/integration/limine-producer.sh SOURCE_ROOT
# SOURCE_ROOT supplies unpatched, SHA-256-bound files from the pinned commit.
# Requires unprivileged Bubblewrap; there is deliberately no host-execution fallback.
# LIMINE_PRODUCER_KEEP=1 retains fixtures and logs at the printed private path.
set -euo pipefail
umask 077

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
[[ $# == 1 && -d $1 ]] || die "usage: $0 PINNED_SOURCE_ROOT (see integrations/limine-entry-tool/source.json)"
for tool in bwrap jq patch sha256sum shellcheck realpath mktemp cp cmp diff mkdir rm chmod ln grep \
  bash env awk tail tr uname flock; do
  command -v "$tool" > /dev/null || die "required command: $tool"
done
source_root=$(realpath -- "$1")
repo=$(realpath -- "${BASH_SOURCE[0]%/*}/../..")
integration=$repo/integrations/limine-entry-tool
metadata=$integration/source.json
parent=${TMPDIR:-/tmp}
[[ -d $parent && ! -L $parent ]] || die 'TMPDIR must be an existing real directory'
scratch=$(mktemp -d "$parent/limine-producer.XXXXXX")
[[ -O $scratch && ! -L $scratch ]] || die 'scratch ownership check failed'
chmod 700 "$scratch"
finish() {
  local rc=$?
  if [[ ${LIMINE_PRODUCER_KEEP:-0} == 1 ]]; then
    printf 'Retained contract evidence: %s (status %s)\n' "$scratch" "$rc"
  else
    rm -rf -- "$scratch"
  fi
}
trap finish EXIT

verify_hash() {
  local actual
  actual=$(sha256sum -- "$1")
  [[ ${actual%% *} == "$2" ]] || die "SHA-256 mismatch: $1"
}
producer=install/arch-linux/limine-mkinitcpio-hook/usr/share/libalpm/scripts/limine-mkinitcpio-install
common=install/arch-linux/limine-entry-tool/usr/lib/limine/limine-common-functions
wrapper=install/arch-linux/limine-mkinitcpio-hook/usr/bin/limine-mkinitcpio
for path in "$producer" "$common" "$wrapper"; do
  mkdir -p "$scratch/original/${path%/*}" "$scratch/patched/${path%/*}"
  cp -- "$source_root/$path" "$scratch/original/$path"
  verify_hash "$scratch/original/$path" "$(jq -er --arg p "$path" '.files[] | select(.path == $p) | .sha256' "$metadata")"
  cp -- "$scratch/original/$path" "$scratch/patched/$path"
done
cp -- "$integration/$(jq -er '.patch.file' "$metadata")" "$scratch/producer.patch"
verify_hash "$scratch/producer.patch" "$(jq -er '.patch.sha256' "$metadata")"
patch --batch --forward --fuzz=0 -p1 -d "$scratch/patched" -i "$scratch/producer.patch" > "$scratch/patch.log"
for path in "$producer" "$common" "$wrapper"; do
  verify_hash "$scratch/patched/$path" "$(jq -er --arg p "$path" '.files[] | select(.path == $p) | .patched_sha256' "$metadata")"
  bash -n "$scratch/patched/$path"
done
shellcheck -x "$scratch/patched/$producer"

# Run the whole script, including collection, configuration, locks, hooks and main.
# /etc and module paths contain only fixtures. Whitelist the utilities used
# by the producer/common functions or the fake commands; no real producer binary
# is available. Fake commands record calls and return injected external results,
# not replacement implementations of the shell producer's control flow.
mkdir -p "$scratch/fake-bin"
cat > "$scratch/fake-bin/command" << 'FAKE'
#!/usr/bin/env bash
set -euo pipefail
cmd=${0##*/}
event() { printf '%s\n' "$*" >> /work/events; }
# Normalize only mktemp's random component for exact original/patched comparison.
{
  printf '%s' "$cmd"
  for arg in "$@"; do
    [[ $arg != /tmp/limine-mkinitcpio.*/* ]] || arg="/tmp/BUILD/${arg##*/}"
    printf ' %q' "$arg"
  done
  printf '\n'
} >> /work/commands
case $cmd in
  mountpoint) [[ $* == '-q /boot' ]] ;;
  findmnt)
    case $* in
      '-n -o FSTYPE /boot') printf 'vfat\n' ;;
      '-n -o FSTYPE /') printf 'btrfs\n' ;;
      *) exit 90 ;;
    esac
    ;;
  tput) exit 1 ;;
  snapper) exit 90 ;;
  sbctl)
    [[ $* == 'setup --print-state --json' ]] || exit 90
    printf '{"installed": %s}\n' "$TEST_SNAPSHOT"
    ;;
  pacman)
    case ${1:-} in
      -Qqo)
        version=${2%/modules.builtin}
        version=${version%/}
        version=${version##*/}
        event "lookup:$version"
        [[ $version != unowned ]] || exit 1
        printf 'linux-%s\n' "$version"
        ;;
      -Ql)
        [[ ${2:-} == linux-[abc] ]] || exit 1
        printf '%s /usr/lib/modules/%s/\n' "$2" "${2#linux-}"
        ;;
      -Q) [[ ${2:-} == linux-[abc] ]] ;;
      *) exit 90 ;;
    esac
    ;;
  mkinitcpio)
    version=''
    output=''
    variant=normal
    while (( $# )); do
      case $1 in
        --kernel)
          version=$2
          shift 2
          ;;
        --uki | --generate)
          output=$2
          shift 2
          ;;
        --cmdline)
          [[ -s $2 ]] || exit 90
          shift 2
          ;;
        --no-cmdline) shift ;;
        -S)
          [[ $2 == autodetect ]] || exit 90
          variant=fallback
          shift 2
          ;;
        --compress)
          [[ $2 == zstd ]] || exit 90
          shift 2
          ;;
        *) exit 90 ;;
      esac
    done
    [[ $version == [abc] && $output == /tmp/limine-mkinitcpio.*/* ]] || exit 90
    event "build:$version:$variant"
    # Even a failed build can leave a file. It must never be installed.
    printf '%s:%s\n' "$version" "$variant" > "$output"
    if [[ $TEST_FAIL == "build:$version:$variant" ]]; then
      event "failed:$TEST_FAIL"
      exit 41
    fi
    ;;
  limine-entry-tool)
    case ${1:-} in
      --get-cmdline) printf 'root=fixture kernel=%s\n' "$2" ;;
      --add-uki | --add-kernel)
        IFS=: read -r version variant < "$3"
        [[ $version == [abc] && $variant == normal || $version == [abc] && $variant == fallback ]] || exit 90
        event "install:$version:$variant"
        if [[ $TEST_FAIL == "install:$version:$variant" ]]; then
          event "failed:$TEST_FAIL"
          exit 42
        fi
        cp -- "$3" "/work/installed/$version-$variant"
        ;;
      --remove-uki | --remove-kernel) event "remove:$2" ;;
      *) exit 90 ;;
    esac
    ;;
  pre | post)
    event "hook:$cmd:$HOOK_CALLER"
    [[ $TEST_HOOK_FAIL != "$cmd" ]] || exit 100
    ;;
  limine-mkinitcpio-remove)
    [[ $* == post ]] || exit 90
    event 'cleanup:post'
    exit "$TEST_REMOVE_RC"
    ;;
  *) exit 90 ;;
esac
FAKE
chmod 755 "$scratch/fake-bin/command"
for cmd in mountpoint findmnt tput snapper sbctl pacman mkinitcpio limine-entry-tool \
  pre post limine-mkinitcpio-remove; do
  ln -s command "$scratch/fake-bin/$cmd"
done
bash -n "$scratch/fake-bin/command"
shellcheck "$scratch/fake-bin/command"

sandbox=(
  bwrap --unshare-all --die-with-parent --new-session --uid 0 --gid 0
  --clearenv --ro-bind /usr/lib /usr/lib --dir /usr/bin
  --symlink usr/bin /bin --symlink usr/lib /lib
  --tmpfs /usr/lib/modules --tmpfs /usr/lib/limine
  --dir /usr/share/libalpm/scripts --dir /usr/share/limine-entry-tool.d
  --proc /proc --dev /dev --tmpfs /tmp --dir /run/lock
  --dir /sys/firmware/efi --dir /var/lib/limine
  --ro-bind "$scratch/fake-bin" /fake-bin
  --ro-bind "$scratch/fake-bin/command" /usr/bin/mkinitcpio
  --ro-bind "$scratch/fake-bin/command" /usr/share/libalpm/scripts/limine-mkinitcpio-remove
  --setenv PATH /fake-bin:/usr/bin --setenv LC_ALL C --setenv TERM dumb
  --setenv HOME /work/home --setenv XDG_CONFIG_HOME /work/home/config
  --setenv XDG_DATA_HOME /work/home/data --setenv XDG_CACHE_HOME /work/home/cache
  --setenv XDG_STATE_HOME /work/home/state --setenv XDG_RUNTIME_DIR /work/runtime
  --setenv HISTFILE /dev/null --setenv TMPDIR /tmp --chdir /work
)
if [[ -d /usr/lib64 ]]; then
  # On Arch, lib64 aliases lib. Preserve that alias so it cannot expose a
  # second view of host modules beneath the read-only library mount.
  if [[ $(realpath /usr/lib64) == "$(realpath /usr/lib)" ]]; then
    sandbox+=(--symlink lib /usr/lib64)
  else
    sandbox+=(--ro-bind /usr/lib64 /usr/lib64)
  fi
  sandbox+=(--symlink usr/lib64 /lib64)
fi
for cmd in bash env mktemp rm mkdir flock awk tail tr uname cp; do
  sandbox+=(--ro-bind "$(realpath -- "$(command -v "$cmd")")" "/usr/bin/$cmd")
done

has_event() { grep -Fxq -- "$2" "$1/events" || die "missing $2 in $1"; }
no_event() {
  if grep -Fxq -- "$2" "$1/events"; then
    die "unexpected $2 in $1"
  fi
}
count=0
run_case() {
  local revision=$1 id=$2 mode=$3 fallback=$4 failure=$5 expected=$6
  local input=${7:-all} hook_fail=${8:-none} remove_rc=${9:-absent} snapshot=${10:-false}
  local work=$scratch/$id-$revision version rc=0
  mkdir -p "$work"/{etc/default,etc/boot/hooks/pre.d,etc/boot/hooks/post.d,modules,boot,installed,home,runtime}
  for version in a b c unowned incomplete; do
    mkdir -p "$work/modules/$version"
    [[ $version == incomplete ]] || : > "$work/modules/$version/modules.builtin"
    : > "$work/modules/$version/vmlinuz"
  done
  printf '11111111111111111111111111111111\n' > "$work/etc/machine-id"
  # The real common-functions config loader must take the highest layer.
  printf 'ENABLE_UKI=wrong\nMKINITCPIO_FALLBACK=wrong\nESP_PATH=/wrong\n' > "$work/etc/limine-entry-tool.conf"
  printf 'ENABLE_UKI=%s\nMKINITCPIO_FALLBACK=%s\nESP_PATH=/boot\nCUSTOM_UKI_NAME=contract\nMKINITCPIO_UKI_OPTIONS=--compress zstd\n' \
    "$mode" "$fallback" > "$work/etc/default/limine"
  ln -s /fake-bin/pre "$work/etc/boot/hooks/pre.d/pre"
  ln -s /fake-bin/post "$work/etc/boot/hooks/post.d/post"
  : > "$work/events"
  : > "$work/commands"
  local removal=()
  if [[ $remove_rc != absent ]]; then
    : > "$work/removed_kernels.list"
    removal=(--ro-bind "$work/removed_kernels.list" /var/lib/limine/removed_kernels.list)
  fi
  local launch=(/usr/bin/bash /usr/share/libalpm/scripts/limine-mkinitcpio-install)
  case $input in
    all) printf 'rebuild\n' > "$work/input" ;;
    targeted) printf 'usr/lib/modules/a/modules.builtin\nusr/lib/modules/c/extramodules/test.ko\n' > "$work/input" ;;
    empty) : > "$work/input" ;;
    wrapper)
      launch=(/usr/bin/bash /usr/bin/limine-mkinitcpio linux-a linux-b linux-c)
      : > "$work/input"
      ;;
    *) die "unknown input: $input" ;;
  esac
  "${sandbox[@]}" --bind "$work" /work --ro-bind "$work/etc" /etc \
    --ro-bind "$work/modules" /usr/lib/modules --bind "$work/boot" /boot \
    --ro-bind "$scratch/$revision/$producer" /usr/share/libalpm/scripts/limine-mkinitcpio-install \
    --ro-bind "$scratch/$revision/$common" /usr/lib/limine/limine-common-functions \
    --ro-bind "$scratch/$revision/$wrapper" /usr/bin/limine-mkinitcpio \
    "${removal[@]}" \
    --setenv TEST_FAIL "$failure" --setenv TEST_HOOK_FAIL "$hook_fail" \
    --setenv TEST_REMOVE_RC "$remove_rc" --setenv TEST_SNAPSHOT "$snapshot" \
    "${launch[@]}" < "$work/input" > "$work/stdout" 2> "$work/stderr" || rc=$?
  printf '%s\n' "$rc" > "$work/status"
  [[ $rc == "$expected" ]] || die "$id/$revision: expected status $expected, got $rc (see $work)"
  has_event "$work" 'hook:pre:limine-mkinitcpio-install'
  if [[ $hook_fail != pre ]]; then
    has_event "$work" 'hook:post:limine-mkinitcpio-install'
    if [[ $hook_fail != post && $remove_rc != absent ]]; then
      has_event "$work" 'cleanup:post'
    else
      no_event "$work" 'cleanup:post'
    fi
  fi
  count=$((count + 1))
}

# Successful behavior must be byte-for-byte identical at the command boundary,
# including options, cmdline selection, naming, comments, hooks and output files.
for mode in yes no; do
  for fallback in no yes linux-b; do
    id=success-$mode-$fallback
    for revision in original patched; do
      run_case "$revision" "$id" "$mode" "$fallback" none 0
      for version in a b c; do
        has_event "$scratch/$id-$revision" "install:$version:normal"
        if [[ $fallback == yes || $fallback == "linux-$version" ]]; then
          has_event "$scratch/$id-$revision" "install:$version:fallback"
        else
          no_event "$scratch/$id-$revision" "build:$version:fallback"
        fi
      done
      no_event "$scratch/$id-$revision" 'lookup:incomplete'
      no_event "$scratch/$id-$revision" 'build:unowned:normal'
    done
    for file in events commands stdout stderr; do
      cmp "$scratch/$id-original/$file" "$scratch/$id-patched/$file"
    done
    diff -r "$scratch/$id-original/installed" "$scratch/$id-patched/installed"
  done
done

# Every normal/fallback build/install error in the first, middle or last kernel:
# original exits zero; patched exits one. No successful later kernel may erase it.
for mode in yes no; do
  for stage in build install; do
    for variant in normal fallback; do
      for failed in a b c; do
        id=failure-$mode-$stage-$variant-$failed
        for revision in original patched; do
          expected=0
          [[ $revision == original ]] || expected=1
          run_case "$revision" "$id" "$mode" yes "$stage:$failed:$variant" "$expected"
          work=$scratch/$id-$revision
          has_event "$work" "failed:$stage:$failed:$variant"
          [[ ! -e $work/installed/$failed-$variant ]] || die "failed artifact installed: $id/$revision"
          for version in a b c; do
            has_event "$work" "lookup:$version"
            has_event "$work" "build:$version:normal"
            if [[ $version != "$failed" ]]; then
              has_event "$work" "install:$version:normal"
              has_event "$work" "install:$version:fallback"
              [[ -s $work/installed/$version-normal && -s $work/installed/$version-fallback ]] || die 'later outputs missing'
            fi
          done
          if [[ $stage == build ]]; then
            no_event "$work" "install:$failed:$variant"
          fi
          if [[ $variant == normal && ( $stage == build || $revision == patched ) ]]; then
            no_event "$work" "build:$failed:fallback"
          fi
        done
      done
    done
  done
done

# Real CLI pipeline, targeted NeedsTargets collection, empty selection, snapshot
# cmdline omission, hook status precedence and final cleanup status preservation.
for revision in original patched; do
  expected=0
  [[ $revision == original ]] || expected=1
  run_case "$revision" wrapper-failure yes yes install:b:fallback "$expected" wrapper
  has_event "$scratch/wrapper-failure-$revision" 'install:c:fallback'
  run_case "$revision" targeted yes no none 0 targeted
  has_event "$scratch/targeted-$revision" 'install:a:normal'
  has_event "$scratch/targeted-$revision" 'install:c:normal'
  no_event "$scratch/targeted-$revision" 'lookup:b'
  run_case "$revision" empty yes yes none 0 empty
  no_event "$scratch/empty-$revision" 'lookup:a'
  run_case "$revision" snapshot yes yes none 0 all none 0 true
  grep -Fq -- '--no-cmdline' "$scratch/snapshot-$revision/commands" || die 'snapshot cmdline omission missing'
  if grep -Fq -- '--get-cmdline' "$scratch/snapshot-$revision/commands"; then
    die 'snapshot cmdline queried'
  fi
  run_case "$revision" pre-hook yes yes none 2 all pre
  no_event "$scratch/pre-hook-$revision" 'lookup:a'
  no_event "$scratch/pre-hook-$revision" 'hook:post:limine-mkinitcpio-install'
  run_case "$revision" post-hook yes yes build:a:normal 3 all post
  no_event "$scratch/post-hook-$revision" 'cleanup:post'
  run_case "$revision" cleanup-failure yes yes none 47 all none 47
  run_case "$revision" combined-failure yes yes build:a:normal 47 all none 47
  run_case "$revision" successful-cleanup yes yes build:a:normal "$expected" all none 0
done
for id in targeted empty snapshot; do
  cmp "$scratch/$id-original/commands" "$scratch/$id-patched/commands"
  cmp "$scratch/$id-original/events" "$scratch/$id-patched/events"
done
printf 'PASS: %s real-producer contract runs; original masking reproduced, patched errors propagated\n' "$count"
