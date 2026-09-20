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
#   - the terminal's session sequences and efibootmgr's raw device-path bytes,
#     which repeat the partition UUIDs in another form, are left out.
# Hashes of files stay as they are: they say nothing about the machine.
#
# What nobody can do for the tester: text typed by hand, such as snapshot
# descriptions, stays as written. The last lines of the output say how often
# the login and host names still occur, and where to look.
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
share_dir=$records_dir/share
rm -rf -- "$share_dir"
mkdir -p "$share_dir" || exit 2

readonly UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# The UEFI global variable and image security namespaces, and Microsoft's owner.
readonly PUBLIC_UUIDS='8be4df61-93ca-11d2-aa0d-00e098032b8c d719b2cb-3d3a-4596-a3bc-dad00e67656f 77fa9abd-0359-4d32-bd60-28f4e78f784b'

# distinct PATTERN: what matches in any record, lower case, in order of first
# appearance, so a value gets the same name whichever record is read first.
distinct() { grep -h -o -i -E -- "$1" "${records[@]}" | tr 'A-F' 'a-f' | awk '!seen[$0]++'; }

# Names from the places the recorder is known to put them, never from guesses
# about words: a login name such as "test" occurs in other text too.
login_names=$(grep -h -o -E '/home/[^/[:space:]'"'"'";]+' "${records[@]}" | cut -d/ -f3 | awk '!seen[$0]++')
host_names=$(grep -h -o -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ [^[:space:]]+ ' "${records[@]}" | cut -d' ' -f2 | awk '!seen[$0]++')

rules=$(mktemp) || exit 2
trap 'rm -f -- "$rules"' EXIT
{
  # The session sequences sudo and systemd print, with or without their escape byte.
  printf 's/\\x1b\\?\\]3008;[^\\\\\\x07]*[\\\\\\x07]\\?//g\n'
  printf '/^[[:space:]]*dp: /d\n'
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
tar -czf "$share_dir/omasecboot-records.tgz" -C "$share_dir" -- "${names[@]}" || exit 1

printf 'Shareable copies: %s\nArchive to attach: %s\n' "$share_dir" "$share_dir/omasecboot-records.tgz"
while IFS= read -r value; do
  [[ -n $value ]] || continue
  left=$(grep -h -o -w -F -- "$value" "$share_dir"/*.md | wc -l)
  (( left == 0 )) || printf 'The name "%s" still occurs %s times in the copies; look before you share: grep -n -w -F -- "%s" %s/*.md\n' "$value" "$left" "$value" "$share_dir"
done <<<"$login_names"$'\n'"$host_names"
printf 'Text you typed yourself, such as snapshot descriptions, is copied as it is.\n'
