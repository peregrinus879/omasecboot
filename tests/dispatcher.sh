#!/bin/bash
# shellcheck disable=SC2154,SC2329 # Tests read globals and override sourced functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-dispatcher.XXXXXX")

cleanup() {
  release_boot_repair_lock 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"
REAL_RECOVER_LIFECYCLE_IF_REQUIRED=$(declare -f recover_lifecycle_if_required)

state_dir_path() {
  printf '%s/state\n' "$TEST_DIR"
}

limine_lock_path() {
  printf '%s/boot-partition.lock\n' "$TEST_DIR"
}

snapshot_restore_lock_path() {
  printf '%s/limine-snapper-restore.lock\n' "$TEST_DIR"
}

pacman_database_lock_path() {
  printf '%s/pacman-db.lck\n' "$TEST_DIR"
}

control_owner_uid() {
  id -u
}

require_control_root() {
  :
}

durable_sync() {
  :
}

PREFLIGHT_ROOT_CHECKED=false
PREFLIGHT_CALLED=false
check_root() {
  [[ "$1" == "windows preflight" ]] || return 1
  PREFLIGHT_ROOT_CHECKED=true
}

windows_encryption_gate() {
  PREFLIGHT_CALLED=true
  _windows_preflight_result=prepared
}

capture_service_state() {
  printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"inactive","unit_file_state":"disabled"}}'
}

systemctl() {
  [[ "$*" == "show --property=ActiveState --value ${TRANSACTION_SERVICE_UNIT}" ]] \
    || return 1
  printf 'inactive\n'
}

noop_transaction() {
  transaction_phase_start "noop"
  transaction_phase_complete "noop"
}

settings_fixture="${TEST_DIR}/limine-defaults"
cat > "$settings_fixture" <<'EOF'
  ENABLE_VERIFICATION = no
ENABLE_VERIFICATION=yes
 COMMANDS_BEFORE_SAVE = "other limine-reset-enroll"
UNRELATED=value
EOF
mapfile -t verification_entries \
  < <(list_limine_default_entries "$settings_fixture" "ENABLE_VERIFICATION")
[[ ${verification_entries[*]} == 'ENABLE_VERIFICATION=no ENABLE_VERIFICATION=yes' ]] \
  || fail_test "Limine setting parser rejected whitespace around equals"
replace_limine_default_entry_in_file "$settings_fixture" \
  "ENABLE_VERIFICATION" "ENABLE_VERIFICATION=no" \
  || fail_test "Limine setting replacement failed"
[[ $(grep -Fc 'ENABLE_VERIFICATION=' "$settings_fixture") -eq 1 ]] \
  || fail_test "Limine setting replacement retained duplicates"
grep -Fxq 'UNRELATED=value' "$settings_fixture" \
  || fail_test "Limine setting replacement changed an unrelated entry"

lifecycle_repair_is_available || fail_test "production lifecycle repair gate is closed"
activation_hook_dir="${TEST_DIR}/activation-hooks"
activation_command="${TEST_DIR}/omasecboot"
mkdir -p "$activation_hook_dir"
printf '#!/bin/bash\n' > "$activation_command"
chmod 755 "$activation_command"
real_current_omasecboot_executable_path=$(declare -f current_omasecboot_executable_path)
real_activation_hook_path=$(declare -f activation_hook_path)
real_producer_package_version=$(declare -f producer_package_version)
real_unconfigure_limine_tools_are_pinned=$(declare -f unconfigure_limine_tools_are_pinned)
ACTIVATION_PACKAGES_SUPPORTED=true
ACTIVATION_UNCONFIGURE_SUPPORTED=true
current_omasecboot_executable_path() { printf '%s\n' "$activation_command"; }
activation_hook_path() { printf '%s/%s\n' "$activation_hook_dir" "$1"; }
producer_package_version() {
  [[ "$ACTIVATION_PACKAGES_SUPPORTED" == true ]] || return 1
  case "$1" in
    limine-mkinitcpio-hook) printf '%s\n' "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" ;;
    limine-snapper-sync) printf '%s\n' "$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION" ;;
    sbctl) printf '%s\n' "$SUPPORTED_SBCTL_VERSION" ;;
    efibootmgr) printf '%s\n' "${WINDOWS_EFIBOOTMGR_PACKAGE_IDENTITY#efibootmgr }" ;;
    coreutils) printf '%s\n' "${WINDOWS_UNLINK_PACKAGE_IDENTITY#coreutils }" ;;
    *) return 1 ;;
  esac
}
unconfigure_limine_tools_are_pinned() {
  [[ "$ACTIVATION_UNCONFIGURE_SUPPORTED" == true ]]
}
write_activation_hook() {
  local key="$1" schema="${2:-$OMASECBOOT_HOOK_SCHEMA_VERSION}" target="$activation_command"
  local hook source line placeholder='@BINDIR@/omasecboot'
  hook=$(activation_hook_path "$key") || return 1
  [[ "${3:-current}" == current ]] || target="${TEST_DIR}/wrong-command"
  case "$key" in
    removal) source="${ROOT_DIR}/pacman-hooks/00-omasecboot-removal-guard.hook" ;;
    transaction) source="${ROOT_DIR}/pacman-hooks/00-omasecboot-transition-guard.hook" ;;
    package-cleanup) source="${ROOT_DIR}/pacman-hooks/zz-omasecboot-cleanup.hook" ;;
    package-sign) source="${ROOT_DIR}/pacman-hooks/zzz-omasecboot.hook" ;;
    limine-pre) source="${ROOT_DIR}/limine-hooks/000-omasecboot-guard" ;;
    limine-post) source="${ROOT_DIR}/limine-hooks/zzz-omasecboot-sign" ;;
    *) return 1 ;;
  esac
  : > "$hook"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line//"$placeholder"/"$target"}
    if [[ "$line" == '# OmaSecBoot hook schema: '* ]]; then
      line="# OmaSecBoot hook schema: ${schema}"
    fi
    printf '%s\n' "$line" >> "$hook"
  done < "$source"
  if [[ "$key" == limine-pre || "$key" == limine-post ]]; then
    chmod 755 "$hook"
  else
    chmod 644 "$hook"
  fi
}
for activation_key in removal transaction package-cleanup package-sign limine-pre limine-post; do
  write_activation_hook "$activation_key"
done
lifecycle_activation_environment_is_ready \
  || fail_test "current activation environment was rejected"
write_activation_hook transaction 0
if lifecycle_activation_environment_is_ready >/dev/null 2>&1; then
  fail_test "stale activation hook schema was accepted"
fi
write_activation_hook transaction
write_activation_hook limine-post "$OMASECBOOT_HOOK_SCHEMA_VERSION" wrong
if lifecycle_activation_environment_is_ready >/dev/null 2>&1; then
  fail_test "incorrectly targeted activation hook was accepted"
fi
write_activation_hook limine-post
transaction_hook=$(activation_hook_path transaction)
transaction_document=$(<"$transaction_hook")
printf '%s\n' "${transaction_document/When = PreTransaction/When = PostTransaction}" \
  > "$transaction_hook"
if lifecycle_activation_environment_is_ready >/dev/null 2>&1; then
  fail_test "semantically altered activation hook was accepted"
fi
write_activation_hook transaction
ACTIVATION_PACKAGES_SUPPORTED=false
if lifecycle_activation_environment_is_ready >/dev/null 2>&1; then
  fail_test "unsupported activation packages were accepted"
fi
ACTIVATION_PACKAGES_SUPPORTED=true
ACTIVATION_UNCONFIGURE_SUPPORTED=false
if lifecycle_activation_environment_is_ready >/dev/null 2>&1; then
  fail_test "unsupported unconfiguration tools were accepted for activation"
fi
ACTIVATION_UNCONFIGURE_SUPPORTED=true
real_observed_limine_setting=$(declare -f observed_limine_setting)
real_observed_limine_token=$(declare -f observed_limine_token)
observed_limine_setting() {
  case "$1" in
    ENABLE_VERIFICATION) printf 'yes # unsupported\n' ;;
    ENABLE_ENROLL_LIMINE_CONFIG) printf 'no\n' ;;
    *) return 1 ;;
  esac
}
observed_limine_token() { printf 'absent\n'; }
if adopt_lifecycle verify_adoption_observations \
  'yes # unsupported' yes no no absent absent absent absent \
  >/dev/null 2>&1; then
  fail_test "unsupported observed adoption value was accepted"
fi
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "unsupported observed adoption value published lifecycle state"
eval "$real_observed_limine_setting"
eval "$real_observed_limine_token"
eval "$real_current_omasecboot_executable_path"
eval "$real_activation_hook_path"
eval "$real_producer_package_version"
eval "$real_unconfigure_limine_tools_are_pinned"

main windows preflight > "${TEST_DIR}/windows-preflight.out" \
  || fail_test "public Windows preflight route failed"
[[ "$PREFLIGHT_ROOT_CHECKED" == true && "$PREFLIGHT_CALLED" == true \
  && "$_windows_preflight_result" == prepared ]] \
  || fail_test "public Windows preflight route was not a thin caller-visible gate"
grep -Fq 'Windows Encryption Preflight' "${TEST_DIR}/windows-preflight.out" \
  || fail_test "public Windows preflight route omitted its heading"
if cmd_windows preflight unexpected >/dev/null 2>&1; then
  fail_test "Windows preflight accepted an extra argument"
fi
cmd_help > "${TEST_DIR}/help.out"
if grep -Eq 'Setup Mode|clear keys|enable Secure Boot' "${TEST_DIR}/help.out"; then
  fail_test "help exposed firmware mutation instructions"
fi
grep -Fq 'Change firmware trust only when setup or enroll prints a validated instruction' \
  "${TEST_DIR}/help.out" \
  || fail_test "help omitted the firmware safety boundary"
if grep -Fq 'Blocked until recoverable commands are activated' "${TEST_DIR}/help.out"; then
  fail_test "help still describes recoverable commands as blocked"
fi
[[ $(cmd_version) == 'omasecboot 1.0.0' ]] || fail_test "version contract changed"

cmd_hook package-cleanup || fail_test "unmanaged package automation did not no-op"
cmd_guard removal || fail_test "pristine lifecycle blocked dependency removal"
REAL_REQUIRE_CONTROL_ROOT=$(declare -f require_control_root)
require_control_root() { return 1; }
if cmd_guard removal >/dev/null 2>&1; then
  fail_test "dependency removal guard did not require root"
fi
eval "$REAL_REQUIRE_CONTROL_ROOT"
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "unmanaged automation created lifecycle state"

adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "active fixture adoption failed"
read_lifecycle || fail_test "active fixture lifecycle was unreadable"
if cmd_guard removal > "${TEST_DIR}/removal-active.out" 2>&1; then
  fail_test "active lifecycle permitted dependency removal"
fi
grep -Fq 'requires verified disabled or pristine lifecycle state' \
  "${TEST_DIR}/removal-active.out" \
  || fail_test "dependency removal guard omitted its lifecycle reason"

active_generation=$_lifecycle_generation
active_lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
real_resolve_package_producer_context=$(declare -f resolve_package_producer_context)
resolve_package_producer_context() { return 1; }
if cmd_hook package-cleanup > "${TEST_DIR}/external.out" 2>&1; then
  fail_test "unrepaired external package mutation reported success"
else
  external_rc=$?
fi
[[ $external_rc -eq 1 ]] || fail_test "external package mutation lost its failure status"
if cmd_hook package-sign >/dev/null 2>&1; then
  fail_test "unowned package signing checkpoint succeeded"
fi
if printf 'usr/lib/modules/6.18.0/modules.builtin\n' \
  | cmd_guard transaction >/dev/null 2>&1; then
  fail_test "package guard accepted a caller without a pacman coordinator"
fi
read_lifecycle || fail_test "rejected producer state became unreadable"
[[ $_lifecycle_state == active && $_lifecycle_generation -eq active_generation \
  && $(sha256_file "$(lifecycle_file_path)") == "$active_lifecycle_hash" ]] \
  || fail_test "rejected producer automation changed lifecycle state"
eval "$real_resolve_package_producer_context"

release_boot_repair_lock
rm -rf "$(state_dir_path)"
run_lifecycle_transaction "disable-test" "disabled" "unmanaged" noop_transaction \
  || fail_test "disabled fixture did not commit"
cmd_hook package-cleanup || fail_test "disabled package automation did not no-op"
if cmd_guard removal >/dev/null 2>&1; then
  fail_test "disabled lifecycle without unconfiguration proof permitted dependency removal"
fi
read_lifecycle || fail_test "disabled state became unreadable"
[[ $_lifecycle_state == disabled ]] || fail_test "disabled automation changed lifecycle state"

route_log="${TEST_DIR}/routes"
producer_limine_hook_pre() { printf 'limine-pre\n' >> "$route_log"; }
producer_limine_hook_post() { printf 'limine-post\n' >> "$route_log"; }
producer_package_checkpoint() { printf 'package-checkpoint\n' >> "$route_log"; }
producer_package_post() { printf 'package-post\n' >> "$route_log"; }
producer_package_pre() { printf 'package-pre\n' >> "$route_log"; }
lifecycle_removal_is_allowed() {
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  printf 'removal\n' >> "$route_log"
}
cmd_hook pre || fail_test "Limine pre-hook route failed"
cmd_hook post || fail_test "Limine post-hook route failed"
cmd_hook package-cleanup || fail_test "package checkpoint route failed"
cmd_hook package-sign || fail_test "package post route failed"
cmd_guard transaction || fail_test "package pre-guard route failed"
cmd_guard removal || fail_test "package removal guard route failed"
[[ $(<"$route_log") == $'limine-pre\nlimine-post\npackage-checkpoint\npackage-post\npackage-pre\nremoval' ]] \
  || fail_test "internal producer routes selected the wrong handlers"
if cmd_hook unknown >/dev/null 2>&1 || cmd_guard unknown >/dev/null 2>&1 \
  || cmd_guard removal extra >/dev/null 2>&1; then
  fail_test "internal dispatcher accepted an unknown phase"
fi

mutation_log="${TEST_DIR}/mutation-routes"
setup_marker="${TEST_DIR}/setup-prepared"
SETUP_STATE=3
RECOVERY_OCCURRED=false
PLAN_CONFIRMED=false
check_deps() { :; }
check_core_deps() { :; }
check_recovery_deps() { :; }
check_efi_mode() { :; }
check_root() { :; }
require_gum() { :; }
gum() { [[ "$1" == confirm ]]; }
disabled_lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
if cmd_adopt --verification-original unknown --enrollment-original yes \
  --before-save-original absent --after-save-original absent \
  > "${TEST_DIR}/adopt-unknown.out" 2>&1; then
  fail_test "public adoption accepted an unknown original value"
fi
grep -Fq 'known original values so unconfiguration remains available' \
  "${TEST_DIR}/adopt-unknown.out" \
  || fail_test "unknown adoption omitted its unconfiguration safety reason"
[[ $(sha256_file "$(lifecycle_file_path)") == "$disabled_lifecycle_hash" ]] \
  || fail_test "unknown public adoption changed lifecycle state"
recover_lifecycle_if_required() {
  printf 'recover\n' >> "$mutation_log"
  _lifecycle_recovery_performed="$RECOVERY_OCCURRED"
}
current_setup_backup_id() {
  [[ -e "$setup_marker" ]] || return 1
  printf '11111111-1111-1111-1111-111111111111\n'
}
prepare_state_aware_setup() {
  [[ "$1" == true ]] || return 1
  : > "$setup_marker"
  printf 'prepare\n' >> "$mutation_log"
}
validate_enrollment_plan() { [[ "$PLAN_CONFIRMED" == true ]]; }
load_enrollment_pk_fingerprints() {
  _enrollment_current_pk_hash=$(printf 'a%.0s' {1..64})
  _enrollment_planned_pk_hash=$(printf 'b%.0s' {1..64})
}
firmware_plan_path() { printf '%s/plan\n' "$TEST_DIR"; }
activate_confirmed_enrollment_plan() {
  [[ "$*" == '11111111-1111-1111-1111-111111111111 true true true' ]] || return 1
  PLAN_CONFIRMED=true
  printf 'activate\n' >> "$mutation_log"
}
observe_setup_state() { printf '%s\n' "$SETUP_STATE"; }
secure_boot_windows_gate() { printf 'windows-gate\n' >> "$mutation_log"; }
validate_setup_instruction_boundary() { printf 'windows-gate\n' >> "$mutation_log"; }
run_dormant_enrollment() { printf 'enroll\n' >> "$mutation_log"; }
run_artifact_repair() {
  [[ "$1" == sign ]] || return 1
  printf 'sign\n' >> "$mutation_log"
}
run_tracking_cleanup() {
  [[ "$1" == cleanup ]] || return 1
  printf 'cleanup\n' >> "$mutation_log"
}
run_dormant_unconfigure() { printf 'unconfigure\n' >> "$mutation_log"; }
add_windows_boot_entry() { printf 'windows-setup\n' >> "$mutation_log"; }
suppress_stale_windows_entry() { printf 'windows-suppress\n' >> "$mutation_log"; }
run_dormant_windows_bootnext() { printf 'windows-bootnext\n' >> "$mutation_log"; }

cmd_setup >/dev/null || fail_test "enabled setup route failed"
cmd_setup >/dev/null || fail_test "enabled setup repair route failed"
SETUP_STATE=2
cmd_enroll >/dev/null || fail_test "enabled enrollment route failed"
cmd_sign >/dev/null || fail_test "enabled signing route failed"
cmd_cleanup >/dev/null || fail_test "enabled cleanup route failed"
cmd_unconfigure >/dev/null || fail_test "enabled unconfigure route failed"
cmd_repair >/dev/null || fail_test "enabled recovery route failed"
cmd_windows setup >/dev/null || fail_test "enabled Windows setup route failed"
cmd_windows suppress >/dev/null || fail_test "enabled Windows suppression route failed"
cmd_windows bootnext >/dev/null || fail_test "enabled BootNext route failed"
expected_mutations=$'recover\nprepare\nactivate\nwindows-gate\nrecover\nsign\nwindows-gate\nrecover\nenroll\nwindows-gate\nrecover\nsign\nrecover\ncleanup\nrecover\nunconfigure\nrecover\nrecover\nwindows-setup\nrecover\nwindows-suppress\nrecover\nwindows-bootnext'
[[ $(<"$mutation_log") == "$expected_mutations" ]] \
  || fail_test "enabled commands selected the wrong recoverable mutations"

RECOVERY_OCCURRED=true
check_deps() { fail_test "command-specific dependencies ran before recovery"; }
check_core_deps() { fail_test "command-specific dependencies ran before recovery"; }
check_efi_mode() { fail_test "command-specific EFI checks ran before recovery"; }
require_gum() { fail_test "interactive dependencies ran before recovery"; }
cmd_setup >/dev/null || fail_test "setup recovery-only route failed"
cmd_windows bootnext >/dev/null || fail_test "BootNext recovery-only route failed"
[[ $(<"$mutation_log") == "${expected_mutations}"$'\nrecover\nrecover' ]] \
  || fail_test "a recovered command started an unintended second mutation"
cmd_adopt --verification-original unknown --enrollment-original no \
  --before-save-original absent --after-save-original absent >/dev/null \
  || fail_test "adoption recovery-only route failed"
[[ $(<"$mutation_log") == "${expected_mutations}"$'\nrecover\nrecover\nrecover' ]] \
  || fail_test "recovered adoption started an unintended second mutation"
for command in setup enroll sign cleanup unconfigure repair; do
  if "cmd_${command}" unexpected >/dev/null 2>&1; then
    fail_test "enabled ${command} command accepted an extra argument"
  fi
done
if cmd_windows bootnext unexpected >/dev/null 2>&1; then
  fail_test "enabled Windows command accepted an extra argument"
fi
for command in status version help; do
  if main "$command" unexpected >/dev/null 2>&1; then
    fail_test "${command} accepted an extra argument"
  fi
done

registry_log="${TEST_DIR}/recovery-registry"
RECOVERY_OPERATION=""
_OMASECBOOT_LIMINE_LOCK_OWNED=true
_OMASECBOOT_REPAIR_LOCK_OWNED=true
reconcile_stale_lifecycle() { :; }
prepare_registered_stale_recovery_runtime_locked() { :; }
prepare_registered_recovery_runtime_locked() { :; }
read_lifecycle() { _lifecycle_state=recovery-required; }
load_recovery_context() { _recovery_root_manifest_json='{}'; }
recovery_operation_for_root_manifest() { printf '%s\n' "$RECOVERY_OPERATION"; }
run_registered_producer_recovery_locked() { printf 'producer\n' >> "$registry_log"; }
run_firmware_recovery_locked() { printf 'firmware\n' >> "$registry_log"; }
run_windows_recovery_locked() { printf 'windows\n' >> "$registry_log"; }
run_software_recovery_locked() { printf 'software\n' >> "$registry_log"; }
run_unconfigure_recovery_locked() { printf 'unconfigure\n' >> "$registry_log"; }
for RECOVERY_OPERATION in producer-recovery firmware-recovery windows-recovery \
  software-recovery unconfigure-recovery; do
  run_registered_recovery_locked || fail_test "registered ${RECOVERY_OPERATION} was rejected"
done
RECOVERY_OPERATION=arbitrary-recovery
if run_registered_recovery_locked; then
  fail_test "unregistered recovery operation reached an executor"
fi
[[ $(<"$registry_log") == $'producer\nfirmware\nwindows\nsoftware\nunconfigure' ]] \
  || fail_test "recovery registry selected the wrong executor"

eval "$REAL_RECOVER_LIFECYCLE_IF_REQUIRED"
with_boot_repair_lock() { :; }
release_boot_repair_lock() { :; }
lifecycle_package_boundary_is_clear() { :; }
read_lifecycle() { _lifecycle_state=transition; }
run_registered_recovery_locked() { :; }
recover_lifecycle_if_required || fail_test "stale completed recovery route failed"
[[ "$_lifecycle_recovery_performed" == true ]] \
  || fail_test "stale completed recovery was not treated as recovery-only"

printf 'dispatcher tests passed\n'
