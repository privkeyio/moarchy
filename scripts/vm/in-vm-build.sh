#!/bin/bash
# Inside the build VM: the image CI builds, built the way CI builds it
# (.github/workflows/image.yml), and checked the same way. Run by `vm.sh build`;
# not meant to be run by hand.
#
#   in-vm-build.sh <ref>
#
# ~/in/moarchy.bundle holds <ref>. A dev image (MOARCHY_SSH_KEY) is built and
# checked beside the release image every time, as CI does, keyed to
# ~/in/dev.pub when there is one and to a throwaway key otherwise. The images
# and their SHA256SUMS end up in ~/out/{release,dev}, from where vm.sh copies
# out the release image and, only when it is yours, the dev one. The log is
# ~/build.log; the last line is BUILD OK or BUILD FAILED.
set -euo pipefail
REF=${1:?usage: in-vm-build.sh <ref>}
: >~/build.log
exec > >(tee -a ~/build.log) 2>&1
trap 'echo "==> BUILD FAILED at line $LINENO (exit $?)"' ERR
echo "==> build of $REF, $(date -u +%FT%TZ)"

# This VM is x86_64, so the arm64 image container runs under qemu-user, which
# does not pass ext4's online-resize ioctl through ("Kernel does not support
# online resizing"). verify.sh's online-grow check therefore fails here and
# only here; CI runs it on a native arm64 runner. That one FAIL is allowed and
# any other is not.
verify() {
  local out rc=0
  out=$(mktemp)
  "$@" 2>&1 | tee "$out" || rc=$?
  [ "$rc" = 0 ] && return 0
  local fails others
  # verify.sh got to its verdict, rather than stopping after that check.
  sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -qE '^\s*some checks failed$' || return 1
  fails=$(sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -E '^\s*FAIL ' || true)
  others=$(printf '%s\n' "$fails" | grep -v 'resize2fs failed on /dev/loop' | grep -c . || true)
  if [ "$others" = 0 ] && [ -n "$fails" ]; then
    echo "==> only the emulated online-resize check failed (qemu-user); CI checks it natively"
    return 0
  fi
  return 1
}

[ -d ~/moarchy/.git ] || git init -q ~/moarchy
cd ~/moarchy
git fetch -q ~/in/moarchy.bundle "$REF"
git reset -q --hard FETCH_HEAD
echo "==> commit $(git rev-parse --short HEAD)"

# A clean tree each run, as CI's is, but for the kernel, which takes most of an
# hour under emulation. Cached as CI caches it: keyed on the [device.sargo]
# pins and the recipe, so a changed config is a rebuild even with no pkgrel
# bump. vm.sh gives every build a fresh VM unless told to reuse one, so the
# cache only lives as long as a VM that is being reused.
KEY=$( { sed -n '/^\[device\.sargo\]/,/^\[/p' manifest.toml;
         find pkgbuilds/linux-moarchy-sdm670 -type f -print0 | sort -z | xargs -0 sha256sum; } |
       sha256sum | cut -c1-16)
CACHE=$HOME/kernel-cache/$KEY
# sudo first: the image container leaves root's files behind, which git clean
# cannot remove.
sudo rm -rf packages images ~/dev-images ~/out
git clean -q -fdx
# And the commit's own files back: packages/.gitkeep went with the rest, and
# build-image.sh refuses a tree that does not match its commit.
git reset -q --hard FETCH_HEAD
[ -z "$(git status --porcelain)" ] || { git status --short; echo "!! the tree does not match the commit"; exit 1; }
mkdir -p packages
if cp "$CACHE"/*.pkg.tar.* packages/ 2>/dev/null; then echo "    the kernel from the cache ($KEY)"; fi
chmod -R a+rwX packages

echo "==> [1/7] the in-repo packages"
PKGBUILD_ONLY="$(ls pkgbuilds)" ./scripts/provision.sh build
sudo chown -R "$(id -u):$(id -g)" packages
# Only kernels this build's manifest names: a package a cut-off build left
# behind is not one.
rm -rf "$HOME/kernel-cache" && mkdir -p "$CACHE"
awk '$2 ~ /^linux-moarchy-sdm670-/ { print "packages/" $2 }' packages/.build-manifest |
  xargs -r cp -t "$CACHE"/

echo "==> [2/7] packages from the published repo"
./scripts/fetch-published.sh packages

echo "==> [3/7] release image"
./scripts/build-image.sh
sudo chown -R "$(id -u):$(id -g)" images
ART=$(ls -td images/moarchy-sargo-*/ | head -1); ART=${ART%/}
verify ./scripts/verify-image.sh "$ART"

echo "==> [4/7] QML tests, in the image container"
docker run --rm --platform linux/arm64 -v "$PWD:/repo:ro" --entrypoint bash moarchy-image \
  -c 'pacman -Sy --noconfirm --needed qt6-declarative >/dev/null && bash /repo/scripts/test-qml.sh'

echo "==> [5/7] the PIN's door, through real sudo and PAM"
docker run --rm --platform linux/arm64 -v "$PWD:/repo:ro" --entrypoint bash moarchy-image \
  /repo/scripts/test-pam-door.sh

echo "==> [6/7] negative test"
docker run --rm --privileged --platform linux/arm64 -v "$PWD/images:/img:ro" \
  --entrypoint bash moarchy-image /repo/image/negative-test.sh "/img/$(basename "$ART")"
mkdir -p ~/out/release
cp "$ART"/boot.img "$ART"/vbmeta.img "$ART"/rootfs.simg ~/out/release/
(cd ~/out/release && sha256sum boot.img vbmeta.img rootfs.simg > SHA256SUMS)

# Always, as CI does: with your key in it, or a throwaway one made here, when
# the image stays in here (vm.sh only copies out a dev image you keyed).
devkey=$HOME/in/dev.pub
if [ ! -s "$devkey" ]; then
  rm -f ~/throwaway ~/throwaway.pub
  ssh-keygen -q -t ed25519 -N '' -C vm-throwaway -f ~/throwaway
  devkey=$HOME/throwaway.pub
fi
echo "==> [7/7] dev image, for $(cut -d' ' -f3- "$devkey")"
MOARCHY_SSH_KEY=$devkey OUTDIR=$HOME/dev-images ./scripts/build-image.sh
sudo chown -R "$(id -u):$(id -g)" ~/dev-images
DEV=$(ls -td ~/dev-images/moarchy-sargo-*/ | head -1); DEV=${DEV%/}
verify env DEV_IMAGE=1 ./scripts/verify-image.sh "$DEV"
docker run --rm --privileged --platform linux/arm64 -e DEV_IMAGE=1 -v "$(dirname "$DEV"):/img:ro" \
  --entrypoint bash moarchy-image /repo/image/negative-test.sh "/img/$(basename "$DEV")"
mkdir -p ~/out/dev
cp "$DEV"/boot.img "$DEV"/vbmeta.img "$DEV"/rootfs.simg ~/out/dev/
(cd ~/out/dev && sha256sum boot.img vbmeta.img rootfs.simg > SHA256SUMS)
echo "==> BUILD OK: $(basename "$ART"), commit $(git rev-parse --short HEAD)"
