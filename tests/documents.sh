#!/bin/bash
# What the documents point at exists: decisions and contracts by number, the
# spec's sections, links with their anchors, sections and form fields named in
# quotation marks, and the messages that the README's troubleshooting table and
# the field guide quote. A renumbering or a rewording that leaves a reference
# behind fails here. Whether a reference points at the right thing stays a
# reader's job.
# shellcheck disable=SC2329 # Case functions are called through run_case.
# shellcheck disable=SC2016 # Markdown backticks and the code's own variables are literal text here.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init documents
cd "$ROOT_DIR" || exit 1

readonly PAGES=(README.md AGENTS.md CONTRIBUTING.md SECURITY.md CHANGELOG.md docs/*.md)
readonly FORMS=(.github/ISSUE_TEMPLATE/*.yml)
readonly TOOL=(bin/omasecboot lib/*.sh)
# This file holds the broken references it plants, so it is not read.
SOURCES=("${TOOL[@]}" limine/90-omasecboot-sign systemd/* omasecboot.install PKGBUILD Makefile tests/lib/*.sh)
for suite in tests/*.sh; do
  [[ $suite == tests/documents.sh ]] || SOURCES+=("$suite")
done
readonly SOURCES

# headings FILE: the titles of a page's headings, one per line.
headings() { sed -n 's/^##* //p' "$1"; }

# GitHub's anchor of a heading: lower case, punctuation dropped, a hyphen for
# each space.
anchor_of() {
  local title=${1,,}
  title=${title//[^a-z0-9 _-]/}
  printf '%s\n' "${title// /-}"
}

numbered_references_resolve() {
  local reference file number references=0
  while IFS=: read -r file reference; do
    references=$((references + 1))
    case $reference in
      D*) grep -q "^### ${reference}\. " docs/spec.md || fail_test "${file} cites ${reference}, which the spec does not define" ;;
      C*) grep -q "^## ${reference}\. " docs/upstream-contracts.md || fail_test "${file} cites ${reference}, which the contracts do not define" ;;
    esac
  done < <(grep -oHE '\b[CD][1-9][0-9]?\b' "${PAGES[@]}" "${FORMS[@]}" "${SOURCES[@]}" | sort -u)
  # "sections" in the plural cites the UEFI specification.
  while IFS=: read -r file reference; do
    references=$((references + 1))
    number=${reference##* }
    grep -q "^##* ${number//./\\.}\.\? " docs/spec.md || fail_test "${file} cites ${reference}, which the spec does not have"
  done < <(grep -oHE '\bsection [0-9]+(\.[0-9]+)?\b' "${PAGES[@]}" "${FORMS[@]}" "${SOURCES[@]}" | sort -u)
  (( references > 50 )) || fail_test "the references were not found"
}

links_resolve() {
  local file link target anchor title found links=0
  while IFS=: read -r file link; do
    links=$((links + 1))
    link=${link#']('} && link=${link%')'}
    target=$file
    [[ $link == '#'* ]] || target=$(dirname "$file")/${link%%#*}
    [[ -e $target ]] || fail_test "${file} links to ${link}, which does not exist"
    [[ $link == *'#'* ]] || continue
    anchor=${link#*#} found=false
    while IFS= read -r title; do
      [[ $(anchor_of "$title") != "$anchor" ]] || found=true
    done < <(headings "$target")
    [[ $found == true ]] || fail_test "${file} links to ${link}, and ${target} has no such heading"
  done < <(grep -oHE '\]\([^)]+\)' "${PAGES[@]}" | grep -vE ':\]\((https?|mailto):')
  (( links > 20 )) || fail_test "the links were not found"
}

# A form cannot link, so it names the README's sections and its own fields in
# quotation marks.
named_sections_and_fields_exist() {
  local file title named=0
  while IFS=: read -r file title; do
    named=$((named + 1))
    title=${title#*\"} && title=${title%\"}
    grep -Fxq -e "## ${title}" -e "### ${title}" README.md || fail_test "${file} names the README's section \"${title}\", which it does not have"
  done < <(grep -oHE "README's \"[^\"]+\"" "${PAGES[@]}" "${FORMS[@]}")
  while IFS=: read -r file title; do
    named=$((named + 1))
    title=${title#*\"} && title=${title%\\\"}
    grep -Eq "^ +label: \"?${title}\"?\$" "$file" || fail_test "${file} names its field \"${title}\", which it does not have"
  done < <(grep -oHE 'under \\"[^"\\]+\\"' "${FORMS[@]}")
  (( named > 0 )) || fail_test "no named section or field was found"
}

# These quote the tool: a row of the README's troubleshooting table that begins
# with a quotation, the quotations of a field guide line that begins with
# "Expected:", and what a page introduces with "says". The code's messages
# carry ${BOLD} and ${NC} around commands, and its comments are no messages.
quoted_messages_are_the_tools() {
  local message messages=0 tool
  tool=$(grep -hv '^[[:space:]]*#' "${TOOL[@]}") && tool=${tool//'${BOLD}'/} && tool=${tool//'${NC}'/}
  while IFS= read -r message; do
    messages=$((messages + 1))
    [[ $tool == *"$message"* ]] || fail_test "a page quotes a message the tool does not print: ${message}"
  done < <(
    sed -n '/^## Troubleshooting$/,/^## Removing it$/s/^| `\([^`]*\)`.*/\1/p' README.md
    grep -h '^Expected:' docs/field-testing.md | grep -oE '"[^"]+"' | tr -d '"'
    grep -ohE 'says "[^"]+"' "${PAGES[@]}" | sed 's/^says "//; s/"$//'
  )
  (( messages > 10 )) || fail_test "the quoted messages were not found"
}

# Each check must be able to fail. A copy of the tree passes them all; then one
# break at a time is planted, seen and taken back.
checks_notice_a_broken_reference() {
  local copy=$FIX/pages check
  mkdir -p "$copy"
  cp --parents "${PAGES[@]}" "${FORMS[@]}" "${SOURCES[@]}" LICENSE "$copy/"
  cd "$copy" || fail_test "cd"
  for check in numbered_references_resolve links_resolve named_sections_and_fields_exist quoted_messages_are_the_tools; do
    ("$check") || fail_test "${check} fails on an unchanged copy"
  done
  planted numbered_references_resolve docs/spec.md 's/\[C2\]/[C99]/' "a contract that does not exist"
  planted numbered_references_resolve lib/files.sh 's/(D5)/(D50)/' "a decision that does not exist"
  planted numbered_references_resolve docs/spec.md 's/(section 4)/(section 40)/' "a section that does not exist"
  planted links_resolve README.md 's/^## If the machine does not start$/## When the machine does not start/' "a link to a renamed heading"
  planted links_resolve README.md 's|(docs/spec.md)|(docs/design.md)|' "a link to a file that does not exist"
  planted named_sections_and_fields_exist README.md 's/^## If the machine does not start$/## When the machine does not start/' "a renamed README section that a form names"
  planted named_sections_and_fields_exist .github/ISSUE_TEMPLATE/field-report.yml 's/^      label: What differed$/      label: Differences/' "a renamed field that the form names"
  planted quoted_messages_are_the_tools README.md 's/^| `Boot files are busy`/| `Boot files are occupied`/' "a README message the tool does not print"
  planted quoted_messages_are_the_tools docs/field-testing.md 's/"Your keys are enrolled and/"Your keys were enrolled and/' "a field guide message the tool does not print"
}

# planted CHECK FILE SED-SCRIPT WHAT: CHECK must fail while FILE carries the
# change, and pass again without it.
planted() {
  cp "$2" "$FIX/unchanged"
  sed -i "$3" "$2"
  ! cmp -s "$2" "$FIX/unchanged" || fail_test "nothing was planted for: $4"
  ("$1") 2>/dev/null && fail_test "$4 went unnoticed"
  cp "$FIX/unchanged" "$2"
}

run_case numbered-references-resolve numbered_references_resolve
run_case links-resolve links_resolve
run_case named-sections-and-fields-exist named_sections_and_fields_exist
run_case quoted-messages-are-the-tools quoted_messages_are_the_tools
run_case checks-notice-a-broken-reference checks_notice_a_broken_reference
finish_suite
