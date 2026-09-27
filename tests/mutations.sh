#!/bin/bash
# The mutation check (spec, section 9): every safety predicate has a named
# case that fails when the predicate is disabled. Each entry below disables
# one predicate in a copy of the working tree and names the case that must
# fail for it. The check fails when a named suite fails on the tree as it is,
# when that case does not fail, when another case fails first, when the edit
# finds nothing to change or leaves a file that does not parse, or when the
# suite errs; an edit that no longer applies after a change of the code is
# updated with that change.
#
# Usage: bash tests/mutations.sh [ID...]   (make test-mutations runs them all)
#
# m ID FILE OCCURRENCE SEARCH REPLACEMENT SUITE/CASE: replace the
# OCCURRENCE-th literal SEARCH in FILE (0 for every one) with REPLACEMENT.
# Left out, because each is repeated by the code after it and disabling it
# changes nothing: the restore check and the ESP check before the lock in
# sign.sh, which the checks after the lock repeat (D2); the guard of an empty
# path list in limine.sh's proof of the regenerated entries, which its loop
# repeats (an empty string reads as one line without a hash); and the check of
# an empty device number in common.sh's esp_mounts, which chooses the message:
# the rule's loop refuses the empty answer that follows.
# shellcheck disable=SC2016 # Search and replacement are code, taken literally.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")

declare -a ids=()
declare -A file occurrence search replacement expected
m() { ids+=("$1"); file[$1]=$2 occurrence[$1]=$3 search[$1]=$4 replacement[$1]=$5 expected[$1]=$6; }

m F01 lib/firmware.sh 1 'lost=$(list_lost_entries "$backup" current) || return 1' 'lost=' firmware/partial-loss-is-refused
m F02 lib/firmware.sh 1 '[[ -z $lost && -n $(foreign_entries KEK) && -n $(foreign_entries db) ]] && dbx_equals_backup "$backup"' '[[ -z $lost ]] && dbx_equals_backup "$backup"' firmware/empty-never-means-append
m F03 lib/firmware.sh 1 '[[ -z $lost && -n $(foreign_entries KEK) && -n $(foreign_entries db) ]] && dbx_equals_backup "$backup"' '[[ -z $lost && -n $(foreign_entries KEK) && -n $(foreign_entries db) ]]' firmware/changed-dbx-is-refused
m F04 lib/firmware.sh 1 $'append_plan_is_sound() {\n' $'append_plan_is_sound() {\n  return 0\n' firmware/plan-proofs-refuse-what-was-not-asked-for
m F05 lib/firmware.sh 1 $'rebuild_plan_is_sound() {\n' $'rebuild_plan_is_sound() {\n  return 0\n' firmware/plan-proofs-refuse-what-was-not-asked-for
m F06 lib/firmware.sh 1 $'rebuild_applies() {\n' $'rebuild_applies() {\n  return 0\n' firmware/empty-never-means-append
m F07 lib/firmware.sh 1 'if variable_holds_local_certificate "$name"; then' 'if false; then' firmware/interrupted-enrollment-is-finished-without-duplicates
m F08 lib/firmware.sh 1 '[[ $(variable_entries "$name") == "${_planned[$name]}" ]] || {' 'true || {' firmware/write-is-judged-by-reading-back
m F09 lib/firmware.sh 1 $'local_certificates_are_identified() {\n' $'local_certificates_are_identified() {\n  return 0\n' status/enrollment-state-chooses-the-next-step
m F10 bin/omasecboot 1 'elif [[ $first_run == true ]]; then' 'elif false; then' firmware/half-cleared-firmware-is-refused
m F11 lib/firmware.sh 1 $'acknowledge_missing_microsoft_kek() {\n' $'acknowledge_missing_microsoft_kek() {\n  return 0\n' firmware/missing-2023-kek-is-asked-about-before-the-pk-goes
m F12 bin/omasecboot 1 '[[ $audit_mode == 0 ]] ||' 'true ||' firmware/audit-mode-is-refused
m F13 bin/omasecboot 1 '[[ $setup_mode == 1 ]] ||' 'true ||' firmware/setup-asks-for-the-pk-then-enrolls-then-confirms
m F14 lib/firmware.sh 1 'variable_is_volatile "$(firmware_variable_path "$name")" || return 1' '[[ -e $(firmware_variable_path "$name") ]] || return 1' firmware/non-volatile-defaults-are-not-used
m F15 lib/firmware.sh 1 '{ backup_is_complete "$1" && is_safe_directory "$1"; } || return 1' 'backup_is_complete "$1" || return 1' firmware/unsafe-backups-are-passed-over
m F16 lib/firmware.sh 1 '    is_safe_file "$file" || return 1' '    :' firmware/unsafe-backups-are-passed-over
m F17 lib/firmware.sh 1 '[[ $existing > $name ]] || continue' 'continue' firmware/backup-is-root-only-complete-and-ordered
m F18 lib/firmware.sh 1 '(( ${#_rebuild_flags[@]} > 0 )) || return 1' ':' firmware/empty-never-means-append
m F19 lib/firmware.sh 1 '&& [[ -e ${directory}PK ]]; }' '; }' firmware/empty-never-means-append
m F20 bin/omasecboot 1 'if [[ $secure_boot != 0 ]]; then' 'if false; then' commands/remove-returns-to-stock
m F21 bin/omasecboot 1 $'  if [[ $secure_boot == 1 ]]; then\n    sbctl_keys_exist' $'  if false; then\n    sbctl_keys_exist' commands/secure-boot-on-needs-trusted-keys
m F22 bin/omasecboot 1 'variable_holds_local_certificate db ||' 'true ||' commands/secure-boot-on-needs-trusted-keys
m F23 bin/omasecboot 1 'if [[ -n $shadows ]]; then' 'if false; then' commands/setup-refuses-before-changing-anything
m F24 bin/omasecboot 1 '[[ $(effective_setting ENABLE_UKI) == yes ]] || {' 'true || {' commands/setup-refuses-before-changing-anything
m F25a bin/omasecboot 1 '! restore_in_progress || die "A snapshot restore is running; run this again when it has finished"' ':' commands/setup-and-remove-wait-for-a-restore
m F25b bin/omasecboot 2 '! restore_in_progress || die "A snapshot restore is running; run this again when it has finished"' ':' commands/setup-and-remove-wait-for-a-restore
m F25c bin/omasecboot 3 '! restore_in_progress || die "A snapshot restore is running; run this again when it has finished"' ':' windows/entry-is-only-taken-out-when-the-loader-follows
m F25d bin/omasecboot 4 '! restore_in_progress || die "A snapshot restore is running; run this again when it has finished"' ':' windows/entry-is-only-taken-out-when-the-loader-follows
m F26b lib/sign.sh 2 'if restore_in_progress; then' 'if false; then' sign/pass-looks-again-after-its-wait
m F27 lib/sign.sh 1 'if ! is_set_up; then' 'if false; then' sign/pass-looks-again-after-its-wait
m F28 lib/sign.sh 2 'if ! esp_is_mounted_vfat; then' 'if false; then' sign/pass-looks-again-after-its-wait
m F29 bin/omasecboot 1 'check_uefi && check_esp && check_tools && esp_has_room || exit 1' 'check_uefi && check_esp && check_tools || exit 1' commands/unmounted-esp-and-unsafe-files-stop-the-commands
m F30 bin/omasecboot 1 '{ is_safe_file "$(settings_originals_file)" && is_safe_file "$(limine_default_config)"; } ||' 'true ||' commands/unmounted-esp-and-unsafe-files-stop-the-commands
m F31 lib/common.sh 1 'if [[ $_boot_lock == local ]]; then' 'if true; then' commands/hook-pass-works-under-the-callers-lock
m F32 lib/common.sh 1 'flock -E 75 -w "$(hook_lock_wait)" 200 || rc=$?' 'flock -E 75 -w "$(hook_lock_wait)" 200 || :' common/inherited-unlocked-descriptor-waits-briefly
m F33 lib/common.sh 1 $'  boot_lock_release\n  "$@" 200>&- || rc=$?' '  "$@" || rc=$?' commands/setup-from-stock-and-again
m F34 lib/common.sh 1 $'boot_lock_acquire() {\n  local lock rc=0\n' $'boot_lock_acquire() {\n  local lock rc=0\n  return 0\n' commands/busy-remove-changes-nothing
m F35 bin/omasecboot 1 '[[ $(limine_seal "$(primary_loader_path)") == unsealed ]] ||' 'true ||' windows/entry-is-only-taken-out-when-the-loader-follows
m F36 lib/windows.sh 1 'if [[ -n $label ]] && lacks_menu_entries "$content"; then' 'if false; then' windows/template-put-there-after-the-look-is-not-written
m F37 lib/files.sh 1 '  local path=${1,,}' '  local path=$1' sign/history-files-are-never-touched
m F38 lib/files.sh 1 '[[ $path == */limine_history/* || ${path##*/} =~ \.efi_(sha1|sha256|b3|blake3|xxh|xxhash)_ ]]' 'false' commands/setup-removes-harmful-sbctl-rows
m F39 lib/files.sh 1 '[[ ${1,,} == "${fallback,,}" ]]' '[[ $1 == "$fallback" ]]' sign/lower-case-foreign-fallback-is-left-alone
m F40 lib/files.sh 1 '[[ ${1,,} == "${fallback,,}" ]]' 'false' commands/fallback-is-offered-only-into-an-empty-place
m F41 lib/limine.sh 1 $'printf \'foreign\\n\'' $'printf \'altered\\n\'' commands/fallback-is-offered-only-into-an-empty-place
m F42 lib/limine.sh 1 '[[ $(fallback_state) == absent ]] || return 1' ':' limine/fallback-states
m F43 bin/omasecboot 1 '[[ $(fallback_state) == absent ]] || return 0' ':' commands/fallback-is-offered-only-into-an-empty-place
m F44 lib/files.sh 1 $'! -ipath \'*/Microsoft/*\' ! -iname \'BOOTIA32.EFI\'' $'! -iname \'BOOTIA32.EFI\'' sign/other-systems-files-are-never-touched
m F45 lib/files.sh 1 $'! -ipath \'*/Microsoft/*\' ! -iname \'BOOTIA32.EFI\'' $'! -ipath \'*/Microsoft/*\'' sign/other-systems-files-are-never-touched
m F46 lib/sign.sh 1 '[[ -n $file && ${file,,} != "${primary,,}" ]] || continue' '[[ -n $file && $file != "$primary" ]] || continue' sign/primary-under-another-case-is-never-signed-in-place
m F47 lib/sign.sh 1 'file_has_path_hash "$file" || hashed=$?' 'hashed=1' commands/silent-build-failure-stops-setup
m F48 lib/limine.sh 1 '[[ ${file,,} != "${named,,}" ]] || return 0' '[[ $file != "$named" ]] || return 0' limine/stale-os-hashes-are-found
m F49 lib/sign.sh 1 'if is_history_file "$file" || is_fallback_loader "$file" || [[ $seal != none ]]; then' 'if is_history_file "$file" || [[ $seal != none ]]; then' sign/harmful-rows-are-found-and-removed
m F50 lib/sign.sh 1 'if is_history_file "$file" || is_fallback_loader "$file" || [[ $seal != none ]]; then' 'if is_fallback_loader "$file" || [[ $seal != none ]]; then' commands/setup-removes-harmful-sbctl-rows
m F51 lib/limine.sh 1 '[[ $(limine_seal "$primary") == "blake2b $checksum" ]] && signature_state "$primary"' '[[ $(limine_seal "$primary") == "blake2b $checksum" ]]' status/sealed-but-unsigned-is-not-called-unsealed
m F52 lib/limine.sh 1 '[[ $(limine_seal "$primary") == "blake2b $checksum" ]] && signature_state "$primary"' 'signature_state "$primary"' sign/failure-writes-needs-attention
m F53 lib/limine.sh 1 'for _ in 1 2 3; do' 'for _ in 1; do' limine/change-during-the-rebuild-is-caught
m F54 lib/limine.sh 1 '[[ $sealed == true && $before == "$after" ]]' '[[ $sealed == true ]]' limine/restless-limine-conf-is-not-reported-sealed
m F55 lib/limine.sh 1 'raw_loader | cmp -s -- - "$primary" || {' 'true || {' commands/remove-without-a-copy-names-the-way-out
m F56 lib/limine.sh 1 '[[ ${verification,,} != yes ]] || generated_os_entries_carry_hashes || {' 'true || {' commands/remove-keeps-its-record-after-a-masked-build-failure
m F57 lib/limine.sh 1 '! os_entries_carry_hashes || return 3' ':' commands/silent-build-failure-stops-setup
m F58 bin/omasecboot 1 $'trap \'\' TERM' ':' commands/watchers-pass-finishes-through-a-stop
m F59 lib/limine.sh 1 'pgrep -x pacman >/dev/null 2>&1 && (( SECONDS < deadline ))' '(( SECONDS < deadline ))' sign/seal-only-waits-for-pacman-to-finish
m F60 lib/limine.sh 1 'pgrep -x pacman >/dev/null 2>&1 && (( SECONDS < deadline ))' 'pgrep -x pacman >/dev/null 2>&1' sign/seal-only-waits-for-pacman-to-finish
m F61 lib/sign.sh 1 $'  converge_windows_entry\n  # Sealed but not signed starts with Secure Boot off; not sealed never does.\n  converge_primary_loader || { primary_is_sealed && rc=1; } || sealed=false' $'  converge_primary_loader || { primary_is_sealed && rc=1; } || sealed=false\n  converge_windows_entry' windows/publication-failures-leave-a-pair-or-say-so
m F62 lib/limine.sh 1 '[[ $(limine_seal "$staging") == "blake2b $checksum" ]] &&' 'true &&' limine/unwritten-seal-or-signature-publishes-nothing
m F63 lib/limine.sh 1 '    signature_state "$staging"; then' '    true; then' limine/unwritten-seal-or-signature-publishes-nothing
m F64 lib/windows.sh 1 'boot_order_holds "$target_number" || return 1' ':' windows/setup-without-a-target-changes-nothing
m F65 lib/windows.sh 1 '[[ $same == 1 && -n $target_label' '[[ -n $target_label' windows/target-is-one-clear-entry-or-none
m F66 lib/windows.sh 1 '[[ ${hex:10:2}${hex:8:2} == "${_windows_number,,}" ]]' 'true' windows/bootnext-is-judged-by-reading-back
m F67 bin/omasecboot 1 '{ [[ -e $(windows_flag) ]] && resolve_windows_target; }' '{ resolve_windows_target; }' windows/entry-is-only-taken-out-when-the-loader-follows
m F68 bin/omasecboot 1 $'  restore_stock_boot_files || die "The boot files are not back to stock; run this again"\n  # Only now: the loader is proved raw, so limine.conf may change under it.\n  write_windows_entry || die "Could not take the Windows entry out of $(limine_config_path); the warning above says what to change by hand, then run this again"' $'  write_windows_entry || die "Could not take the Windows entry out of $(limine_config_path); the warning above says what to change by hand, then run this again"\n  restore_stock_boot_files || die "The boot files are not back to stock; run this again"' windows/failed-remove-keeps-limine-conf-and-loader-together
m F69 lib/windows.sh 1 $'printf \'%s\' "$content" | atomic_write "$config" "$mode" config_is_still "$before"' $'printf \'%s\' "$content" | atomic_write "$config" "$mode"' windows/late-writer-is-not-overwritten
m F70 lib/limine.sh 1 'atomic_write "$file" "$mode" default_config_is_still "$before"' 'atomic_write "$file" "$mode"' limine/settings-file-changed-meanwhile-is-not-overwritten
m F71 lib/limine.sh 1 '(( ${#markers[@]} == 1 )) || {' '(( ${#markers[@]} >= 1 )) || {' limine/seal-classes-follow-the-slot
m F72 lib/sign.sh 1 $'      failed=1\n    fi\n  done <<<"$stale"' $'      :\n    fi\n  done <<<"$stale"' sign/stale-hash-alone-fails-the-pass
m F73 lib/sign.sh 1 'run_visible run_sbctl sign "$file" && { durable_sync' 'run_visible run_sbctl sign -s "$file" && { durable_sync' sign/converges-and-is-idempotent
m F74 lib/sign.sh 1 '{ esp_has_room && run_visible run_sbctl sign' '{ run_visible run_sbctl sign' sign/full-esp-is-not-written-to
m F75 lib/limine.sh 1 $'  [[ -d $parent ]] || return 1\n  esp_has_room || return 1' '  [[ -d $parent ]] || return 1' sign/full-esp-is-not-written-to
m F76 limine/90-omasecboot-sign 1 $'sign --quiet || :\nexit 0' 'sign --quiet' commands/hook-never-fails-its-caller
m F77 lib/sign.sh 1 $'  elif [[ $scope == full ]]; then\n    clear_attention "$ATTENTION_PASS"' $'  else\n    clear_attention "$ATTENTION_PASS"' sign/failure-writes-needs-attention
m F78 lib/limine.sh 1 '! path_is_snapshot "$line" || continue' ':' commands/setup-and-remove-on-the-real-shape
m F79 lib/sign.sh 1 'run_sbctl remove-file "$file" >/dev/null || {' '{ run_sbctl remove-file "$file" >/dev/null || :; } || {' commands/setup-removes-harmful-sbctl-rows
m F80 bin/omasecboot 1 '  if os_entries_carry_hashes; then' '  if false; then' commands/setup-from-stock-and-again
m F84 bin/omasecboot 1 $'  is_set_up || die "OmaSecBoot is not set up. Run: ${BOLD}sudo omasecboot setup${NC}"\n  check_uefi && check_esp || exit 1' '  check_uefi && check_esp || exit 1' windows/windows-setup-needs-a-machine-that-is-set-up
m F86 lib/limine.sh 1 $' "${esp}/EFI/BOOT/${LOADER_STAGING_PREFIX}"* \\\n    "${esp}"/.limine.conf.??????' ' "${esp}/EFI/BOOT/${LOADER_STAGING_PREFIX}"*' limine/stale-staging-files-are-swept
m F87 lib/status.sh 1 '[[ -z $shadow ]] || blocking_problem "A second limine.conf shadows the real one; remove it: ${shadow}"' ':' status/shadowing-limine-conf-blocks
m F98 lib/windows.sh 1 'esp_room_is_enough || {' 'true || {' windows/unsafe-writes-are-refused
m F99 limine/90-omasecboot-sign 1 '[[ -e /var/lib/omasecboot/enabled ]] || exit 0' ':' commands/hook-never-fails-its-caller
m F100 bin/omasecboot 1 $'  check_root sign\n  is_set_up || die' $'  check_root sign\n  true || die' commands/usage-errors-exit-2
m F102 bin/omasecboot 1 'remove_harmful_sbctl_rows || exit 1' 'remove_harmful_sbctl_rows || :' commands/setup-removes-harmful-sbctl-rows
m F103 lib/firmware.sh 1 'readonly -a KEY_VARIABLES=(db KEK PK)' 'readonly -a KEY_VARIABLES=(PK KEK db)' firmware/rotated-keys-are-enrolled-beside-the-old-ones
m F105 bin/omasecboot 1 $'  qheader "Sign"\n  sign_boot_files "$scope"' $'  qheader "Sign"\n  if [[ $QUIET == true ]]; then sign_boot_files "$scope" 2>/dev/null; else sign_boot_files "$scope"; fi' windows/entry-problems-are-reported-not-failed
m F106 lib/firmware.sh 1 '[[ -n ${_local[$name]} && ${_local[$name]} != *' '[[ -n ${_local[$name]} || ${_local[$name]} != *' firmware/local-certificates-are-found-by-owner
m F107 lib/firmware.sh 1 '[[ -z $lost && -n $(foreign_entries KEK) && -n $(foreign_entries db) ]]' '[[ -z $lost && -n $(foreign_entries db) ]]' firmware/empty-never-means-append
m F108 lib/firmware.sh 1 '% entry_size == 0 )) || return 1' '% entry_size >= 0 )) || return 1' firmware/signature-lists-are-read-entry-by-entry
m F109 bin/omasecboot 1 '{ read_mode_variable SecureBoot && read_mode_variable SetupMode; } >/dev/null || {' '{ read_mode_variable SecureBoot; } >/dev/null || {' firmware/setup-needs-setup-mode-readable-before-any-change
m F110 lib/firmware.sh 1 '[[ ${#bytes[@]} == 5 && ${bytes[4]} =~ ^[01]$ ]] || return 1' '[[ ${bytes[4]} =~ ^[01]$ ]] || return 1' firmware/mode-variables-are-read-exactly
m F111 lib/firmware.sh 1 ' && cmp -s -- "$path" "${directory}/${name}"; } || return 1' '; } || return 1' firmware/torn-backup-copy-is-refused
m F112 lib/status.sh 1 'absent) problem "The Windows entry is missing' 'absent) note "The Windows entry is missing' windows/entry-comes-back-after-limine-conf-is-replaced
m F113 lib/status.sh 1 'stale) problem "The Windows entry in limine.conf' 'stale) note "The Windows entry in limine.conf' windows/entry-problems-are-reported-not-failed
m F114 lib/status.sh 1 'displaced) problem "The Windows entry in limine.conf' 'displaced) pass "The Windows entry in limine.conf' windows/displaced-entry-is-moved-behind-upstreams
m F115 lib/windows.sh 1 '[[ ${entries,,} == *"$WINDOWS_LOADER"* ]]' 'false' windows/windows-without-a-listed-volume-is-not-ruled-out
m F116 lib/windows.sh 1 'elif [[ $listed == 2 ]]; then' 'elif false; then' windows/windows-without-a-listed-volume-is-not-ruled-out

m F117 bin/omasecboot 1 'acknowledge_windows_encryption || exit 1' ': || exit 1' windows/encryption-is-acknowledged-before-the-firmware-changes
m F118 bin/omasecboot 2 'acknowledge_windows_encryption || exit 1' ': || exit 1' windows/encryption-is-acknowledged-before-the-firmware-changes
m F119 bin/omasecboot 1 'confirm "the key enrollment" "$question" || exit 1' ': || exit 1' firmware/setup-asks-for-the-pk-then-enrolls-then-confirms
m F120 bin/omasecboot 1 '      firmware_starts_primary ||' '      true ||' firmware/setup-asks-for-the-pk-then-enrolls-then-confirms
m F121 bin/omasecboot 1 'sign_boot_files || exit "$?"' 'sign_boot_files || :' commands/setup-stops-when-the-pass-fails
m F122 bin/omasecboot 1 'confirm "the return to stock" "Return the Limine settings and boot files to stock?" || exit 1' ': || exit 1' commands/remove-returns-to-stock
m F123 lib/sign.sh 1 '_esp_write_unconfirmed=true; } && signature_state "$file"; } || {' '_esp_write_unconfirmed=true; }; } || {' sign/claimed-signature-is-proved
m F124 lib/sign.sh 1 'converge_primary_loader || { primary_is_sealed && rc=1; } || sealed=false' 'converge_primary_loader || { primary_is_sealed && rc=1; } || :' sign/failure-writes-needs-attention
m F125 lib/sign.sh 1 'if [[ $(fallback_state) == altered ]]; then' 'if false; then' sign/fallback-is-returned-to-raw
m F126 lib/limine.sh 1 'elif [[ $seal == unsealed ]] && ! signature_state "$fallback"; then' 'elif [[ $seal == unsealed ]]; then' limine/fallback-states
m F127 lib/limine.sh 1 '[[ ! -e $originals ]] || return 0' ':' limine/originals-are-recorded-once
m F128 lib/limine.sh 1 $'      *) return 1 ;;\n    esac\n  done <"$originals"' $'      *) ;;\n    esac\n  done <"$originals"' limine/malformed-originals-record-is-no-answer
m F129 lib/limine.sh 1 '    run_visible run_sbctl sign "$staging" &&' '    run_visible run_sbctl sign -s "$staging" &&' sign/converges-and-is-idempotent
m F130 lib/limine.sh 2 'esp_has_room || return 1' ': || return 1' limine/fallback-is-not-added-without-room
m F131 lib/limine.sh 3 'esp_has_room || return 1' ': || return 1' sign/full-esp-is-not-written-to
m F133 lib/firmware.sh 1 ' && entry_size > 16 )) || return 1' ' )) || return 1' firmware/signature-lists-are-read-entry-by-entry
m F134 lib/firmware.sh 1 '      cmp -s -- "$path" "${directory}/${name}" || return 1' '      :' firmware/backup-is-taken-once-and-complete
m F135 lib/firmware.sh 1 'is_safe_directory "$(firmware_backup_root)" || return 1' ':' firmware/unsafe-backups-are-passed-over
m F136 lib/firmware.sh 1 '{12})$ ]] || return 1' '{12})$ ]] || :' firmware/local-certificates-are-found-by-owner
m F137 lib/files.sh 1 '.[0].file_name == $file and' '' sign/answer-about-another-file-is-no-answer
m F138 lib/common.sh 1 '[[ $uid == "$(owner_uid)" && $links == 1 ]] && mode_is_safe "$mode"' '[[ $uid == "$(owner_uid)" ]] && mode_is_safe "$mode"' common/file-safety-refuses-what-others-can-change
m F139 lib/common.sh 1 'while [[ $path == *//* ]]; do path=${path//\/\//\/}; done' ':' common/esp-path-has-one-form
m F140 lib/common.sh 1 '[[ $path == / ]] || path=${path%/}' ':' common/esp-path-has-one-form
m F141 lib/windows.sh 1 '(( targets == 1 )) || return 1' '(( targets >= 1 )) || return 1' windows/target-is-one-clear-entry-or-none
m F142 lib/windows.sh 1 '$target_label != *[![:ascii:]]* ]] || return 3' '$target_label != *[![:ascii:]]* ]] || :' windows/target-name-must-be-one-limine-matches
m F143 lib/windows.sh 1 '&& signed && !foreign)' '&& signed)' windows/misplaced-comment-is-never-deleted
m F144 lib/windows.sh 1 '  is_safe_file "$config" || {' '  true || {' windows/unsafe-writes-are-refused
m F146 bin/omasecboot 1 '{ read_enrollment_plan && firmware_is_enrolled; } || die "The firmware does not hold your keys after the write' '{ read_enrollment_plan && firmware_is_enrolled; } || : "The firmware does not hold your keys after the write' firmware/enrollment-is-judged-by-the-variables-afterwards
m F145 lib/status.sh 1 'blocking_problem "Secure Boot is on, but the firmware does not hold your keys' 'note "Secure Boot is on, but the firmware does not hold your keys' status/enrollment-state-chooses-the-next-step

m F147 lib/sign.sh 1 $'          unsealed)\n            qnote "Not signing' $'          unsealed-never)\n            qnote "Not signing' sign/unsealed-limine-is-never-signed
m F148 lib/sign.sh 1 $'          unsupported)\n            fail "Not signing' $'          unsupported-never)\n            fail "Not signing' sign/untold-seal-is-not-signed-and-fails-the-pass
m F149 lib/sign.sh 1 ' || [[ $seal != none ]]; then' '; then' sign/harmful-rows-are-found-and-removed
m F150 lib/sign.sh 1 $'  [[ -z $rows ]] || {\n    warn "sbctl still lists' $'  true || {\n    warn "sbctl still lists' sign/harmful-rows-are-found-and-removed
m F151 lib/status.sh 1 '0:unsealed) blocking_problem' '0:unsealed) pass' status/unsealed-limine-is-reported-by-its-signature
m F152 lib/status.sh 1 '      show_unsealed_signed_loader' '      :' status/signed-unsealed-loader-is-said-after-remove
m F153 lib/status.sh 1 '    blocking_problem "Secure Boot is on, and the Limine loader carries your signature and no seal' '    note "Secure Boot is on, and the Limine loader carries your signature and no seal' status/signed-unsealed-loader-is-said-after-remove
m F154 lib/limine.sh 1 'if (( ${#slot} == 256 )) && [[ ${slot:128} =~ ^0+$ ]]; then' 'if (( ${#slot} == 256 )); then' limine/seal-classes-follow-the-slot
m F155 lib/limine.sh 1 'elif (( ${#slot} != 128 )); then' 'elif false; then' limine/seal-classes-follow-the-slot
m F156 lib/limine.sh 1 '(( $? <= 1 )) || return 1' ':' limine/seal-classes-follow-the-slot
m F157 lib/limine.sh 1 'if [[ $seal == none || $seal == unsupported ]]; then' 'if [[ $seal == none ]]; then' limine/fallback-states

m F158 lib/sign.sh 1 $'            failed=1\n            continue\n            ;;\n          unreadable)' $'            continue\n            ;;\n          unreadable)' sign/untold-seal-is-not-signed-and-fails-the-pass
m F159 lib/sign.sh 1 $'seal=$(limine_seal "$file") || seal=unreadable\n        case $seal in' $'seal=$(limine_seal "$file") || seal=none\n        case $seal in' sign/untold-seal-is-not-signed-and-fails-the-pass
m F160 lib/status.sh 1 '1:unsupported) blocking_problem' '1:unsupported) note' status/unsealed-limine-is-reported-by-its-signature
m F161 lib/status.sh 1 '  variable_holds_local_certificate db || return 0' '  true || return 0' status/signed-unsealed-loader-is-said-after-remove
m F162 lib/limine.sh 1 'count=257' 'count=256' limine/seal-classes-follow-the-slot
m F163 bin/omasecboot 1 'if ! sbctl_keys_exist || [[ $(effective_setting ENABLE_ENROLL_LIMINE_CONFIG) == yes ]]; then' 'if true; then' commands/remove-warns-only-while-the-firmware-trusts-the-key
m F164 lib/status.sh 1 '    blocking_problem "The Limine loader carries your signature and no seal, the firmware trusts your key, and whether Secure Boot is on' '    note "The Limine loader carries your signature and no seal, the firmware trusts your key, and whether Secure Boot is on' status/signed-unsealed-loader-is-said-after-remove
m F165 bin/omasecboot 1 '  elif variable_holds_local_certificate db; then' '  elif true; then' commands/remove-warns-only-while-the-firmware-trusts-the-key
m F166 bin/omasecboot 1 '[[ $(effective_setting ENABLE_ENROLL_LIMINE_CONFIG) == yes ]]; then' 'false; then' commands/remove-warns-only-while-the-firmware-trusts-the-key

m F167 bin/omasecboot 1 'could not be read: if it does, keep Secure Boot off until its factory keys' 'could not be read: nothing to do until its factory keys' commands/remove-warns-only-while-the-firmware-trusts-the-key
m F168 lib/status.sh 1 $'  if ! read_enrollment_plan 2>/dev/null; then\n    warn "The Limine loader' $'  if false; then\n    warn "The Limine loader' status/signed-unsealed-loader-is-said-after-remove
m F169 lib/status.sh 1 '0:unsupported) blocking_problem' '0:unsupported) pass' status/unsealed-limine-is-reported-by-its-signature
m F170 lib/status.sh 1 '[01]:unreadable) blocking_problem' '[01]:unreadable) pass' status/unsealed-limine-is-reported-by-its-signature
m F171 lib/sign.sh 1 $'    seal=$(limine_seal "$file") || seal=unreadable\n    if is_history_file' $'    seal=$(limine_seal "$file") || seal=none\n    if is_history_file' sign/harmful-rows-are-found-and-removed
m F172 lib/sign.sh 1 $'            failed=1\n            continue\n            ;;\n        esac' $'            continue\n            ;;\n        esac' sign/untold-seal-is-not-signed-and-fails-the-pass

m F173 lib/windows.sh 1 '  if [[ $(limine_seal "$(primary_loader_path)" 2>/dev/null) != unsealed ]]; then' '  if false; then' windows/failed-preparation-changes-neither-file
m F174 lib/windows.sh 1 $'    trap \'\' "${HELD_SIGNALS[@]}"' '    :' windows/signal-between-the-renames-leaves-a-pair
m F175 lib/windows.sh 1 '    trap "signal=${held}" "$held"' '    :' windows/signal-between-the-renames-leaves-a-pair
m F176 lib/windows.sh 1 'readonly HELD_SIGNALS=(HUP INT QUIT TERM)' 'readonly HELD_SIGNALS=(INT QUIT TERM)' windows/signal-between-the-renames-leaves-a-pair
m F177 lib/windows.sh 1 '  [[ -z $signal ]] || kill -s "$signal" "$BASHPID"' '  :' windows/signal-between-the-renames-leaves-a-pair
m F178 lib/windows.sh 1 '      [[ $(config_checksum) == "$after" ]] || exit 1' '      exit 1' windows/publication-failures-leave-a-pair-or-say-so
m F179 lib/windows.sh 1 '      _esp_write_unconfirmed=true' '      :' windows/publication-failures-leave-a-pair-or-say-so
m F180 lib/sign.sh 1 'if [[ $_esp_write_unconfirmed == false ]] && durable_sync "$(esp_path)"; then' 'if [[ $_esp_write_unconfirmed == false ]]; then' sign/unsynced-esp-is-said
m F181 lib/windows.sh 1 $'    rm -f -- "$staging"\n    warn "limine.conf changed while' $'    warn "limine.conf changed while' windows/publication-failures-leave-a-pair-or-say-so
m F182 lib/windows.sh 1 '  [[ -z $staging ]] || rm -f -- "$staging"' '  :' windows/publication-failures-leave-a-pair-or-say-so

m F183 lib/windows.sh 1 '  eval "$saved"' '  :' windows/watchers-pass-keeps-ignoring-term
m F184 lib/windows.sh 1 '      durable_sync "$(dirname "$(primary_loader_path)")" || unconfirmed=true' '      durable_sync "$(dirname "$(primary_loader_path)")" || :' windows/publication-failures-leave-a-pair-or-say-so
m F185 lib/limine.sh 1 '  durable_sync "$(dirname "$target")" || _esp_write_unconfirmed=true' '  durable_sync "$(dirname "$target")" || :' sign/unsynced-esp-is-said
m F186 lib/limine.sh 1 '    durable_sync "$parent" || _esp_write_unconfirmed=true' '    durable_sync "$parent" || :' sign/unsynced-esp-is-said
m F187 lib/sign.sh 1 '  elif [[ $synced == false ]]; then' '  elif false; then' sign/unsynced-esp-is-said
m F188 lib/windows.sh 1 '  if [[ $(limine_seal "$(primary_loader_path)" 2>/dev/null) != unsealed ]]; then' '  if true; then' windows/entry-is-written-once-and-taken-out-whole
m F189 bin/omasecboot 1 '  [[ $_esp_write_unconfirmed == false ]] || die "The ESP did not confirm the write of' '  : || die "The ESP did not confirm the write of' commands/remove-says-an-unconfirmed-write
m F190 lib/common.sh 1 'while IFS= read -r line || [[ -n $line ]]; do' 'while IFS= read -r line; do' common/needs-attention-round-trip
m F191 lib/common.sh 1 $'  is_safe_directory "$(state_dir)" || return 1\n  kept=$(attention_without' $'  kept=$(attention_without' common/needs-attention-round-trip
m F192 lib/sign.sh 1 '  # Each kind of finding is written or cleared under the lock,' $'  boot_lock_release\n  # Each kind of finding is written or cleared under the lock,' sign/failure-writes-needs-attention

m F193 lib/sign.sh 1 '{ durable_sync "$file" || _esp_write_unconfirmed=true; }' 'durable_sync "$file"' sign/unsynced-esp-is-said
m F194 bin/omasecboot 2 '[[ $_esp_write_unconfirmed == false ]] || die "The ESP did not confirm the write of' ': || die "The ESP did not confirm the write of' windows/windows-remove-says-an-unconfirmed-write

m F195 lib/common.sh 1 '[[ $uid != 0 || ,$options, == *,idmapped,* ]]' '[[ ,$options, == *,idmapped,* ]]' common/esp-mount-rule-follows-the-kernels-options
m F196 lib/common.sh 1 '(( (8#$fmask & 022) != 022 || (8#$dmask & 022) != 022 ))' '(( (8#$dmask & 022) != 022 ))' common/esp-mount-rule-follows-the-kernels-options
m F197 lib/common.sh 1 '(( (8#$fmask & 022) != 022 || (8#$dmask & 022) != 022 ))' '(( (8#$fmask & 022) != 022 ))' common/esp-mount-rule-follows-the-kernels-options
m F198 lib/common.sh 1 'if [[ -z $fmask || -z $dmask ]]; then' 'if false; then' common/esp-mount-rule-follows-the-kernels-options
m F199 lib/common.sh 1 $'\'$1 == device { print $2, $3 }\'' $'\'{ print $2, $3 }\'' common/esp-mount-rule-follows-the-kernels-options
m F200 lib/sign.sh 1 '  if ! unsafe=$(esp_mount_is_safe); then' '  if false; then' sign/unsafe-esp-mount-writes-nothing
m F201 lib/status.sh 1 '    if ! unsafe=$(esp_mount_is_safe); then' '    if false; then' status/unsafe-esp-mount-blocks
m F202 bin/omasecboot 1 '  unsafe=$(esp_mount_is_safe) || {' '  unsafe=$(esp_mount_is_safe) || true || {' commands/setup-refuses-an-unsafe-esp-mount
m F203 lib/common.sh 1 '[[ $uid != 0 || ,$options, == *,idmapped,* ]]' '[[ $uid != 0 ]]' common/esp-mount-rule-follows-the-kernels-options

# run_one ID BASE WORK: prints one line, "ID RESULT detail".
run_one() {
  local id=$1 base=$2 dir=$3/$1 suite=${expected[$1]%%/*} output rc caught line
  cp -a "$base" "$dir"
  SEARCH=${search[$id]} REPLACE=${replacement[$id]} OCC=${occurrence[$id]} perl -0777 -i -pe '
    my ($s, $r, $o) = ($ENV{SEARCH}, $ENV{REPLACE}, $ENV{OCC}); my $n = 0;
    s/\Q$s\E/ (++$n == $o || $o == 0) ? $r : $s /ge;' "$dir/${file[$id]}"
  if cmp -s "$dir/${file[$id]}" "$base/${file[$id]}"; then
    printf '%s NOMATCH in %s\n' "$id" "${file[$id]}"
    return
  fi
  bash -n "$dir/${file[$id]}" 2>/dev/null || {
    printf '%s ERROR the edit leaves %s that does not parse\n' "$id" "${file[$id]}"
    return
  }
  output=$(cd "$dir" && timeout 300 bash "tests/${suite}.sh" 2>&1)
  rc=$?
  line=$(grep -m1 '^FAIL: ' <<<"$output" | cut -c1-200)
  caught=$(grep -o '^FAIL: [a-z-]*/[a-z0-9-]*' <<<"$line")
  caught=${caught#FAIL: }
  if (( rc == 0 )); then
    printf '%s SURVIVED %s\n' "$id" "${expected[$id]}"
  elif [[ $caught == "${expected[$id]}" ]]; then
    printf '%s CAUGHT %s\n' "$id" "${line#FAIL: }"
  elif [[ -n $caught ]]; then
    printf '%s CAUGHT-BY-ANOTHER %s (expected %s)\n' "$id" "${line#FAIL: }" "${expected[$id]}"
  else
    printf '%s ERROR %s exited %s without a FAIL line\n' "$id" "$suite" "$rc"
  fi
}

main() {
  local base id jobs results suite
  (( $# )) || set -- "${ids[@]}"
  local -A named=()
  for id in "$@"; do
    [[ -n ${file[$id]:-} ]] || { printf 'Unknown mutation: %s\n' "$id" >&2; exit 2; }
    [[ -z ${named[$id]:-} ]] || { printf 'Mutation named twice: %s\n' "$id" >&2; exit 2; }
    named[$id]=1
  done
  WORK=$(mktemp -d /tmp/omasecboot-mutations.XXXXXX) || exit 2
  trap 'rm -rf "$WORK"' EXIT
  base=$WORK/base
  mkdir "$base" "$WORK/results"
  # The files of the working tree that git does not ignore, as make package
  # takes them.
  git -C "$ROOT_DIR" ls-files -z --cached --others --exclude-standard |
    (cd "$ROOT_DIR" && while IFS= read -r -d '' f; do [[ ! -e $f ]] || printf '%s\0' "$f"; done) |
    tar -C "$ROOT_DIR" --null -T - -cf - | tar -C "$base" -xf - || exit 2
  jobs=$(nproc 2>/dev/null || printf '2')
  # A case that fails on the tree as it is would read as a catch.
  for suite in $(for id in "$@"; do printf '%s\n' "${expected[$id]%%/*}"; done | sort -u); do
    while (( $(jobs -rp | wc -l) >= jobs )); do wait -n; done
    { (cd "$base" && timeout 300 bash "tests/${suite}.sh" >/dev/null 2>&1) || printf '%s\n' "$suite" >"$WORK/baseline-${suite}"; } &
  done
  wait
  if compgen -G "$WORK/baseline-*" >/dev/null; then
    printf 'mutations: these suites fail on the tree as it is: %s\n' "$(cat "$WORK"/baseline-* | tr '\n' ' ')"
    exit 1
  fi
  for id in "$@"; do
    while (( $(jobs -rp | wc -l) >= jobs )); do wait -n; done
    run_one "$id" "$base" "$WORK" >"$WORK/results/$id" &
  done
  wait
  results=$(cat "$WORK"/results/* | LC_ALL=C sort -V)
  printf '%s\n' "$results"
  if [[ $(grep -c ' CAUGHT ' <<<"$results") != "$#" ]]; then
    printf 'mutations: %s of %s not caught as expected\n' "$(( $# - $(grep -c ' CAUGHT ' <<<"$results") ))" "$#"
    exit 1
  fi
  printf 'mutations caught (%s)\n' "$#"
}

main "$@"
