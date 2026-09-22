#!/bin/bash
# Builders for EFI signature lists (UEFI 2.10, 32.4.1), shared by the harness
# and the sbctl stub: a 16-byte type, the list size, a header size of zero and
# the entry size as little-endian uint32, then entries of a 16-byte owner and
# the data. Types and owners are given as the hex of their stored bytes.

readonly ESL_X509_TYPE=a159c0a5e494a74a87b5ab155c2bf072
readonly ESL_SHA256_TYPE=2616c4c14c509240aca941f936934328

# shellcheck disable=SC2001 # Every pair of digits gets a prefix; no expansion does that.
hex_bytes() { printf '%b' "$(sed 's/../\\x&/g' <<<"$1")"; }

le32() {
  local hex
  printf -v hex '%02x%02x%02x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255))
  hex_bytes "$hex"
}

# x509_row OWNER CERTIFICATE-TEXT: the row the reader prints for that
# certificate, "TYPE OWNER SHA256-OF-THE-DATA", for the suites' assertions.
x509_row() { printf '%s %s %s\n' "$ESL_X509_TYPE" "$1" "$(printf '%s' "$2" | sha256sum | cut -d' ' -f1)"; }

# x509_list OWNER CERTIFICATE-TEXT: a list with one certificate, which is how
# firmware and sbctl store them, because certificates differ in size.
x509_list() {
  local LC_ALL=C
  local entry_size=$((16 + ${#2}))
  hex_bytes "$ESL_X509_TYPE"
  le32 $((28 + entry_size))
  le32 0
  le32 "$entry_size"
  hex_bytes "$1"
  printf '%s' "$2"
}

# sha256_list OWNER HASH...: one list with an entry per 64-digit hash, as dbx
# holds them.
sha256_list() {
  local owner=$1 hash
  shift
  hex_bytes "$ESL_SHA256_TYPE"
  le32 $((28 + 48 * $#))
  le32 0
  le32 48
  for hash in "$@"; do
    hex_bytes "$owner"
    hex_bytes "$hash"
  done
}
