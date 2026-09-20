#!/bin/bash
# Copies of acceptance records that are fit for a public issue.
#
#   bash tests/acceptance-share.sh [records-directory]
#
# The records of tests/acceptance-record.sh are written for a private review:
# they hold the machine's host name, the login name, the machine-id, boot and
# session identifiers, and the UUIDs of partitions, filesystems, the LUKS
# volume and sbctl's owner. This writes <records>/share/ with one copy per
# record and omasecboot-records.tgz beside them, in which
#   - every UUID reads uuid-1, uuid-2, ... and every 32-digit identifier id-1,
#     id-2, ..., the same value under the same name in every record, so that
#     entries can still be told apart and matched;
#   - the UUIDs that are the same on every machine stay: the UEFI variable
#     namespaces and Microsoft's signature owner;
#   - the login name reads "user" in home paths and sudo's log lines, the host
#     name "host" in journal lines;
#   - the terminal's session sequences and efibootmgr's raw bytes, which
#     repeat partition UUIDs in another form, are left out;
#   - the archive's members belong to nobody: tar would otherwise write the
#     login name into every header.
#
# What stays, because the review needs it or no rule can know it: the machine's
# model and firmware version, package versions, disk and partition sizes, boot
# entry labels, the time zone of time stamps, hashes of boot files, and every
# text typed by hand, such as snapshot descriptions. The last lines of the
# output say where the login and host names still occur. Skim the copies
# before they go anywhere public.
set -uo pipefail

records_dir=${1:-$PWD/acceptance-records}
[[ -d $records_dir ]] || {
  printf 'No records directory: %s\n' "$records_dir" >&2
  exit 2
}
shopt -s nullglob
records=("$records_dir"/*.md)
(( ${#records[@]} > 0 )) || {
  printf 'No records in %s\n' "$records_dir" >&2
  exit 2
}
# Only records are copied, and only earlier copies are deleted: the directory
# comes from the command line.
for record in "${records[@]}"; do
  [[ $(head -n 1 -- "$record") == '# Acceptance record '* ]] || {
    printf 'Not an acceptance record: %s\n' "$record" >&2
    exit 2
  }
done
share_dir=$records_dir/share
if [[ -e $share_dir ]]; then
  [[ -d $share_dir && ! -L $share_dir && -z $(find "$share_dir" -mindepth 1 ! -name '*.md' ! -name 'omasecboot-records.tgz' -print -quit) ]] || {
    printf 'Refusing to replace %s: it holds something other than earlier copies\n' "$share_dir" >&2
    exit 2
  }
  rm -rf -- "$share_dir"
fi
mkdir -p "$share_dir" || exit 2

readonly UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# The UEFI global variable and image security namespaces, and Microsoft's owner.
readonly PUBLIC_UUIDS='8be4df61-93ca-11d2-aa0d-00e098032b8c d719b2cb-3d3a-4596-a3bc-dad00e67656f 77fa9abd-0359-4d32-bd60-28f4e78f784b'

# distinct PATTERN: what matches in any record, lower case, in order of first
# appearance, so a value gets the same name whichever record is read first.
distinct() { grep -h -o -i -E -- "$1" "${records[@]}" | tr 'A-F' 'a-f' | awk '!seen[$0]++'; }

# Names are renamed only in the places the recorder is known to put them,
# never as words: a login name such as "test" occurs in other text too. They
# are found in home paths, in sudo's log lines and in the journal's host
# column; this machine's own names join the closing check, because the copies
# are usually made where the records were.
login_names=$({
  grep -h -o -E '/home/[^/[:space:]'"'"'";]+' "${records[@]}" | cut -d/ -f3
  grep -h -o -E 'sudo\[[0-9]+\]: +[^[:space:]]+ :' "${records[@]}" | awk '{print $2}'
} | awk '$0 != "root" && !seen[$0]++')
host_names=$(grep -h -o -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ [^[:space:]]+ ' "${records[@]}" | cut -d' ' -f2 | awk '!seen[$0]++')

rules=$(mktemp) || exit 2
trap 'rm -f -- "$rules"' EXIT
{
  # The session sequences sudo and systemd print, with or without their escape byte.
  printf 's/\\x1b\\?\\]3008;[^\\\\\\x07]*[\\\\\\x07]\\?//g\n'
  printf '/^[[:space:]]*dp: /d\n'
  printf 's/\\(\\.efi\\)[0-9a-fA-F]\\{16,\\}$/\\1 (optional data left out)/I\n'
  number=0
  while IFS= read -r value; do
    [[ -n $value && " $PUBLIC_UUIDS " != *" $value "* ]] || continue
    number=$((number + 1))
    printf 's/\\b%s\\b/uuid-%s/gI\n' "$value" "$number"
  done < <(distinct "\\b${UUID}\\b")
  number=0
  while IFS= read -r value; do
    [[ -n $value ]] || continue
    number=$((number + 1))
    printf 's/\\b%s\\b/id-%s/gI\n' "$value" "$number"
  done < <(distinct '\b[0-9a-fA-F]{32}\b')
  while IFS= read -r value; do
    [[ -n $value ]] || continue
    escaped=$(sed 's/[][\\.*^$/]/\\&/g' <<<"$value")
    printf 's/\\/home\\/%s\\b/\\/home\\/user/g\n' "$escaped"
    printf 's/\\(sudo\\[[0-9]*\\]: *\\)%s :/\\1user :/g\n' "$escaped"
    printf 's/\\b\\(USER\\|LOGNAME\\|SUDO_USER\\)=%s\\b/\\1=user/g\n' "$escaped"
  done <<<"$login_names"
  while IFS= read -r value; do
    [[ -n $value ]] || continue
    escaped=$(sed 's/[][\\.*^$/]/\\&/g' <<<"$value")
    printf 's/^\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9:+-]* \\)%s /\\1host /\n' "$escaped"
    printf 's/\\bhostname=%s\\b/hostname=host/g\n' "$escaped"
  done <<<"$host_names"
} >"$rules"

names=()
for record in "${records[@]}"; do
  sed -f "$rules" -- "$record" >"$share_dir/${record##*/}" || exit 1
  names+=("${record##*/}")
done
tar --owner=0 --group=0 --numeric-owner -czf "$share_dir/omasecboot-records.tgz" -C "$share_dir" -- "${names[@]}" || exit 1

printf 'Shareable copies: %s\nArchive to attach: %s\n' "$share_dir" "$share_dir/omasecboot-records.tgz"
[[ -n $login_names ]] || printf 'No login name was found in the records, so none was renamed.\n'
[[ -n $host_names ]] || printf 'No host name was found in the records, so none was renamed.\n'
while IFS= read -r value; do
  [[ -n $value && $value != root ]] || continue
  left=$(grep -h -o -w -F -- "$value" "$share_dir"/*.md | wc -l)
  (( left == 0 )) || printf 'The name "%s" still occurs %s times in the copies; look before you share: grep -n -w -F -- "%s" %s/*.md\n' "$value" "$left" "$value" "$share_dir"
done < <(printf '%s\n%s\n%s\n%s\n' "$login_names" "$host_names" "${SUDO_USER:-$(id -un)}" "$(uname -n)" | awk '!seen[$0]++')
printf 'Text typed by hand, such as snapshot descriptions and your notes, is copied as it is. Skim the copies before you share them.\n'
