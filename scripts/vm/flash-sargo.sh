#!/bin/bash
# Flash an image directory that `vm.sh build` brought out (boot.img,
# vbmeta.img, rootfs.simg, SHA256SUMS) to a Pixel 3a in fastboot.
#
#   scripts/vm/flash-sargo.sh <image-directory>
#
# This script, from the repo you read, and not the flash.sh an image build
# writes into its artifact: anything that comes out of the VM is data, never a
# program to run. Overwrites boot and userdata.
set -euo pipefail
dir=${1:?usage: flash-sargo.sh <image-directory>}
cd "$dir"
# These prove the files arrived as the VM wrote them, and nothing more.
sha256sum -c SHA256SUMS

fastboot devices | grep -q . || { echo "!! no fastboot device" >&2; exit 1; }
# A timeout, because fastboot otherwise waits for a device forever and the
# capture hides its "waiting for any device" line.
getvar() { { timeout 10 fastboot getvar "$1" 2>&1 || true; } | sed -n "s/^$1: *//p"; }
p=$(getvar product); [ "$p" = sargo ] || { echo "!! product is '${p:-no answer}', not sargo" >&2; exit 1; }
u=$(getvar unlocked); [ "$u" = yes ] || { echo "!! unlocked is '${u:-no answer}'" >&2; exit 1; }

# vbmeta before boot: flashed after, the bootloader rejects the kernel already there.
fastboot flash vbmeta vbmeta.img
fastboot flash boot boot.img
fastboot flash userdata rootfs.simg

# The slot it booted from, made active again, which resets its retry count
# (docs/devices.md D26).
slot=$(getvar current-slot)
fastboot --set-active="${slot:?could not read current-slot}"
fastboot reboot
