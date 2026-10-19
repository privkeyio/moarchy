#!/usr/bin/env bash
# Fill the gaps in packages/ from the signed [moarchy] repo the manifest names.
#
#   scripts/fetch-published.sh [packages-dir]
#
# For a PKGBUILD_ONLY build (CI): every package this tree built is already in
# packages/ and wins. A name only the published repo has is downloaded, its
# signature checked against pkgbuilds/moarchy-keyring, and vouched for in
# .build-manifest so build-image.sh's pkgset_vouched accepts it. The published
# repo is built from upstream's pins, which can trail manifest.toml, so an image
# made this way tests this tree's packages, not a release.
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

# VALIDSIG's last field is the primary key's fingerprint, whichever subkey signed.
verify() {
  gpg --batch --status-fd=1 --verify "$1.sig" "$1" 2>/dev/null |
    awk -v k="$keyid" '$2 == "VALIDSIG" && $NF == k { found = 1 } END { exit !found }' ||
    { echo "!! $1 is not signed by $keyid" >&2; rm -f "$1" "$1.sig"; return 1; }
}

fetch() {
  [ -s "$CACHE/$1" ] || curl -fsSL --proto '=https' --retry 5 -o "$CACHE/$1" "$server/$1"
  [ -s "$CACHE/$1.sig" ] || curl -fsSL --proto '=https' --retry 5 -o "$CACHE/$1.sig" "$server/$1.sig"
}

rm -f "$CACHE/$name.db" "$CACHE/$name.db.sig"
fetch "$name.db"
verify "$CACHE/$name.db"

# Names this tree built, from the manifest rather than the directory, which may
# hold files a cache restored. Anything the manifest does not vouch for goes, or
# two versions of one name reach the image.
built=$(awk 'NF == 2 && $2 ~ /\.pkg\.tar\./ { print $2 }' "$PKGS/.build-manifest")
have=$(printf '%s\n' "$built" | sed -e 's/\.pkg\.tar\..*$//' -e 's/-[^-]*-[^-]*-[^-]*$//')
for p in "$PKGS"/*.pkg.tar.*; do
  [ -e "$p" ] || continue
  printf '%s\n' "$built" | grep -qxF "${p##*/}" || rm -f "$p"
done

mkdir "$work/db" && tar xzf "$CACHE/$name.db" -C "$work/db"
took=0
for d in "$work"/db/*/; do
  pkg=$(awk '/^%NAME%$/ { getline; print; exit }' "$d/desc")
  file=$(awk '/^%FILENAME%$/ { getline; print; exit }' "$d/desc")
  case "$file" in */*|.*|"") echo "!! refusing filename '$file' from $name.db" >&2; exit 1 ;; esac
  printf '%s\n' "$have" | grep -qxF "$pkg" && continue
  fetch "$file"
  verify "$CACHE/$file"
  cp "$CACHE/$file" "$PKGS/$file"
  printf '%s  %s\n' "$(sha256sum "$PKGS/$file" | cut -d' ' -f1)" "$file" >> "$PKGS/.build-manifest"
  took=$((took + 1))
done
echo "==> $took packages from $server, $(printf '%s\n' "$have" | grep -c . || true) from this tree"
