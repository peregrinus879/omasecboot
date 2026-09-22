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
#   - the short volume identifier of a FAT filesystem reads vol-1, vol-2, ...
#     wherever it occurs, once a mount point of removable media or a UUID=
#     has named it;
#   - the UUIDs that are the same on every machine stay: the UEFI variable
#     namespaces and Microsoft's signature owner;
#   - the login name reads "user" in home paths, in the mount points of
#     removable media and in sudo's log lines, the host name "host" in journal
#     lines of either time stamp form;
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
# Only earlier copies are replaced: a copy is a plain file whose first line is
# a record's, or the archive; anything else in there is somebody's and stops
# this script.
if [[ -e $share_dir ]]; then
  [[ -d $share_dir && ! -L $share_dir ]] || {
    printf 'Refusing to replace %s: it is not a directory of earlier copies\n' "$share_dir" >&2
    exit 2
  }
  while IFS= read -r -d '' entry; do
    if [[ -L $entry || ! -f $entry ]] ||
      { [[ ${entry##*/} != omasecboot-records.tgz ]] && [[ $(head -n 1 -- "$entry") != '# Acceptance record '* ]]; }; then
      printf 'Refusing to replace %s: %s is not an earlier copy\n' "$share_dir" "${entry##*/}" >&2
      exit 2
    fi
  done < <(find "$share_dir" -mindepth 1 -maxdepth 1 -print0)
  rm -rf -- "$share_dir"
fi
mkdir -p "$share_dir" || exit 2

readonly UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# The same with every dash escaped, as systemd writes a UUID into a unit name.
readonly ESCAPED_UUID='[0-9a-fA-F]{8}\\x2d[0-9a-fA-F]{4}\\x2d[0-9a-fA-F]{4}\\x2d[0-9a-fA-F]{4}\\x2d[0-9a-fA-F]{12}'
# The UEFI global variable and image security namespaces, and Microsoft's owner.
readonly PUBLIC_UUIDS='8be4df61-93ca-11d2-aa0d-00e098032b8c d719b2cb-3d3a-4596-a3bc-dad00e67656f 77fa9abd-0359-4d32-bd60-28f4e78f784b'

# distinct PATTERN: what matches in any record, lower case, in order of first
# appearance, so a value gets the same name whichever record is read first.
distinct() { grep -h -o -i -E -- "$1" "${records[@]}" | tr 'A-F' 'a-f' | awk '!seen[$0]++'; }

# Names are renamed only in the places the recorder is known to put them,
# never as words: a login name such as "test" occurs in other text too. They
# are found in home paths, in the mount points udisks gives removable media,
# in sudo's log lines and in the journal's host column, which follows an ISO
# time stamp in the recorder's own blocks and a syslog one in a journalctl
# that was recorded as a command; this machine's own names join the closing
# check, because the copies are usually made where the records were.
login_names=$({
  grep -h -o -E '/home/[^/[:space:]'"'"'";]+' "${records[@]}" | cut -d/ -f3
  grep -h -o -E '/run/media/[^/[:space:]'"'"'";]+' "${records[@]}" | cut -d/ -f4
  grep -h -o -E 'sudo\[[0-9]+\]: +[^[:space:]]+ :' "${records[@]}" | awk '{print $2}'
} | awk '$0 != "root" && !seen[$0]++')
readonly SYSLOG_STAMP='[A-Z][a-z]{2} [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2}'
host_names=$({
  grep -h -o -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:+-]+ [^[:space:]]+ ' "${records[@]}" | cut -d' ' -f2
  grep -h -o -E "^${SYSLOG_STAMP} [^[:space:]]+ [^[:space:]]+\[[0-9]+\]:" "${records[@]}" | cut -c17- | cut -d' ' -f1
} | awk '!seen[$0]++')

rules=$(mktemp) || exit 2
trap 'rm -f -- "$rules"' EXIT
{
  # The session sequences sudo and systemd print, with or without their escape byte.
  printf 's/\\x1b\\?\\]3008;[^\\\\\\x07]*[\\\\\\x07]\\?//g\n'
  # Records made before the recorder left these out itself.
  printf '/^[[:space:]]*\\(dp\\|data\\): /d\n'
  printf 's/\\()\\|\\.efi\\)[0-9a-fA-F]\\{8,\\}$/\\1 (optional data left out)/I\n'
  # An identifier is renamed wherever it stands, inside a longer word too: a
  # machine-id names a UKI as <id>_linux.efi, and systemd writes the dash before
  # a UUID as \x2d. A longer run of digits is a hash and stays.
  number=0
  while IFS= read -r value; do
    [[ -n $value && " $PUBLIC_UUIDS " != *" $value "* ]] || continue
    number=$((number + 1))
    printf 's/%s/uuid-%s/gI\n' "$value" "$number"
    printf 's/%s/uuid-%s/gI\n' "${value//-/\\\\x2d}" "$number"
  done < <({ distinct "$UUID"; distinct "$ESCAPED_UUID" | sed 's/\\x2d/-/g'; } | awk '!seen[$0]++')
  number=0
  while IFS= read -r value; do
    [[ -n $value ]] || continue
    number=$((number + 1))
    printf 's/%s/id-%s/gI\n' "$value" "$number"
  done < <(distinct '[0-9a-fA-F]{32,}' | awk 'length($0) == 32')
  # A FAT volume identifier is too short to be told from other text by its
  # form, so only the ones a mount point, a UUID= or a Limine uuid() names
  # are renamed.
  number=0
  while IFS= read -r value; do
    [[ -n $value ]] || continue
    number=$((number + 1))
    printf 's/\\(^\\|[^-0-9A-Za-z]\\)%s\\($\\|[^-0-9A-Za-z]\\)/\\1vol-%s\\2/g\n' "$value" "$number"
  done < <(grep -h -o -E '(/run/media/[^/[:space:]]+/|UUID=|uuid\()[0-9A-F]{4}-[0-9A-F]{4}\b' "${records[@]}" | grep -o -E '[0-9A-F]{4}-[0-9A-F]{4}$' | awk '!seen[$0]++')
  while IFS= read -r value; do
    [[ -n $value ]] || continue
    escaped=$(sed 's/[][\\.*^$/]/\\&/g' <<<"$value")
    printf 's/\\/home\\/%s\\b/\\/home\\/user/g\n' "$escaped"
    printf 's/\\/run\\/media\\/%s\\b/\\/run\\/media\\/user/g\n' "$escaped"
    printf 's/\\(sudo\\[[0-9]*\\]: *\\)%s :/\\1user :/g\n' "$escaped"
    printf 's/\\b\\(USER\\|LOGNAME\\|SUDO_USER\\)=%s\\b/\\1=user/g\n' "$escaped"
  done <<<"$login_names"
  while IFS= read -r value; do
    [[ -n $value ]] || continue
    escaped=$(sed 's/[][\\.*^$/]/\\&/g' <<<"$value")
    printf 's/^\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9:+-]* \\)%s /\\1host /\n' "$escaped"
    printf 's/^\\([A-Z][a-z]\\{2\\} [ 0-9][0-9] [0-9:]\\{8\\} \\)%s /\\1host /\n' "$escaped"
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
  # The placeholders themselves are in every copy.
  [[ -n $value && $value != root && $value != user && $value != host ]] || continue
  left=$(grep -h -o -w -F -- "$value" "$share_dir"/*.md | wc -l)
  (( left == 0 )) || printf 'The name "%s" still occurs in the copies, %s time(s); look before you share: grep -n -w -F -- "%s" %s/*.md\n' "$value" "$left" "$value" "$share_dir"
done < <(printf '%s\n%s\n%s\n%s\n' "$login_names" "$host_names" "${SUDO_USER:-$(id -un)}" "$(uname -n)" | awk '!seen[$0]++')
printf 'Text typed by hand, such as snapshot descriptions and your notes, is copied as it is. Skim the copies before you share them.\n'
