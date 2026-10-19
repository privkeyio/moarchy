#!/usr/bin/env bash
# Fill the gaps in packages/ from the signed [moarchy] repo the manifest names.
#
#   scripts/fetch-published.sh [packages-dir]
#
# For a PKGBUILD_ONLY build (CI): every package this tree built is already in
# packages/ and wins. A name only the published repo has is downloaded, checked
# against the hash the signed database gives it and against its own signature,
# and vouched for in .build-manifest so build-image.sh's pkgset_vouched accepts
# it. The published repo is built from upstream's pins, which can trail
# manifest.toml, so an image made this way tests this tree's packages, not a
# release.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKGS="${1:-$REPO_ROOT/packages}"
CACHE="${PKGCACHE:-$REPO_ROOT/.cache/published}"
. "$REPO_ROOT/scripts/manifest.sh"

server=$(manifest_get repo server) || exit 1
keyid=$(manifest_get repo keyid) || exit 1
name=$(manifest_get repo name) || exit 1

[ -f "$PKGS/.build-manifest" ] || { echo "!! no $PKGS/.build-manifest" >&2; exit 1; }
mkdir -p "$CACHE"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"; mkdir -m700 "$GNUPGHOME"
gpg --batch --quiet --import "$REPO_ROOT/pkgbuilds/moarchy-keyring/moarchy.gpg"

# GOODSIG rules out an expired or revoked key, which still gets a VALIDSIG.
# VALIDSIG's last field is the primary key's fingerprint, whichever subkey signed.
verify() {
  gpg --batch --status-fd=1 --verify "$1.sig" "$1" 2>/dev/null |
    awk -v k="$keyid" '$2 == "GOODSIG" { g = 1 } $2 == "VALIDSIG" && $NF == k { v = 1 } END { exit !(g && v) }' ||
    { echo "!! $1 is not signed by $keyid" >&2; rm -f "$1" "$1.sig"; return 1; }
}

fetch() {
  local f
  for f in "$1" "$1.sig"; do
    [ -s "$CACHE/$f" ] ||
      curl -fsSLg --proto '=https' --retry 5 --connect-timeout 30 --max-time 1800 \
        -o "$CACHE/$f" "$server/$f"
  done
}

rm -f "$CACHE/$name.db" "$CACHE/$name.db.sig"
fetch "$name.db"
verify "$CACHE/$name.db"

# Every in-repo recipe is this tree's to build (one package per directory, named
# after it). One the build did not vouch for is an error, not a gap for the
# published copy to fill: CI would pass on upstream's bytes.
built=$(awk 'NF == 2 && $2 ~ /\.pkg\.tar\./ { print $2 }' "$PKGS/.build-manifest")
have=$(printf '%s\n' "$built" | sed -e 's/\.pkg\.tar\..*$//' -e 's/-[^-]*-[^-]*-[^-]*$//')
for d in "$REPO_ROOT"/pkgbuilds/*/; do
  p=$(basename "$d")
  printf '%s\n' "$have" | grep -qxF -e "$p" ||
    { echo "!! $p is an in-repo package but not in $PKGS/.build-manifest" >&2; exit 1; }
done
# packages/ may hold files a cache restored. Anything the manifest does not
# vouch for goes, or two versions of one name reach the image.
for p in "$PKGS"/*.pkg.tar.*; do
  [ -e "$p" ] || continue
  printf '%s\n' "$built" | grep -qxF -e "${p##*/}" || rm -f "$p"
done

mkdir "$work/db" && tar xzf "$CACHE/$name.db" -C "$work/db"
took=0
for d in "$work"/db/*/; do
  pkg=$(awk '/^%NAME%$/ { getline; print; exit }' "$d/desc")
  file=$(awk '/^%FILENAME%$/ { getline; print; exit }' "$d/desc")
  sum=$(awk '/^%SHA256SUM%$/ { getline; print; exit }' "$d/desc")
  case "$file" in
    */*|.*|*[!A-Za-z0-9._+@:-]*) echo "!! refusing filename '$file' from $name.db" >&2; exit 1 ;;
    *.pkg.tar.*) ;;
    *) echo "!! refusing filename '$file' from $name.db" >&2; exit 1 ;;
  esac
  [[ $sum =~ ^[0-9a-f]{64}$ ]] || { echo "!! no SHA256SUM for $file in $name.db" >&2; exit 1; }
  printf '%s\n' "$have" | grep -qxF -e "$pkg" && continue
  fetch "$file"
  # The signed database names these exact bytes. A detached signature alone
  # would accept any package ever signed under this filename, an older one
  # included.
  printf '%s  %s\n' "$sum" "$CACHE/$file" | sha256sum -c --quiet - ||
    { echo "!! $file does not match $name.db" >&2; rm -f "$CACHE/$file" "$CACHE/$file.sig"; exit 1; }
  verify "$CACHE/$file"
  cp "$CACHE/$file" "$PKGS/$file"
  # The database's hash, not a fresh one: pkgset_vouched then re-checks the copy.
  printf '%s  %s\n' "$sum" "$file" >> "$PKGS/.build-manifest"
  took=$((took + 1))
done
echo "==> $took packages from $server, $(printf '%s\n' "$have" | grep -c . || true) from this tree"
