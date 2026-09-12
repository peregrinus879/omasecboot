#!/usr/bin/env bash
# Real stock-pacman contracts, entirely inside unprivileged Bubblewrap namespaces.
# This exercises package metadata, hook matching and failure delivery, not the
# OmaSecBoot lifecycle implementation. No network or host-execution fallback.
# PACMAN_CONTRACT_KEEP=1 retains the printed fixture directory and transcripts.
set -euo pipefail
umask 077

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || die 'this suite takes no arguments'
for tool in bwrap pacman bsdtar bash env realpath mktemp mkdir rm cp chmod cmp \
  cat grep sha256sum shellcheck; do
  command -v "$tool" >/dev/null || die "required command: $tool"
done
parent=${TMPDIR:-/tmp}
[[ -d $parent && ! -L $parent ]] || die 'TMPDIR must be an existing real directory'
scratch=$(mktemp -d "$parent/pacman-contract.XXXXXX")
[[ -O $scratch && ! -L $scratch ]] || die 'scratch ownership check failed'
chmod 700 "$scratch"
finish() {
  local rc=$?
  if [[ ${PACMAN_CONTRACT_KEEP:-0} == 1 ]]; then
    printf 'Retained pacman contract evidence: %s (status %s)\n' "$scratch" "$rc"
  else
    rm -rf -- "$scratch"
  fi
}
trap finish EXIT

mkdir -p "$scratch/fixtures/packages" "$scratch/fixtures/hooks"
make_package() {
  local name=$1 version=$2 module=$3 scriptlet=${4:-none}
  local root=$scratch/package-$name-$version
  mkdir -p "$root/usr/share/omasecboot-contract"
  chmod 755 "$root/usr" "$root/usr/share" "$root/usr/share/omasecboot-contract"
  printf 'fixture %s %s\n' "$name" "$version" >"$root/usr/share/omasecboot-contract/$name"
  chmod 644 "$root/usr/share/omasecboot-contract/$name"
  if [[ $module != none ]]; then
    mkdir -p "$root/usr/lib/modules/$module"
    chmod 755 "$root/usr/lib" "$root/usr/lib/modules" "$root/usr/lib/modules/$module"
    if [[ $module != directory-only ]]; then
      printf 'fixture builtin\n' >"$root/usr/lib/modules/$module/modules.builtin"
      printf 'fixture kernel %s\n' "$version" >"$root/usr/lib/modules/$module/vmlinuz"
      chmod 644 "$root/usr/lib/modules/$module/"*
    fi
  fi
  cat >"$root/.PKGINFO" <<EOF
pkgname = $name
pkgbase = $name
pkgver = $version
pkgdesc = Disposable OmaSecBoot contract fixture
url = https://example.invalid/omasecboot-contract
builddate = 1
packager = OmaSecBoot contract fixture
size = 128
arch = any
license = MIT
EOF
  case $scriptlet in
    remove-hook)
      cat >"$root/.INSTALL" <<'EOF'
post_install() {
  rm /etc/pacman.d/hooks/80-contract-producer.hook
}
EOF
      ;;
    change-hook)
      cat >"$root/.INSTALL" <<'EOF'
post_install() {
  printf '\n# changed after expectation\n' >>/etc/pacman.d/hooks/80-contract-producer.hook
}
EOF
      ;;
    none) ;;
    *) die "unknown fixture scriptlet: $scriptlet" ;;
  esac
  local -a entries=(.PKGINFO usr)
  [[ $scriptlet == none ]] || entries+=(.INSTALL)
  bsdtar --uid 0 --gid 0 --uname root --gname root \
    -cf "$scratch/fixtures/packages/$name-$version-any.pkg.tar" -C "$root" "${entries[@]}"
}
make_package contract-kernel 1-1 contract-a
make_package contract-kernel 2-1 contract-a
make_package contract-kernel 3-1 contract-b
make_package contract-unrelated 1-1 none
make_package contract-directory-owner 1-1 directory-only
make_package mkinitcpio 1-1 none
make_package contract-remove-hook 1-1 contract-a remove-hook
make_package contract-change-hook 1-1 contract-a change-hook

# Use exactly the same trigger text for an expectation and its producer. The
# native matcher, not the fixture, decides Install/Upgrade/Remove and targets.
cat >"$scratch/fixtures/build.trigger" <<'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/modules.builtin

[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = mkinitcpio
EOF
cat >"$scratch/fixtures/remove.trigger" <<'EOF'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/modules.builtin
EOF
cat >"$scratch/fixtures/all.trigger" <<'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Operation = Remove
Target = *
EOF
make_hook() {
  local name=$1 trigger=$2 when=$3 action=$4 abort=${5:-false}
  cat "$scratch/fixtures/$trigger.trigger" >"$scratch/fixtures/hooks/$name.hook"
  cat >>"$scratch/fixtures/hooks/$name.hook" <<EOF

[Action]
When = $when
Exec = /usr/bin/bash /fixtures/hook $action
NeedsTargets
EOF
  if [[ $abort == true ]]; then
    printf 'AbortOnFail\n' >>"$scratch/fixtures/hooks/$name.hook"
  fi
}
make_hook 00-contract-open all PreTransaction open true
make_hook 01-contract-expect-build build PreTransaction 'expect build' true
make_hook 01-contract-expect-remove remove PreTransaction 'expect remove' true
make_hook 80-contract-producer build PostTransaction 'run build'
make_hook 90-contract-remove remove PostTransaction 'run remove'
make_hook 99-contract-final all PostTransaction finish

# The minimal expected/terminal files below expose pacman's behavior. They are
# deliberately not production manifests, ownership validation or artifact proof.
cat >"$scratch/fixtures/hook" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ -f /fixtures/identity && -d /work && ! -e /sys/firmware ]] || exit 99
hook_set() { sha256sum /etc/pacman.d/hooks/*.hook; }
if [[ $1 == open ]]; then
  attempt=0
  [[ ! -f /work/current ]] || attempt=$(</work/current)
  ((attempt += 1))
  printf '%s\n' "$attempt" >/work/current
  mkdir -p "/work/attempts/$attempt/expected" "/work/attempts/$attempt/observed"
  hook_set >"/work/attempts/$attempt/hooks.before"
  exit 0
fi
attempt=$(</work/current)
record=/work/attempts/$attempt
mode=$(</work/mode)
case $1 in
  expect)
    [[ $mode != pre-failure ]] || exit 31
    cat >"$record/expected/$2"
    ;;
  run)
    [[ -f $record/expected/$2 ]] || exit 32
    cat >"$record/observed/$2"
    cmp "$record/expected/$2" "$record/observed/$2" || exit 33
    rc=0
    if [[ $mode == child-missing ]]; then
      /not-installed/producer || rc=$?
    else
      /usr/bin/bash /fixtures/producer "$2" || rc=$?
    fi
    printf '%s\n' "$rc" >"$record/$2.result"
    exit "$rc"
    ;;
  finish)
    hook_set >"$record/hooks.after"
    cmp "$record/hooks.before" "$record/hooks.after" || exit 34
    for expected in "$record"/expected/*; do
      [[ -f $expected ]] || continue
      role=${expected##*/}
      [[ -f $record/$role.result && $(<"$record/$role.result") == 0 ]] || exit 35
      cmp "$expected" "$record/observed/$role" || exit 36
    done
    printf 'complete\n' >"$record/complete"
    ;;
  *) exit 98 ;;
esac
EOF
cat >"$scratch/fixtures/producer" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ -f /fixtures/identity && -d /work ]] || exit 99
printf '%s\n' "$1" >>/work/producer-ran
[[ $(</work/mode) != child-failure ]] || exit 42
[[ $(</work/mode) != child-signal ]] || kill -TERM "$$"
if [[ $1 == build ]]; then
  printf 'new fixture output\n' >/work/output
fi
EOF
printf 'isolated pacman contract fixture\n' >"$scratch/fixtures/identity"

cat >"$scratch/fixtures/driver" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ $EUID == 0 && -f /fixtures/identity && ! -e /sys/firmware ]] || exit 99
case_name=$1
mkdir -p /etc/pacman.d/hooks /var/lib/pacman/local /var/cache/pacman/pkg /var/log \
  /work/home /work/runtime /work/empty-keyring
cat >/etc/pacman.conf <<'CONFIG'
[options]
Architecture = auto
DBPath = /var/lib/pacman
LogFile = /work/pacman.log
GPGDir = /work/empty-keyring
HookDir = /etc/pacman.d/hooks
SigLevel = Never
CONFIG
pkg=/fixtures/packages/contract-kernel-1-1-any.pkg.tar
pac() { /usr/bin/pacman --config /etc/pacman.conf --noconfirm "$@"; }
fail() { printf 'CASE FAILED: %s: %s\n' "$case_name" "$*" >&2; exit 1; }
expect_rc() {
  local expected=$1 actual=0
  shift
  pac "$@" || actual=$?
  printf 'pacman exit: %s\n' "$actual"
  if [[ $expected == zero ]]; then
    [[ $actual == 0 ]] || fail "expected pacman success, got $actual"
  else
    [[ $actual != 0 ]] || fail 'expected pacman failure'
  fi
}
record() { printf '/work/attempts/%s' "$(</work/current)"; }
complete() { [[ -f $(record)/complete ]]; }
missing_result() { [[ ! -e $(record)/build.result ]]; }
unchanged_output() { [[ $(</work/output) == 'old fixture output' ]]; }
installed() { pac -Q contract-kernel >/dev/null 2>&1; }

case $case_name in
  upgrade|kernel-version-change|remove|declared-missing-file|declared-missing-directory|invalid-database|missing-file-list)
    pac -U "$pkg"
    ;;
esac
cp /fixtures/hooks/*.hook /etc/pacman.d/hooks/
printf 'success\n' >/work/mode
printf 'old fixture output\n' >/work/output

case $case_name in
  install)
    expect_rc zero -U "$pkg"
    if ! complete || ! installed; then fail 'installation did not complete'; fi
    [[ -f $(record)/expected/build && ! -f $(record)/expected/remove ]] || fail 'wrong install obligations'
    ;;
  upgrade)
    expect_rc zero -U /fixtures/packages/contract-kernel-2-1-any.pkg.tar
    complete || fail 'upgrade did not complete'
    [[ -f $(record)/expected/build && ! -f $(record)/expected/remove ]] || fail 'same-path upgrade became removal'
    ;;
  kernel-version-change)
    expect_rc zero -U /fixtures/packages/contract-kernel-3-1-any.pkg.tar
    complete || fail 'kernel-version upgrade did not complete'
    [[ -f $(record)/expected/build && -f $(record)/expected/remove ]] || fail 'missing install/removal obligation'
    grep -Fxq usr/lib/modules/contract-b/modules.builtin "$(record)/expected/build" || fail 'new module identity omitted'
    grep -Fxq usr/lib/modules/contract-a/modules.builtin "$(record)/expected/remove" || fail 'old module identity omitted'
    ;;
  remove)
    expect_rc zero -R contract-kernel
    complete || fail 'removal did not complete'
    [[ ! -f $(record)/expected/build && -f $(record)/expected/remove ]] || fail 'wrong removal obligations'
    if installed; then fail 'package still installed'; fi
    ;;
  unrelated)
    expect_rc zero -U /fixtures/packages/contract-unrelated-1-1-any.pkg.tar
    complete || fail 'unrelated package incorrectly refused'
    [[ ! -f $(record)/expected/build && ! -f $(record)/expected/remove ]] || fail 'invented kernel obligation'
    ;;
  directory-only-owner)
    expect_rc zero -U /fixtures/packages/contract-directory-owner-1-1-any.pkg.tar
    complete || fail 'directory-only package did not complete'
    pac -Ql contract-directory-owner >/work/declarations
    grep -Fxq 'contract-directory-owner /usr/lib/modules/directory-only/' /work/declarations || fail 'directory declaration missing'
    if grep -q modules.builtin /work/declarations; then fail 'directory ownership invented a kernel declaration'; fi
    [[ ! -f $(record)/expected/build ]] || fail 'directory-only package triggered a kernel build'
    ;;
  mixed-duplicate-targets)
    # Repeat one trigger in both counterparts. Pacman must deduplicate the
    # actual target stream, retaining package and path targets from one txn.
    for spec in '01-contract-expect-build PreTransaction expect' '80-contract-producer PostTransaction run'; do
      read -r name when action <<<"$spec"
      { cat /fixtures/build.trigger /fixtures/build.trigger
        printf '\n[Action]\nWhen = %s\nExec = /usr/bin/bash /fixtures/hook %s build\nNeedsTargets\n' "$when" "$action"
        [[ $when != PreTransaction ]] || printf 'AbortOnFail\n'
      } >"/etc/pacman.d/hooks/$name.hook"
    done
    expect_rc zero -U "$pkg" /fixtures/packages/mkinitcpio-1-1-any.pkg.tar
    complete || fail 'mixed triggers did not complete'
    printf 'mkinitcpio\nusr/lib/modules/contract-a/modules.builtin\n' >/work/wanted-targets
    cmp /work/wanted-targets "$(record)/expected/build" || fail 'incorrect deduplication/order'
    ;;
  child-failure|child-signal|child-missing|runner-missing|dependency-missing|finalizer-missing)
    printf '%s\n' "$case_name" >/work/mode
    if [[ $case_name == runner-missing || $case_name == finalizer-missing ]]; then
      name=80-contract-producer
      trigger=build
      if [[ $case_name == finalizer-missing ]]; then name=99-contract-final; trigger=all; fi
      { cat "/fixtures/$trigger.trigger"
        printf '\n[Action]\nWhen = PostTransaction\nExec = /not-installed/runner\nNeedsTargets\n'
      } >"/etc/pacman.d/hooks/$name.hook"
    elif [[ $case_name == dependency-missing ]]; then
      printf 'Depends = contract-never-installed\n' >>/etc/pacman.d/hooks/80-contract-producer.hook
    fi
    expect_rc zero -U "$pkg"
    installed || fail 'post-hook error should follow package installation'
    if complete; then fail 'failed/missing operation incorrectly completed'; fi
    case $case_name in
      child-failure) [[ $(<"$(record)/build.result") == 42 ]] || fail 'child failure not preserved'; unchanged_output ;;
      child-signal) [[ $(<"$(record)/build.result") == 143 ]] || fail 'signal failure not preserved'; unchanged_output ;;
      child-missing) [[ $(<"$(record)/build.result") == 127 ]] || fail 'exec failure not preserved'; unchanged_output ;;
      runner-missing|dependency-missing)
        if ! missing_result || ! unchanged_output; then fail 'missing runner fabricated a result'; fi
        ;;
      finalizer-missing) [[ $(<"$(record)/build.result") == 0 ]] || fail 'producer should have succeeded' ;;
    esac
    ;;
  pre-failure|pre-exec-missing)
    printf 'pre-failure\n' >/work/mode
    if [[ $case_name == pre-exec-missing ]]; then
      { cat /fixtures/build.trigger
        printf '\n[Action]\nWhen = PreTransaction\nExec = /not-installed/expectation\nNeedsTargets\nAbortOnFail\n'
      } >/etc/pacman.d/hooks/01-contract-expect-build.hook
    fi
    expect_rc nonzero -U "$pkg"
    if installed || complete; then fail 'failed expectation allowed installation/completion'; fi
    [[ ! -e /work/producer-ran ]] || fail 'post producer ran after aborted transaction'
    unchanged_output || fail 'aborted transaction changed output'
    ;;
  removed-post-hook|changed-post-hook)
    name=contract-remove-hook
    [[ $case_name != changed-post-hook ]] || name=contract-change-hook
    expect_rc zero -U "/fixtures/packages/$name-1-1-any.pkg.tar"
    [[ -f $(record)/expected/build ]] || fail 'pre expectation missing'
    if complete; then fail 'changed hook set was accepted'; fi
    [[ $case_name != removed-post-hook ]] || { missing_result && unchanged_output; }
    ;;
  retry)
    printf 'child-failure\n' >/work/mode
    expect_rc zero -U "$pkg"
    if complete; then fail 'first failed attempt completed'; fi
    printf 'success\n' >/work/mode
    expect_rc zero -U "$pkg"
    complete || fail 'fresh successful retry did not complete'
    [[ $(</work/current) == 2 && $(</work/attempts/1/build.result) == 42 ]] || fail 'retry lost predecessor failure'
    [[ ! -e /work/attempts/1/complete ]] || fail 'retry rewrote failed predecessor'
    ;;
  declared-missing-file|declared-missing-directory)
    pac -Ql contract-kernel >/work/declarations.before
    if [[ $case_name == declared-missing-file ]]; then
      rm /usr/lib/modules/contract-a/modules.builtin
    else
      rm -r /usr/lib/modules/contract-a
    fi
    pac -Ql contract-kernel >/work/declarations.after
    cmp /work/declarations.before /work/declarations.after || fail 'metadata depended on file survival'
    grep -Fxq 'contract-kernel /usr/lib/modules/contract-a/modules.builtin' /work/declarations.after || fail 'missing declared obligation'
    if pac -Qk contract-kernel; then fail 'file-existence check ignored missing payload'; fi
    ;;
  invalid-database|missing-file-list)
    if [[ $case_name == invalid-database ]]; then
      mkdir /var/lib/pacman/local/invalid-entry
    else
      rm /var/lib/pacman/local/contract-kernel-1-1/files
    fi
    # The real CLI can return zero with a partial view. A future proof reader
    # must also reject its diagnostics, not treat successful exit as complete.
    rc=0
    pac -Ql >/work/declarations 2>/work/query-errors || rc=$?
    [[ $rc == 0 && -s /work/query-errors ]] || fail 'expected partial successful query with diagnostics'
    if [[ $case_name == invalid-database ]]; then
      grep -Fxq 'contract-kernel /usr/lib/modules/contract-a/modules.builtin' /work/declarations || fail 'healthy row missing'
    else
      [[ ! -s /work/declarations ]] || fail 'missing file list unexpectedly complete'
    fi
    ;;
  *) fail 'unknown case' ;;
esac
EOF
for script in hook producer driver; do
  bash -n "$scratch/fixtures/$script"
  shellcheck "$scratch/fixtures/$script"
done

sandbox=(
  bwrap --unshare-all --die-with-parent --new-session --uid 0 --gid 0
  --cap-add CAP_SYS_CHROOT --clearenv
  --ro-bind /usr/lib /usr/lib --dir /usr/bin
  --symlink usr/bin /bin --symlink usr/lib /lib
  --tmpfs /usr/lib/modules --dir /usr/share/libalpm/hooks
  --proc /proc --dev /dev --tmpfs /tmp --dir /run --dir /etc --dir /var --dir /boot
  --ro-bind "$scratch/fixtures" /fixtures
  --setenv PATH /usr/bin --setenv LC_ALL C --setenv TERM dumb
  --setenv HOME /work/home --setenv XDG_CONFIG_HOME /work/home/config
  --setenv XDG_DATA_HOME /work/home/data --setenv XDG_CACHE_HOME /work/home/cache
  --setenv XDG_STATE_HOME /work/home/state --setenv XDG_RUNTIME_DIR /work/runtime
  --setenv HISTFILE /dev/null --setenv TMPDIR /tmp --chdir /work
)
if [[ -d /usr/lib64 ]]; then
  [[ $(realpath /usr/lib64) == "$(realpath /usr/lib)" ]] || die 'requires the merged-/usr lib64 alias'
  sandbox+=(--symlink lib /usr/lib64 --symlink usr/lib64 /lib64)
fi
for tool in bash pacman cat mkdir cp rm cmp grep sha256sum; do
  sandbox+=(--ro-bind "$(realpath -- "$(command -v "$tool")")" "/usr/bin/$tool")
done

printf 'Stock pacman executable: '
sha256sum "$(realpath -- "$(command -v pacman)")"
pacman --version
count=0
for name in install upgrade kernel-version-change remove unrelated directory-only-owner mixed-duplicate-targets \
  child-failure child-signal child-missing runner-missing dependency-missing finalizer-missing \
  pre-failure pre-exec-missing removed-post-hook changed-post-hook retry \
  declared-missing-file declared-missing-directory invalid-database missing-file-list; do
  mkdir -p "$scratch/$name"
  if ! "${sandbox[@]}" --bind "$scratch/$name" /work /usr/bin/bash /fixtures/driver "$name" \
    >"$scratch/$name/transcript" 2>&1; then
    cat "$scratch/$name/transcript" >&2
    die "real pacman case: $name"
  fi
  printf 'PASS: %s\n' "$name"
  ((count += 1))
done
printf 'Passed %s isolated stock-pacman contracts.\n' "$count"
