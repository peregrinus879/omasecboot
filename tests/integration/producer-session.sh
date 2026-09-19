#!/usr/bin/env bash
# Real Core lifecycle/locks and actual Java framing/peer in fixture namespaces.
set -euo pipefail
umask 077
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 && -d $1 && -x $2/bin/javac ]] || die 'usage: producer-session.sh SOURCE_ROOT JDK25_HOME'
for tool in bwrap jq patch sha256sum realpath mktemp shellcheck; do command -v "$tool" >/dev/null || die "missing $tool"; done
repo=$(realpath "${BASH_SOURCE[0]%/*}/../..")
source_root=$(realpath "$1")
java_home=$(realpath "$2")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/producer-session.XXXXXX")
finish() {
  local status=$?
  if [[ ${PRODUCER_SESSION_KEEP:-0} == 1 ]]; then printf 'Retained session evidence: %s (status %s)\n' "$scratch" "$status"
  else rm -rf -- "$scratch"; fi
}
trap finish EXIT
# shellcheck source=tests/integration/lib/limine-sources.sh
source "$repo/tests/integration/lib/limine-sources.sh"
limine_prepare_sources "$source_root" "$scratch" "$repo/integrations/limine-entry-tool/source.json" "$repo/integrations/limine-entry-tool"
limine_prepare_java_dependencies "$scratch" "$repo/integrations/limine-entry-tool/source.json" "${LIMINE_NATIVE_JSON_JAR:-}"
mkdir -p "$scratch/fixtures" "$scratch/compiler"
cp "$repo/tests/integration/fixtures/ProducerSessionContract.java" "$scratch/fixtures/"
cat >"$scratch/fixtures/native" <<'SCRIPT'
#!/usr/bin/bash
set -euo pipefail
if [[ -e /work/recovery-copy-active && ${1:-} != --validate-managed-plan ]]; then
  printf 'unexpected producer/render invocation during retained copy\n' >/work/recovery-copy-forbidden
  exit 90
fi
entry=ProducerSessionContract
[[ ${1:-} != --decode-managed-stream && ${1:-} != --validate-managed-plan && ${1:-} != --validate-managed-targets ]] || entry=org.limine.entry.tool.Main
if [[ ${1:-} == publish-prepare || ${1:-} == publish-apply ]]; then printf 'worker executable entered\n' >"/work/context-worker-${1#publish-}"; fi
if [[ ${1:-} == --decode-managed-stream && ${SESSION_EXIT_FIXTURE:-} == decoder-exit-* ]]; then
  [[ $SESSION_EXIT_FIXTURE == decoder-exit-0 || $SESSION_EXIT_FIXTURE == decoder-exit-19 ]] || exit 90
  # Finish the actual strict decoder before delivering EOF. The wrapper itself
  # stays alive until Core's real identity read, on an independent exit gate.
  rc=0
  /jdk/bin/java -Xmx128m -XX:ActiveProcessorCount=2 -XX:-UsePerfData -Duser.home=/work/home \
    -cp /classes:/dependencies/jackson-core-3.2.2.jar "$entry" "$@" || rc=$?
  printf '%s\n' "$rc" >/work/strict-decoder-status
  (( rc == 0 )) || exit "$rc"
  exec 1>&-
  touch /work/decoder-exit-ready
  IFS= read -r -t 15 gate </work/decoder-exit-gate
  [[ $gate == exit ]] || exit 90
  exit "${SESSION_EXIT_FIXTURE##*-}"
fi
launcher=()
if [[ ${1:-} == publish-apply && ${2:-} == publish-native-namespace ]]; then
  [[ ${MOUNT_CUSTODY_FIXTURE:-} == 1 ]] || exit 90
  readlink /proc/self/ns/mnt >/work/worker-namespace-before
  printf '%s\n' "$$" >/work/worker-exec-pid
  # unshare execs the actual bound JVM at the same PID, with all original FDs.
  launcher=(/usr/bin/unshare --mount --propagation unchanged)
fi
exec "${launcher[@]}" /jdk/bin/java -Xmx128m -XX:ActiveProcessorCount=2 -XX:-UsePerfData -Duser.home=/work/home \
  --add-opens java.base/java.io=ALL-UNNAMED \
  -cp /classes:/dependencies/jackson-core-3.2.2.jar "$entry" "$@"
SCRIPT
chmod 755 "$scratch/fixtures/native"
cat >"$scratch/fixtures/session-child" <<'SCRIPT'
#!/usr/bin/bash
set -euo pipefail
case $1 in
  ignore) trap '' TERM ;;
esac
touch /work/child-ready
IFS= read -r -t 30 gate <&"$3"
[[ $gate == exit ]] || exit 90
exit "$2"
SCRIPT
chmod 755 "$scratch/fixtures/session-child"
cat >"$scratch/fixtures/dd" <<'SCRIPT'
#!/usr/bin/bash
set -euo pipefail
output=''
for argument in "$@"; do [[ $argument != of=* ]] || output=${argument#of=}; done
if [[ $output == /work/state/transactions/*/.publication-original.* && $(</work/signer-case) == publish-original-copy-failure ]]; then
  printf 'original configuration dd copy failed\n' >/work/original-fault
  exit 73
fi
if [[ -f /work/grow-source && -n $output ]]; then
  /usr/bin/stat -Lc %s /work/input >/work/original-copy-size
  /real/dd if=/dev/zero of=/work/input bs=131072 count=1 oflag=append conv=notrunc status=none
fi
/real/dd "$@"
if [[ -f /work/grow-source && -n $output ]]; then /usr/bin/stat -Lc %s "$output" >/work/observed-copy-size; fi
SCRIPT
chmod 755 "$scratch/fixtures/dd"
cat >"$scratch/fixtures/mount-custody" <<'SCRIPT'
#!/usr/bin/bash
# Independent witnesses, not replacements for Core/native custody predicates.
set -euo pipefail
[[ ${MOUNT_CUSTODY_FIXTURE:-} == 1 && -s /work/mount-stages.json ]] || exit 90
mount_id() {
  local line value=''
  while IFS= read -r line; do
    if [[ $line == mnt_id:* ]]; then
      [[ -z $value && $line =~ ^mnt_id:[[:blank:]]+([1-9][0-9]*)$ ]] || return 1
      value=${BASH_REMATCH[1]}
    fi
  done <"/proc/$$/fdinfo/$1"
  [[ -n $value ]] && printf '%s\n' "$value"
}
snapshot() {
  local path paths
  paths=$(jq -er '[.[] | .target, .stage.path] | unique[]' /work/mount-stages.json)
  while IFS= read -r path; do
    [[ $path == /boot/* && -f $path && ! -L $path ]] || return 1
    printf '%s ' "$path"
    stat -Lc '%d:%i %f %u:%g' "$path"
    sha256sum "$path"
  done <<<"$paths"
}
case $1 in
  snapshot)
    [[ $2 =~ ^[a-z-]+$ ]] || exit 90
    snapshot >"/work/mount-witness-$2"
    ;;
  bind)
    path=$2
    [[ $path == /boot/EFI/Linux || $path == /boot/limine.conf ]] ||
      jq -e --arg path "$path" 'any(.[]; .stage.path == $path)' /work/mount-stages.json >/dev/null
    snapshot >/work/mount-witness-before-bind
    cmp /work/mount-witness-prepared /work/mount-witness-before-bind
    namespace=$(readlink /proc/self/ns/mnt)
    exec 3<"$path"
    before=$(mount_id 3)
    identity=$(stat -Lc '%d:%i %f %u:%g' /proc/self/fd/3)
    rc=0
    /usr/bin/mount --no-mtab --bind -- "$path" "$path" || rc=$?
    printf '%s\n' "$rc" >/work/mount-command-result
    if (( rc != 0 )); then
      printf 'BLOCKER: private namespace self-bind failed\n' >/work/mount-blocker
      exit 90
    fi
    exec 4<"$path"
    after=$(mount_id 4)
    [[ $before != "$after" && $(mount_id 3) == "$before" && $path -ef /proc/self/fd/3 && $path -ef /proc/self/fd/4 ]]
    [[ $(stat -Lc '%d:%i %f %u:%g' /proc/self/fd/3) == "$identity" && $(stat -Lc '%d:%i %f %u:%g' /proc/self/fd/4) == "$identity" ]]
    [[ $(readlink /proc/self/ns/mnt) == "$namespace" ]]
    snapshot >/work/mount-witness-after-bind
    cmp /work/mount-witness-prepared /work/mount-witness-after-bind
    jq -cn --arg path "$path" --arg before "$before" --arg after "$after" --arg identity "$identity" --arg namespace "$namespace" \
      '{path:$path,before_mount:$before,after_mount:$after,identity:$identity,namespace:$namespace,same_object:true}' >/work/mount-bind-proof.json
    ;;
  unmount)
    path=$(jq -er '.path' /work/mount-bind-proof.json)
    rc=0
    /usr/bin/umount --no-mtab -- "$path" || rc=$?
    printf '%s\n' "$rc" >/work/unmount-command-result
    if (( rc != 0 )); then
      printf 'BLOCKER: private namespace unmount failed\n' >/work/mount-blocker
      exit 90
    fi
    exec 3<"$path"
    [[ $(mount_id 3) == "$(jq -r '.before_mount' /work/mount-bind-proof.json)" ]]
    [[ $(stat -Lc '%d:%i %f %u:%g' /proc/self/fd/3) == "$(jq -r '.identity' /work/mount-bind-proof.json)" ]]
    snapshot >/work/mount-witness-unmounted
    cmp /work/mount-witness-prepared /work/mount-witness-unmounted
    printf 'original mount and all file bytes/inodes restored\n' >/work/mount-unmounted-proof
    ;;
  *) exit 90 ;;
esac
SCRIPT
chmod 755 "$scratch/fixtures/mount-custody"
cat >"$scratch/fixtures/context-python" <<'SCRIPT'
#!/usr/bin/bash -p
# Fixed interpreter binding only. Core still opens/hashes the actual helper,
# interpreter and public certificate. No hardware acquisition is exercised here.
set -euo pipefail
printf 'fixture interpreter entered\n' >/work/context-wrapper-entered
trap 'printf "fixture interpreter assertion line %s\n" "$LINENO" >/work/context-wrapper-error' ERR
[[ $# == 15 && $1 == -I && $2 == -S && $3 =~ ^/proc/[0-9]+/fd/[0-9]+$ ]]
[[ $4 == --root-fd && $6 == --esp-fd && $8 == --root-path && $9 == / && ${10} == --esp-path && ${11} == /boot &&
   ${12} == --config-path && ${13} == /boot/limine.conf && ${14} == --certificate-fd ]]
[[ $5 =~ ^[0-9]+$ && $7 =~ ^[0-9]+$ && ${15} =~ ^[0-9]+$ ]]
[[ -d /proc/self/fd/$5 && / -ef /proc/self/fd/$5 && -d /proc/self/fd/$7 && /boot -ef /proc/self/fd/$7 ]]
certificate=/var/lib/sbctl/keys/db/db.pem
[[ -f /proc/self/fd/${15} && $certificate -ef /proc/self/fd/${15} ]]
[[ $(readlink -e "$3") == /core/lib/publication-context.py && -f $3 ]]
cmp "$3" /core/lib/publication-context.py
helper_hash=$(sha256sum "$3"); helper_hash=${helper_hash%% *}
[[ $helper_hash == "$(</fixtures/context-helper.sha256)" ]]
# Bash adds its own PWD/SHLVL/_; the interpreter must receive only Core's three
# explicit environment entries, never the caller's injected Python/session data.
[[ $LC_ALL == C && $PATH == /usr/bin && $HOME == /nonexistent ]]
while IFS= read -r variable; do
  case $variable in LC_ALL|PATH|HOME|PWD|SHLVL|_) ;; *) exit 90 ;; esac
done < <(compgen -e)
der=$(openssl x509 -in "/proc/self/fd/${15}" -outform DER | sha256sum); der=${der%% *}
pem=$(sha256sum "/proc/self/fd/${15}"); pem=${pem%% *}
jq -cn --arg helper "$helper_hash" --arg der "$der" --arg pem "$pem" \
  '{helper_sha256:$helper,certificate_der_sha256:$der,certificate_pem_sha256:$pem,isolated_arguments:true,clean_environment:true,root_directory:true,esp_directory:true,public_certificate:true}' >>/work/context-wrapper.jsonl
mode=$(</work/context-mode)
case $mode in
  unknown) printf '{"format":"omasecboot-publication-context","schema":1,"complete":false,"context":null}\n'; exit 0 ;;
  malformed) printf '{"format":'; exit 0 ;;
  capture-drift)
    # Public bytes only: make the held certificate differ from Core's pre-read.
    chmod 600 "$certificate"
    printf '\n' >>"$certificate"
    chmod 400 "$certificate"
    printf 'public certificate bytes changed during capture\n' >/work/context-capture-drift
    ;;
  sbctl-appeared|sbctl-inplace)
    # Change only valid metadata, after Core's first boundary observation. Build
    # the response on both sides to distinguish read-span refusal from bad data.
    response=$(jq -c --arg der "$der" '.local_db_certificate_der_sha256=$der |
      {format:"omasecboot-publication-context",schema:1,complete:true,context:.}' /work/context-platform.json)
    config=/etc/sbctl/sbctl.conf
    if [[ $mode == sbctl-appeared ]]; then
      [[ ! -e $config && ! -L $config ]]
      mkdir -p /etc/sbctl
      printf 'landlock: true\n' >"$config"
    else
      [[ -f $config && $(<"$config") == 'landlock: true' ]]
      identity=$(stat -Lc '%d:%i' "$config")
      printf '# same default policy, different bytes\n' >>"$config"
      [[ $(stat -Lc '%d:%i' "$config") == "$identity" ]]
    fi
    cp "$config" /work/context-sbctl-post.conf
    [[ $(sha256sum "/proc/self/fd/${15}") == "$pem  /proc/self/fd/${15}" ]]
    observed=$(openssl x509 -in "/proc/self/fd/${15}" -outform DER | sha256sum)
    [[ ${observed%% *} == "$der" ]]
    printf '%s\n' "$response" >/work/context-sbctl-response.json
    printf 'valid sbctl configuration changed inside fixture interpreter\n' >/work/context-sbctl-injected
    ;;
esac
observed=$(jq -c --arg der "$der" '.local_db_certificate_der_sha256=$der |
  {format:"omasecboot-publication-context",schema:1,complete:true,context:.}' /work/context-platform.json)
[[ $mode != sbctl-* || $observed == "$response" ]]
printf '%s\n' "$observed"
SCRIPT
chmod 755 "$scratch/fixtures/context-python"
sha256sum "$repo/lib/publication-context.py" | cut -d ' ' -f 1 >"$scratch/fixtures/context-helper.sha256"
cat >"$scratch/fixtures/no-platform-query" <<'SCRIPT'
#!/usr/bin/bash
printf 'unexpected hardware acquisition command\n' >/work/context-host-query
exit 90
SCRIPT
chmod 755 "$scratch/fixtures/no-platform-query"
# Preserve actual sbctl bytes while giving the copied executable fixture-root
# ownership in the user namespace, as required by its real metadata boundary.
cp "$(realpath "$(type -P sbctl)")" "$scratch/fixtures/sbctl"
cat >"$scratch/fixtures/sbctl-call" <<'SCRIPT'
#!/usr/bin/bash -p
# Fixture-only executable binding, like the JVM/interpreter bindings above.
# Core hashes/opens this fixed wrapper; the existing real sbctl binary handles
# every ordinary call. Package/ELF admission is outside this seam's proof scope.
set -euo pipefail
trap 'printf "sbctl fixture assertion line %s\n" "$LINENO" >/work/signer-boundary-error' ERR
argv=("$@")
phase=bootstrap mode=ordinary bound=false frozen=null
[[ ! -f /work/signer-phase ]] || phase=$(</work/signer-phase)
[[ ! -f /work/signer-case ]] || mode=$(</work/signer-case)
# Record entry before any fixture assertions: a wrapper-side refusal must never
# masquerade as Core refusing to launch a key-using command.
jq -cn --argjson pid "$$" --arg phase "$phase" --args \
  '{event:"entry",pid:$pid,phase:$phase,argv:$ARGS.positional}' -- "${argv[@]}" >>/work/signer-commands.jsonl
if [[ ${1:-} == --config ]]; then
  [[ $0 =~ ^/proc/[0-9]+/fd/[0-9]+$ && $0 -ef /usr/bin/sbctl && $2 =~ ^/proc/[0-9]+/fd/[0-9]+$ && -f $2 ]]
  config=$2
  path=$(readlink -e "$config")
  [[ $path == /work/state/transactions/*/.publication-sbctl-config.* && $(stat -Lc '%a' "$config") == 400 ]]
  hash=$(sha256sum "$config"); hash=${hash%% *}
  if [[ -f /work/signer-policy.json ]]; then
    state=$(jq -r '.configuration_state' /work/signer-policy.json)
    if [[ $state == absent ]]; then
      expected=$(printf '{}\n' | sha256sum); expected=${expected%% *}
    else expected=$(jq -r '.configuration_sha256' /work/signer-policy.json); fi
    [[ $hash == "$expected" ]]
  fi
  frozen=$(jq -cn --arg fd "$config" --arg path "$path" --arg hash "$hash" --arg text "$(<"$config")" \
    '{fd:$fd,path:$path,sha256:$hash,text:$text}')
  bound=true
  shift 2
fi
operation=$1
jq -cn --argjson pid "$$" --arg phase "$phase" --arg operation "$operation" --arg executable "$0" \
  --argjson bound "$bound" --argjson frozen "$frozen" --args \
  '{event:"invoke",pid:$pid,phase:$phase,operation:$operation,executable:$executable,bound:$bound,frozen:$frozen,argv:$ARGS.positional}' \
  -- "${argv[@]}" >>/work/signer-commands.jsonl
injected=false
if [[ $phase == prepare && $operation == sign && $mode == publish-signer-*-span && ! -e /work/signer-span-injected ]]; then
  [[ $bound == true && $2 == --output && $3 == "$4" && $(<"$config") == 'landlock: true' ]]
  control=/etc/sbctl/sbctl.conf
  [[ $mode != publish-signer-cert-span ]] || control=/var/lib/sbctl/keys/db/db.pem
  before=$(LC_ALL=C TZ=UTC stat -Lc '%d:%i:%f:%u:%g:%s:%y:%z' "$control")
  metadata_before=$(LC_ALL=C TZ=UTC stat -Lc '%d:%i:%f:%u:%g:%s:%y' "$control")
  [[ $mode != publish-signer-config-restore-span ]] || touch -r "$control" /work/signer-time-reference
  if [[ $mode == publish-signer-cert-span ]]; then chmod 600 "$control"
  else printf '# valid invocation-time change\n' >>"$control"; fi
  cp "$config" /work/signer-frozen.conf
  printf 'control changed at the bound sbctl sign invocation\n' >/work/signer-span-injected
  injected=true
fi
absent_injected=false
if [[ $phase == prepare && $operation == verify && $mode == publish-signer-absent-* && ! -e /work/signer-absent-injected ]]; then
  [[ $bound == true && $# == 3 && $2 == --json && $(<"$config") == '{}' && ! -e /etc/sbctl/sbctl.conf && ! -L /etc/sbctl/sbctl.conf ]]
  parent=$(jq -r '.configuration_span' /work/signer-absent-before.json)
  parent_existed=false
  if [[ $mode == publish-signer-absent-sbctl-parent ]]; then
    [[ $parent == /etc/sbctl && -d /etc/sbctl && ! -L /etc/sbctl ]]
    parent_existed=true
  else [[ $parent == /etc && ! -e /etc/sbctl && ! -L /etc/sbctl ]]; fi
  parent_before=$(LC_ALL=C TZ=UTC stat -Lc '%d:%i:%f:%u:%g:%s:%y:%z' "$parent")
  ctime_before=$(LC_ALL=C TZ=UTC stat -Lc '%z' "$parent")
  [[ $parent_before == "$(jq -r '.configuration_stamp' /work/signer-absent-before.json)" ]]
  [[ $parent_existed == true ]] || mkdir /etc/sbctl
  printf 'landlock: true\n' >/etc/sbctl/sbctl.conf
  cp /etc/sbctl/sbctl.conf /work/signer-absent-transient.conf
  cp "$config" /work/signer-frozen.conf
  printf 'absent config created at the managed verify invocation\n' >/work/signer-absent-injected
  absent_injected=true
fi
status=0 synthetic=false verification=null tool_result=real
if [[ $phase == executor-check && $operation == verify && ( $mode == publish-signer-unsigned-* || $mode == publish-signer-result-* ) &&
      $3 == "$(</work/signer-negative-target)" && ! -e /work/signer-negative-injected ]]; then
  [[ $bound == true && $# == 3 && $2 == --json && $(</work/preparation-result) == 0 ]]
  # Substitute only this existing command's output/status after real preparation.
  # Positive-looking JSON with a nonzero status must still be a technical error.
  case $mode in
    publish-signer-unsigned-*)
      jq -cn --arg file "$3" '[{file_name:$file,is_signed:0}]' >/work/signer-unsigned-result.json
      cat /work/signer-unsigned-result.json
      synthetic=true; tool_result=unsigned
      verification=$(</work/signer-unsigned-result.json) ;;
    publish-signer-result-malformed-*)
      printf '{"file_name":' >/work/signer-tool-output
      cat /work/signer-tool-output
      tool_result=malformed ;;
    publish-signer-result-nonzero-*)
      jq -cn --arg file "$3" '[{file_name:$file,is_signed:1}]' >/work/signer-tool-output
      cat /work/signer-tool-output
      verification=$(</work/signer-tool-output); status=19; tool_result=nonzero ;;
  esac
  printf '%s result injected only at executor input/stage check\n' "$tool_result" >/work/signer-negative-injected
elif [[ $operation == verify && ${2:-} == --json ]]; then
  output=$(/real/sbctl "${argv[@]}") || status=$?
  printf '%s\n' "$output"
  verification=$(jq -cse 'if length == 1 then .[0] else null end' <<<"$output" 2>/dev/null) || verification=null
else /real/sbctl "${argv[@]}" || status=$?; fi
if [[ $absent_injected == true ]]; then
  # Restore exactly the initial absence before Core's post-command observation.
  rm -- /etc/sbctl/sbctl.conf
  [[ $parent_existed == true ]] || rm -d -- /etc/sbctl
  [[ ! -e /etc/sbctl/sbctl.conf && ! -L /etc/sbctl/sbctl.conf ]]
  if [[ $parent_existed == true ]]; then [[ -d /etc/sbctl && ! -L /etc/sbctl ]]
  else [[ ! -e /etc/sbctl && ! -L /etc/sbctl ]]; fi
  parent_after=$(LC_ALL=C TZ=UTC stat -Lc '%d:%i:%f:%u:%g:%s:%y:%z' "$parent")
  ctime_after=$(LC_ALL=C TZ=UTC stat -Lc '%z' "$parent")
  [[ $parent_before != "$parent_after" && $ctime_before != "$ctime_after" ]]
  observed=$(sha256sum "$config"); [[ ${observed%% *} == "$hash" ]]
  jq -cn --arg parent "$parent" --arg before "$parent_before" --arg after "$parent_after" \
    --arg ctime_before "$ctime_before" --arg ctime_after "$ctime_after" --argjson parent_existed "$parent_existed" \
    --argjson frozen "$frozen" --argjson status "$status" \
    '{parent:$parent,before_stamp:$before,after_stamp:$after,before_ctime:$ctime_before,after_ctime:$ctime_after,
      parent_existed:$parent_existed,config_absent_before:true,config_absent_after:true,original_layout_restored:true,
      frozen:$frozen,real_status:$status}' >/work/signer-absent-span.json
fi
if [[ $injected == true ]]; then
  case $mode in
    publish-signer-config-restore-span)
      printf 'landlock: true\n' >"$control"
      touch -r /work/signer-time-reference "$control" ;;
    publish-signer-cert-span) chmod 400 "$control" ;;
  esac
  after=$(LC_ALL=C TZ=UTC stat -Lc '%d:%i:%f:%u:%g:%s:%y:%z' "$control")
  metadata_after=$(LC_ALL=C TZ=UTC stat -Lc '%d:%i:%f:%u:%g:%s:%y' "$control")
  [[ $before != "$after" ]]
  observed=$(sha256sum "$config"); [[ ${observed%% *} == "$hash" ]]
  jq -cn --arg control "$control" --arg before "$before" --arg after "$after" --argjson status "$status" \
    --arg metadata_before "$metadata_before" --arg metadata_after "$metadata_after" --argjson frozen "$frozen" \
    '{control:$control,before_stamp:$before,after_stamp:$after,metadata_before:$metadata_before,metadata_after:$metadata_after,real_status:$status,frozen:$frozen}' >/work/signer-span.json
fi
jq -cn --argjson pid "$$" --arg phase "$phase" --arg operation "$operation" --argjson status "$status" --argjson synthetic "$synthetic" --argjson verification "$verification" --arg tool_result "$tool_result" \
  '{event:"result",pid:$pid,phase:$phase,operation:$operation,status:$status,synthetic_unsigned:$synthetic,verification:$verification,tool_result:$tool_result}' >>/work/signer-commands.jsonl
exit "$status"
SCRIPT
chmod 755 "$scratch/fixtures/sbctl-call"
cat >"$scratch/fixtures/case" <<'SCRIPT'
#!/usr/bin/bash
# shellcheck disable=SC1090,SC1091,SC2154,SC2329
set -euo pipefail
for module in common lifecycle records software checks discover sign enroll; do source "/core/lib/$module.sh"; done
[[ $1 == inherited-flag-* ]] || source /core/lib/producer-session.sh
[[ $1 == inherited-flag-* ]] || source /core/lib/publication.sh
if [[ $1 == publish-signer-absent-* ]]; then
  # Observe the actual Core gate's result, without replacing its decisions or
  # running another command. The command-boundary fixture supplies the mutation.
  definition=$(declare -f publication_run_sbctl)
  eval "${definition/publication_run_sbctl/fixture_real_publication_run_sbctl}"
  publication_run_sbctl() {
    local status=0
    fixture_real_publication_run_sbctl "$@" || status=$?
    jq -cn --argjson status "$status" --args '{status:$status,argv:$ARGS.positional}' -- "$@" >>/work/signer-managed-gate.jsonl
    return "$status"
  }
fi
state_dir_path() { printf '/work/state\n'; }
pacman_database_lock_path() { printf '/work/pacman-db.lck\n'; }
# Explicit namespace package/path metadata, not package-admission evidence. The
# real dependency and sbctl metadata boundary functions are used; no key reader.
publication_context_helper_path() { printf '/core/lib/publication-context.py\n'; }
publication_context_python_path() { printf '/fixtures/context-python\n'; }
producer_package_version() { [[ $1 == sbctl ]] && printf '%s\n' "$SUPPORTED_SBCTL_VERSION"; }
producer_file_owner_package() {
  case $1 in
    /core/lib/publication-context.py) printf 'omasecboot\n' ;;
    /fixtures/context-python) printf 'python\n' ;;
    /usr/bin/sbctl) printf 'sbctl\n' ;;
    *) return 1 ;;
  esac
}
# Inject only at a real collection boundary, after actual worker exit and Core's
# final effect proof. Acquisition stays the production wrapper in every case.
if [[ $1 != inherited-flag-* ]]; then
  definition=$(declare -f publication_collect_stable_context)
  eval "${definition/publication_collect_stable_context/fixture_real_publication_collect_stable_context}"
fi
publication_collect_stable_context() {
  local status=0
  if [[ ${fixture_context_terminal:-false} == true && ! -e /work/context-terminal-injected ]]; then
    [[ -z $_producer_session_worker_pid && -z $_producer_session_decoder_pid &&
       ! -e /proc/$fixture_context_worker_pid && ! -e /proc/$fixture_context_decoder_pid ]] || return 1
    publication_all_effects_applied || return 1
    case $CASE in
      publish-context-after-cert)
        # A second actual sbctl PUBLIC certificate supplies genuinely different
        # DER. Neither the seam nor its evidence opens a private key.
        install -m400 /var/lib/sbctl/keys/KEK/KEK.pem /var/lib/sbctl/keys/db/db.pem ;;
      publish-context-after-platform) fixture_context_change '.esp.partition_uuid="cccccccc-cccc-4ccc-8ccc-cccccccccccc"' ;;
      *) return 1 ;;
    esac
    printf 'actual workers collected; final effects proved; context changed before re-collection\n' >/work/context-terminal-injected
  fi
  fixture_real_publication_collect_stable_context || status=$?
  jq -cn --argjson status "$status" --argjson terminal "${fixture_context_terminal:-false}" \
    '{status:$status,after_worker_exit:$terminal}' >>/work/context-collections.jsonl
  return "$status"
}
fixture_context_change() {
  jq -c "$1" /work/context-platform.json >/work/context-platform.next || return 1
  mv /work/context-platform.next /work/context-platform.json
}
fixture_context_sbctl_boundary() {
  local status=0 identity=null config certificate der
  validate_sbctl_enrollment_boundary || status=$?
  printf '%s\n' "$status" >"/work/context-sbctl-$1-result"
  (( status == 0 )) || return "$status"
  config=$(sbctl_config_path) || return 1
  if [[ -f $config ]]; then identity=$(jq -cn --arg identity "$(stat -Lc '%d:%i' "$config")" '$identity'); fi
  certificate="$_sbctl_keydir/db/db.pem"
  der=$(openssl x509 -in "$certificate" -outform DER | sha256sum) || return 1
  jq -cn --arg state "$_sbctl_config_state" --arg hash "$_sbctl_config_hash" --argjson identity "$identity" \
    --arg executable "$_sbctl_executable_hash" --arg certificate "$certificate" \
    --arg pem "$(sha256_file "$certificate")" --arg der "${der%% *}" \
    '{config:{state:$state,sha256:$hash,identity:$identity},executable_sha256:$executable,
      certificate:{path:$certificate,pem_sha256:$pem,der_sha256:$der}}' >"/work/context-sbctl-$1.json"
}
fixture_context_setup() {
  printf 'valid\n' >/work/context-mode
  # Stable identity is deliberately simulated. Live FD/mount/object custody and
  # real sbctl signing are independent; no Btrfs/FAT/host proof is claimed.
  jq -cn '{schema_version:1,architecture:"x86_64",machine_id:"11111111111111111111111111111111",
    configuration_path:"/boot/limine.conf",local_db_certificate_der_sha256:("0"*64),
    root:{path:"/",filesystem_type:"btrfs",filesystem_uuid:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      subvolume:{kind:"subvolume",id:"256",uuid:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}},
    esp:{path:"/boot",partition_scheme:"gpt",partition_type:"c12a7328-f81f-11d2-ba4b-00a0c93ec93b",
      partition_uuid:"dddddddd-dddd-4ddd-8ddd-dddddddddddd",filesystem_type:"vfat",filesystem_uuid:"1234-ABCD"}}' >/work/context-platform.json
  case $CASE in
    publish-context-unknown|publish-context-malformed|publish-context-capture-drift) printf '%s\n' "${CASE#publish-context-}" >/work/context-mode ;;
    publish-context-machine) fixture_context_change '.machine_id="22222222222222222222222222222222"' ;;
    publish-context-path) fixture_context_change '.configuration_path="/boot/other.conf"' ;;
    publish-context-esp) fixture_context_change '.esp.path="/other" | .configuration_path="/other/limine.conf"' ;;
    publish-context-shape) fixture_context_change '.root.subvolume.id=256' ;;
    publish-context-sbctl-*)
      printf '%s\n' "${CASE#publish-context-}" >/work/context-mode
      if [[ $CASE == publish-context-sbctl-inplace ]]; then
        mkdir -p /etc/sbctl
        printf 'landlock: true\n' >/etc/sbctl/sbctl.conf
      fi
      fixture_context_sbctl_boundary before || return 1
      ;;
    publish-signer-absent-*)
      [[ ! -e /etc/sbctl/sbctl.conf && ! -L /etc/sbctl/sbctl.conf ]] || return 1
      if [[ $CASE == publish-signer-absent-sbctl-parent ]]; then mkdir -p /etc/sbctl
      else [[ ! -e /etc/sbctl && ! -L /etc/sbctl ]] || return 1; fi
      fixture_context_sbctl_boundary before || return 1
      ;;
    publish-signer-*)
      mkdir -p /etc/sbctl
      printf 'landlock: true\n' >/etc/sbctl/sbctl.conf
      fixture_context_sbctl_boundary before || return 1
      ;;
  esac
  # Deliberately contaminate the caller, proving env -i at the actual wrapper.
  export PYTHONPATH=/work/injected PYTHONHOME=/work/injected CONTEXT_INJECTED=fixture
  stat -Lc '%d:%i' /boot/limine.conf >/work/context-config-before
  openssl x509 -in /var/lib/sbctl/keys/db/db.pem -outform DER | sha256sum | cut -d ' ' -f 1 >/work/context-cert-before
  cp /work/context-platform.json /work/context-original-platform.json
}
fixture_context_sync_fault() {
  local path=$1 manifest record failures=0
  [[ -n ${fixture_context_fault:-} ]] || return 0
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  if [[ $fixture_context_fault == record && $path == "${manifest%/*}"/publication-*.json && -f $path ]]; then
    jq -e '.kind == "invocation-start" and .schema_version == 2' "$path" >/dev/null || return 0
  elif [[ $fixture_context_fault == head && $path == "$manifest" ]]; then
    record=$(jq -r '.publication_records[-1].path // empty' "$manifest") || return 1
    [[ -n $record ]] && jq -e '.kind == "invocation-start" and .schema_version == 2' "$record" >/dev/null || return 0
  else return 0; fi
  [[ ! -e /work/context-sync-faults ]] || failures=$(wc -l </work/context-sync-faults)
  (( failures < ${fixture_context_fault_limit:-2} )) || return 0
  fixture_start_head "refused-$fixture_context_fault" || return 1
  printf '%s\n' "$fixture_context_fault" >>/work/context-sync-faults
  return 1
}
# Read actual on-disk heads at the syscall/durability boundaries. The outer
# oracle checks these observations independently of Core's manifest validation.
fixture_start_head() {
  local manifest record reference=null document=null original=null path
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  reference=$(jq -c '.publication_records[0] // null' "$manifest") || return 1
  if [[ $reference != null ]]; then
    record=$(jq -r '.path' <<<"$reference") || return 1
    document=$(jq -c . "$record") || return 1
    path=$(jq -r '.body.original_configuration.path' <<<"$document") || return 1
    original=$(fixture_original_state "$path") || return 1
  fi
  jq -cn --arg boundary "$1" --argjson manifest "$(jq -c '{file_rollback_policy,publication_records}' "$manifest")" \
    --argjson record "$document" --argjson original "$original" \
    --arg config_identity "$(stat -Lc '%d:%i' /boot/limine.conf)" --arg config_hash "$(sha256_file /boot/limine.conf)" \
    --argjson worker_started "$([[ -e /work/context-worker-prepare || -e /work/context-worker-apply ]] && printf true || printf false)" \
    '{boundary:$boundary,manifest:$manifest,record:$record,original:$original,
      configuration:{identity:$config_identity,sha256:$config_hash},worker_started:$worker_started}' >>/work/start-heads.jsonl
}
fixture_original_state() {
  jq -cn --arg path "$1" --arg sha256 "$(sha256_file "$1")" --argjson bytes "$(stat -Lc %s "$1")" \
    --arg identity "$(stat -Lc '%d:%i' "$1")" --arg mode "$(stat -Lc %a "$1")" --arg owner "$(stat -Lc '%u:%g' "$1")" \
    '{path:$path,sha256:$sha256,bytes:$bytes,identity:$identity,mode:$mode,owner:$owner}'
}
mv() {
  local status=0 destination=${!#}
  /usr/bin/mv "$@" || status=$?
  if [[ ${fixture_start_observing:-false} == true && $destination == "$(lifecycle_manifest_path "$_transaction_id")" ]]; then
    printf '%s\n' "$status" >>/work/start-manifest-renames
    fixture_start_head manifest-rename || printf 'manifest observation failed\n' >/work/start-observation-error
  fi
  return "$status"
}
fixture_original_sync_fault() {
  local path=$1 directory destination
  [[ $CASE == publish-original-* && ! -e /work/original-fault ]] || return 0
  directory=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  destination="$directory/publication-data-11111111-1111-4111-8111-111111111111-original-configuration"
  case $CASE in
    publish-original-temp-sync) [[ $path == "$directory"/.publication-original.* ]] || return 0 ;;
    publish-original-data-sync) [[ $path == "$destination" ]] || return 0 ;;
    publish-original-directory-sync) [[ $path == "$directory" && -f $destination ]] || return 0 ;;
    publish-original-candidate-collision)
      [[ $path == "$directory"/.publication-original.* ]] || return 0
      printf 'foreign original-copy candidate\n' >"$destination"
      chmod 400 "$destination"
      fixture_original_state "$destination" >/work/original-foreign-before.json || return 1
      printf 'collision before actual create-once rename\n' >/work/original-fault
      return 0 ;;
    publish-original-source-drift)
      [[ $path == "$destination" ]] || return 0
      fixture_original_state "$destination" >/work/original-copy-before.json || return 1
      printf '# source drift after original copy\n' >>/boot/limine.conf
      printf 'source changed after original-copy publication\n' >/work/original-fault
      return 0 ;;
    *) return 0 ;;
  esac
  fixture_start_head original-sync-refused || return 1
  printf '%s\n' "$path" >/work/original-fault
  return 1
}
fixture_start_parts() {
  local part reference body actual status
  find_publication_record "$_publication_invocation" invocation-start || return 1
  reference=$_publication_found_reference body=$_publication_found_body
  for part in intent context original_configuration recovery; do
    find_publication_authority_part "$_publication_invocation" "$part" || return 1
    json_is '.[0] == .[1]' "[$reference,$_publication_found_reference]" || return 1
    actual=$(jq -c --arg part "$part" '.[$part]' <<<"$body") || return 1
    json_is '.[0] == .[1]' "[$actual,$_publication_found_body]" || return 1
    [[ $_publication_found_container_kind == invocation-start && $_publication_found_projection == ".body.$part" ]] || return 1
    jq -cn --arg part "$part" --arg container "$_publication_found_container_kind" --arg projection "$_publication_found_projection" \
      --argjson reference "$_publication_found_reference" --argjson body "$_publication_found_body" \
      '{part:$part,container:$container,projection:$projection,reference:$reference,body:$body}' >>/work/start-typed-parts.jsonl
  done
  for part in intent context; do
    status=0; find_publication_record "$_publication_invocation" "$part" || status=$?
    [[ $status == 1 && -z $_publication_found_reference && -z $_publication_found_body ]] || return 1
  done
  printf 'actual-kind lookup does not fabricate legacy records\n' >/work/start-actual-kind-proof
}
fixture_intent_snapshot() {
  local label=$1 record original
  find_publication_record "$_publication_invocation" invocation-start || return 1
  printf '%s\n' "$_publication_found_reference" >"/work/intent-reference-$label.json"
  record=$(jq -r '.path' <<<"$_publication_found_reference") || return 1
  original=$(jq -r '.original_configuration.path' <<<"$_publication_found_body") || return 1
  cp "$record" "/work/intent-start-$label.json" || return 1
  fixture_original_state "$record" >"/work/intent-start-state-$label.json" || return 1
  fixture_original_state "$original" >"/work/intent-original-$label.json" || return 1
  cmp "$original" /work/config-before || return 1
  fixture_directory_journal >"/work/intent-journal-$label.json"
}
fixture_intent_begin() {
  local first_status=$1 retry=0 selected
  if [[ $CASE == *-head ]]; then
    [[ $first_status != 0 && $(wc -l </work/context-sync-faults) == 1 ]] || return 1
  else [[ $first_status == 0 ]] || return 1; fi
  # Faults are cleared before every retry/launch: a fresh sync failure cannot
  # hide the durable A versus memory B mismatch under test.
  fixture_context_fault=''
  fixture_intent_snapshot before || return 1
  jq -c '.publication.model |= (fromjson | .comment="same-invocation alternate model B" | tojson)' \
    /work/admitted-intent.json >/work/alternate-intent.json || return 1
  [[ $CASE != publish-intent-match-model ]] || return 0
  selected=$(</work/alternate-intent.json)
  [[ $CASE != publish-intent-retry-same* ]] || selected=$(</work/admitted-intent.json)
  publication_authority_begin "$_publication_invocation" "$selected" || retry=$?
  printf '%s\n' "$retry" >/work/intent-retry-result
  printf '%s\n' "$_publication_intent" >/work/intent-memory-after-retry.json
  printf '%s\n' "$_publication_stable_context" >/work/intent-context-after-retry.json
  fixture_start_head after-intent-retry || return 1
  fixture_intent_snapshot after-retry || return 1
  cp "$(lifecycle_manifest_path "$_transaction_id")" /work/intent-manifest-after-retry.json || return 1
  cmp /work/context-begin-manifest.json /work/intent-manifest-after-retry.json || return 1
  if [[ $CASE == publish-intent-retry-same* ]]; then [[ $retry == 0 ]] || return 1
  else [[ $retry != 0 ]] || return 1; fi
  # Deliberately proceed to the actual run_bound_producer_session launch even
  # after retry B failed. A later native constructor mismatch is not this gate.
}
fixture_context_begin() {
  local status=0 retry=0 record path original
  fixture_start_observing=true
  find /boot -mindepth 1 -printf '%P %y %D:%i\n' | sort >/work/start-boot-before
  fixture_start_head before-begin || return 1
  case $CASE in
    publish-intent-retry-*-head) fixture_context_fault='head'; fixture_context_fault_limit=1 ;;
    # Historical context fault names now exercise the containing atomic start.
    publish-context-record-*|publish-context-head-*)
      fixture_context_fault=${CASE#publish-context-}; fixture_context_fault=${fixture_context_fault%%-*}
      [[ $CASE != *-uncertain ]] || fixture_context_fault_limit=100 ;;
  esac
  publication_authority_begin 11111111-1111-4111-8111-111111111111 "$(</work/admitted-intent.json)" || status=$?
  fixture_start_head after-begin || return 1
  find /boot -mindepth 1 -printf '%P %y %D:%i\n' | sort >/work/start-boot-after
  cmp /work/start-boot-before /work/start-boot-after || return 1
  printf '%s\n' "$status" >/work/context-begin-result
  cp "$(lifecycle_manifest_path "$_transaction_id")" /work/context-begin-manifest.json || return 1
  if [[ $CASE == publish-intent-* ]]; then
    fixture_intent_begin "$status" || return 1
    status=0
  fi
  if [[ $CASE == publish-context-record-* || $CASE == publish-context-head-* ]]; then
    [[ $status != 0 && -s /work/context-sync-faults ]] || return 1
    for path in "$(dirname "$(lifecycle_manifest_path "$_transaction_id")")"/publication-*.json; do
      if jq -e '.kind == "invocation-start"' "$path" >/dev/null; then record=$path; break; fi
    done
    [[ -n ${record:-} ]] || return 1
    cp "$record" /work/context-candidate.json
    stat -Lc '%d:%i' "$record" >/work/context-candidate-inode
    original=$(jq -r '.body.original_configuration.path' "$record") || return 1
    fixture_original_state "$original" >/work/original-copy-before.json || return 1
    cmp "$original" /work/config-before || return 1
    if [[ $CASE == *-retry ]]; then
      append_publication_invocation_start "$_publication_invocation" "$_publication_intent" "$_publication_stable_context" \
        "$_publication_original_configuration" || retry=$?
      [[ $retry != 0 ]] || return 1
      printf '%s\n' "$retry" >/work/context-retry-result
      append_publication_invocation_start "$_publication_invocation" "$_publication_intent" "$_publication_stable_context" \
        "$_publication_original_configuration" || return 1
      fixture_start_head after-retry || return 1
      find /boot -mindepth 1 -printf '%P %y %D:%i\n' | sort >/work/start-boot-after
      cmp /work/start-boot-before /work/start-boot-after || return 1
      cmp "$record" /work/context-candidate.json || return 1
      [[ $(stat -Lc '%d:%i' "$record") == "$(</work/context-candidate-inode)" && ! -e /work/context-worker-prepare ]] || return 1
      fixture_original_state "$original" >/work/original-copy-after.json || return 1
      cmp /work/original-copy-before.json /work/original-copy-after.json || return 1
      cmp "$original" /work/config-before || return 1
      printf 'same complete start and private original-copy inode after two failed syncs, before any worker\n' >/work/context-retry-verified
      status=0
    else
      fixture_start_observing=false
      [[ $fixture_context_fault != head ]] || fixture_start_parts || return 1
      # Exercise the actual launch gate with unbound/uncertain start, rather
      # than relying only on the caller respecting begin's nonzero result.
      return 0
    fi
  fi
  fixture_start_observing=false
  if (( status != 0 )); then
    if [[ $CASE == publish-context-sbctl-* ]]; then
      # A separate call to the actual boundary must accept the changed config.
      # The collector's nonzero result must not be an invalid-policy refusal.
      fixture_context_sbctl_boundary after || return 1
      publication_context_matches_intent "$(jq -c '.context' /work/context-sbctl-response.json)" "$_publication_intent" || return 1
      printf 'post-change metadata and unchanged context independently accepted\n' >/work/context-sbctl-boundary-verified
    fi
    jq -e '.file_rollback_policy == "restore" and .publication_records == []' /work/context-begin-manifest.json >/dev/null || return 1
    if [[ $CASE == publish-original-source-drift ]]; then
      [[ $(sha256_file /boot/limine.conf) != "$(sha256_file /work/config-before)" ]] || return 1
    else cmp /work/config-before /boot/limine.conf || return 1; fi
    [[ $(stat -Lc '%d:%i' /boot/limine.conf) == "$(</work/context-config-before)" && ! -e /boot/EFI/Linux/contract_linux.efi ]] || return 1
    printf 'begin refused with restore policy and empty authority journal\n' >/work/context-capture-refused
    printf '%s\n' "$status" >/work/publication-result
    return "$status"
  fi
  fixture_start_parts || return 1
  case $CASE in
    publish-context-launch-record|publish-context-launch-head)
      fixture_context_fault=${CASE##*-}; fixture_context_fault_limit=100 ;;
  esac
}
# Invoke the actual predicate, then inject a pathname change at a later pass.
definition=$(declare -f producer_runtime_is_clear)
eval "${definition/producer_runtime_is_clear/fixture_runtime_is_clear}"
rebind_with_competitor() {
  mv /run/lock/boot-partition.lock /run/lock/old-boot.lock
  touch /run/lock/boot-partition.lock
  (exec 9>/run/lock/boot-partition.lock; /usr/bin/flock 9; touch /work/competitor-ready; exec sleep 30) &
  competitor=$!
  while [[ ! -f /work/competitor-ready ]]; do sleep 0.01; done
  rm /work/arm-late
}
producer_runtime_is_clear() {
  fixture_runtime_is_clear || return 1
  if [[ ${CASE:-} == late-lock-rebind && -f /work/arm-late ]]; then rebind_with_competitor; fi
}
flock() {
  /usr/bin/flock "$@" || return "$?"
  if [[ ${CASE:-} == post-lock-rebind && $* == '-n 201' && -f /work/arm-late ]]; then rebind_with_competitor; fi
}
# The worker fixture is a JVM launcher. All PID/start/UID/parent/transaction/lock
# checks remain production code; this seam binds its actual JVM and main class.
producer_session_worker_is_bound() {
  [[ $(control_file_identity "/proc/$1/exe") == "$(control_file_identity /jdk/bin/java)" ]] &&
    process_cmdline_has_argument "$1" ProducerSessionContract
}
# These observation seams release real gated children, then call the original
# procfs readers. They neither reap children nor manufacture terminal statuses.
for helper in process_start_time process_state; do
  definition=$(declare -f "$helper")
  eval "${definition/$helper/fixture_real_$helper}"
done
fixture_observe_disappearance() {
  local pid=$1 index
  for ((index=0; index<300; index++)); do
    [[ -e /proc/$pid ]] || return 0
    /usr/bin/sleep 0.01
  done
  return 1
}
fixture_exit_at_read() {
  local pid=$1 boundary=$2
  [[ -e /proc/$pid ]] || return 1
  printf '%s\n' "$boundary" >>/work/exit-boundaries
  if [[ ${CASE:-} == decoder-exit-* ]]; then
    [[ -f /work/decoder-exit-ready && $(</work/strict-decoder-status) == 0 ]] || return 1
    printf 'exit\n' >/work/decoder-exit-gate
  else printf 'exit\n' >&"$fixture_gate"; fi
  fixture_observe_disappearance "$pid" || return 1
  touch /work/exit-observed
}
process_start_time() {
  local rc=0
  if [[ ${fixture_boundary:-} == unknown-identity && $1 == "${fixture_child:-}" ]]; then return 1; fi
  if [[ ${CASE:-} == decoder-exit-* && $1 == "${_producer_session_decoder_pid:-}" && -e /work/decoder-exit-ready && ! -e /work/exit-observed \
    || ${fixture_boundary:-} == identity && $1 == "${fixture_child:-}" && ! -e /work/exit-observed ]]; then
    fixture_exit_at_read "$1" identity || return 1
    fixture_real_process_start_time "$@" 2>/dev/null || rc=$?
    printf '%s\n' "$rc" >/work/exit-read-status
    return "$rc"
  fi
  fixture_real_process_start_time "$@"
}
process_state() {
  local rc=0
  if [[ ${fixture_boundary:-} == state && $1 == "${fixture_child:-}" && ! -e /work/exit-observed ]]; then
    fixture_exit_at_read "$1" state || return 1
    fixture_real_process_state "$@" 2>/dev/null || rc=$?
    printf '%s\n' "$rc" >/work/exit-read-status
    return "$rc"
  fi
  if [[ ${fixture_boundary:-} == unreadable && $1 == "${fixture_child:-}" ]]; then return 1; fi
  fixture_real_process_state "$@"
}
kill() {
  local rc=0
  if [[ ${fixture_child:-} == "${2:-}" ]]; then
    printf '%s\n' "$1" >>/work/child-signals
    if [[ ${fixture_boundary:-} == "$1" ]]; then fixture_exit_at_read "$2" "$1" || return 1; fi
    builtin kill "$@" 2>/dev/null || rc=$?
    if [[ ${fixture_boundary:-} == drift && $1 == -TERM ]]; then
      # A failed procfs identity observation on the next shutdown iteration.
      fixture_boundary=unknown-identity
    fi
    return "$rc"
  fi
  builtin kill "$@"
}
sleep() {
  if [[ ${fixture_count_sleeps:-false} == true && $1 == 0.05 ]]; then fixture_sleeps=$((fixture_sleeps+1)); fi
  /usr/bin/sleep "$@"
}
fixture_start_child() {
  local mode=$1 status=$2 index
  rm -f /work/child-ready /work/exit-observed /work/exit-read-status /work/child-signals
  fixture_boundary=''
  /fixtures/session-child "$mode" "$status" "$fixture_gate" &
  fixture_child=$!
  fixture_start=$(process_start_time "$fixture_child")
  for ((index=0; index<300; index++)); do
    [[ ! -e /work/child-ready ]] || return 0
    /usr/bin/sleep 0.01
  done
  return 1
}
fixture_supervision_races() {
  local status operation boundary rc before
  _producer_session_owner_pid=$BASHPID
  mkfifo /work/child-gate
  exec {fixture_gate}<>/work/child-gate
  for operation in wait stop; do
    for boundary in identity state; do
      for status in 0 19; do
        fixture_start_child normal "$status"
        fixture_boundary=$boundary
        if [[ $operation == wait ]]; then producer_session_wait_child "$fixture_child" "$fixture_start" 1
        else producer_session_stop_child "$fixture_child" "$fixture_start"; fi
        [[ $_producer_session_wait_status == "$status" && -e /work/exit-observed && $(</work/exit-read-status) != 0 && ! -e /work/child-signals ]]
        printf '%s/%s: actual wait %s\n' "$operation" "$boundary" "$status" >>/work/helper-results
      done
    done
  done
  for boundary in -TERM -KILL; do
    for status in 0 19; do
      fixture_start_child ignore "$status"
      fixture_boundary=$boundary
      producer_session_stop_child "$fixture_child" "$fixture_start"
      [[ $_producer_session_wait_status == "$status" && -e /work/exit-observed ]]
      printf 'stop/%s: actual wait %s\n' "$boundary" "$status" >>/work/helper-results
    done
  done
  # An actual live process with a different start identity models a reused PID.
  # Unknown state/identity reads, including after TERM, must not fall into wait.
  for boundary in mismatch unreadable drift; do
    fixture_start_child ignore 0
    fixture_boundary=$boundary
    before=$EPOCHSECONDS
    if [[ $boundary != drift ]]; then
      status=$fixture_start
      [[ $boundary != mismatch ]] || status=$((fixture_start+1))
      if producer_session_wait_child "$fixture_child" "$status" 1; then return 1; fi
      if producer_session_stop_child "$fixture_child" "$status"; then return 1; fi
      [[ ! -e /work/child-signals ]]
    else
      if producer_session_stop_child "$fixture_child" "$fixture_start"; then return 1; fi
      [[ $(</work/child-signals) == -TERM && $(fixture_real_process_start_time "$fixture_child") == "$fixture_start" ]]
    fi
    [[ $_producer_session_wait_status == null && -e /proc/$fixture_child && $((EPOCHSECONDS-before)) -lt 5 ]]
    builtin kill -KILL "$fixture_child"
    rc=0; wait "$fixture_child" 2>/dev/null || rc=$?
    [[ $rc == 137 ]]
    printf '%s: refused live child without collection\n' "$boundary" >>/work/helper-results
  done
  fixture_start_child ignore 0
  fixture_sleeps=0; fixture_count_sleeps=true
  if producer_session_wait_child "$fixture_child" "$fixture_start" 1; then return 1; fi
  [[ $fixture_sleeps == 20 && $_producer_session_wait_status == null && ! -e /work/child-signals ]]
  fixture_sleeps=0
  producer_session_stop_child "$fixture_child" "$fixture_start"
  [[ $_producer_session_wait_status == 137 && $fixture_sleeps -ge 20 && $(</work/child-signals) == $'-TERM\n-KILL' ]]
  fixture_count_sleeps=false
  printf 'deadlines: 20 wait ticks and full TERM grace before KILL\n' >>/work/helper-results
  # This shell never owned the fixture grandchild. Its real wait reports 127.
  fixture_child=$(/usr/bin/bash -c 'sleep 0.1 & printf "%s\n" "$!"')
  fixture_observe_disappearance "$fixture_child"
  producer_session_wait_child "$fixture_child" 0 1
  [[ $_producer_session_wait_status == 127 ]]
  printf 'unavailable: actual wait 127\n' >>/work/helper-results
}
# Exact-operation seams for the real Core directory journal and held-parent mkdir.
if [[ $1 != inherited-flag-* ]]; then
  for helper in append_publication_record publication_validate_targets; do
    definition=$(declare -f "$helper")
    eval "${definition/$helper/fixture_real_$helper}"
  done
fi
fixture_directory_event() {
  local data='{}'
  (( $# < 4 )) || data=$4
  jq -cn --arg event "$1" --arg path "$2" --argjson status "$3" --argjson data "$data" \
    '{event:$event,path:$path,status:$status,data:$data}' >>/work/directory-events.jsonl
}
fixture_directory_journal() {
  local paths path
  local -a files=()
  paths=$(jq -r '.publication_records[].path' "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  while IFS= read -r path; do [[ -z $path ]] || files+=("$path"); done <<<"$paths"
  (( ${#files[@]} > 0 )) || return 1
  jq -s 'sort_by(.ordinal)' "${files[@]}"
}
append_publication_record() {
  local fixture_record_kind=$2 fixture_record_body=$3 status=0
  fixture_real_append_publication_record "$@" || status=$?
  if [[ ${CASE:-} == publish-mkdir-* ]]; then
    case $fixture_record_kind in
      directory-pending|directory-created|boot-stage|prepared-terminal)
        fixture_directory_event "$fixture_record_kind" "$(jq -r '.path // .target // ""' <<<"$fixture_record_body")" "$status" "$fixture_record_body" || return 1 ;;
    esac
  fi
  return "$status"
}
publication_validate_targets() {
  local status=0
  if [[ ${CASE:-} != publish-mkdir-* ]]; then fixture_real_publication_validate_targets; return; fi
  fixture_real_publication_validate_targets 2>>/work/target-validation.stderr || status=$?
  fixture_directory_event targets '' "$status" || return 1
  return "$status"
}
mkdir() {
  local path parent descriptor status=0 reported pending_status=0
  if [[ ${CASE:-} != publish-mkdir-* || $# != 2 || $1 != -- || ! $2 =~ ^/proc/$BASHPID/fd/([0-9]+)/[^/]+$ ]]; then
    /usr/bin/mkdir "$@"; return
  fi
  descriptor=${BASH_REMATCH[1]}
  parent=$(readlink -e "/proc/$BASHPID/fd/$descriptor") || return 1
  path="$parent/${2##*/}"
  [[ $path == /boot/* && ${_publication_directory_fds[$parent]:-} == "$descriptor" ]] || return 1
  fixture_directory_event mkdir-invoke "$path" 0 "$(jq -cn --arg fd "$descriptor" --arg identity "$(stat -Lc '%d:%i' "/proc/$BASHPID/fd/$descriptor")" '{parent_fd:$fd,parent_identity:$identity}')" || return 1
  # Observe ordering without supplying Core's pending-record guard ourselves.
  # A missing pending head must fail the outer oracle, never suppress the syscall.
  fixture_directory_journal >/work/journal-before-mkdir.json || pending_status=$?
  jq -e --arg path "$path" 'any(.[]; .kind == "directory-pending" and .body.path == $path)' /work/journal-before-mkdir.json >/dev/null || pending_status=$?
  fixture_directory_event mkdir-pending-proof "$path" "$pending_status" || return 1
  if [[ $CASE == publish-mkdir-eexist && $path == /boot/EFI && ! -e /work/directory-fault ]]; then
    /usr/bin/mkdir -- "$2" || return 1
    printf 'foreign user data\n' >"$path/user-data"
    stat -Lc '%d:%i' "$path" >/work/foreign-directory-before
    stat -Lc '%d:%i' "$path/user-data" >/work/foreign-file-before
    sha256sum "$path/user-data" >/work/foreign-bytes-before
    printf 'real EEXIST after durable intent\n' >/work/directory-fault
  fi
  /usr/bin/mkdir "$@" || status=$?
  reported=$status
  if [[ $CASE == publish-mkdir-failed-created && $path == /boot/EFI && ! -e /work/directory-fault ]]; then
    [[ $status == 0 && -d $path ]] || return 1
    stat -Lc '%d:%i' "$path" >/work/failed-created-identity
    printf 'syscall created directory but reported failure\n' >/work/directory-fault
    reported=73
  fi
  fixture_directory_event mkdir-result "$path" "$reported" "$(jq -cn --argjson actual "$status" '{actual_status:$actual}')" || return 1
  return "$reported"
}
fixture_directory_sync_fault() {
  local path=$1 manifest record
  [[ $CASE == publish-mkdir-* ]] || return 0
  if [[ $CASE == publish-mkdir-pending-record || $CASE == publish-mkdir-pending-head ]]; then
    [[ ${fixture_record_kind:-} == directory-pending && ! -e /work/directory-fault ]] || return 0
    manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
    if [[ $CASE == publish-mkdir-pending-record && $path == "${manifest%/*}"/publication-*.json && -f $path ]] &&
      jq -e '.kind == "directory-pending" and .body.path == "/boot/EFI"' "$path" >/dev/null; then
      printf 'pending record sync refused before head\n' >/work/directory-fault
    elif [[ $CASE == publish-mkdir-pending-head && $path == "$manifest" ]]; then
      record=$(jq -r '.publication_records[-1].path' "$manifest") || return 1
      jq -e '.kind == "directory-pending" and .body.path == "/boot/EFI"' "$record" >/dev/null || return 0
      printf 'pending head sync refused before mkdir\n' >/work/directory-fault
    else return 0; fi
  elif [[ $CASE == publish-mkdir-retry-dir-sync || $CASE == publish-mkdir-retry-parent-sync || $CASE == publish-mkdir-replaced ]]; then
    [[ -n ${_publication_directory_candidates[/boot/EFI]:-} && -z ${_publication_directory_completed[/boot/EFI]:-} ]] || return 0
    [[ $CASE == publish-mkdir-retry-parent-sync && $path == /boot || $CASE != publish-mkdir-retry-parent-sync && $path == /boot/EFI ]] || return 0
    (( ${fixture_directory_sync_failures:-0} < 2 )) || return 0
    fixture_directory_sync_failures=$((${fixture_directory_sync_failures:-0}+1))
    printf 'directory candidate sync failure %s\n' "$fixture_directory_sync_failures" >>/work/directory-fault
  else return 0; fi
  fixture_directory_event sync-refused "$path" 1 || return 1
  return 1
}
fixture_directory_candidate() {
  local path=/boot/EFI fd=${_publication_directory_fds[/boot/EFI]:-} candidate=${_publication_directory_candidates[/boot/EFI]:-}
  [[ -n $candidate && -n $fd && $path -ef /proc/$BASHPID/fd/$fd ]] || return 1
  jq -cn --arg fd "$fd" --argjson candidate "$candidate" --argjson held "$(publication_fd_state "$fd")" \
    '{fd:$fd,candidate:$candidate,held:$held}'
}
fixture_directory_handler() {
  local document=$2 status=0 retry=0 attempt before fd
  publication_authority_handler "$@" || status=$?
  printf '%s\n' "$status" >/work/directory-first-result
  if [[ $CASE == publish-mkdir-efi || $CASE == publish-mkdir-linux ]]; then return "$status"; fi
  [[ $status != 0 && -s /work/directory-fault && ${#_publication_stage_bodies[@]} == 0 ]] || return 1
  fixture_directory_journal >/work/journal-at-directory-failure.json || return 1
  if [[ $CASE == publish-mkdir-retry-* ]]; then
    fixture_directory_candidate >/work/directory-candidate-first.json || return 1
    for attempt in second final; do
      retry=0
      publication_authority_handler "$1" "$document" || retry=$?
      printf '%s\n' "$retry" >"/work/directory-$attempt-result"
      fixture_directory_candidate >"/work/directory-candidate-$attempt.json" || return 1
      cmp /work/directory-candidate-first.json "/work/directory-candidate-$attempt.json" || return 1
      if [[ $attempt == second ]]; then [[ $retry != 0 && ${#_publication_stage_bodies[@]} == 0 ]] || return 1
      else [[ $retry == 0 ]] || return 1; fi
    done
    printf 'same live directory candidate completed after two failed syncs\n' >/work/directory-retry-verified
    return 0
  fi
  if [[ $CASE == publish-mkdir-failed-created || $CASE == publish-mkdir-eexist ]]; then
    [[ -z ${_publication_directory_candidates[/boot/EFI]:-} && -z ${_publication_directory_fds[/boot/EFI]:-} ]] || return 1
    before=$(stat -Lc '%d:%i' /boot/EFI) || return 1
  elif [[ $CASE == publish-mkdir-replaced ]]; then
    fixture_directory_candidate >/work/directory-candidate-first.json || return 1
    fd=${_publication_directory_fds[/boot/EFI]}
    mv --no-copy /boot/EFI /boot/replaced-directory || return 1
    /usr/bin/mkdir /boot/EFI || return 1
    printf 'replacement user data\n' >/boot/EFI/user-data
    stat -Lc '%d:%i' /boot/EFI >/work/foreign-directory-before
    stat -Lc '%d:%i' /boot/EFI/user-data >/work/foreign-file-before
    sha256sum /boot/EFI/user-data >/work/foreign-bytes-before
    [[ /boot/replaced-directory -ef /proc/$BASHPID/fd/$fd && ! /boot/EFI -ef /proc/$BASHPID/fd/$fd ]] || return 1
    printf 'retained inode survives at moved path, replacement has another inode\n' >/work/directory-replacement-proof
    before=$(stat -Lc '%d:%i' /boot/EFI) || return 1
  else return "$status"; fi
  publication_authority_handler "$1" "$document" || retry=$?
  printf '%s\n' "$retry" >/work/directory-second-result
  [[ $retry != 0 && $(stat -Lc '%d:%i' /boot/EFI) == "$before" && ${#_publication_stage_bodies[@]} == 0 ]] || return 1
  if [[ $CASE == publish-mkdir-replaced ]]; then [[ $_publication_mount_invalid == true ]] || return 1; fi
  printf 'uncertain or replaced directory cannot be attributed on retry\n' >/work/directory-retry-refused
  return "$retry"
}
durable_sync() {
  local worker directory count record kind id=''
  fixture_original_sync_fault "$1" || return 1
  fixture_context_sync_fault "$1" || return 1
  if [[ ${CASE:-} == publish-mkdir-* ]]; then
    fixture_directory_sync_fault "$1" || return 1
    if [[ $1 == /boot || $1 == /boot/* ]]; then
      /usr/bin/sync -f "$1" || return 1
      fixture_directory_event sync "$1" 0 || return 1
      return 0
    fi
  fi
  if [[ -n ${PUBLISH_FAULT:-} && ! -e /work/publication-sync-failed ]]; then
    directory=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
    if [[ $1 == "$directory" ]]; then
      count=$(jq -r '.publication_records | length' "$directory/manifest.json")
      record=''; kind=''
      case $PUBLISH_FAULT in
        config-data)
          if [[ -z ${fixture_record_kind:-} && -f $directory/publication-data-$_publication_invocation-configuration ]]; then
            record="$directory/publication-data-$_publication_invocation-configuration"; kind=configuration-data
          fi ;;
        config-record) record="$directory/publication-$((count+1)).json"; kind=configuration ;;
        config-stage) record="$directory/publication-$((count+1)).json"; kind=boot-stage; id=configuration ;;
        config-head) record="$directory/publication-$count.json"; kind=configuration ;;
        plan-head) record="$directory/publication-$count.json"; kind=plan ;;
        pending-head) record="$directory/publication-$count.json"; kind=effect-pending ;;
        applied-head) record="$directory/publication-$count.json"; kind=effect-applied ;;
      esac
      if [[ -n $record && -f $record ]] && { [[ $kind == configuration-data ]] ||
        jq -e --arg kind "$kind" --arg id "$id" --arg invocation "$_publication_invocation" \
          '.kind == $kind and .invocation == $invocation and ($id == "" or .body.id == $id)' "$record" >/dev/null; }; then
        jq -cn --arg fault "$PUBLISH_FAULT" --arg kind "$kind" --arg source "$record" --argjson head "$count" \
          '{fault:$fault,kind:$kind,source:$source,head_ordinal:$head}' >/work/publication-sync-witness.json
        touch /work/publication-sync-failed
        return 1
      fi
    fi
  fi
  if [[ ${RETENTION_FAULT:-} == ready-head-again && ! -e /work/second-sync-failed ]]; then
    directory=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
    if [[ $1 == "$directory" ]]; then touch /work/second-sync-failed; return 1; fi
  fi
  if [[ -n ${RETENTION_FAULT:-} && ! -e /work/retention-sync-failed ]]; then
    directory=$(dirname "$(lifecycle_manifest_path "$_transaction_id")")
    if [[ $1 == "$directory" ]]; then
      count=$(jq -r '.publication_records | length' "$directory/manifest.json")
      if [[ $RETENTION_FAULT == ready && -f $directory/publication-3.json && $count == 2 \
        || $RETENTION_FAULT == data && -f $directory/publication-data-11111111-1111-4111-8111-111111111111-image && $count == 3 \
        || $RETENTION_FAULT == record && -f $directory/publication-4.json && $count == 3 \
        || $RETENTION_FAULT == ready-head && $count == 3 && ! -f $directory/publication-data-11111111-1111-4111-8111-111111111111-image \
        || $RETENTION_FAULT == head && $count == 4 ]]; then
        touch /work/retention-sync-failed
        return 1
      fi
    fi
  fi
  if [[ $CASE == core-interrupt || $CASE == handler-exit || $CASE == backpressure-interrupt ]] && [[ -f /work/request-seen ]]; then
    worker=$(jq -r '.worker.pid' /work/launch.json)
    if [[ -e /proc/$worker/stat ]] && [[ $(process_state "$worker") != Z ]]; then
      printf 'recovery while writer alive\n' >/work/unsafe-recovery
    fi
  fi
  /usr/bin/sync -f "$1"
}
retention_handler() {
  local document=$2 result=0
  if [[ $1 == request && $CASE == retain-retry-* && ! -e /work/retention-sync-failed ]] && json_is '.payload.id == "image"' "$document"; then
    RETENTION_FAULT=${CASE#retain-retry-}
    publication_authority_handler "$@" || result=$?
    [[ $result != 0 && -f /work/retention-sync-failed ]] || return 1
    if [[ $CASE == retain-retry-ready-head ]]; then
      RETENTION_FAULT=ready-head-again
      if publication_authority_handler "$@"; then return 1; fi
      [[ -e /work/second-sync-failed && ! -e $(dirname "$(lifecycle_manifest_path "$_transaction_id")")/publication-data-11111111-1111-4111-8111-111111111111-image ]] || return 1
    fi
    RETENTION_FAULT=''
  fi
  publication_authority_handler "$@"
}
publication_fixture_handler() {
  local document=$2 operation result=0
  if [[ $1 == launch ]]; then
    fixture_context_worker_pid=$_producer_session_worker_pid
    fixture_context_decoder_pid=$_producer_session_decoder_pid
    printf '%s\n' "$document" >/work/publication-launch.json
    printf '%s\n' "$document" >>/work/context-launches.jsonl
    if find_publication_authority_part "$_publication_invocation" context; then
      printf '%s\n' "$_publication_found_reference" >>/work/context-at-launch.jsonl
      fixture_directory_journal >/work/context-launch-journal.json || return 1
      if [[ ! -e /work/context-first-launch-journal.json ]]; then
        [[ ! -e /work/context-worker-prepare ]] || return 1
        cp /work/context-launch-journal.json /work/context-first-launch-journal.json || return 1
        printf 'bound complete start observed before first worker executable\n' >/work/context-first-launch-proof
      fi
    fi
  fi
  if [[ $1 == request ]]; then
    jq -cr '.payload | {operation,id}' <<<"$document" >>/work/publication-requests.jsonl
    if [[ $CASE == publish-context-native-* ]]; then printf '%s\n' "$document" >/work/context-native-request.json; fi
    if [[ $CASE == publish-intent-match-model ]] && json_is '.payload.operation == "match-intent"' "$document"; then
      # Actual Java/decoder wire B and in-memory B agree. Keep the bound A record
      # and context untouched, then invoke the real three-way authority check.
      printf '%s\n' "$_publication_intent" >/work/intent-memory-before-match.json
      printf '%s\n' "$document" >/work/intent-wire-request.json
      _publication_intent=$(jq -c '.payload.intent' <<<"$document") || return 1
      printf '%s\n' "$_publication_intent" >/work/intent-memory-after-match.json
    fi
  fi
  if [[ $1 == terminal && $_publication_apply_phase == true && $CASE == publish-context-after-* ]]; then
    json_is '.worker_status == 0 and .decoder_status == 0 and .supervision_status == 0 and .protocol_complete and .completion_acknowledged' "$document" || return 1
    printf '%s\n' "$document" >/work/context-terminal-before.json
    fixture_context_terminal=true
  fi
  if [[ $1 == request && $CASE == publish-mkdir-* && $CASE != publish-mkdir-collision-* && ! -e /work/directory-first-result ]] &&
    json_is '.payload.operation == "stage-input"' "$document"; then
    fixture_directory_handler "$@"
    return
  fi
  if [[ $1 == request && $CASE == publish-plan-omit ]] && json_is '.payload.operation == "prepare-plan"' "$document"; then
    document=$(jq -c '.payload.plan.puts=[]' <<<"$document")
  fi
  if [[ $1 == request && $CASE == publish-unstarted-after ]] && json_is '.payload.operation == "before"' "$document"; then
    if [[ ${ORACLE_FAULT:-} == unstarted ]]; then
      _producer_session_reply='{"accepted":true}'
      result=0
    else publication_authority_handler "$1" "$document" || result=$?; fi
    printf '%s\n' "$result" >/work/unstarted-handler-result
    return "$result"
  fi
  if [[ $1 == request && $CASE == publish-retry-* && ! -e /work/publication-sync-failed ]]; then
    operation=$(jq -r '.payload.operation' <<<"$document")
    if [[ $operation == stage-config && $CASE == publish-retry-config-* \
      || $operation == prepare-plan && $CASE == publish-retry-plan-head \
      || $operation == before && $CASE == publish-retry-pending-head \
      || $operation == applied && $CASE == publish-retry-applied-head ]]; then
      PUBLISH_FAULT=${CASE#publish-retry-}
      publication_authority_handler "$1" "$document" || result=$?
      [[ $result != 0 && -e /work/publication-sync-failed ]] || return 1
      PUBLISH_FAULT=''
    fi
  fi
  result=0
  publication_authority_handler "$1" "$document" || result=$?
  if [[ $CASE == publish-intent-* ]]; then
    jq -cn --arg event "$1" --argjson apply "$_publication_apply_phase" --argjson status "$result" \
      --argjson matched "$_publication_intent_matched" \
      '{event:$event,apply_phase:$apply,status:$status,intent_matched:$matched}' >>/work/intent-gates.jsonl
  fi
  if [[ $CASE == publish-context-* && $1 == request && $result != 0 ]]; then
    printf '%s\n' "$result" >/work/context-request-refused
  fi
  (( result == 0 )) || return "$result"
  if [[ $1 == request ]] && json_is '.payload.operation == "application"' "$document"; then
    printf '%s\n' "$_producer_session_reply" >/work/application.json
  fi
}
fixture_core_pins() {
  local pin
  for pin in "${_publication_pins[@]}"; do
    printf '%s ' "$pin"
    publication_fd_state "$pin" || return 1
  done
}
fixture_core_mount_start() {
  local path=/boot/EFI/Linux status=0 retry=0
  [[ $CASE != publish-core-config-bind ]] || path=/boot/limine.conf
  producer_session_context_is_owned && publication_verify_live || return 1
  [[ $_publication_apply_phase == false && $_producer_session_active == false && -n $_publication_plan ]] || return 1
  fixture_core_pins >/work/core-pins-before || return 1
  /fixtures/mount-custody bind "$path" || return 1
  fixture_core_pins >/work/core-pins-after || return 1
  cmp /work/core-pins-before /work/core-pins-after || return 1
  # Real start must reach the live guard, not pass on generic lifecycle failure.
  publication_start_executor || status=$?
  printf '%s\n' "$status" >/work/publication-result
  [[ $status != 0 && $_publication_mount_invalid == true && $_publication_apply_phase == false ]] || return 1
  printf 'Core executor start refused changed mount with unchanged pins\n' >/work/core-mount-refused
  /fixtures/mount-custody unmount || return 1
  # The raw observation is valid again. The same attempt must stay invalid.
  producer_session_context_is_owned && publication_check_live || return 1
  if publication_verify_live; then return 1; fi
  publication_start_executor || retry=$?
  printf '%s\n' "$retry" >/work/executor-retry-result
  [[ $retry != 0 && $_publication_mount_invalid == true && $_publication_apply_phase == false ]] || return 1
  printf 'restored mount cannot revive the invalid attempt\n' >/work/core-sticky-refused
  /fixtures/mount-custody snapshot final || return 1
  cmp /work/mount-witness-prepared /work/mount-witness-final || return 1
  return "$status"
}
handler() {
  case $1 in
    launch)
      [[ $CASE != launch-refusal ]] || return 1
      printf '%s\n' "$2" >/work/launch.json
      ;;
    request)
      printf 'seen\n' >/work/request-seen
      if json_is '.payload.operation == "hello"' "$2"; then
        [[ $CASE != request-refusal ]] || return 1
        [[ $CASE != core-interrupt ]] || kill -TERM "$BASHPID"
        [[ $CASE != handler-exit ]] || exit 23
        exec {session_pin}</work/pinned
        if [[ $CASE == lock-rebind ]]; then mv /run/lock/boot-partition.lock /run/lock/old-boot.lock; touch /run/lock/boot-partition.lock; fi
        if [[ $CASE == abort-identity ]]; then _producer_session_worker_start=invalid; fi
      elif ! json_is '.payload.operation == "complete"' "$2"; then return 1
      fi
      _producer_session_reply='{"accepted":true}'
      if [[ $CASE == backpressure || $CASE == backpressure-interrupt ]]; then _producer_session_reply=$(jq -cn '{data:("x" * 1048576)}'); fi
      if [[ $CASE == oversized-reply ]]; then _producer_session_reply=$(jq -cn '{data:("x" * 2097152)}'); fi
      if [[ $CASE == backpressure-interrupt ]]; then
        owner=$BASHPID
        (sleep 0.25; kill -TERM "$owner") &
      fi
      ;;
    terminal)
      printf '%s\n' "$2" >/work/terminal.json
      [[ $CASE != terminal-refusal ]] || return 1
      if [[ -n ${session_pin:-} ]]; then
        [[ $(cat "/proc/$BASHPID/fd/$session_pin") == retained ]] || return 1
        printf 'pin survived callback\n' >/work/pin-survived
      fi
      ;;
    *) return 1 ;;
  esac
}
body() {
  local fd timeout=10 mode=$CASE token=$OMASECBOOT_TRANSACTION_TOKEN rc=0
  if [[ $CASE == inherited-flag-* ]]; then
    transaction_backup_file /work/pinned || return 1
    printf 'changed\n' >/work/pinned
    case $CASE in
      inherited-flag-success) return 0 ;;
      inherited-flag-failure) return 12 ;;
      inherited-flag-interrupt) kill -TERM "$BASHPID" ;;
    esac
  fi
  exec {fd}</fixtures/native
  if [[ $CASE == publish-* ]]; then
    mkdir -p /var/lib/sbctl
    if [[ $CASE != publish-mkdir-* ]]; then mkdir -p /boot/EFI/Linux /boot/11111111111111111111111111111111/linux; fi
    printf '# original configuration\ntimeout: 3\n/+Foreign OS\n  protocol: efi_boot_entry\n  entry: Foreign OS\n' >/boot/limine.conf
    cp /boot/limine.conf /work/config-before
    if [[ $CASE == publish-mkdir-* ]]; then
      stat -Lc '%d:%i' /boot/limine.conf >/work/config-inode-before
      : >/work/directory-events.jsonl
      find /boot -mindepth 1 -printf '%P\n' | sort >/work/boot-paths-before
    fi
    if [[ ${MOUNT_CUSTODY_FIXTURE:-} == 1 ]]; then
      # Present, different bytes require a real replacement, with before-inode proof.
      printf 'fixture target before publication\n' >/boot/EFI/Linux/contract_linux.efi
    fi
    if [[ $CASE == publish-native-final-third-state || $CASE == publish-core-death-final-third-state ]]; then
      if [[ $CASE == publish-core-death-final-third-state ]]; then
        printf 'fixture original pinned target\n' >/boot/EFI/Linux/contract_linux.efi
        jq -cn --arg identity "$(stat -Lc '%d:%i' /boot/EFI/Linux/contract_linux.efi)" \
          --arg hash "$(sha256_file /boot/EFI/Linux/contract_linux.efi)" '{kind:"file",identity:$identity,sha256:$hash}' >/work/third-state-original.json
      else
        [[ ! -e /boot/EFI/Linux/contract_linux.efi ]] || return 1
        printf '{"kind":"absent","identity":null,"sha256":null}\n' >/work/third-state-original.json
      fi
    fi
    cp /efi-input /work/input
    printf 'fixture initramfs\n' >/work/initrd
    sbctl create-keys >/work/create-keys.log
    if [[ $CASE == publish-noop ]]; then
      sbctl sign --output /work/input /work/input >/work/source-sign.log
      cp /work/input /boot/EFI/Linux/contract_linux.efi
      chmod 600 /boot/EFI/Linux/contract_linux.efi
      stat -Lc '%d:%i' /boot/EFI/Linux/contract_linux.efi >/work/target-before
    fi
    /fixtures/native describe-publish "$CASE" </dev/null >/work/admitted-intent.json
    fixture_context_setup || return 1
    fixture_context_begin || return 1
    printf '%s\n' "$_publication_signing_policy" >/work/signer-policy.json
    printf 'prepare\n' >/work/signer-phase
    if [[ $CASE == publish-signer-absent-* ]]; then publication_observe_signer >/work/signer-absent-before.json || return 1; fi
    if [[ $CASE == publish-signer-config-before ]]; then
      printf '# valid change after context capture\n' >>/etc/sbctl/sbctl.conf
      fixture_context_sbctl_boundary changed || return 1
      printf 'valid configuration changed before retain request\n' >/work/signer-before-injected
    fi
    if [[ $CASE == publish-signer-cert-before || $CASE == publish-signer-executable-before ]]; then
      if [[ $CASE == publish-signer-cert-before ]]; then
        install -m400 /var/lib/sbctl/keys/KEK/KEK.pem /var/lib/sbctl/keys/db/db.pem
        sha256_file /var/lib/sbctl/keys/KEK/KEK.pem >/work/signer-replacement-certificate-sha256
      else
        [[ /usr/bin/sbctl -ef /work/sbctl-call-writable && ! /usr/bin/sbctl -ef /fixtures/sbctl-call ]] || return 1
        printf '\n# per-case executable-byte drift\n' >>/usr/bin/sbctl
        printf 'executable mutation confined to per-case writable bind\n' >/work/signer-executable-private
      fi
      fixture_context_sbctl_boundary changed || return 1
      printf 'signer bytes changed after capture, before managed retention\n' >/work/signer-before-injected
    fi
    if [[ $CASE == publish-config-drift ]]; then printf '# changed configuration\n' >/boot/limine.conf; fi
    run_bound_producer_session "$fd" "$fd" 11111111-1111-4111-8111-111111111111 publication_fixture_handler 30 publish-prepare "$CASE" || rc=$?
    printf '%s\n' "$rc" >/work/preparation-result
    if [[ $CASE == publish-recovery-copy-signed ]]; then
      # The actual managed addition has signed, staged and rendered its complete
      # plan. Interrupt before executor admission, after both children are reaped.
      [[ $rc == 0 && -n $_publication_plan && $_publication_apply_phase == false &&
        -z $_producer_session_worker_pid && -z $_producer_session_decoder_pid &&
        ! -e /proc/$fixture_context_worker_pid && ! -e /proc/$fixture_context_decoder_pid ]] || return 1
      local kind id
      for kind in retained configuration; do
        id=''; [[ $kind != retained ]] || id=resource-0
        find_publication_record "$_publication_invocation" "$kind" "$id" || return 1
        jq -cn --argjson reference "$_publication_found_reference" --argjson body "$_publication_found_body" \
          '{reference:$reference,body:$body}' >"/work/recovery-original-$kind.json" || return 1
      done
      fixture_directory_journal >/work/recovery-original-journal.json || return 1
      [[ $(sha256_file /work/input) == "$(sha256_file /efi-input)" ]] || return 1
      /fixtures/namespace-id capture /work/recovery-original-namespace || return 1
      printf 'actual preparation worker and decoder reaped before root interruption\n' >/work/recovery-original-workers-exited
      printf '19\n' >/work/publication-result
      return 19
    fi
    if [[ $CASE == publish-intent-* ]]; then
      fixture_intent_snapshot after-session || return 1
      if (( rc != 0 )); then printf '%s\n' "$rc" >/work/publication-result; fi
    fi
    if [[ $CASE == publish-signer-* && $rc != 0 ]]; then
      fixture_context_sbctl_boundary after || return 1
      if [[ $CASE == publish-signer-absent-* ]]; then publication_observe_signer >/work/signer-absent-after.json || return 1; fi
      printf '%s\n' "$rc" >/work/publication-result
      [[ $_publication_apply_phase == false ]] || return 1
      printf 'retention refused; apply phase remains false\n' >/work/signer-retain-refused
    fi
    if [[ $CASE == publish-context-* ]]; then
      fixture_context_fault=''
      if (( rc != 0 )); then printf '%s\n' "$rc" >/work/publication-result; fi
      if [[ $CASE == *-uncertain || $CASE == publish-context-launch-* ]]; then
        [[ $rc != 0 && ! -e /work/context-worker-prepare && ! -e /work/publication-requests.jsonl ]] || return 1
        printf 'actual launch gate refused before worker executable\n' >/work/context-launch-refused
      fi
    fi
    if [[ $CASE == publish-mkdir-* ]]; then
      fixture_directory_journal >/work/directory-journal.json || return 1
      if (( rc != 0 )); then printf '%s\n' "$rc" >/work/publication-result; fi
    fi
    if (( rc == 0 )); then
      if [[ ${MOUNT_CUSTODY_FIXTURE:-} == 1 ]]; then
        local mount_stages='{}' mount_id
        for mount_id in "${!_publication_stage_bodies[@]}"; do
          mount_stages=$(jq -c --arg id "$mount_id" --argjson stage "${_publication_stage_bodies[$mount_id]}" '.[$id]=$stage' <<<"$mount_stages") || return 1
        done
        printf '%s\n' "$mount_stages" >/work/mount-stages.json
        /fixtures/mount-custody snapshot prepared || return 1
      fi
      if [[ $CASE == publish-core-directory-bind || $CASE == publish-core-config-bind ]]; then
        fixture_core_mount_start || rc=$?
        return "$rc"
      fi
      if [[ $CASE == publish-third-state ]]; then printf 'third state\n' >/boot/EFI/Linux/contract_linux.efi; fi
      if [[ $CASE == publish-context-between-* ]]; then
        fixture_core_pins >/work/context-pins-before || return 1
        case $CASE in
          publish-context-between-root) fixture_context_change '.root.filesystem_uuid="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"' ;;
          publish-context-between-subvolume) fixture_context_change '.root.subvolume.uuid="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"' ;;
        esac
      fi
      printf 'executor-check\n' >/work/signer-phase
      if [[ $CASE == publish-signer-unsigned-* || $CASE == publish-signer-result-* ]]; then
        fixture_core_pins >/work/signer-pins-before || return 1
        local signer_id=resource-0 signer_retained signer_stage
        signer_retained=$(jq -r '.file.path' <<<"${_publication_retained[$signer_id]}") || return 1
        signer_stage=$(jq -r '.stage.path' <<<"${_publication_stage_bodies[$signer_id]}") || return 1
        jq -cn --arg retained "$signer_retained" --arg stage "$signer_stage" '{retained:$retained,stage:$stage}' >/work/signer-check-targets.json
        if [[ $CASE == *-retained ]]; then printf '%s\n' "$signer_retained" >/work/signer-negative-target
        else printf '%s\n' "$signer_stage" >/work/signer-negative-target; fi
      fi
      publication_start_executor || rc=$?
      printf '%s\n' "$rc" >/work/executor-start-result
      if [[ $CASE == publish-signer-unsigned-* || $CASE == publish-signer-result-* ]]; then
        [[ $rc != 0 && $_publication_apply_phase == false && ! -e /work/context-worker-apply ]] || return 1
        fixture_core_pins >/work/signer-pins-after || return 1
        cmp /work/signer-pins-before /work/signer-pins-after || return 1
        fixture_context_sbctl_boundary after || return 1
        printf 'verification result refused executor with unchanged pins and apply phase false\n' >/work/signer-executor-refused
      fi
      if [[ $CASE == publish-context-between-* ]]; then
        [[ $rc != 0 && $_publication_apply_phase == false && ! -e /work/context-worker-apply ]] || return 1
        fixture_core_pins >/work/context-pins-after || return 1
        cmp /work/context-pins-before /work/context-pins-after || return 1
        printf 'stable context drift refused executor with unchanged live pins\n' >/work/context-executor-refused
      fi
      if [[ $CASE == publish-mkdir-* ]]; then fixture_directory_event executor-start '' "$rc" || return 1; fi
      if (( rc != 0 )); then printf '%s\n' "$rc" >/work/publication-result; return "$rc"; fi
      printf 'apply\n' >/work/signer-phase
      # Each worker receives the original terminal stream, independently of RPC.
      run_bound_producer_session "$fd" "$fd" 11111111-1111-4111-8111-111111111111 publication_fixture_handler 30 publish-apply "$CASE" </work/user-input || rc=$?
      printf '%s\n' "$rc" >/work/publication-result
      if (( rc == 0 )); then
        local stages='{}' id
        for id in "${!_publication_stage_bodies[@]}"; do stages=$(jq -c --arg id "$id" --argjson stage "${_publication_stage_bodies[$id]}" '.[$id]=$stage' <<<"$stages"); done
        printf '%s\n' "$stages" >/work/stages.json
        if [[ $CASE == publish-mkdir-* ]]; then
          fixture_directory_journal >/work/directory-journal.json || return 1
          for id in "${!_publication_directory_completed[@]}"; do
            jq -cn --arg path "$id" --arg identity "$(stat -Lc '%d:%i' "$id")" '{path:$path,identity:$identity}' >>/work/directory-identities.jsonl
          done
        fi
        /fixtures/native ordinary-publish "$CASE" </dev/null || return 1
        if [[ $CASE == publish-noop ]]; then
          [[ ${ORACLE_FAULT:-} != noop && $(stat -Lc '%d:%i' /boot/EFI/Linux/contract_linux.efi) == "$(</work/target-before)" ]] || return 1
          printf 'exact before inode retained\n' >/work/noop-verified
        fi
      fi
    fi
    return "$rc"
  fi
  if [[ $CASE == retain-* ]]; then
    mkdir -p /boot/EFI/Linux /var/lib/sbctl
    printf 'fixture configuration\n' >/boot/limine.conf
    cp /efi-input /work/input
    local role=uki operation=add-uki resources intent
    if [[ $CASE == retain-kernel || $CASE == retain-bytes ]]; then
      role=kernel; operation=add-kernel
      printf 'fixture initramfs\n' >/work/initrd
    fi
    if [[ $CASE == retain-bytes ]]; then printf 'non-PE kernel bytes\n' >/work/input; fi
    if [[ $CASE != retain-bytes && $CASE != retain-source-drift && $CASE != retain-incomplete && $CASE != retain-fifo && $CASE != retain-growing ]]; then
      sbctl create-keys >/work/create-keys.log
    fi
    if [[ $CASE == retain-signed ]]; then sbctl sign /work/input >/work/initial-sign.log; fi
    resources=$(jq -cn --arg role "$role" --arg hash "$(sha256_file /work/input)" \
      '[{id:"image",role:$role,source:"/work/input",target:"/boot/EFI/Linux/image.efi",sha256:$hash}]')
    if [[ $role == kernel ]]; then
      resources=$(jq -c --arg hash "$(sha256_file /work/initrd)" '. += [{id:"initrd",role:"initramfs",source:"/work/initrd",target:"/boot/initrd",sha256:$hash}]' <<<"$resources")
    fi
    intent=$(jq -cn --arg operation "$operation" --arg hash "$(sha256_file /boot/limine.conf)" --argjson resources "$resources" \
      '{operation:$operation,esp_path:"/boot",configuration:{path:"/boot/limine.conf",sha256:$hash},resources:$resources}')
    publication_authority_begin 11111111-1111-4111-8111-111111111111 "$intent" || return 1
    local retention_timeout=20
    [[ $CASE != retain-fifo ]] || retention_timeout=1
    run_bound_producer_session "$fd" "$fd" 11111111-1111-4111-8111-111111111111 retention_handler "$retention_timeout" "$CASE" || rc=$?
    printf '%s\n' "$rc" >/work/retention-result
    printf '%s\n' "$(lifecycle_manifest_path "$_transaction_id")" >/work/manifest-path
    if [[ $CASE != retain-source-drift && $CASE != retain-incomplete && $CASE != retain-fifo && $CASE != retain-growing ]]; then
      find_publication_record 11111111-1111-4111-8111-111111111111 retained image || return 1
      printf '%s\n' "$_publication_found_body" >/work/retained.json
      if [[ $CASE != retain-bytes ]]; then
        verify_publication_input "$(jq -r '.file.path' /work/retained.json)" || return 1
        sbctl list-files --json >/work/tracking.json
        json_is '. == []' "$(</work/tracking.json)" || return 1
      fi
    fi
    return "$rc"
  fi
  case $CASE in
    launch-refusal|request-refusal|terminal-refusal|core-interrupt|handler-exit|restore-marker|wrong-token|lock-rebind|oversized-reply|worker-exec-failure|decoder-exec-failure) mode=success ;;
    hang|close-and-hang|backpressure|backpressure-interrupt) timeout=1 ;;
    abort-identity) mode=hang-after-hello; timeout=1 ;;
    decoder-exit-0|decoder-exit-19)
      mode=success
      export SESSION_EXIT_FIXTURE=$CASE
      mkfifo /work/decoder-exit-gate
      ;;
  esac
  [[ $CASE != restore-marker ]] || touch /run/lock/limine-snapper-restore.lock
  [[ $CASE != wrong-token ]] || OMASECBOOT_TRANSACTION_TOKEN=invalid
  local other=$fd
  if [[ $CASE == late-lock-rebind || $CASE == post-lock-rebind ]]; then
    transaction_backup_file /work/pinned || return 1
    printf 'changed\n' >/work/pinned
    touch /work/arm-late
  fi
  if [[ $CASE == worker-exec-failure || $CASE == decoder-exec-failure ]]; then
    printf '#!/missing-interpreter\n' >/work/bad-exec
    chmod 755 /work/bad-exec
    exec {other}</work/bad-exec
  fi
  if [[ $CASE == worker-exec-failure ]]; then
    run_bound_producer_session "$other" "$fd" 11111111-1111-4111-8111-111111111111 handler "$timeout" "$mode" || rc=$?
  else
    run_bound_producer_session "$fd" "$other" 11111111-1111-4111-8111-111111111111 handler "$timeout" "$mode" || rc=$?
  fi
  OMASECBOOT_TRANSACTION_TOKEN=$token
  exec {fd}<&-
  return "$rc"
}
CASE=$1
printf '%s\n' "$CASE" >/work/signer-case
if [[ $CASE == supervision-races ]]; then fixture_supervision_races; exit 0; fi
printf 'retained\n' >/work/pinned
rc=0
operation=session-contract
[[ $CASE != retain-* && $CASE != publish-* ]] || operation=sign
if [[ $CASE == publish-core-death || $CASE == publish-core-death-directory-bind || $CASE == publish-core-death-final-third-state ]]; then
  (run_lifecycle_transaction_with_preflight sign active unmanaged : body) </work/user-input &
  supervisor=$!
  wait "$supervisor" || rc=$?
  printf '%s\n' "$rc" >/work/result
  [[ $rc == 137 ]] || exit 91
  for ((attempt=0; attempt<200; attempt++)); do [[ ! -e /work/after-core-death ]] || break; sleep 0.05; done
  [[ -e /work/after-core-death && -e /work/custody-proof ]] || exit 92
  cmp /work/config-before /boot/limine.conf || exit 93
  exit 0
fi
run_lifecycle_transaction_with_preflight "$operation" active unmanaged : body || rc=$?
printf '%s\n' "$rc" >/work/result
if [[ $CASE == abort-identity ]]; then
  # The deliberately corrupted live identity prevented signaling. Prove that
  # abandonment closed Core's copies without unlocking the worker's copies.
  exec 9>/run/lock/boot-partition.lock 8>/work/state/repair.lock
  if flock -n 9 || flock -n 8; then printf 'abandonment unlocked child\n' >/work/unsafe-recovery; fi
  _producer_session_worker_start=$(jq -r '.worker.start_time' /work/launch.json)
  producer_session_abort
  flock -n 9 && flock -n 8
fi
if [[ $CASE == inherited-flag-success ]]; then
  [[ $rc == 0 ]] && read_lifecycle && [[ $_lifecycle_state == active ]]
elif [[ $CASE == success || $CASE == decoder-exit-0 ]]; then
  [[ $rc == 0 ]] && read_lifecycle && [[ $_lifecycle_state == active ]]
  json_is '.worker_status == 0 and .decoder_status == 0 and .protocol_complete and .supervision_status == 0' "$(</work/terminal.json)"
  [[ -f /work/pin-survived ]]
else
  [[ $rc != 0 ]]
  read_lifecycle && [[ $_lifecycle_state != active ]]
fi
if [[ $CASE == lock-rebind || $CASE == abort-identity ]]; then
  read_lifecycle && [[ $_lifecycle_state == transition ]]
fi
if [[ $CASE == late-lock-rebind || $CASE == post-lock-rebind ]]; then
  read_lifecycle && [[ $_lifecycle_state == transition ]]
  [[ $(</work/pinned) == changed && ! -f /work/launch.json ]]
  kill -TERM "$competitor"
  wait "$competitor" || true
fi
if [[ $CASE == publish-recovery-copy-signed ]]; then
  [[ $rc == 19 && $_lifecycle_state == recovery-required && ! -e /work/context-worker-apply ]]
  root=$(jq -r '.transaction.root_incident.id' <<<"$_lifecycle_json")
  directory=$(dirname "$(lifecycle_manifest_path "$root")")
  sha256sum "$directory/manifest.json" "$directory/incident.json" "$directory"/publication-*.json \
    "$directory"/publication-data-* >/work/recovery-original-sha256
  sha256sum /work/signer-commands.jsonl /work/context-wrapper.jsonl /work/publication-requests.jsonl >/work/recovery-activity-before
fi
SCRIPT
cat >"$scratch/fixtures/namespace-id" <<'SCRIPT'
#!/usr/bin/bash
set -euo pipefail
# NS_GET_MNTNS_ID, Linux UAPI nsfs.h: _IOR(0xb7, 5, __u64). Unlike the nsfs
# inode shown by readlink, this identity is not recycled during one kernel boot.
# Linux v6.12 fs/nsfs.c returns mnt_namespace.seq, assigned from mnt_ns_seq.
# This fixture compares lifetimes in one boot, never stable recovery identity.
valid_observation() {
  jq -se '
    def identifier: type == "string" and test("\\A[1-9][0-9]{0,19}\\z") and
      (length < 20 or . <= "18446744073709551615");
    length == 1 and (.[0] | type == "object" and
      keys == ["mount_namespace_id","nsfs_inode"] and all(.[]; identifier))' "$1" >/dev/null
}
case ${1:-} in
  capture)
    [[ $# == 2 ]] || exit 64
    "$0" observe >"$2" || exit 1
    valid_observation "$2"
    exit "$?"
    ;;
  compare)
    [[ $# == 3 ]] || exit 64
    valid_observation "$2" && valid_observation "$3" || exit 1
    jq -se 'length == 2 and .[0].mount_namespace_id != .[1].mount_namespace_id' "$2" "$3" >/dev/null
    exit "$?"
    ;;
  observe)
    [[ $# == 1 ]] || exit 64
    # Deliberate oracle faults, used only by this test helper's negative checks.
    case ${NAMESPACE_TEST_FAULT:-} in
      failure) exit 73 ;;
      empty) exit 0 ;;
      multiple) printf '%s\n' '{"nsfs_inode":"1","mount_namespace_id":"1"}' '{"nsfs_inode":"2","mount_namespace_id":"2"}'; exit 0 ;;
      malformed) printf '%s\n' '{"nsfs_inode":"1","mount_namespace_id":2}'; exit 0 ;;
      '') ;;
      *) exit 64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
exec /usr/bin/env -i PATH=/usr/bin LC_ALL=C HOME=/nonexistent /real/namespace-python -I -S -B -c '
import array, fcntl, json, os
fd = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
try:
    value = array.array("Q", [0])
    assert value.itemsize == 8
    assert fcntl.ioctl(fd, (2 << 30) | (8 << 16) | (0xb7 << 8) | 5, value, True) == 0
    assert value[0] > 0
    print(json.dumps({"nsfs_inode": str(os.fstat(fd).st_ino), "mount_namespace_id": str(value[0])}))
finally:
    os.close(fd)
'
SCRIPT
chmod 755 "$scratch/fixtures/namespace-id"
cat >"$scratch/fixtures/recovery-copy" <<'SCRIPT'
#!/usr/bin/bash
# shellcheck disable=SC1090,SC1091,SC2154,SC2329
# A fresh shell/namespace consumes the actual sealed tree, with no producer or
# platform acquisition. Only the final independent oracle invokes real sbctl.
set -euo pipefail
trap 'status=$?; printf "recovery-copy failed at line %s (status %s)\n" "$LINENO" "$status" >&2' ERR
for module in common lifecycle records software checks discover sign enroll producer-session publication; do source "/core/lib/$module.sh"; done
state_dir_path() { printf '/work/state\n'; }
pacman_database_lock_path() { printf '/work/pacman-db.lck\n'; }
# Keep the real collector/signer definitions for the later fresh-authority
# phase; the copy phase below must reach none of them.
for helper in publication_collect_stable_context publication_verify_stable_context publication_verify_live \
  publication_run_sbctl verify_publication_input publication_input_is_efi publication_stage_file; do
  definition=$(declare -f "$helper")
  eval "${definition/#"$helper"/fixture_real_$helper}"
done
for helper in publication_collect_stable_context publication_verify_stable_context publication_verify_live \
  publication_run_sbctl verify_publication_input publication_input_is_efi publication_authority_begin \
  publication_authority_handler publication_stage_file publication_start_executor run_bound_producer_session sbctl; do
  eval "$helper() { printf 'unexpected $helper during retained copy\n' >/work/recovery-copy-forbidden; return 90; }"
done
touch /work/recovery-copy-active
/fixtures/namespace-id capture /work/recovery-fresh-namespace
/fixtures/namespace-id compare /work/recovery-original-namespace /work/recovery-fresh-namespace
# Neither failed/empty capture nor two values in one file may stand in for the
# missing other observation. Exercise the same capture/comparison helper.
for fault in failure empty multiple malformed; do
  if NAMESPACE_TEST_FAULT=$fault /fixtures/namespace-id capture /work/invalid-namespace 2>/work/namespace-negative.stderr; then exit 90; fi
  if /fixtures/namespace-id compare /work/invalid-namespace /work/recovery-fresh-namespace 2>>/work/namespace-negative.stderr; then exit 90; fi
  if /fixtures/namespace-id compare /work/recovery-original-namespace /work/invalid-namespace 2>>/work/namespace-negative.stderr; then exit 90; fi
done
if /fixtures/namespace-id compare /work/recovery-original-namespace /work/recovery-original-namespace; then exit 90; fi
# Recycled inode numbers do not invalidate distinct namespace lifetimes. Keep
# the real observations untouched; this separate synthetic pair tests the oracle.
jq --arg inode "$(jq -r .nsfs_inode /work/recovery-original-namespace)" '.nsfs_inode=$inode' \
  /work/recovery-fresh-namespace >/work/recycled-inode-observation
/fixtures/namespace-id compare /work/recovery-original-namespace /work/recycled-inode-observation
printf 'failed/empty/multiple/malformed and equal identities refused; recycled inode accepted with distinct namespace ID\n' >/work/namespace-oracle-verified
[[ -z $_publication_invocation && -z $_publication_signing_policy && ${#_publication_pins[@]} == 0 ]]
[[ ! -e /boot/limine.conf && ! -e /boot/EFI && -e /work/recovery-original-workers-exited ]]
rm -- /work/input
with_boot_repair_lock
read_lifecycle
root=$(jq -c '.transaction.root_incident' <<<"$_lifecycle_json")
directory=$(dirname "$(lifecycle_manifest_path "$(jq -r '.id' <<<"$root")")")
sha256sum --check /work/recovery-original-sha256 >/work/recovery-original-check-before
printf 'begin original-basis attempt\n'
begin_publication_recovery_attempt "$root" 11111111-1111-4111-8111-111111111111
manifest=$(lifecycle_manifest_path "$_transaction_id")
for id in resource-0 configuration; do
  printf 'retain %s\n' "$id"
  retain_publication_recovery_input "$id"
  body=$_publication_recovery_copy_record reference=$_publication_recovery_copy_reference
  if [[ $id == resource-0 ]]; then
    original=$(</work/recovery-original-retained.json)
    source=$(jq -c '.resources[0] | {path:.source,sha256}' /work/admitted-intent.json)
    signing=local-efi
  else
    original=$(</work/recovery-original-configuration.json)
    source=$(jq -c '.configuration' /work/admitted-intent.json)
    signing=bytes
  fi
  expected=$(jq -cn --arg id "$id" --arg signing "$signing" --argjson source "$source" --argjson original "$original" \
    --arg path "${manifest%/*}/publication-data-11111111-1111-4111-8111-111111111111-$id" '
    {id:$id,original_record:$original.reference,original_source:$source,original_retained:$original.body.file,
      signing:$signing,file:($original.body.file | .path=$path)}')
  json_is '.[0] == .[1]' "[$body,$expected]"
  # Both references name their REAL containing records, with direct hash proof.
  original_reference=$(jq -c '.reference' <<<"$original")
  validate_artifact_reference_file "$original_reference" "$directory"
  jq -e --argjson reference "$original_reference" '.publication_records | index($reference) != null' "$directory/manifest.json" >/dev/null
  validate_artifact_reference_file "$reference" "${manifest%/*}"
  jq -e --argjson reference "$reference" '.publication_records | index($reference) != null' "$manifest" >/dev/null
  record=$(jq -r '.path' <<<"$reference")
  jq -e --argjson body "$body" '.schema_version == 2 and .kind == "retained-copy" and .body == $body' "$record" >/dev/null
  original_file=$(jq -r '.original_retained.path' <<<"$body")
  file=$(jq -r '.file.path' <<<"$body")
  cmp -- "$original_file" "$file"
  [[ ! $original_file -ef $file && $(stat -Lc '%a:%u:%g' "$file") == 400:0:0 ]]
  [[ $(sha256_file "$file") == "$(jq -r '.file.sha256' <<<"$body")" &&
    $(stat -Lc %s "$file") == "$(jq -r '.file.bytes' <<<"$body")" ]]
  json_is '.original_source.sha256 != .file.sha256 and .file.sha256 == .original_retained.sha256' "$body"
  jq -cn --argjson body "$body" --argjson reference "$reference" \
    '{body:$body,reference:$reference}' >>/work/recovery-copies.jsonl
done
read_transaction_manifest "$_transaction_id"
json_is '.kind == "recovery-attempt" and .status == "transition" and .file_rollback_policy == "preserve" and
  .current_phase == null and .completed_phases == [] and (.domain_records | all(. == null)) and
  (.publication_records | length == 5 and all(.schema_version == 2))' "$_manifest_json"
[[ -z $_publication_invocation && -z $_publication_signing_policy && ${#_publication_pins[@]} == 0 &&
  ! -e /work/recovery-copy-forbidden && ! -e /work/context-worker-apply && ! -e /boot/limine.conf ]]
sha256sum --check /work/recovery-original-sha256 >/work/recovery-original-check-after
sha256sum /work/signer-commands.jsonl /work/context-wrapper.jsonl /work/publication-requests.jsonl >/work/recovery-activity-after
cmp /work/recovery-activity-before /work/recovery-activity-after
# An independent cryptographic oracle checks the retained PE after the writer has
# finished. It uses the unchanged fixture certificate through real sbctl, without
# constructing fresh Core signer policy or granting boot execution authority.
certificate=$(openssl x509 -in /var/lib/sbctl/keys/db/db.pem -outform DER | sha256sum)
[[ ${certificate%% *} == "$(</work/context-cert-before)" ]]
file=$(jq -r 'select(.body.id == "resource-0") | .body.file.path' /work/recovery-copies.jsonl)
# Match verify_publication_input's sbctl0.18 Landlock scope for a private file.
SYSTEMD_ESP_PATH="${file%/*}" ESP_PATH="${file%/*}" /real/sbctl verify --json "$file" >/work/recovery-copy-sbctl-verify.json
jq -e --arg file "$file" 'length == 1 and .[0].file_name == $file and .[0].is_signed == 1' /work/recovery-copy-sbctl-verify.json >/dev/null
sha256sum --check /work/recovery-original-sha256 >/work/recovery-original-check-verified
# A3: fresh stable context and one classified observation per original effect
# in the same attempt. The real collector wrapper and the real signer run again
# through the fixture bindings; the producer, renderer and staging stay forbidden.
for helper in publication_collect_stable_context publication_verify_stable_context publication_verify_live \
  publication_run_sbctl verify_publication_input publication_input_is_efi; do
  definition=$(declare -f "fixture_real_$helper")
  eval "${definition/#fixture_real_"$helper"/$helper}"
done
unset -f sbctl
publication_context_helper_path() { printf '/core/lib/publication-context.py\n'; }
publication_context_python_path() { printf '/fixtures/context-python\n'; }
producer_package_version() { [[ $1 == sbctl ]] && printf '%s\n' "$SUPPORTED_SBCTL_VERSION"; }
producer_file_owner_package() {
  case $1 in
    /core/lib/publication-context.py) printf 'omasecboot\n' ;;
    /fixtures/context-python) printf 'python\n' ;;
    /usr/bin/sbctl) printf 'sbctl\n' ;;
    *) return 1 ;;
  esac
}
printf 'valid\n' >/work/context-mode
printf 'recovery\n' >/work/signer-phase
witnesses=$(jq -s 'length' /work/context-wrapper.jsonl)
printf 'fresh context\n'
prepare_publication_recovery_context
context=$_publication_recovery_context_record
json_is '.[0].context == .[1].body.context and .[0].original_context.projection == ".body.context"' \
  "[$context,$(cat "$directory/publication-1.json")]"
json_is '.signing_policy.configuration_state == "absent" and .signing_policy.configuration_sha256 == "" and
  .signing_policy.executable == "/usr/bin/sbctl" and .signing_policy.certificate == "/var/lib/sbctl/keys/db/db.pem"' "$context"
[[ $(jq -r '.context.local_db_certificate_der_sha256' <<<"$context") == "$(</work/context-cert-before)" ]]
[[ $(jq -s 'length' /work/context-wrapper.jsonl) == $((witnesses+1)) ]]
jq -se --arg der "$(</work/context-cert-before)" 'last.certificate_der_sha256 == $der' /work/context-wrapper.jsonl >/dev/null
# The resource target's ancestors are absent on the empty ESP: the fresh
# authorization refuses rather than creating them. Recreate the ancestors as
# the later readiness step would, then classify the absent target.
[[ ! -e /boot/EFI ]]
if authorize_publication_recovery_target resource-0; then exit 90; fi
[[ -z $_publication_recovery_authorization_record && -z $_publication_recovery_authorization_reference &&
  ! -e /boot/EFI && $_publication_mount_invalid == false ]]
printf 'missing ancestors refused\n'
mkdir -p /boot/EFI/Linux
for id in resource-0 configuration; do
  printf 'authorize %s\n' "$id"
  authorize_publication_recovery_target "$id"
  body=$_publication_recovery_authorization_record reference=$_publication_recovery_authorization_reference
  copy=$(jq -c --arg id "$id" 'select(.body.id == $id)' /work/recovery-copies.jsonl)
  json_is '.classification == "allowed-absence" and .observation.state.kind == "absent" and
    .original_effect.absence.reason == "original-recreate-missing" and .mount_view.directories[0].path == "/"' "$body"
  json_is '.[0].copy.reference == .[1].reference and .[0].copy.file == .[1].body.file' "[$body,$copy]"
  if [[ $id == resource-0 ]]; then
    # shellcheck disable=SC2016 # jq-bound certificate hash.
    jq -e --arg der "$(</work/context-cert-before)" '.original_effect.signing == "local-efi" and
      .signature == {verified:true,certificate_der_sha256:$der}' <<<"$body" >/dev/null
  else json_is '.original_effect.signing == "bytes" and .signature == null' "$body"; fi
  jq -e --argjson reference "$reference" '.publication_records | index($reference) != null' "$manifest" >/dev/null
  jq -cn --argjson body "$body" --argjson reference "$reference" '{body:$body,reference:$reference}' >>/work/recovery-authorizations.jsonl
done
read_transaction_manifest "$_transaction_id"
json_is '.kind == "recovery-attempt" and .status == "transition" and .file_rollback_policy == "preserve" and
  .current_phase == null and .completed_phases == [] and (.domain_records | all(. == null)) and
  (.publication_records | length == 8 and all(.schema_version == 2))' "$_manifest_json"
if commit_lifecycle_recovery_attempt; then exit 90; fi
sha256sum --check /work/recovery-original-sha256 >/work/recovery-original-check-authorized
# Only the recreated ancestor directories exist on the ESP: no file was written.
[[ ! -e /work/recovery-copy-forbidden && ! -e /work/context-worker-apply && ! -e /boot/limine.conf &&
  -d /boot/EFI/Linux && -z $(find /boot -type f) ]]
printf 'PASS: fresh context and classified authorizations recorded in fresh namespace\n'
# A4a: disposable sibling stages from the private copies, then the readiness
# plan validated by the real native plan validator through a held descriptor.
# The stage writer stays forbidden through context and authorization; only
# the staging phase restores it.
definition=$(declare -f fixture_real_publication_stage_file)
eval "${definition/#fixture_real_publication_stage_file/publication_stage_file}"
for id in resource-0 configuration; do
  printf 'stage %s\n' "$id"
  stage_publication_recovery_target "$id"
  body=$_publication_recovery_stage_record reference=$_publication_recovery_stage_reference
  auth=$(jq -c --arg id "$id" 'select(.body.id == $id) | .body' /work/recovery-authorizations.jsonl)
  # shellcheck disable=SC2016 # jq-local parent path.
  json_is '(.[1].target | split("/")[:-1] | join("/")) as $parent |
    .[0].target == .[1].target and .[0].before == .[1].observation.state and .[0].retained == .[1].copy.file and
    .[0].stage.state.sha256 == .[1].copy.file.sha256 and (.[0].stage.path | startswith($parent + "/.omasecboot-"))' "[$body,$auth]"
  cmp -- "$(jq -r '.retained.path' <<<"$body")" "$(jq -r '.stage.path' <<<"$body")"
  jq -cn --argjson body "$body" --argjson reference "$reference" '{body:$body,reference:$reference}' >>/work/recovery-stages.jsonl
done
exec {native_fd}</fixtures/native
printf 'ready\n'
ready_publication_recovery_plan "$native_fd"
exec {native_fd}<&-
printf '%s\n' "$_publication_recovery_ready_record" >/work/recovery-ready.json
json_is '.format == "limine-prepared-publication" and .schema == 1 and (.puts | length == 1) and .puts[0].id == "resource-0" and
  .configuration.id == "configuration" and .puts[0].before.kind == "absent" and .configuration.before.kind == "absent" and
  .puts[0].after.kind == "file" and .deletes == [] and .references == []' "$_publication_recovery_ready_record"
json_is '.[0] == .[1]' "[$_publication_recovery_ready_record,$_publication_plan]"
read_transaction_manifest "$_transaction_id"
json_is '.status == "transition" and .current_phase == null and (.domain_records | all(. == null)) and
  (.publication_records | length == 11 and all(.schema_version == 2))' "$_manifest_json"
if commit_lifecycle_recovery_attempt; then exit 90; fi
sha256sum --check /work/recovery-original-sha256 >/work/recovery-original-check-ready
# The stages are the only files on the ESP: hidden siblings, no canonical target.
[[ ! -e /work/recovery-copy-forbidden && ! -e /work/context-worker-apply && ! -e /boot/limine.conf &&
  ! -e /boot/EFI/Linux/contract_linux.efi && $(find /boot -type f | wc -l) == 2 &&
  -z $(find /boot -type f ! -name '.omasecboot-*') ]]
printf 'PASS: fresh stages and readiness plan recorded in fresh namespace\n'
release_boot_repair_lock
printf 'PASS: exact signed PE and literal configuration retained in fresh namespace\n'
SCRIPT
shellcheck "$scratch/fixtures/native" "$scratch/fixtures/case" "$scratch/fixtures/session-child" "$scratch/fixtures/dd" "$scratch/fixtures/mount-custody" "$scratch/fixtures/context-python" "$scratch/fixtures/no-platform-query" "$scratch/fixtures/sbctl-call" "$scratch/fixtures/namespace-id" "$scratch/fixtures/recovery-copy"
sandbox=(bwrap --unshare-all --die-with-parent --new-session --uid 0 --gid 0 --clearenv
  --ro-bind /usr/lib /usr/lib --dir /usr/bin --symlink usr/bin /bin --symlink usr/lib /lib
  --tmpfs /usr/lib/modules --proc /proc --dev /dev --tmpfs /tmp --dir /etc --dir /var --dir /sys --dir /run/lock
  --ro-bind "$java_home" /jdk --ro-bind "$repo/lib" /core/lib --ro-bind "$scratch/fixtures" /fixtures
  "${LIMINE_JAVA_MOUNTS[@]}" --setenv PATH /usr/bin:/jdk/bin --setenv LC_ALL C.UTF-8 --setenv TERM dumb
  --setenv HOME /work/home --setenv HISTFILE /dev/null --setenv TMPDIR /tmp --setenv ESP_PATH /boot --chdir /work)
if [[ -d /usr/lib64 ]]; then sandbox+=(--symlink lib /usr/lib64 --symlink usr/lib64 /lib64); fi
for tool in bash jq stat readlink realpath mkdir chmod chown mv sync cat od tr sha256sum b2sum sleep dirname basename date wc find flock openssl touch awk id rm install mktemp cp cut sort head timeout mkfifo sbctl kill cmp env base64; do
  sandbox+=(--ro-bind "$(realpath "$(type -P "$tool")")" "/usr/bin/$tool")
done
sandbox+=(--ro-bind "$(realpath "$(type -P dd)")" /real/dd --ro-bind "$scratch/fixtures/dd" /usr/bin/dd)
sandbox+=(--ro-bind "$scratch/fixtures/context-python" /usr/bin/python
  --ro-bind "$scratch/fixtures/no-platform-query" /usr/bin/btrfs --ro-bind "$scratch/fixtures/no-platform-query" /usr/bin/blkid
  --ro-bind "$scratch/fixtures/sbctl" /real/sbctl --ro-bind "$scratch/fixtures/sbctl-call" /usr/bin/sbctl)
sources=()
for path in "${LIMINE_PATCHED_JAVA[@]}"; do sources+=("/source/$path"); done
"${sandbox[@]}" --bind "$scratch/compiler" /work --ro-bind "$scratch/patched" /source \
  /jdk/bin/javac -J-Xmx1g -J-XX:ActiveProcessorCount=4 -cp "$LIMINE_JAVA_CLASSPATH" -d /work/classes \
  "${sources[@]}" /fixtures/ProducerSessionContract.java >"$scratch/compile.log" 2>&1 || {
    cat "$scratch/compile.log" >&2; die 'Java source compilation';
  }
count=0
for name in supervision-races decoder-exit-0 decoder-exit-19 success nonzero-after-complete no-complete trailing-invalid trailing-frame raw-nul duplicate-key \
  wrong-sequence wrong-invocation unknown-request hang close-and-hang launch-refusal request-refusal \
  terminal-refusal core-interrupt handler-exit restore-marker wrong-token backpressure \
  inherited-flag-success inherited-flag-failure inherited-flag-interrupt lock-rebind abort-identity \
  backpressure-interrupt oversized-reply worker-exec-failure decoder-exec-failure late-lock-rebind post-lock-rebind \
  retain-efi retain-kernel retain-bytes retain-signed retain-source-drift retain-incomplete retain-nonzero \
  retain-fifo retain-growing retain-retry-ready retain-retry-ready-head retain-retry-data retain-retry-record retain-retry-head \
  publish-efi publish-efi-hash publish-linux publish-noop publish-late-failure publish-plan-omit publish-config-drift publish-third-state \
  publish-unstarted-after publish-core-death publish-retry-config-data publish-retry-config-record publish-retry-config-head \
  publish-retry-config-stage publish-retry-plan-head publish-retry-pending-head publish-retry-applied-head \
  publish-core-directory-bind publish-native-namespace publish-native-directory-bind publish-native-stage-bind \
  publish-core-death-directory-bind publish-core-config-bind \
  publish-mkdir-efi publish-mkdir-linux publish-mkdir-pending-record publish-mkdir-pending-head \
  publish-mkdir-retry-dir-sync publish-mkdir-retry-parent-sync publish-mkdir-failed-created publish-mkdir-eexist \
  publish-mkdir-replaced publish-mkdir-collision-target publish-mkdir-collision-ancestor publish-mkdir-collision-config \
  publish-native-final-third-state publish-core-death-final-third-state \
  publish-context-valid publish-context-unknown publish-context-malformed publish-context-shape publish-context-capture-drift \
  publish-context-helper-mismatch publish-context-machine publish-context-path publish-context-esp \
  publish-context-native-machine publish-context-native-path publish-context-between-root publish-context-between-subvolume \
  publish-context-after-cert publish-context-after-platform publish-context-record-retry publish-context-head-retry \
  publish-context-record-uncertain publish-context-head-uncertain publish-context-launch-record publish-context-launch-head \
  publish-context-sbctl-appeared publish-context-sbctl-inplace \
  publish-signer-config-before publish-signer-config-span publish-signer-config-restore-span publish-signer-cert-span \
  publish-signer-unsigned-retained publish-signer-unsigned-stage \
  publish-signer-cert-before publish-signer-executable-before publish-signer-result-malformed-retained publish-signer-result-malformed-stage \
  publish-signer-result-nonzero-retained publish-signer-result-nonzero-stage \
   publish-signer-absent-sbctl-parent publish-signer-absent-etc-parent \
   publish-original-copy-failure publish-original-temp-sync publish-original-data-sync publish-original-directory-sync \
   publish-original-candidate-collision publish-original-source-drift \
   publish-intent-retry-model publish-intent-retry-model-head publish-intent-retry-same publish-intent-retry-same-head \
   publish-intent-match-model publish-recovery-copy-signed; do
  # Space-separated exact case names permit targeted runs with one compilation.
  [[ -z ${PRODUCER_SESSION_CASE:-} || " $PRODUCER_SESSION_CASE " == *" $name "* ]] || continue
  work=$scratch/$name
  mkdir -p "$work/home" "$work/boot" "$work/sbctl"
  printf 'fixture user input\n' >"$work/user-input"
  rc=0
  # An outer watchdog makes a broken internal deadline a bounded test failure.
  watchdog=45
  [[ $name != publish-* ]] || watchdog=300
  mount_case=false
  case $name in
    publish-core-directory-bind|publish-native-namespace|publish-native-directory-bind|publish-native-stage-bind|publish-core-death-directory-bind|publish-core-config-bind) mount_case=true ;;
  esac
  extra=()
  if [[ $name == publish-recovery-copy-signed ]]; then
    extra+=(--ro-bind "$(realpath "$(type -P python)")" /real/namespace-python)
  fi
  if [[ $name == publish-signer-executable-before ]]; then
    cp "$scratch/fixtures/sbctl-call" "$work/sbctl-call-writable"
    chmod 755 "$work/sbctl-call-writable"
    sha256sum "$scratch/fixtures/sbctl-call" | cut -d ' ' -f 1 >"$work/signer-executable-original-sha256"
    extra+=(--bind "$work/sbctl-call-writable" /usr/bin/sbctl)
  fi
  if [[ $name == publish-context-helper-mismatch ]]; then
    # Mutate only this case's disposable copy. Core's fixed literal must reject it
    # before invoking the interpreter; all other cases receive the real file.
    cp "$repo/lib/publication-context.py" "$work/helper-mismatch.py"
    printf '\n# fixture byte mismatch\n' >>"$work/helper-mismatch.py"
    extra+=(--ro-bind "$work/helper-mismatch.py" /core/lib/publication-context.py)
  fi
  if [[ $mount_case == true ]]; then
    extra+=(--cap-add CAP_SYS_ADMIN --setenv MOUNT_CUSTODY_FIXTURE 1)
    for tool in mount umount unshare; do extra+=(--ro-bind "$(realpath "$(type -P "$tool")")" "/usr/bin/$tool"); done
  fi
  timeout --kill-after=5 "$watchdog" "${sandbox[@]}" --bind "$work" /work --ro-bind "$scratch/compiler/classes" /classes \
    --bind "$work/boot" /boot --bind "$work/sbctl" /var/lib/sbctl \
    --ro-bind /usr/share/limine/BOOTX64.EFI /efi-input \
    --setenv _producer_session_active true \
    --setenv ORACLE_FAULT "${PUBLICATION_ORACLE_FAULT:-}" \
    "${extra[@]}" /usr/bin/bash /fixtures/case "$name" <"$work/user-input" >"$work/stdout" 2>"$work/stderr" || rc=$?
  expected=0
  [[ $name != core-interrupt ]] || expected=143
  [[ $name != inherited-flag-interrupt ]] || expected=143
  [[ $name != backpressure-interrupt ]] || expected=143
  [[ $name != handler-exit ]] || expected=23
  if [[ $rc != "$expected" || -e $work/unsafe-recovery || -e $work/signer-boundary-error ]]; then
    cat "$work/stdout" "$work/stderr" >&2
    die "$name expected case status $expected, got $rc"
  fi
  if [[ $name == nonzero-after-complete ]]; then jq -e '.worker_status == 19' "$work/terminal.json" >/dev/null; fi
  if [[ $name == supervision-races ]]; then
    [[ $(wc -l <"$work/helper-results") == 17 ]] || die 'missing supervision race evidence'
  fi
  if [[ $name == decoder-exit-* ]]; then
    [[ $(<"$work/strict-decoder-status") == 0 && $(<"$work/exit-read-status") != 0 && -e $work/exit-observed ]] || die 'decoder exit gate did not reach a real failed read'
    jq -e --argjson status "${name##*-}" '.worker_status == 0 and .decoder_status == $status and .completion_acknowledged and
      (if $status == 0 then .protocol_complete and .supervision_status == 0 else (.protocol_complete | not) and .supervision_status != 0 end)' "$work/terminal.json" >/dev/null
  fi
  if [[ $name == trailing-invalid ]]; then jq -e '.worker_status == 0 and .decoder_status != 0' "$work/terminal.json" >/dev/null; fi
  if [[ $name == trailing-frame ]]; then jq -e '.completion_acknowledged and (.protocol_complete | not) and .supervision_status != 0' "$work/terminal.json" >/dev/null; fi
  if [[ $name == close-and-hang ]]; then jq -e '.protocol_complete and .decoder_status == 0 and .supervision_status != 0' "$work/terminal.json" >/dev/null; fi
  if [[ $name == raw-nul || $name == duplicate-key ]]; then [[ ! -f $work/request-seen ]] || die 'invalid bytes reached handler'; fi
  if [[ $name == launch-refusal || $name == restore-marker || $name == wrong-token ]]; then
    [[ ! -s $work/stdout && ! -e $work/request-seen ]] || die 'refused launch ran the worker'
  fi
  if [[ $name == inherited-flag-failure || $name == inherited-flag-interrupt ]]; then [[ $(<"$work/pinned") == retained ]] || die 'inherited flag skipped rollback'; fi
  if [[ $name == retain-* ]]; then
    [[ -f $work/retention-result ]] || die 'retention body did not finish'
    [[ ! -e $work/context-wrapper-entered && ! -e $work/context-collections.jsonl ]] || die 'raw retention acquired publication context'
    jq -se 'all(.[]; .schema_version == 1 and .kind != "context" and .kind != "invocation-start" and
      (.body | has("recovery") | not) and (.kind != "intent" or (.body | has("publication") | not)))' \
      "$work"/state/transactions/*/publication-*.json >/dev/null || die 'raw retention changed its historical intent flow'
    case $name in
      retain-source-drift|retain-incomplete|retain-nonzero|retain-fifo|retain-growing) [[ $(<"$work/retention-result") != 0 ]] || die 'invalid retention succeeded' ;;
      *) [[ $(<"$work/retention-result") == 0 ]] || { cat "$work/stderr" >&2; die 'valid retention failed'; } ;;
    esac
    # Until full publication/recovery proof is wired, even a successful input
    # session stays recovery-required rather than activating the partial runtime.
    jq -e '.state == "recovery-required"' "$work/state/lifecycle.json" >/dev/null
    if [[ $name == retain-growing ]]; then cmp "$work/original-copy-size" "$work/observed-copy-size" || die 'copy exceeded captured source extent'; fi
    if [[ $name == retain-retry-* ]]; then [[ -e $work/retention-sync-failed ]] || die 'retention sync fault did not run'; fi
  fi
  if [[ $name == publish-mkdir-* ]]; then
    for evidence in preparation-result publication-result directory-journal.json directory-events.jsonl config-inode-before boot-paths-before; do
      [[ -s $work/$evidence ]] || die "$name missing $evidence"
    done
    jq -se 'all(.[]; .event != "mkdir-pending-proof" or .status == 0)' "$work/directory-events.jsonl" >/dev/null || die 'mkdir reached without a bound pending record'
    directory_success=false
    case $name in publish-mkdir-efi|publish-mkdir-linux|publish-mkdir-retry-*) directory_success=true ;; esac
    if [[ $directory_success == true ]]; then
      [[ $(<"$work/preparation-result") == 0 && $(<"$work/publication-result") == 0 && -s $work/parity-verified && -s $work/directory-identities.jsonl ]] || die "$name failed publication/parity"
      expected_directories='["/boot/EFI","/boot/EFI/Linux"]'
      [[ $name != publish-mkdir-linux ]] || expected_directories='["/boot/11111111111111111111111111111111","/boot/11111111111111111111111111111111/linux"]'
      find "$work/boot" -mindepth 1 -type d -printf '/boot/%P\n' | sort >"$work/created-directory-paths"
      jq -Rse --argjson paths "$expected_directories" '(split("\n") | map(select(length > 0))) == $paths' "$work/created-directory-paths" >/dev/null || die 'created unrelated directory paths'
      jq -e --argjson paths "$expected_directories" '
        . as $records | [.[] | select(.kind == "directory-pending")] as $pending |
        [.[] | select(.kind == "directory-created")] as $created |
        ($pending | map(.body.path) | sort) == $paths and ($created | map(.body.path) | sort) == $paths and
        all($created[]; . as $c | any($pending[]; .body.id == $c.body.id and .ordinal < $c.ordinal) and
          any($records[]; .kind == "boot-stage" and (.body.target | startswith($c.body.path + "/")) and .ordinal > $c.ordinal))' "$work/directory-journal.json" >/dev/null || die "$name directory journal order/coverage"
      while IFS= read -r identity; do
        path=$(jq -r '.path' <<<"$identity")
        actual=$(stat -Lc '%d:%i' "$work/boot${path#/boot}")
        [[ $actual == "$(jq -r '.identity' <<<"$identity")" ]] || die 'created directory identity changed'
        jq -e --arg path "$path" --arg identity "$actual" 'any(.[]; .kind == "directory-created" and .body.path == $path and .body.state.identity == $identity)' "$work/directory-journal.json" >/dev/null
      done <"$work/directory-identities.jsonl"
      jq -se --argjson paths "$expected_directories" '
        to_entries as $events |
        def indexes($event; $path): [$events[] | select(.value.event == $event and .value.path == $path and .value.status == 0) | .key];
        ([.[] | select(.event == "mkdir-invoke") | .path] | sort) == $paths and
        all($paths[]; . as $path | indexes("mkdir-result"; $path)[0] as $mkdir |
          indexes("directory-created"; $path)[0] as $created |
          indexes("directory-pending"; $path)[0] < indexes("mkdir-invoke"; $path)[0] and
          any($events[]; .key < $mkdir and .value.event == "targets" and .value.status == 0) and
          any($events[]; .key > $mkdir and .key < $created and .value.event == "targets" and .value.status == 0) and
          any(indexes("sync"; $path)[]; . as $synced | $synced > $mkdir and $synced < $created and
            any(indexes("sync"; ($path | split("/") | .[:-1] | join("/")))[]; . > $synced and . < $created))) and
        indexes("prepared-terminal"; "")[0] as $prepared | indexes("executor-start"; "")[0] as $executor |
        any($events[]; .key > $prepared and .key < $executor and .value.event == "targets" and .value.status == 0)
      ' "$work/directory-events.jsonl" >/dev/null || die "$name missed real validation/mkdir/sync boundaries"
      if [[ $name == publish-mkdir-retry-* ]]; then
        for evidence in directory-fault directory-first-result directory-second-result directory-final-result directory-retry-verified directory-candidate-first.json directory-candidate-second.json directory-candidate-final.json; do
          [[ -s $work/$evidence ]] || die "$name missing $evidence"
        done
        [[ $(<"$work/directory-first-result") != 0 && $(<"$work/directory-second-result") != 0 && $(<"$work/directory-final-result") == 0 ]]
        cmp "$work/directory-candidate-first.json" "$work/directory-candidate-second.json"
        cmp "$work/directory-candidate-first.json" "$work/directory-candidate-final.json"
        jq -e '.candidate.state == .held and .held.kind == "directory"' "$work/directory-candidate-first.json" >/dev/null
        jq -se '[.[] | select(.event == "sync-refused")] | length == 2' "$work/directory-events.jsonl" >/dev/null
      fi
    else
      [[ $(<"$work/preparation-result") != 0 && $(<"$work/publication-result") != 0 && ! -e $work/application.json ]] || die "$name did not refuse preparation"
      cmp "$work/config-before" "$work/boot/limine.conf"
      [[ $(stat -Lc '%d:%i' "$work/boot/limine.conf") == "$(<"$work/config-inode-before")" ]] || die 'configuration inode changed on directory refusal'
      jq -e 'all(.[]; .kind != "directory-created" and .kind != "boot-stage" and .kind != "effect-pending" and .kind != "effect-applied")' "$work/directory-journal.json" >/dev/null
      [[ -z $(find "$work/boot" -name '*.stage' -print -quit) ]] || die "$name allocated a stage"
      if [[ $name == publish-mkdir-pending-* || $name == publish-mkdir-collision-* ]]; then
        find "$work/boot" -mindepth 1 -printf '%P\n' | sort >"$work/boot-paths-after"
        cmp "$work/boot-paths-before" "$work/boot-paths-after"
        jq -se 'all(.[]; .event != "mkdir-invoke")' "$work/directory-events.jsonl" >/dev/null
        if [[ $name == publish-mkdir-pending-* ]]; then
          [[ -s $work/directory-fault && -s $work/directory-first-result && $(<"$work/directory-first-result") != 0 ]] || die 'pending durability fault not reached'
          jq -se 'any(.[]; .event == "sync-refused" and .status != 0)' "$work/directory-events.jsonl" >/dev/null
        else
          [[ -s $work/target-validation.stderr ]] || die 'target validator diagnostic missing'
          diagnostic=$(<"$work/target-validation.stderr")
          if [[ $name == publish-mkdir-collision-ancestor ]]; then
            [[ $diagnostic == *'Overlapping or aliased publication targets:'* ]] || die 'ancestor refused before actual target validator'
          else [[ $diagnostic == *'Duplicate target or target outside the admitted ESP:'* ]] || die 'collision refused before actual target validator'; fi
          jq -se 'any(.[]; .event == "targets" and .status != 0)' "$work/directory-events.jsonl" >/dev/null
          jq -se 'last.operation == "match-intent"' "$work/publication-requests.jsonl" >/dev/null
        fi
      else
        for evidence in directory-fault directory-first-result directory-second-result directory-retry-refused journal-at-directory-failure.json; do
          [[ -s $work/$evidence ]] || die "$name missing $evidence"
        done
        [[ $(<"$work/directory-first-result") != 0 && $(<"$work/directory-second-result") != 0 ]]
        jq -se '[.[] | select(.event == "mkdir-invoke")] | length == 1' "$work/directory-events.jsonl" >/dev/null
        jq -e '[.[] | select(.kind == "directory-pending")] | length == 1' "$work/directory-journal.json" >/dev/null
        if [[ $name == publish-mkdir-failed-created ]]; then
          [[ -s $work/failed-created-identity && $(stat -Lc '%d:%i' "$work/boot/EFI") == "$(<"$work/failed-created-identity")" ]] || die 'uncertain created inode changed'
          jq -se 'any(.[]; .event == "mkdir-result" and .status == 73 and .data.actual_status == 0)' "$work/directory-events.jsonl" >/dev/null
        else
          for evidence in foreign-directory-before foreign-file-before foreign-bytes-before; do [[ -s $work/$evidence ]] || die "missing $evidence"; done
          [[ $(stat -Lc '%d:%i' "$work/boot/EFI") == "$(<"$work/foreign-directory-before")" && $(stat -Lc '%d:%i' "$work/boot/EFI/user-data") == "$(<"$work/foreign-file-before")" ]]
          read -r expected_hash _ <"$work/foreign-bytes-before"
          actual_hash=$(sha256sum "$work/boot/EFI/user-data")
          [[ ${actual_hash%% *} == "$expected_hash" ]] || die 'foreign directory user data changed'
          if [[ $name == publish-mkdir-eexist ]]; then
            jq -se 'any(.[]; .event == "mkdir-result" and .status != 0 and .data.actual_status != 0)' "$work/directory-events.jsonl" >/dev/null
          else
            [[ -s $work/directory-replacement-proof && -s $work/directory-candidate-first.json ]] || die 'retained directory replacement not proved'
            [[ $(stat -Lc '%d:%i' "$work/boot/replaced-directory") == "$(jq -r '.held.identity' "$work/directory-candidate-first.json")" && ! $work/boot/replaced-directory -ef $work/boot/EFI ]]
          fi
        fi
      fi
    fi
  fi
  if [[ $mount_case == true ]]; then
    for evidence in preparation-result publication-result result mount-stages.json mount-witness-prepared mount-witness-final; do
      [[ -s $work/$evidence ]] || die "$name missing $evidence"
    done
    [[ ! -e $work/mount-blocker && $(<"$work/preparation-result") == 0 && $(<"$work/publication-result") != 0 ]] || die "$name did not exercise a prepared mount refusal"
    cmp "$work/mount-witness-prepared" "$work/mount-witness-final" || die "$name changed stage/config/target bytes or inodes"
    records=("$work"/state/transactions/*/publication-*.json)
    jq -se 'all(.[]; .kind != "effect-applied")' "${records[@]}" >/dev/null || die "$name applied an effect"
    if [[ $name != publish-native-namespace ]]; then
      for evidence in mount-command-result mount-bind-proof.json mount-witness-before-bind mount-witness-after-bind; do
        [[ -s $work/$evidence ]] || die "$name missing $evidence"
      done
      [[ $(<"$work/mount-command-result") == 0 ]] || die "$name mount capability blocker"
      jq -e '.same_object and .before_mount != .after_mount' "$work/mount-bind-proof.json" >/dev/null
      cmp "$work/mount-witness-prepared" "$work/mount-witness-before-bind"
      cmp "$work/mount-witness-prepared" "$work/mount-witness-after-bind"
    fi
    if [[ $name == publish-core-directory-bind || $name == publish-core-config-bind ]]; then
      for evidence in core-mount-refused core-sticky-refused executor-retry-result mount-unmounted-proof unmount-command-result core-pins-before core-pins-after; do
        [[ -s $work/$evidence ]] || die "$name missing $evidence"
      done
      [[ $(<"$work/executor-retry-result") != 0 && $(<"$work/unmount-command-result") == 0 && ! -e $work/application.json ]] || die "$name revived invalid attempt"
      cmp "$work/core-pins-before" "$work/core-pins-after"
      jq -se 'all(.[]; .kind != "effect-pending")' "${records[@]}" >/dev/null
    else
      for evidence in native-mount-refused.json custody-proof application.json publication-launch.json executor-start-result publication-requests.jsonl; do
        [[ -s $work/$evidence ]] || die "$name missing $evidence"
      done
      [[ $(<"$work/executor-start-result") == 0 ]] || die "$name failed before native executor"
      jq -e '.applied_calls == 0 and (.reason | length > 0)' "$work/native-mount-refused.json" >/dev/null
      if [[ $name == publish-native-namespace ]]; then
        [[ -s $work/namespace-proof.json ]] || die 'namespace exec witness missing'
        jq -e '.before != .after and .same_pid and .inherited_pins' "$work/namespace-proof.json" >/dev/null
        jq -e '.reason == "Publication mount namespace changed" and .boundary == "worker-exec"' "$work/native-mount-refused.json" >/dev/null
        jq -se 'last.operation == "application"' "$work/publication-requests.jsonl" >/dev/null
        jq -se 'all(.[]; .kind != "effect-pending")' "${records[@]}" >/dev/null
      else
        for evidence in last-authorized-frontier.json native-sticky-refused.json mount-unmounted-proof unmount-command-result; do
          [[ -s $work/$evidence ]] || die "$name missing $evidence"
        done
        [[ $(<"$work/unmount-command-result") == 0 ]] || die 'native sticky test unmount failed'
        jq -e '.reason == "Publication live custody was invalidated" and .same_authority and .applied_calls == 0' "$work/native-sticky-refused.json" >/dev/null
        jq -e '.phase == "pending" and .applied_calls == 0' "$work/last-authorized-frontier.json" >/dev/null
        alive=true
        [[ $name != publish-core-death-directory-bind ]] || alive=false
        jq -e --arg path "$(jq -r '.path' "$work/mount-bind-proof.json")" --argjson alive "$alive" \
          '.path == $path and .reason == ("Fresh pathname differs from held mount/object custody: " + $path) and
           .boundary == "after-last-pending-frontier" and .core_alive == $alive' "$work/native-mount-refused.json" >/dev/null
        jq -se 'last.operation == "frontier"' "$work/publication-requests.jsonl" >/dev/null
        jq -se '[.[] | select(.kind == "effect-pending")] | length == 1' "${records[@]}" >/dev/null
      fi
    fi
  fi
  if [[ $name == publish-native-final-third-state || $name == publish-core-death-final-third-state ]]; then
    for evidence in preparation-result executor-start-result publication-result result custody-proof application.json third-state-original.json \
      third-state-frontier.json third-state-core.json third-state-first-local.json third-state-boundary.json native-target-refused.json \
      third-state-preserved-before.json third-state-preserved-after.json third-state-final.json third-state-foreign-bytes \
      third-state-requests-before third-state-requests-after; do
      [[ -s $work/$evidence ]] || die "$name missing $evidence"
    done
    [[ $(<"$work/preparation-result") == 0 && $(<"$work/executor-start-result") == 0 && $(<"$work/publication-result") != 0 ]] || die 'final target guard not reached'
    alive=true; original_kind=absent
    if [[ $name == publish-core-death-final-third-state ]]; then alive=false; original_kind='file'; fi
    jq -e --argjson alive "$alive" --arg kind "$original_kind" --slurpfile original "$work/third-state-original.json" \
      --slurpfile frontier "$work/third-state-frontier.json" --slurpfile first "$work/third-state-first-local.json" \
      --slurpfile final "$work/third-state-final.json" '
        . as $b | .local_call == 2 and .first_local_passed and .core_alive == $alive and .before.kind == $kind and
        (.before | {kind,identity,sha256}) == $original[0] and
        .foreign.kind == "file" and .foreign.identity != .before.identity and .foreign.identity != .authorized_after.identity and
        .foreign.sha256 != .authorized_after.sha256 and .foreign == $final[0].target and
        .mount.parent == .mount.expected and .mount.parent == .mount.stage and .mount.parent == .mount.target and
        (.mount.parent | test("^[1-9][0-9]*$")) and (.mount.namespace | test("^mnt:\\[[1-9][0-9]*\\]$")) and
        .site.method == "org.limine.entry.tool.processes.PreparedPublication.applyPut" and .site.first_line > 0 and .site.final_line > .site.first_line and
        $frontier[0].phase == "pending" and $frontier[0].local_calls == 0 and $frontier[0].target == .before and $frontier[0].observed == .authorized_after and
        $first[0].local_call == 1 and $first[0].target == .before and $first[0].core_alive == $alive and
        $final[0].local_calls == 2 and $final[0].applied_calls == 0' "$work/third-state-boundary.json" >/dev/null || die 'wrong final local-check injection boundary'
    jq -e --argjson alive "$alive" '.alive == $alive and .killed == ($alive | not) and .pins_survived' "$work/third-state-core.json" >/dev/null
    target=$(jq -r '.target' "$work/third-state-boundary.json")
    [[ $target == /boot/EFI/Linux/contract_linux.efi ]] || die 'unexpected target witness'
    jq -e --arg target "$target" --argjson alive "$alive" '
      .reason == ("Publication target left its pinned before/after states: " + $target) and .local_call == 2 and .core_alive == $alive and .applied_calls == 0' \
      "$work/native-target-refused.json" >/dev/null || die 'missing exact local target refusal'
    cmp "$work/third-state-foreign-bytes" "$work/boot${target#/boot}"
    [[ $(stat -Lc '%d:%i' "$work/boot${target#/boot}") == "$(jq -r '.foreign.identity' "$work/third-state-boundary.json")" ]] || die 'foreign target overwritten'
    jq -se '.[0] == .[1]' "$work/third-state-preserved-before.json" "$work/third-state-preserved-after.json" >/dev/null || die 'pinned stage/configuration changed'
    for object in stage configuration; do
      path=$(jq -r --arg object "$object" '.[$object].path' "$work/third-state-preserved-after.json")
      [[ $path == /boot/* ]] || die 'invalid preserved object witness'
      identity=$(stat -Lc '%d:%i' "$work/boot${path#/boot}")
      hash=$(sha256sum "$work/boot${path#/boot}")
      jq -e --arg object "$object" --arg identity "$identity" --arg hash "${hash%% *}" \
        '.[$object].state.kind == "file" and .[$object].state.identity == $identity and .[$object].state.sha256 == $hash' "$work/third-state-preserved-after.json" >/dev/null
    done
    cmp "$work/third-state-requests-before" "$work/third-state-requests-after"
    cmp "$work/third-state-requests-after" "$work/publication-requests.jsonl"
    jq -se 'last.operation == "frontier"' "$work/publication-requests.jsonl" >/dev/null
    records=("$work"/state/transactions/*/publication-*.json)
    jq -se --slurpfile boundary "$work/third-state-boundary.json" '
      all(.[]; .kind != "effect-applied") and ([.[] | select(.kind == "effect-pending")] | length == 1) and
      any(.[]; .kind == "effect-pending" and .body.observed == $boundary[0].before and .body.result == $boundary[0].authorized_after)' \
      "${records[@]}" >/dev/null || die 'final target rejection has incorrect effect records'
  fi
  if [[ $name == publish-core-death || $name == publish-core-death-directory-bind || $name == publish-core-death-final-third-state ]]; then
    for evidence in result publication-result after-core-death custody-proof; do [[ -s $work/$evidence ]] || die "$name missing $evidence"; done
    [[ $(<"$work/result") == 137 && $(<"$work/publication-result") != 0 ]] || die 'Core-death outcome missing'
  fi
  if [[ $name == publish-* ]]; then
    [[ ! -e $work/context-host-query && ! -e $work/context-wrapper-error && -s $work/context-begin-result ]] || die "$name missed fixture context boundary"
    [[ -s $work/start-heads.jsonl && ! -e $work/start-observation-error ]] || die 'actual manifest head observations missing'
    cmp "$work/start-boot-before" "$work/start-boot-after" || die 'begin/retry changed canonical boot objects'
    jq -se --slurpfile intent "$work/admitted-intent.json" --slurpfile platform "$work/context-original-platform.json" \
      --arg der "$(<"$work/context-cert-before")" --arg case "$name" '
      first.configuration as $before |
      first.boundary == "before-begin" and first.manifest.file_rollback_policy == "restore" and first.manifest.publication_records == [] and
      all(.[]; (.worker_started | not) and .configuration.identity == $before.identity and
        ($case == "publish-original-source-drift" or .configuration.sha256 == $before.sha256)) and
      all(.[]; if .manifest.publication_records == [] then .manifest.file_rollback_policy == "restore" and .record == null
        else .manifest.file_rollback_policy == "preserve" and (.manifest.publication_records | length) == 1 and
          .manifest.publication_records[0].schema_version == 2 and .record.schema_version == 2 and .record.kind == "invocation-start" and
          .record.ordinal == 1 and .record.previous == null and
          (.record.body | keys == ["context","intent","original_configuration","recovery"]) and .record.body.intent == $intent[0] and
          .record.body.context == ($platform[0] | .local_db_certificate_der_sha256=$der) and
          .record.body.context.configuration_path == $intent[0].configuration.path and
          .record.body.recovery == {recreate_missing:([$intent[0].resources[] | {id,target}] + [{id:"configuration",target:$intent[0].configuration.path}])} and
          .record.body.original_configuration == (.original | {path,sha256,bytes}) and
          .original.sha256 == $intent[0].configuration.sha256 and .original.mode == "400" and .original.owner == "0:0"
        end)' "$work/start-heads.jsonl" >/dev/null || die 'actual head exposed partial original authority or an early preserve policy'
    if jq -se 'any(.[]; .record != null)' "$work/start-heads.jsonl" >/dev/null; then
      [[ -s $work/start-manifest-renames && $(<"$work/start-manifest-renames") == 0 ]] || die 'start/preserve did not use exactly one manifest rename'
    else [[ ! -e $work/start-manifest-renames ]] || die 'failed pre-bind start changed manifest'; fi
    if [[ -s $work/start-typed-parts.jsonl ]]; then
      [[ -s $work/start-actual-kind-proof ]] || die 'actual-kind reader proof missing'
      jq -se '[.[].part] == ["intent","context","original_configuration","recovery"] and
        ([.[].reference] | unique | length) == 1 and all(.[]; .container == "invocation-start" and .projection == (".body." + .part) and .reference.schema_version == 2)' \
        "$work/start-typed-parts.jsonl" >/dev/null || die 'typed view changed real containing reference'
    fi
    for record in "$work"/state/transactions/*/publication-*.json; do
      [[ -f $record ]] || continue
      if jq -e '.kind == "invocation-start"' "$record" >/dev/null; then
        path=$(jq -r '.body.original_configuration.path' "$record")
        [[ $path == /work/state/transactions/*/publication-data-11111111-1111-4111-8111-111111111111-original-configuration ]] || die 'wrong original-copy namespace'
        original="$work/${path#/work/}"
        cmp "$original" "$work/config-before" || die 'original configuration bytes not preserved'
        hash=$(sha256sum "$original")
        jq -e --arg hash "${hash%% *}" --argjson bytes "$(stat -Lc %s "$original")" --slurpfile intent "$work/admitted-intent.json" '
          .schema_version == 2 and .body.intent == $intent[0] and
          .body.original_configuration.sha256 == $hash and .body.original_configuration.bytes == $bytes and
          .body.recovery == {recreate_missing:([$intent[0].resources[] | {id,target}] + [{id:"configuration",target:$intent[0].configuration.path}])}' \
          "$record" >/dev/null || die 'start original-copy hash/length or exact permission differs'
        [[ $(stat -Lc %a "$original") == 400 && ! $original -ef "$work/boot/limine.conf" ]] || die 'original configuration is not a separate private copy'
        hash=$(sha256sum "$record")
        jq -se --arg hash "${hash%% *}" 'all(.[]; .record == null or .manifest.publication_records[0].sha256 == $hash)' "$work/start-heads.jsonl" >/dev/null
      else jq -e '.schema_version == 1 and .kind != "intent" and .kind != "context"' "$record" >/dev/null || die 'publication fabricated a legacy authority record'; fi
    done
    if [[ $name == publish-context-helper-mismatch ]]; then
      [[ ! -e $work/context-wrapper-entered && ! -e $work/context-wrapper.jsonl ]] || die 'wrong helper bytes reached interpreter'
    else
      [[ -s $work/context-wrapper.jsonl ]] || die "$name did not invoke the real collector wrapper"
      jq -se --arg helper "$(<"$scratch/fixtures/context-helper.sha256")" \
        'all(.[]; .helper_sha256 == $helper and .isolated_arguments and .clean_environment and .root_directory and .esp_directory and .public_certificate)' \
        "$work/context-wrapper.jsonl" >/dev/null || die 'collector binding/environment/descriptors not witnessed'
      jq -se --arg der "$(<"$work/context-cert-before")" 'first.certificate_der_sha256 == $der' "$work/context-wrapper.jsonl" >/dev/null
    fi
    if [[ -s $work/context-first-launch-journal.json ]]; then
      [[ -s $work/context-first-launch-proof ]] || die 'launch ordering proof missing'
      jq -e 'sort_by(.ordinal) | map(.kind) == ["invocation-start"]' "$work/context-first-launch-journal.json" >/dev/null || die 'complete start not persisted before first launch'
      jq -e --arg der "$(<"$work/context-cert-before")" --slurpfile intent "$work/admitted-intent.json" '
        map(select(.kind == "invocation-start")) | length == 1 and (.[0].body.context |
          keys == ["architecture","configuration_path","esp","local_db_certificate_der_sha256","machine_id","root","schema_version"] and
          .schema_version == 1 and .local_db_certificate_der_sha256 == $der and
          .machine_id == ($intent[0].publication.model | fromjson | .machine_id) and
          .configuration_path == $intent[0].configuration.path and .esp.path == $intent[0].esp_path and .root.path == "/" and
          (.root | keys == ["filesystem_type","filesystem_uuid","path","subvolume"]) and
          (.root.subvolume | keys == ["id","kind","uuid"] and .id == "256") and
          (.esp | keys == ["filesystem_type","filesystem_uuid","partition_scheme","partition_type","partition_uuid","path"]))' \
        "$work/context-first-launch-journal.json" >/dev/null || die 'wrong typed context at launch'
    fi
  fi
  if [[ $name == publish-context-* ]]; then
    [[ -s $work/publication-result && $(<"$work/result") != 0 ]] || die "$name missing explicit publication/lifecycle results"
    jq -e '.state != "active"' "$work/state/lifecycle.json" >/dev/null
    case $name in
      publish-context-unknown|publish-context-malformed|publish-context-shape|publish-context-capture-drift|publish-context-helper-mismatch|publish-context-machine|publish-context-path|publish-context-esp|publish-context-sbctl-*)
        [[ $(<"$work/context-begin-result") != 0 && -s $work/context-capture-refused && $(<"$work/publication-result") != 0 &&
           ! -e $work/publication-launch.json && ! -e $work/context-worker-prepare && ! -e $work/publication-requests.jsonl && ! -s $work/stdout ]] || die "$name did not refuse initial capture"
        jq -e '.file_rollback_policy == "restore" and .publication_records == []' "$work/context-begin-manifest.json" >/dev/null
        [[ -z $(find "$work/state/transactions" -name 'publication-*.json' -print -quit) ]] || die 'capture failure published an intent/context record'
        cmp "$work/config-before" "$work/boot/limine.conf"
        [[ $(stat -Lc '%d:%i' "$work/boot/limine.conf") == "$(<"$work/context-config-before")" && ! -e $work/boot/EFI/Linux/contract_linux.efi ]] || die 'capture refusal changed canonical outputs'
        jq -se 'length == 1 and first.status != 0' "$work/context-collections.jsonl" >/dev/null
        if [[ $name == publish-context-capture-drift ]]; then [[ -s $work/context-capture-drift ]] || die 'capture drift injection not reached'; fi
        if [[ $name == publish-context-sbctl-* ]]; then
          [[ -s $work/context-sbctl-injected && -s $work/context-sbctl-boundary-verified &&
             $(<"$work/context-sbctl-before-result") == 0 && $(<"$work/context-sbctl-after-result") == 0 ]] || die 'valid sbctl metadata boundary not exercised'
          jq -se 'length == 1' "$work/context-wrapper.jsonl" >/dev/null
          jq -se --slurpfile wrapper "$work/context-wrapper.jsonl" '
            .[0].certificate == .[1].certificate and .[0].certificate.der_sha256 == $wrapper[0].certificate_der_sha256 and
            .[0].certificate.pem_sha256 == $wrapper[0].certificate_pem_sha256 and
            .[0].executable_sha256 == .[1].executable_sha256 and .[1].config.state == "present" and
            .[0].config.sha256 != .[1].config.sha256' "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null || die 'metadata span did not isolate the configuration change'
          if [[ $name == publish-context-sbctl-appeared ]]; then
            jq -e '.config == {state:"absent",sha256:"",identity:null}' "$work/context-sbctl-before.json" >/dev/null
          else
            jq -se '.[0].config.state == "present" and .[0].config.identity == .[1].config.identity' \
              "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null || die 'hash drift replaced the configuration inode'
          fi
          jq -e --slurpfile platform "$work/context-platform.json" --slurpfile boundary "$work/context-sbctl-after.json" '
            .format == "omasecboot-publication-context" and .schema == 1 and .complete and
            .context == ($platform[0] | .local_db_certificate_der_sha256=$boundary[0].certificate.der_sha256)' \
            "$work/context-sbctl-response.json" >/dev/null || die 'metadata change altered the valid context body'
          hash=$(sha256sum "$work/context-sbctl-post.conf")
          jq -e --arg hash "${hash%% *}" '.config.sha256 == $hash' "$work/context-sbctl-after.json" >/dev/null
        fi
        ;;
      *)
        records=("$work"/state/transactions/*/publication-*.json)
        jq -s 'sort_by(.ordinal)' "${records[@]}" >"$work/context-final-journal.json"
        case $name in
          publish-context-valid|publish-context-record-retry|publish-context-head-retry)
            [[ $(<"$work/preparation-result") == 0 && $(<"$work/publication-result") == 0 && -s $work/parity-verified ]] || die "$name valid publication failed"
            jq -e 'last.kind == "terminal" and last.body.supervision_status == 0 and last.body.worker_status == 0 and last.body.decoder_status == 0 and
               ([.[] | select(.kind == "invocation-start")] | length == 1) and
              ([.[] | select(.kind == "effect-applied")] | length == 2)' "$work/context-final-journal.json" >/dev/null
            jq -se 'length == 3 and all(.[]; .status == 0)' "$work/context-collections.jsonl" >/dev/null
            if [[ $name == *-retry ]]; then
              [[ -s $work/context-retry-verified && $(<"$work/context-begin-result") != 0 && $(<"$work/context-retry-result") != 0 && $(wc -l <"$work/context-sync-faults") == 2 ]] || die 'context retry did not cross both sync failures'
              jq -e --slurpfile candidate "$work/context-candidate.json" '[.[] | select(.kind == "invocation-start")] == $candidate' "$work/context-final-journal.json" >/dev/null
              cmp "$work/original-copy-before.json" "$work/original-copy-after.json"
            fi
            ;;
          publish-context-native-*)
            [[ $(<"$work/context-begin-result") == 0 && $(<"$work/preparation-result") != 0 && -s $work/context-request-refused && -s $work/context-worker-prepare && ! -e $work/context-worker-apply ]] || die 'native mismatch refused before actual match-intent request'
            jq -se 'length == 1 and first.operation == "match-intent"' "$work/publication-requests.jsonl" >/dev/null
            jq -e --slurpfile intent "$work/admitted-intent.json" '.payload.intent != $intent[0]' "$work/context-native-request.json" >/dev/null
            if [[ $name == *-machine ]]; then
              jq -e '.payload.intent.publication.model | fromjson | .machine_id == "22222222222222222222222222222222"' "$work/context-native-request.json" >/dev/null
            else jq -e '.payload.intent.configuration.path == "/boot/other.conf"' "$work/context-native-request.json" >/dev/null; fi
            jq -e 'all(.[]; .kind != "retained" and .kind != "boot-stage" and .kind != "executor")' "$work/context-final-journal.json" >/dev/null
            cmp "$work/config-before" "$work/boot/limine.conf"
            ;;
          publish-context-between-*)
            [[ $(<"$work/preparation-result") == 0 && $(<"$work/executor-start-result") != 0 && -s $work/context-executor-refused && ! -e $work/context-worker-apply ]] || die 'stable context change did not refuse executor'
            cmp "$work/context-pins-before" "$work/context-pins-after"
            cmp "$work/config-before" "$work/boot/limine.conf"
            jq -e 'last.kind == "prepared-terminal" and last.body.supervision_status == 0 and all(.[]; .kind != "executor" and .kind != "effect-pending")' "$work/context-final-journal.json" >/dev/null
            jq -se 'length == 2 and all(.[]; .status == 0)' "$work/context-collections.jsonl" >/dev/null
            field=filesystem_uuid; [[ $name != *-subvolume ]] || field=subvolume
            jq -e --arg field "$field" --slurpfile platform "$work/context-platform.json" 'any(.[]; .kind == "invocation-start" and .body.context.root[$field] != $platform[0].root[$field])' "$work/context-final-journal.json" >/dev/null
            ;;
          publish-context-after-*)
            [[ $(<"$work/preparation-result") == 0 && $(<"$work/executor-start-result") == 0 && $(<"$work/publication-result") != 0 && -s $work/context-terminal-injected ]] || die 'context drift missed post-exit final proof'
            jq -e '.worker_status == 0 and .decoder_status == 0 and .supervision_status == 0 and .protocol_complete and .completion_acknowledged' "$work/context-terminal-before.json" >/dev/null
            jq -e 'last.kind == "terminal" and last.body.supervision_status == 1 and last.body.worker_status == 0 and last.body.decoder_status == 0 and last.body.protocol_complete and
              ([.[] | select(.kind == "effect-applied")] | length == 2)' "$work/context-final-journal.json" >/dev/null
            jq -se 'length == 3 and all(.[]; .status == 0) and last.after_worker_exit' "$work/context-collections.jsonl" >/dev/null
            if [[ $name == *-cert ]]; then
              jq -se 'first.certificate_der_sha256 != last.certificate_der_sha256' "$work/context-wrapper.jsonl" >/dev/null
            else
              jq -e --slurpfile platform "$work/context-platform.json" 'any(.[]; .kind == "invocation-start" and .body.context.esp.partition_uuid != $platform[0].esp.partition_uuid)' "$work/context-final-journal.json" >/dev/null
            fi
            ;;
          publish-context-*-uncertain|publish-context-launch-*)
            [[ $(<"$work/preparation-result") != 0 && -s $work/context-launch-refused && -s $work/context-sync-faults && ! -e $work/context-worker-prepare && ! -e $work/context-worker-apply && ! -s $work/stdout ]] || die 'uncertain context released a worker'
            jq -e 'length == 1 and .[0].kind == "invocation-start"' "$work/context-final-journal.json" >/dev/null
            cmp "$work/config-before" "$work/boot/limine.conf"
            ;;
          *) die 'missing context case oracle' ;;
        esac
        if [[ $name == publish-context-record-* ]]; then
          jq -e '.file_rollback_policy == "restore" and .publication_records == []' "$work/context-begin-manifest.json" >/dev/null
        else jq -e '.file_rollback_policy == "preserve" and (.publication_records | length) == 1' "$work/context-begin-manifest.json" >/dev/null; fi
        jq -e '.state == "recovery-required"' "$work/state/lifecycle.json" >/dev/null
        ;;
    esac
  fi
  if [[ $name == publish-original-* ]]; then
    [[ -s $work/original-fault && $(<"$work/context-begin-result") != 0 && $(<"$work/publication-result") != 0 &&
       -s $work/context-capture-refused && ! -e $work/publication-launch.json && ! -e $work/context-worker-prepare &&
       ! -e $work/context-worker-apply && ! -e $work/publication-requests.jsonl && ! -s $work/stdout ]] || die 'original-copy fault released a worker'
    jq -e '.file_rollback_policy == "restore" and .publication_records == []' "$work/context-begin-manifest.json" >/dev/null
    [[ -z $(find "$work/state/transactions" -name 'publication-*.json' -print -quit) &&
       -z $(find "$work/state/transactions" -name '.publication-original.*' -print -quit) ]] || die 'pre-start retention failure published authority or leaked its temporary'
    [[ $(stat -Lc '%d:%i' "$work/boot/limine.conf") == "$(<"$work/context-config-before")" && ! -e $work/boot/EFI/Linux/contract_linux.efi ]] || die 'original-copy failure changed canonical objects'
    jq -e '.state != "active"' "$work/state/lifecycle.json" >/dev/null
    jq -se 'all(.[]; .file_rollback_policy == "restore" and .publication_records == [])' "$work"/state/transactions/*/manifest.json >/dev/null
    original=$(find "$work/state/transactions" -name 'publication-data-*-original-configuration' -print)
    if [[ $name == publish-original-copy-failure || $name == publish-original-temp-sync ]]; then
      [[ -z $original ]] || die 'failed original copy published data'
    else
      [[ -f $original && $(stat -Lc %a "$original") == 400 ]] || die 'original data candidate missing'
      hash=$(sha256sum "$original")
      if [[ $name == publish-original-candidate-collision ]]; then
        jq -e --arg hash "${hash%% *}" --arg identity "$(stat -Lc '%d:%i' "$original")" '.sha256 == $hash and .identity == $identity' \
          "$work/original-foreign-before.json" >/dev/null || die 'foreign original candidate overwritten'
        [[ $(<"$original") == 'foreign original-copy candidate' ]] || die 'foreign bytes changed'
      else cmp "$original" "$work/config-before" || die 'unbound original candidate lost exact source bytes'; fi
    fi
    if [[ $name == publish-original-source-drift ]]; then
      hash=$(sha256sum "$work/boot/limine.conf")
      jq -e --arg hash "${hash%% *}" '.configuration.sha256 != $hash' "$work/admitted-intent.json" >/dev/null || die 'source drift not injected'
      hash=$(sha256sum "$original")
      jq -e --arg hash "${hash%% *}" --arg identity "$(stat -Lc '%d:%i' "$original")" '.sha256 == $hash and .identity == $identity' "$work/original-copy-before.json" >/dev/null
    else cmp "$work/config-before" "$work/boot/limine.conf"; fi
  fi
  if [[ $name == publish-intent-* ]]; then
    for evidence in alternate-intent.json intent-start-before.json intent-start-after-session.json intent-gates.jsonl \
      intent-reference-before.json intent-reference-after-session.json intent-original-before.json intent-original-after-session.json \
      intent-start-state-before.json intent-start-state-after-session.json intent-journal-after-session.json publication-launch.json preparation-result publication-result; do
      [[ -s $work/$evidence ]] || die "$name missing $evidence"
    done
    jq -se '.[0] as $a | .[1] as $b | $a != $b and
      ($a | del(.publication.model)) == ($b | del(.publication.model)) and
      ($a.publication.model | fromjson | del(.comment)) == ($b.publication.model | fromjson | del(.comment)) and
      ($b.publication.model | fromjson | .comment) == "same-invocation alternate model B"' \
      "$work/admitted-intent.json" "$work/alternate-intent.json" >/dev/null || die 'retry B changed more than the native model comment'
    for part in start start-state reference original; do
      cmp "$work/intent-$part-before.json" "$work/intent-$part-after-session.json" || die 'session changed original A authority/copy'
    done
    jq -e --slurpfile intent "$work/admitted-intent.json" '.kind == "invocation-start" and .body.intent == $intent[0]' "$work/intent-start-before.json" >/dev/null
    if [[ $name == *-head ]]; then
      [[ $(<"$work/context-begin-result") != 0 && $(wc -l <"$work/context-sync-faults") == 1 ]] || die 'A did not reach post-bind sync failure'
    else [[ $(<"$work/context-begin-result") == 0 && ! -e $work/context-sync-faults ]] || die 'A was not fully bound before retry/match'; fi
    if [[ $name == publish-intent-retry-* ]]; then
      for part in start start-state reference original; do
        cmp "$work/intent-$part-before.json" "$work/intent-$part-after-retry.json" || die 'retry changed A authority/copy'
      done
      cmp "$work/context-begin-manifest.json" "$work/intent-manifest-after-retry.json" || die 'retry changed the anchored manifest'
      jq -e --slurpfile context "$work/intent-context-after-retry.json" '.body.context == $context[0]' "$work/intent-start-before.json" >/dev/null
      expected="$work/alternate-intent.json"
      [[ $name != publish-intent-retry-same* ]] || expected="$work/admitted-intent.json"
      jq -se '.[0] == .[1]' "$expected" "$work/intent-memory-after-retry.json" >/dev/null || die 'retry did not leave the selected in-memory model'
      # Negative launch cases collect once per begin, with no executor/final pass.
      collections=2; [[ $name != publish-intent-retry-same* ]] || collections=4
      jq -se --argjson count "$collections" 'length == $count and all(.[]; .status == 0)' "$work/context-collections.jsonl" >/dev/null
    fi
    if [[ $name == publish-intent-retry-same* ]]; then
      [[ $(<"$work/intent-retry-result") == 0 && $(<"$work/preparation-result") == 0 && $(<"$work/publication-result") == 0 &&
         -s $work/parity-verified && -s $work/context-worker-prepare && -s $work/context-worker-apply ]] || die 'same A retry failed normal publication'
      jq -se '[.[] | select(.event == "launch")] | length == 2 and all(.[]; .status == 0)' "$work/intent-gates.jsonl" >/dev/null
    else
      [[ $(<"$work/preparation-result") != 0 && $(<"$work/publication-result") != 0 && ! -e $work/context-worker-apply ]] || die 'changed intent was accepted'
      cmp "$work/config-before" "$work/boot/limine.conf"
      [[ $(stat -Lc '%d:%i' "$work/boot/limine.conf") == "$(<"$work/context-config-before")" && ! -e $work/boot/EFI/Linux/contract_linux.efi ]] || die 'changed intent mutated canonical targets'
      if [[ $name == publish-intent-retry-model* ]]; then
        [[ $(<"$work/intent-retry-result") != 0 && ! -e $work/context-worker-prepare && ! -e $work/publication-requests.jsonl && ! -s $work/stdout ]] || die 'rejected B retry reached worker executable/native constructor'
        jq -se '. == [{event:"launch",apply_phase:false,status:1,intent_matched:false}]' "$work/intent-gates.jsonl" >/dev/null || die 'rejected B missed actual launch gate'
        jq -e 'map(.kind) == ["invocation-start"]' "$work/intent-journal-after-session.json" >/dev/null || die 'rejected B launch published a session/executor record'
      else
        [[ -s $work/context-worker-prepare ]] || die 'match-intent drift did not reach actual worker'
        jq -se '.[0] == .[1]' "$work/admitted-intent.json" "$work/intent-memory-before-match.json" >/dev/null
        jq -se --slurpfile wire "$work/intent-wire-request.json" '.[0] == .[1] and .[0] == $wire[0].payload.intent and
          $wire[0].payload.operation == "match-intent"' "$work/alternate-intent.json" "$work/intent-memory-after-match.json" >/dev/null || die 'memory/wire B did not agree against durable A'
        jq -se 'map(.event) == ["launch","request","terminal"] and .[0].status == 0 and .[1].status == 1 and
          all(.[]; (.intent_matched | not))' "$work/intent-gates.jsonl" >/dev/null || die 'durable-intent RPC gate not exercised'
        jq -se 'map(.operation) == ["match-intent"]' "$work/publication-requests.jsonl" >/dev/null
        jq -e 'map(.kind) == ["invocation-start","session","prepared-terminal"] and last.body.supervision_status == 1 and
          (last.body.protocol_complete | not)' "$work/intent-journal-after-session.json" >/dev/null || die 'match-intent refusal advanced preparation'
      fi
    fi
    jq -e '.state == "recovery-required"' "$work/state/lifecycle.json" >/dev/null
  fi
  if [[ $name == publish-signer-* ]]; then
    for evidence in signer-policy.json preparation-result publication-result signer-commands.jsonl context-sbctl-before.json context-sbctl-after.json; do
      [[ -s $work/$evidence ]] || die "$name missing $evidence"
    done
    [[ $(<"$work/context-begin-result") == 0 && $(<"$work/publication-result") != 0 &&
       $(<"$work/context-sbctl-before-result") == 0 && $(<"$work/context-sbctl-after-result") == 0 && ! -e $work/context-worker-apply ]] || die 'signer gate did not reach the intended refusal'
    cmp "$work/config-before" "$work/boot/limine.conf"
    [[ $(stat -Lc '%d:%i' "$work/boot/limine.conf") == "$(<"$work/context-config-before")" && ! -e $work/boot/EFI/Linux/contract_linux.efi ]] || die 'signer refusal changed canonical targets'
    case $name in
      publish-signer-cert-before)
        jq -se --arg replacement "$(<"$work/signer-replacement-certificate-sha256")" '
          .[0].config == .[1].config and .[0].executable_sha256 == .[1].executable_sha256 and
          .[0].certificate.path == .[1].certificate.path and .[0].certificate.pem_sha256 != .[1].certificate.pem_sha256 and
          .[0].certificate.der_sha256 != .[1].certificate.der_sha256 and .[1].certificate.pem_sha256 == $replacement' \
          "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null || die 'public certificate byte drift not isolated' ;;
      publish-signer-executable-before)
        [[ -s $work/signer-executable-private ]] || die 'executable mutation was not private to the case'
        hash=$(sha256sum "$scratch/fixtures/sbctl-call")
        [[ ${hash%% *} == "$(<"$work/signer-executable-original-sha256")" ]] || die 'shared fixture executable changed'
        jq -se --arg original "${hash%% *}" '
          .[0].certificate == .[1].certificate and .[0].config == .[1].config and
          .[0].executable_sha256 == $original and .[0].executable_sha256 != .[1].executable_sha256' \
          "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null || die 'per-case executable byte drift not isolated' ;;
      *)
        jq -se '.[0].certificate == .[1].certificate and .[0].executable_sha256 == .[1].executable_sha256' \
          "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null || die 'signer fixture changed public certificate bytes or executable' ;;
    esac
    records=("$work"/state/transactions/*/publication-*.json)
    jq -s 'sort_by(.ordinal)' "${records[@]}" >"$work/signer-journal.json"
    jq -e 'all(.[]; .kind != "executor" and .kind != "effect-pending" and .kind != "effect-applied")' "$work/signer-journal.json" >/dev/null
    jq -e '.state == "recovery-required"' "$work/state/lifecycle.json" >/dev/null
    if [[ $name == publish-signer-unsigned-* || $name == publish-signer-result-* ]]; then
      [[ $(<"$work/preparation-result") == 0 && $(<"$work/executor-start-result") != 0 && -s $work/signer-executor-refused && -s $work/signer-negative-injected ]] || die 'tool result missed executor verification gate'
      cmp "$work/signer-pins-before" "$work/signer-pins-after"
      jq -e 'last.kind == "prepared-terminal" and last.body.supervision_status == 0 and last.body.worker_status == 0 and last.body.decoder_status == 0' "$work/signer-journal.json" >/dev/null
      if [[ $name == publish-signer-unsigned-* ]]; then
        jq -se --arg target "$(<"$work/signer-negative-target")" '
          [.[] | select(.event == "result" and .synthetic_unsigned)] as $negative |
          ($negative | length) == 1 and $negative[0].phase == "executor-check" and $negative[0].status == 0 and
          $negative[0].verification == [{file_name:$target,is_signed:0}] and
          any(.[]; .event == "result" and .phase == "prepare" and .operation == "sign" and .status == 0) and
          any(.[]; .event == "result" and .phase == "prepare" and .operation == "verify" and .status == 0 and
            (.synthetic_unsigned | not) and .verification[0].is_signed == 1)' "$work/signer-commands.jsonl" >/dev/null || die 'missing real preparation or exact unsigned-result injection'
      else
        [[ $(<"$work/result") == 1 && $(<"$work/executor-start-result") == 1 && $(<"$work/publication-result") == 1 ]] || die 'technical tool failure did not propagate to root error'
        jq -s '.[0]' "$work"/state/transactions/*/manifest.json >"$work/signer-root-manifest.json"
        jq -e '.kind == "root" and .operation == "sign" and .status == "failed" and .failure.exit_code == 1' "$work/signer-root-manifest.json" >/dev/null
        jq -e '.transaction.root_incident.kind == "root" and .transaction.root_incident.status == "failed"' "$work/state/lifecycle.json" >/dev/null
        kind=${name#publish-signer-result-}; kind=${kind%-*}
        jq -se --arg kind "$kind" --arg target "$(<"$work/signer-negative-target")" '
          [.[] | select(.event == "result" and .tool_result != "real")] as $errors |
          ($errors | length) == 1 and $errors[0].tool_result == $kind and $errors[0].phase == "executor-check" and
          (if $kind == "malformed" then $errors[0].status == 0 and $errors[0].verification == null
           else $errors[0].status == 19 and $errors[0].verification == [{file_name:$target,is_signed:1}] end) and
          any(.[]; .event == "result" and .phase == "prepare" and .operation == "sign" and .status == 0) and
          any(.[]; .event == "result" and .phase == "prepare" and .operation == "verify" and .tool_result == "real" and .verification[0].is_signed == 1)' \
          "$work/signer-commands.jsonl" >/dev/null || die 'technical result injection missed real preparation or selected check'
        if [[ $kind == malformed ]]; then
          [[ $(<"$work/signer-tool-output") == '{"file_name":' ]] || die 'malformed output witness missing'
        else
          jq -e --arg target "$(<"$work/signer-negative-target")" '. == [{file_name:$target,is_signed:1}]' "$work/signer-tool-output" >/dev/null
        fi
      fi
      expected=1; [[ $name != *-stage ]] || expected=2
      jq -se --argjson expected "$expected" --slurpfile targets "$work/signer-check-targets.json" '
        [.[] | select(.event == "invoke" and .phase == "executor-check" and .operation == "verify")] as $calls |
        ($calls | length) == $expected and $calls[0].argv[-1] == $targets[0].retained and
        (if $expected == 2 then $calls[1].argv[-1] == $targets[0].stage and
          any(.[]; .event == "result" and .pid == $calls[0].pid and .status == 0 and .tool_result == "real" and
            .verification == [{file_name:$targets[0].retained,is_signed:1}]) else true end)' "$work/signer-commands.jsonl" >/dev/null || die 'wrong independent executor check was substituted'
    else
      [[ $(<"$work/preparation-result") != 0 && -s $work/signer-retain-refused ]] || die 'signer drift allowed retention'
      jq -e 'all(.[]; .kind != "input-ready" and .kind != "retained" and .kind != "boot-stage")' "$work/signer-journal.json" >/dev/null
      jq -se 'last.operation == "retain"' "$work/publication-requests.jsonl" >/dev/null
      if [[ $name == publish-signer-absent-* ]]; then
        [[ -s $work/signer-absent-injected && $(<"$work/result") == 1 && $(<"$work/preparation-result") == 1 && $(<"$work/publication-result") == 1 ]] || die 'absent config span did not refuse managed retention'
        parent=/etc; [[ $name != publish-signer-absent-sbctl-parent ]] || parent=/etc/sbctl
        jq -e --arg parent "$parent" --slurpfile before "$work/signer-absent-before.json" --slurpfile after "$work/signer-absent-after.json" '
          .parent == $parent and .parent_existed == ($parent == "/etc/sbctl") and .config_absent_before and .config_absent_after and
          .original_layout_restored and .real_status == 0 and .frozen.text == "{}" and
          .before_stamp != .after_stamp and .before_ctime != .after_ctime and
          $before[0].configuration_span == $parent and $after[0].configuration_span == $parent and
          $before[0].configuration_stamp == .before_stamp and $after[0].configuration_stamp == .after_stamp and
          ($before[0] | del(.configuration_stamp)) == ($after[0] | del(.configuration_stamp)) and
          $before[0].policy.configuration_state == "absent" and $before[0].policy.configuration_sha256 == ""' \
          "$work/signer-absent-span.json" >/dev/null || die 'wrong absent-policy parent/stamp boundary'
        jq -se 'length == 1 and .[0].status == 1 and .[0].argv[0:2] == ["verify","--json"]' "$work/signer-managed-gate.jsonl" >/dev/null || die 'actual managed-call post-span gate was not observed'
        jq -se '[.[] | select(.event == "entry" and .phase == "prepare")] as $entries |
          ($entries | length) == 1 and $entries[0].argv[0] == "--config" and $entries[0].argv[2] == "verify" and
          any(.[]; .event == "result" and .pid == $entries[0].pid and .status == 0 and .tool_result == "real" and .verification[0].is_signed == 0) and
          all(.[]; .operation != "sign")' "$work/signer-commands.jsonl" >/dev/null || die 'real absent-policy verify/sign frontier not proved'
        jq -se '.[0] == .[1] and .[0].config == {state:"absent",sha256:"",identity:null}' "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null
        [[ $(<"$work/signer-absent-transient.conf") == 'landlock: true' && $(<"$work/signer-frozen.conf") == '{}' ]] || die 'wrong transient/frozen config bytes'
        hash=$(sha256sum "$work/signer-frozen.conf")
        jq -e --arg hash "${hash%% *}" '.frozen.sha256 == $hash' "$work/signer-absent-span.json" >/dev/null
      elif [[ $name == publish-signer-cert-before || $name == publish-signer-executable-before ]]; then
        [[ -s $work/signer-before-injected && $(<"$work/context-sbctl-changed-result") == 0 ]] || die 'otherwise valid signer metadata was not observed'
        jq -se 'all(.[]; .phase == "bootstrap")' "$work/signer-commands.jsonl" >/dev/null || die 'signer byte drift reached a managed sbctl entry'
      elif [[ $name == publish-signer-config-before ]]; then
        [[ -s $work/signer-before-injected && $(<"$work/context-sbctl-changed-result") == 0 ]] || die 'valid pre-retain configuration drift not proved'
        jq -se 'all(.[]; .phase == "bootstrap")' "$work/signer-commands.jsonl" >/dev/null || die 'pre-retain drift reached a key-using command'
        jq -se '.[0].config.sha256 != .[1].config.sha256' "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null
      else
        [[ -s $work/signer-span-injected && -s $work/signer-span.json ]] || die 'invocation span injection not reached'
        jq -e --slurpfile policy "$work/signer-policy.json" '.real_status == 0 and .before_stamp != .after_stamp and
          .frozen.sha256 == $policy[0].configuration_sha256 and .frozen.text == "landlock: true"' "$work/signer-span.json" >/dev/null
        hash=$(sha256sum "$work/signer-frozen.conf")
        jq -e --arg hash "${hash%% *}" '.configuration_sha256 == $hash' "$work/signer-policy.json" >/dev/null
        jq -se '[.[] | select(.event == "invoke" and .phase == "prepare") | .operation] == ["verify","sign"] and
          any(.[]; .event == "result" and .operation == "sign" and .status == 0 and (.synthetic_unsigned | not))' "$work/signer-commands.jsonl" >/dev/null
        if [[ $name == publish-signer-config-span ]]; then
          jq -se '.[0].config.sha256 != .[1].config.sha256' "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null
        else
          jq -se '.[0] == .[1]' "$work/context-sbctl-before.json" "$work/context-sbctl-after.json" >/dev/null || die 'restored controls did not isolate the ctime span'
          jq -e '.metadata_before == .metadata_after and .before_stamp != .after_stamp' "$work/signer-span.json" >/dev/null || die 'restored control differed beyond ctime'
        fi
      fi
    fi
  fi
  if [[ $name == publish-* && -s $work/signer-policy.json ]]; then
    jq -se --slurpfile policy "$work/signer-policy.json" '
      all(.[]; .event != "invoke" or .phase == "bootstrap" or
        (.bound and (.executable | test("^/proc/[0-9]+/fd/[0-9]+$")) and .argv[0] == "--config" and
         .argv[1] == .frozen.fd and .argv[2] == .operation and
         (if $policy[0].configuration_state == "absent" then .frozen.text == "{}"
          else .frozen.sha256 == $policy[0].configuration_sha256 end)))' "$work/signer-commands.jsonl" >/dev/null || die 'publication call escaped frozen configuration/open-executable binding'
  fi
  if [[ $name == publish-* && $name != publish-context-* && $name != publish-original-* && $name != publish-intent-* && $name != publish-signer-* && $name != publish-core-death && $name != publish-core-death-directory-bind && $name != publish-core-death-final-third-state ]]; then
    [[ -s $work/preparation-result ]] || die 'publication preparation result missing'
    if [[ $name != publish-plan-omit && $name != publish-config-drift ]]; then
      [[ -s $work/publication-result ]] || die 'publication result missing'
    fi
    case $name in
      publish-recovery-copy-signed) [[ $(<"$work/preparation-result") == 0 && $(<"$work/publication-result") == 19 && -s $work/recovery-original-workers-exited ]] || die 'signed-copy fixture missed deliberate post-preparation interruption' ;;
      publish-plan-omit|publish-config-drift) [[ $(<"$work/preparation-result") != 0 ]] || die 'invalid plan preparation succeeded' ;;
      publish-mkdir-efi|publish-mkdir-linux|publish-mkdir-retry-*) [[ $(<"$work/publication-result") == 0 ]] || die 'directory publication failed' ;;
      publish-mkdir-*) [[ $(<"$work/publication-result") != 0 ]] || die 'invalid directory publication succeeded' ;;
      publish-late-failure|publish-third-state|publish-unstarted-after|publish-core-*-bind|publish-native-*) [[ $(<"$work/publication-result") != 0 ]] || die 'invalid publication succeeded' ;;
      *) [[ $(<"$work/publication-result") == 0 ]] || { cat "$work/stderr" >&2; die 'valid publication failed'; } ;;
    esac
    case $name in
      publish-recovery-copy-signed) [[ ! -e $work/parity-verified && ! -e $work/context-worker-apply ]] || die 'signed-copy fixture ran another publisher' ;;
      publish-mkdir-efi|publish-mkdir-linux|publish-mkdir-retry-*) [[ -s $work/parity-verified ]] || die 'directory ordinary parity missing' ;;
      publish-mkdir-*) ;;
      publish-plan-omit|publish-config-drift|publish-late-failure|publish-third-state|publish-unstarted-after|publish-core-*-bind|publish-native-*) ;;
      *) [[ -f $work/parity-verified ]] || die 'ordinary parity verification missing' ;;
    esac
    if [[ $name == publish-noop ]]; then [[ -f $work/noop-verified ]] || die 'no-op identity verification missing'; fi
    if [[ $name == publish-unstarted-after ]]; then
      [[ -f $work/unstarted-handler-result && $(<"$work/unstarted-handler-result") != 0 ]] || die 'unstarted after-state was acknowledged'
      for record in "$work"/state/transactions/*/publication-*.json; do
        jq -e '.kind != "effect-pending" and .kind != "effect-applied"' "$record" >/dev/null || die 'unstarted effect acquired a receipt'
      done
    fi
    jq -e '.state == "recovery-required"' "$work/state/lifecycle.json" >/dev/null
    if [[ $name == publish-linux || $name == publish-mkdir-linux || $name == publish-efi-hash ]]; then
      hashes=0
      while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*(path|module_path):[[:space:]]boot\(\):(/[^\#]+)\#([0-9a-f]{128})$ ]]; then
          output=$(b2sum "$work/boot${BASH_REMATCH[2]}")
          [[ ${output%% *} == "${BASH_REMATCH[3]}" ]] || die 'managed hash differs from final resource'
          hashes=$((hashes+1))
        fi
      done <"$work/boot/limine.conf"
      expected_hashes=1
      [[ $name != publish-linux && $name != publish-mkdir-linux ]] || expected_hashes=2
      [[ $hashes == "$expected_hashes" ]] || die 'required Limine hashes missing'
    fi
    if [[ $name == publish-retry-* ]]; then
      [[ -e $work/publication-sync-failed && -s $work/publication-sync-witness.json ]] || die 'publication sync fault not exercised'
      jq -e --arg fault "${name#publish-retry-}" '.fault == $fault and (.kind | length > 0) and (.source | startswith("/work/state/transactions/"))' "$work/publication-sync-witness.json" >/dev/null
    fi
  fi
  if [[ $name == publish-recovery-copy-signed ]]; then
    # Reuse the actual owned tree after the original Core/JVM namespace exits.
    # /boot is now empty; strict data decoding uses real isolated Python rather
    # than the platform-acquisition seam. Each phase keeps the existing watchdog.
    rc=0
    timeout --kill-after=5 "$watchdog" "${sandbox[@]}" --bind "$work" /work --tmpfs /boot \
      --ro-bind "$scratch/compiler/classes" /classes \
      --bind "$work/sbctl" /var/lib/sbctl --ro-bind "$(realpath "$(type -P python)")" /usr/bin/python \
      --ro-bind "$(realpath "$(type -P python)")" /real/namespace-python \
      /usr/bin/bash /fixtures/recovery-copy >"$work/recovery-copy.stdout" 2>"$work/recovery-copy.stderr" || rc=$?
    printf '%s\n' "$rc" >"$work/recovery-copy.status"
    if [[ $rc != 0 || -e $work/recovery-copy-forbidden ]]; then
      cat "$work/recovery-copy.stdout" "$work/recovery-copy.stderr" >&2
      die "$name recovery-copy namespace expected status 0, got $rc"
    fi
    jq -se '[.[].body.id] == ["resource-0","configuration"] and all(.[]; .reference.schema_version == 2)' \
      "$work/recovery-copies.jsonl" >/dev/null || die 'signed-copy evidence incomplete'
    jq -se 'any(.[]; .event == "result" and .phase == "prepare" and .operation == "sign" and .status == 0 and
      .tool_result == "real") and any(.[]; .event == "result" and .phase == "prepare" and .operation == "verify" and
      .status == 0 and (.verification | any(.is_signed == 1)))' "$work/signer-commands.jsonl" >/dev/null || die 'original managed path did not really sign and verify'
    cmp "$work/recovery-activity-before" "$work/recovery-activity-after" || die 'copy invoked signing, context acquisition or the producer'
    jq -se '[.[].body.id] == ["resource-0","configuration"] and all(.[]; .reference.schema_version == 2 and
      .body.classification == "allowed-absence")' "$work/recovery-authorizations.jsonl" >/dev/null || die 'fresh authorization evidence incomplete'
    jq -se 'length == 2 and first.certificate_der_sha256 == last.certificate_der_sha256 and
      all(.[]; .isolated_arguments and .clean_environment)' "$work/context-wrapper.jsonl" >/dev/null || die 'fresh context did not reuse the real collector wrapper once'
    jq -se '([.[] | select(.phase == "recovery" and .event == "invoke")] | length == 1 and all(.[]; .operation == "verify" and .bound == true)) and
      any(.[]; .event == "result" and .phase == "recovery" and .operation == "verify" and .status == 0 and
        .tool_result == "real" and (.verification | any(.is_signed == 1)))' "$work/signer-commands.jsonl" >/dev/null ||
      die 'fresh authorization signer activity is not exactly one real bound verification'
    [[ -s $work/recovery-original-check-authorized && ! -e $work/context-host-query ]] || die 'fresh authorization changed originals or queried the host'
    jq -se '[.[].body.id] == ["resource-0","configuration"] and all(.[]; .reference.schema_version == 2 and .body.before.kind == "absent")' \
      "$work/recovery-stages.jsonl" >/dev/null || die 'fresh stage evidence incomplete'
    jq -e '.format == "limine-prepared-publication" and (.puts | length == 1)' "$work/recovery-ready.json" >/dev/null || die 'readiness plan missing'
    [[ -s $work/recovery-original-check-ready && ! -e $work/context-worker-apply && ! -e $work/context-worker-prepare-recovery ]] || die 'readiness changed originals or ran a worker'
    cat "$work/recovery-copy.stdout"
  fi
  printf 'PASS: Core producer session/%s\n' "$name"
  count=$((count+1))
done
(( count > 0 )) || die 'no matching session case'
printf 'Passed %s Core/Java producer session contracts.\n' "$count"
