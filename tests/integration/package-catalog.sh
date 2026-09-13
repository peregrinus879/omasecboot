#!/usr/bin/env bash
# Actual core catalog reader and real pacman, in a fixture-only namespace.
set -euo pipefail
umask 077
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || die 'this suite takes no arguments'
for tool in bwrap pacman pacman-conf bsdtar cc bash env realpath mktemp mkdir rm cp chmod cmp \
  cat grep sha256sum shellcheck readlink stat jq iconv find findmnt sort xargs awk ln base64; do
  command -v "$tool" >/dev/null || die "required command: $tool"
done
repo=$(realpath -- "${BASH_SOURCE[0]%/*}/../..")
parent=${TMPDIR:-/tmp}
[[ -d $parent && ! -L $parent ]] || die 'TMPDIR must be a real directory'
scratch=$(mktemp -d "$parent/package-catalog.XXXXXX")
finish() {
  local rc=$?
  if [[ ${PACKAGE_CATALOG_KEEP:-0} == 1 ]]; then
    printf 'Retained package-catalog evidence: %s (status %s)\n' "$scratch" "$rc"
  else
    rm -rf -- "$scratch"
  fi
}
trap finish EXIT
mkdir -p "$scratch/fixtures/packages" "$scratch/fixtures/runtime"
# shellcheck source=tests/integration/lib/pacman-fixtures.sh
source "$repo/tests/integration/lib/pacman-fixtures.sh"
pacman_fixture_read_error
pacman_fixture_package contract-kernel 1-1 contract-a
pacman_fixture_package contract-second 2-1 contract-b
pacman_fixture_package contract-directory-owner 1-1 directory-only
printf 'isolated pacman contract fixture\n' >"$scratch/fixtures/identity"
for tool in pacman pacman-conf findmnt; do
  cp -- "$(realpath -- "$(command -v "$tool")")" "$scratch/fixtures/runtime/$tool"
done
cat >"$scratch/fixtures/query-noise" <<'EOF'
#!/usr/bin/bash
tool=${0##*/}
/fixtures/runtime/"$tool" "$@" || exit
case ${QUERY_DIAGNOSTIC:-} in
  text) printf 'fixture diagnostic\n' >&2; exit 0 ;;
  newline) printf '\n' >&2; exit 0 ;;
  nul) printf '\000' >&2; exit 0 ;;
  stdout-nul) printf '\000'; exit 0 ;;
  exit) exit 41 ;;
esac
if [[ $tool == pacman-conf ]]; then
  printf 'unexpected context line\n'
else
  for arg in "$@"; do
    [[ $arg != -Q ]] || printf 'unexpected package line\n'
  done
fi
EOF
cat >"$scratch/fixtures/encoder-fail" <<'EOF'
#!/usr/bin/bash
/usr/bin/cat >/dev/null
exit 42
EOF
cat >"$scratch/fixtures/mount-query-fault" <<'EOF'
#!/usr/bin/bash
case $MOUNT_FAULT in
  empty) printf '{"filesystems":[]}\n' ;;
  exit) exit 42 ;;
  stderr-nul) /fixtures/runtime/findmnt "$@" || exit; printf '\000' >&2 ;;
  *) exit 97 ;;
esac
EOF
chmod 755 "$scratch/fixtures/query-noise"
chmod 755 "$scratch/fixtures/encoder-fail"
chmod 755 "$scratch/fixtures/mount-query-fault"
shellcheck "$scratch/fixtures/query-noise" "$scratch/fixtures/encoder-fail" "$scratch/fixtures/mount-query-fault"
cat >"$scratch/fixtures/driver" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
[[ $EUID == 0 && -f /fixtures/identity && ! -e /sys/firmware ]] || exit 99
case_name=$1
# shellcheck source=/dev/null
source /core/common.sh
# shellcheck source=/dev/null
source /core/outputs.sh
root=/
db=/var/lib/pacman
capture=/work/capture
root_override=''
db_override=''
[[ $case_name != alternate-root ]] || root='/work/target root'
[[ $case_name != alternate-database ]] || db='/work/package database'
mkdir -p "$root" "$db/local" /etc/pacman.d/hooks /var/log /work/empty-keyring /work/capture
chmod 700 /work/capture
cat >/etc/pacman.conf <<CONFIG
[options]
Architecture = auto
RootDir = $root
DBPath = $db
LogFile = /work/pacman.log
GPGDir = /work/empty-keyring
SigLevel = Never
CONFIG
pac() { /usr/bin/pacman --config /etc/pacman.conf --noconfirm "$@"; }
# The bind target below local exists at namespace construction, before pacman
# initializes this fixture. Supply the native version record for that layout.
[[ $case_name != capture-local-subtree ]] || printf '9\n' >"$db/local/ALPM_DB_VERSION"
if [[ $case_name == empty ]]; then
  printf '9\n' >"$db/local/ALPM_DB_VERSION"
elif [[ $case_name == empty-uninitialized ]]; then
  :
elif [[ $case_name == directory-only ]]; then
  pac -U /fixtures/packages/contract-directory-owner-1-1-any.pkg.tar
else
  pac -U /fixtures/packages/contract-kernel-1-1-any.pkg.tar /fixtures/packages/contract-second-2-1-any.pkg.tar \
    /fixtures/packages/contract-directory-owner-1-1-any.pkg.tar
fi
expected=0
case $case_name in
  normal|alternate-root|alternate-database|empty|directory-only|database-bind|local-bind|same-filesystem) ;;
  large)
    # Copy real installed metadata into a large synthetic catalog. This checks
    # reader scale/argument framing, not additional package installations.
    for ((i=0; i<2200; i++)); do
      printf -v package 'contract-extra-%04d' "$i"
      cp -a "$db/local/contract-directory-owner-1-1" "$db/local/$package-1-1"
      CATALOG_NAME="$package" awk '$0 == "%NAME%" {print; getline; print ENVIRON["CATALOG_NAME"]; next} {print}' \
        "$db/local/contract-directory-owner-1-1/desc" >"$db/local/$package-1-1/desc"
    done
    ;;
  bad-context|bad-package-output|context-diagnostic-*|encoder-failure) expected=1 ;;
  missing-file) rm "${root%/}/usr/lib/modules/contract-a/modules.builtin" ;;
  missing-directory) rm -r "${root%/}/usr/lib/modules/contract-a" ;;
  database-alias)
    mv "$db" /work/actual-database
    ln -s /work/actual-database "$db"
    ;;
  input-link)
    mv "$db/local/contract-kernel-1-1/files" /work/linked-files
    ln -s /work/linked-files "$db/local/contract-kernel-1-1/files"
    ;;
  explicit-root)
    mkdir '/work/explicit root'
    root_override='/work/explicit root'
    ;;
  explicit-database)
    cp -a "$db" '/work/explicit database'
    db_override='/work/explicit database'
    ;;
  root-alias-newline|root-alias-trailing-newline)
    target=$'/work/target\nroot'
    [[ $case_name != root-alias-trailing-newline ]] || target=$'/work/target\n'
    mkdir "$target" /work/target
    ln -s "$target" /work/root-alias
    root_override=/work/root-alias
    expected=1
    ;;
  local-alias|local-rebind|capture-local-overlap)
    mv "$db/local" /work/local-a
    ln -s /work/local-a "$db/local"
    if [[ $case_name == local-rebind ]]; then
      cp -a /work/local-a /work/local-b
      cp -a /work/local-a/contract-kernel-1-1 /work/local-b/contract-added-1-1
      awk '$0 == "%NAME%" {print; getline; print "contract-added"; next} {print}' \
        /work/local-a/contract-kernel-1-1/desc >/work/local-b/contract-added-1-1/desc
      export OMASECBOOT_TEST_LOCAL_REBIND=1 LD_PRELOAD=/fixtures/pacman-read-error.so
      expected=1
    elif [[ $case_name == capture-local-overlap ]]; then
      capture=/work/local-a/capture
      mkdir -m 700 "$capture"
      expected=1
    fi
    ;;
  capture-database-overlap)
    capture="$db/capture"
    mkdir -m 700 "$capture"
    expected=1
    ;;
  capture-database-bind|capture-local-bind|capture-database-subtree|capture-local-subtree|capture-source-child-bind)
    case $case_name in
      capture-database-bind) capture=/work/database/capture ;;
      capture-local-bind) capture=/work/local/capture ;;
      *) capture=/work/alias ;;
    esac
    mkdir -p "$capture"
    chmod 700 "$capture"
    expected=1
    ;;
  mount-fault-*) expected=1 ;;
  version-link)
    mv "$db/local/ALPM_DB_VERSION" /work/linked-version
    ln -s /work/linked-version "$db/local/ALPM_DB_VERSION"
    ;;
  ignored-link) ln -s /dev/null "$db/local/ignored-link" ;;
  invalid-entry) mkdir "$db/local/invalid-entry"; expected=1 ;;
  missing-file-list) rm "$db/local/contract-kernel-1-1/files"; expected=1 ;;
  no-version) rm "$db/local/ALPM_DB_VERSION"; expected=1 ;;
  empty-uninitialized) expected=1 ;;
  missing-local) rm -r "$db/local"; expected=1 ;;
  wrong-version) printf '999\n' >"$db/local/ALPM_DB_VERSION"; expected=1 ;;
  silent-read-error)
    export OMASECBOOT_TEST_READ_ERROR=1 LD_PRELOAD=/fixtures/pacman-read-error.so
    expected=1
    ;;
  source-drift)
    export OMASECBOOT_TEST_CATALOG_DRIFT=1 LD_PRELOAD=/fixtures/pacman-read-error.so
    expected=1
    ;;
  *) exit 98 ;;
esac
case $case_name in
  database-bind|local-bind|capture-*-bind|capture-*-subtree|same-filesystem)
    [[ $(stat -c %d "$capture") == "$(stat -c %d "$db")" ]] || exit 1
    [[ $(stat -c %i "$capture") != "$(stat -c %i "$db")" ]] || exit 1
    ;;
esac
rc=0
collect_package_kernel_catalog "$capture" /etc/pacman.conf "$root_override" "$db_override" >/work/catalog.json 2>/work/catalog.err || rc=$?
[[ $rc == "$expected" ]] || { printf 'catalog expected %s, got %s\n' "$expected" "$rc" >&2; cat /work/catalog.err >&2; exit 1; }
if [[ $expected != 0 ]]; then
  [[ ! -s /work/catalog.json ]] || exit 1
  if [[ $case_name == silent-read-error ]]; then
    grep -Fq 'not a complete view' /work/catalog.err || exit 1
    [[ ! -s /work/capture/files.err && -s /work/capture/files.raw ]] || exit 1
  elif [[ $case_name == no-version || $case_name == empty-uninitialized || $case_name == missing-local ]]; then
    [[ ! -e $db/local/ALPM_DB_VERSION && ! -e /work/capture/packages.raw ]] || exit 1
    [[ $case_name != missing-local || ! -e $db/local ]] || exit 1
  elif [[ $case_name == source-drift ]]; then
    grep -Fq 'Package catalog source changed during observation:' /work/catalog.err || exit 1
    cmp /work/capture/files.expected.sorted /work/capture/files.sorted || exit 1
  elif [[ $case_name == local-rebind ]]; then
    grep -Fq 'Package database local binding changed' /work/catalog.err || exit 1
    [[ $(readlink "$db/local") == /work/local-b ]] || exit 1
    cmp /work/capture/before.hashes /work/capture/after.hashes || exit 1
    cmp /work/capture/before.stats /work/capture/after.stats || exit 1
  elif [[ $case_name == capture-* || $case_name == mount-fault-* ]]; then
    grep -Fq 'Capture directory overlaps' /work/catalog.err || exit 1
    [[ -z $(find "$capture" -mindepth 1 -print -quit) ]] || exit 1
  elif [[ $case_name == root-alias-newline || $case_name == root-alias-trailing-newline ]]; then
    [[ -z $(find "$capture" -mindepth 1 -print -quit) ]] || exit 1
  fi
  exit 0
fi
[[ ! -s /work/catalog.err ]] || { cat /work/catalog.err >&2; exit 1; }
jq -e '.format == "omasecboot-package-catalog" and .schema == 1 and .database_version == 9
  and (.view | keys | sort) == ["files_sha256","metadata_sha256","packages_sha256","source_sha256"]' /work/catalog.json >/dev/null
if [[ $case_name == empty || $case_name == directory-only ]]; then
  jq -e '.kernels == []' /work/catalog.json >/dev/null
else
  jq -e '.kernels == [
    {package:"contract-kernel",package_version:"1-1",kernel_version:"contract-a",declaration:"/usr/lib/modules/contract-a/modules.builtin"},
    {package:"contract-second",package_version:"2-1",kernel_version:"contract-b",declaration:"/usr/lib/modules/contract-b/modules.builtin"}
  ]' /work/catalog.json >/dev/null
fi
if [[ $case_name == empty ]]; then
  jq -e '.packages == [] and .query_status == {packages:1,files:1}' /work/catalog.json >/dev/null
elif [[ $case_name == large ]]; then
  jq -e '(.packages | length) == 2203' /work/catalog.json >/dev/null
  [[ $(stat -c '%s' /work/capture/packages.json) -gt 131072 ]] || exit 1
fi
if [[ $case_name == alternate-root ]]; then
  jq -e '.context.root.resolved == "/work/target root"' /work/catalog.json >/dev/null
elif [[ $case_name == alternate-database ]]; then
  jq -e '.context.database.resolved == "/work/package database"' /work/catalog.json >/dev/null
elif [[ $case_name == database-alias ]]; then
  jq -e '.context.database.resolved == "/work/actual-database"' /work/catalog.json >/dev/null
elif [[ $case_name == explicit-root ]]; then
  jq -e '.context.root.resolved == "/work/explicit root"' /work/catalog.json >/dev/null
elif [[ $case_name == explicit-database ]]; then
  jq -e '.context.database.resolved == "/work/explicit database"' /work/catalog.json >/dev/null
fi
EOF
bash -n "$scratch/fixtures/driver"
shellcheck "$scratch/fixtures/driver"
sandbox=(bwrap --unshare-all --die-with-parent --new-session --uid 0 --gid 0 --cap-add CAP_SYS_CHROOT --clearenv
  --ro-bind /usr/lib /usr/lib --dir /usr/bin --symlink usr/bin /bin --symlink usr/lib /lib
  --tmpfs /usr/lib/modules --dir /usr/share/libalpm/hooks --proc /proc --dev /dev --tmpfs /tmp
  --dir /run --dir /etc --dir /var --dir /boot --ro-bind "$scratch/fixtures" /fixtures
  --ro-bind "$repo/lib/common.sh" /core/common.sh --ro-bind "$repo/lib/outputs.sh" /core/outputs.sh
  --setenv PATH /usr/bin --setenv LC_ALL C --setenv TERM dumb
  --setenv HOME /work/home --setenv XDG_CONFIG_HOME /work/home/config --setenv XDG_DATA_HOME /work/home/data
  --setenv XDG_CACHE_HOME /work/home/cache --setenv XDG_STATE_HOME /work/home/state
  --setenv XDG_RUNTIME_DIR /work/runtime --setenv HISTFILE /dev/null --chdir /work)
if [[ -d /usr/lib64 ]]; then
  [[ $(realpath /usr/lib64) == "$(realpath /usr/lib)" ]] || die 'requires merged-/usr lib64 alias'
  sandbox+=(--symlink lib /usr/lib64 --symlink usr/lib64 /lib64)
fi
for tool in bash cat mkdir cp mv rm chmod ln cmp grep sha256sum readlink realpath stat jq iconv find findmnt sort xargs awk base64; do
  sandbox+=(--ro-bind "$(realpath -- "$(command -v "$tool")")" "/usr/bin/$tool")
done
for tool in pacman pacman-conf; do sandbox+=(--ro-bind "$scratch/fixtures/runtime/$tool" "/usr/bin/$tool"); done
count=0
for name in normal missing-file missing-directory directory-only empty large alternate-root alternate-database \
  database-alias input-link version-link ignored-link invalid-entry missing-file-list no-version wrong-version \
  empty-uninitialized missing-local silent-read-error source-drift bad-context bad-package-output \
  explicit-root explicit-database root-alias-newline root-alias-trailing-newline local-alias local-rebind \
  capture-database-overlap capture-local-overlap context-diagnostic-text context-diagnostic-newline \
  context-diagnostic-nul context-diagnostic-stdout-nul context-diagnostic-exit encoder-failure \
  database-bind local-bind same-filesystem capture-database-bind capture-local-bind \
  capture-database-subtree capture-local-subtree capture-source-child-bind \
  mount-fault-empty mount-fault-exit mount-fault-stderr-nul; do
  mkdir "$scratch/$name"
  extra=()
  case $name in
    database-bind|same-filesystem|capture-database-bind)
      mkdir "$scratch/$name/database"
      extra+=(--bind "$scratch/$name/database" /var/lib/pacman)
      ;;
    local-bind|capture-local-bind)
      mkdir -p "$scratch/$name/database/local"
      # DBPath/local is a separate bind alias, not a child of the DB backing range.
      mkdir "$scratch/$name/local"
      extra+=(--bind "$scratch/$name/database" /var/lib/pacman --bind "$scratch/$name/local" /var/lib/pacman/local)
      ;;
    capture-database-subtree|capture-local-subtree)
      location=capture
      [[ $name != capture-local-subtree ]] || location=local/capture
      mkdir -p "$scratch/$name/database/$location"
      extra+=(--bind "$scratch/$name/database" /var/lib/pacman --bind "$scratch/$name/database/$location" /work/alias)
      ;;
    capture-source-child-bind)
      mkdir "$scratch/$name/database" "$scratch/$name/alias"
      extra+=(--bind "$scratch/$name/database" /var/lib/pacman --bind "$scratch/$name/alias" /var/lib/pacman/alias)
      ;;
    mount-fault-*)
      extra+=(--ro-bind "$scratch/fixtures/mount-query-fault" /usr/bin/findmnt --setenv MOUNT_FAULT "${name#mount-fault-}")
      ;;
  esac
  if [[ $name == bad-context ]]; then extra=(--ro-bind "$scratch/fixtures/query-noise" /usr/bin/pacman-conf); fi
  if [[ $name == bad-package-output ]]; then extra=(--ro-bind "$scratch/fixtures/query-noise" /usr/bin/pacman); fi
  if [[ $name == context-diagnostic-* ]]; then
    extra=(--ro-bind "$scratch/fixtures/query-noise" /usr/bin/pacman-conf --setenv QUERY_DIAGNOSTIC "${name#context-diagnostic-}")
  fi
  if [[ $name == encoder-failure ]]; then extra=(--ro-bind "$scratch/fixtures/encoder-fail" /usr/bin/base64); fi
  if ! "${sandbox[@]}" --bind "$scratch/$name" /work "${extra[@]}" /usr/bin/bash /fixtures/driver "$name" \
    >"$scratch/$name/transcript" 2>&1; then
    cat "$scratch/$name/transcript" >&2
    die "package catalog case: $name"
  fi
  printf 'PASS: catalog/%s\n' "$name"
  count=$((count + 1))
done
printf 'Passed %s real core/package-catalog contracts.\n' "$count"
