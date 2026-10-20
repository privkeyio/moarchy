#!/bin/bash
# Prove the verifier can fail.
#
# Every check in verify.sh passed on the first image that was built, including
# two that were passing for the wrong reason and two that were FAILING for the
# wrong reason. A suite that has only ever been run against a good image has not
# been shown to measure anything.
#
# So: take a good artifact, break specific things, and assert that verify.sh
# reports exactly those and exits non-zero.
#
# Ported from the sunxi-gpt artifact on 2026-09-19. That version broke the
# u-boot SPL magic at byte 131076 and loop-mounted the rootfs at LBA 266240 --
# both facts about a whole-disk image on removable media, and neither one
# expressible about a directory of boot.img/vbmeta.img/rootfs.simg. The planted
# defects below are the same six ideas against the shape that is left: one per
# layer verify.sh has (artifact, boot image, verified boot, rootfs contents,
# first-boot units).
#
# Disk: the rootfs is sparse, so breaking anything inside it means expanding it,
# editing it, and re-sparsing it. Peak usage is about twice the rootfs -- the
# raw copy is deleted as soon as img2simg has read it, and verify.sh then
# expands its own. [[docker-vm-disk-kills-image-build]] is what this comment is
# here to prevent a repeat of.
set -uo pipefail
ART=${1:?usage: negative-test.sh <artifact-directory>}
ART=${ART%/}
W=/ntwork; rm -rf $W; mkdir -p $W/bad $W/r
FAIL=0
ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
no() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }

[ -d "$ART" ] || { echo "not a directory: $ART -- an Android artifact is a directory (D10)"; exit 1; }

echo "==> building a deliberately broken copy of $(basename "$ART")"
# The small files are copied; the rootfs is rebuilt below.
cp "$ART/boot.img" "$ART/vbmeta.img" "$ART/flash.sh" $W/bad/
chmod +x $W/bad/flash.sh

# 1. destroy the boot image magic the bootloader looks for
printf 'XXXXXXXX' | dd of=$W/bad/boot.img bs=1 seek=0 conv=notrunc status=none

# 2. clear the AVB "verification disabled" flag, so an Android 12 bootloader
#    would refuse this kernel. Flags are a big-endian u32 at byte 120.
printf '\0\0\0\0' | dd of=$W/bad/vbmeta.img bs=1 seek=120 conv=notrunc status=none

# 3. drop the slot retry reset (D26) -- the defect that bricks a boot silently
sed -i 's/--set-active/--no-such-flag/g' $W/bad/flash.sh

echo "==> expanding the rootfs to plant the rest"
simg2img "$ART/rootfs.simg" $W/root.raw || { echo "simg2img failed"; exit 1; }
mount -o loop $W/root.raw $W/r || { echo "mount failed"; exit 1; }
if [ "${DEV_IMAGE:-0}" = 1 ]; then
  # A dev image, verified as one: the defects are the ways its way in could
  # widen past the cable.
  # d1. a second listener, in the keyword=value form sshd accepts
  printf 'ListenAddress=0.0.0.0\n' > $W/r/etc/ssh/sshd_config.d/99-planted.conf
  # d2. a Match block that opens sshd to the LAN
  printf 'Match Address 192.168.0.0/16\n  AllowUsers *\n' >> $W/r/etc/ssh/sshd_config.d/99-planted.conf
  # d3. sshd's packet filter widened to Wi-Fi by one added line
  echo 'RestrictNetworkInterfaces=wlan0' >> $W/r/etc/systemd/system/sshd.service.d/20-moarchy-usbnet.conf
  # d4. a drop-in that could reset it
  printf '[Service]\nIPAddressDeny=\n' > $W/r/etc/systemd/system/sshd.service.d/99-planted.conf
  # d5. IPv6 left on for the USB host to configure
  sed -i '/disable_ipv6/d' $W/r/usr/local/sbin/moarchy-usbnet
  # d6. a type-wide drop-in that resets the filter for every service
  mkdir -p $W/r/etc/systemd/system/service.d
  printf '[Service]\nRestrictNetworkInterfaces=\n' > $W/r/etc/systemd/system/service.d/99-planted.conf
  # d7. a slice drop-in whose allow list every unit under it inherits
  mkdir -p $W/r/etc/systemd/system/system.slice.d
  printf '[Slice]\nIPAddressAllow=any\n' > $W/r/etc/systemd/system/system.slice.d/99-planted.conf
  # d8. a whole replacement sshd.service
  cp $W/r/usr/lib/systemd/system/sshd.service $W/r/etc/systemd/system/sshd.service
  # d9. NetworkManager allowed to take the link
  sed -i 's/^unmanaged-devices=/#&/' $W/r/etc/NetworkManager/conf.d/90-moarchy-usbnet.conf
  # d10. a socket-activated sshd, outside sshd.service's drop-ins
  mkdir -p $W/r/etc/systemd/system/sockets.target.wants
  ln -sf /usr/lib/systemd/system/sshd.socket $W/r/etc/systemd/system/sockets.target.wants/sshd.socket
  umount $W/r
  img2simg $W/root.raw $W/bad/rootfs.simg || { echo "img2simg failed"; exit 1; }
  rm -f $W/root.raw
  echo "==> running DEV_IMAGE=1 verify.sh against it (it MUST fail)"
  DEVICE=sargo WORK=/ntverify bash /repo/image/verify.sh $W/bad > $W/out.txt 2>&1
  rc=$?
  sed -e 's/\x1b\[[0-9;]*m//g' $W/out.txt > $W/plain.txt
  catches() { if grep -q "FAIL.*$1" $W/plain.txt; then ok "caught: $2"; else no "MISSED: $2"; fi; }
  echo; echo "==> did each break get caught?"
  catches "ANDROID!"                      "corrupted boot image header"
  catches "vbmeta flags"                  "AVB verification left enabled"
  catches "set-active"                    "flash.sh no longer resets the retry counter"
  catches "listens on '0.0.0.0:22 10.66.0.2:22 '" "a second sshd listener"
  catches "AllowUsers is '\* ', not moarchy@10.66.0.1 alone (as seen from 192.168.1.5)" \
                                          "a Match block opening sshd to the LAN"
  catches "drop-in is not the one configure.sh writes" "sshd's packet filter widened to Wi-Fi"
  catches "could undo.*sshd.service.d/99-planted.conf" "a drop-in that could reset the filter"
  catches "could undo.*/etc/systemd/system/service.d/99-planted.conf" "a type-wide drop-in resetting the filter"
  catches "could undo.*/etc/systemd/system/system.slice.d/99-planted.conf" "a slice drop-in widening the filter"
  catches "could undo.*/etc/systemd/system/sshd.service\( \|$\)" "a replacement sshd.service"
  catches "accepts IPv6 router"           "IPv6 left on usb0"
  catches "NetworkManager could manage the link" "NetworkManager allowed to take the link"
  catches "ssh socket unit is enabled"    "a socket-activated sshd"
  echo
  if [ $rc -ne 0 ]; then ok "verify.sh exited non-zero ($rc)"; else no "verify.sh exited 0 on a broken dev image"; fi
  [ $FAIL = 0 ] && printf '  \033[32mthe verifier detects every planted defect\033[0m\n' \
                || printf '  \033[31mthe verifier is blind to something\033[0m\n'
  exit $FAIL
fi
# 4. a credential the image must never carry
mkdir -p $W/r/etc/NetworkManager/system-connections
echo "[connection]" > $W/r/etc/NetworkManager/system-connections/leaked.nmconnection
# 5. mark it a debug image
touch $W/r/etc/moarchy-debug-image
# 6. give the account a real password hash
sed -i 's|^moarchy:!:|moarchy:$6$fakehashfakehashfakehash:|' $W/r/etc/shadow
# 7. remove a shell plugin
rm -rf $W/r/usr/share/moarchy/plugins/moarchy.control-center
# 8. un-enable the grow unit
rm -f $W/r/etc/systemd/system/sysinit.target.wants/moarchy-grow-rootfs.service
# 9. ship a pacman keyring, the master secret every flashed phone would share
mkdir -p $W/r/etc/pacman.d/gnupg/private-keys-v1.d
touch $W/r/etc/pacman.d/gnupg/private-keys-v1.d/planted.key
# 10. a plain-HTTP mirror, over which the unsigned ALARM databases travel
echo 'Server = http://mirror.archlinuxarm.org/$arch/$repo' >> $W/r/etc/pacman.d/mirrorlist
# 11. turn the mDNS responder back on behind the image's back
mkdir -p $W/r/etc/systemd/resolved.conf.d
printf '[Resolve]\nMulticastDNS=yes\n' > $W/r/etc/systemd/resolved.conf.d/99-planted.conf
# 12. the USB dev link's sshd drop-in, in an image that is not a dev image
mkdir -p $W/r/etc/ssh/sshd_config.d
printf 'ListenAddress 10.66.0.2\n' > $W/r/etc/ssh/sshd_config.d/20-moarchy-usbnet.conf
# 13. the lock screen's sudo rule widened to any argument, which is root for
#     anyone holding the phone: `moarchy-pin set` with no PIN asked
# Appended, not substituted: a substitution that stops matching when the rule
# changes plants nothing, and the miss reads as a blind verifier.
sed -i 's|$|, /usr/lib/moarchy/bin/moarchy-pin set|' $W/r/etc/sudoers.d/20-moarchy-pin
# 14. su setuid again, an uncounted way to guess the PIN
chmod 4755 $W/r/usr/bin/su
# 15. upstream's PAM service, which arms upstream's lock beside ours
printf '#%%PAM-1.0\nauth required pam_unix.so\n' > $W/r/etc/pam.d/omarchy-lock-password
# 17. system-auth back on pam_unix, so sudo checks the PIN uncounted
sed -i 's|pam_exec.so .*moarchy-pin pam$|pam_unix.so          try_first_pass nullok|' $W/r/etc/pam.d/system-auth
# 18. polkit's agent helper back to read-only /var/lib, which fails every prompt
rm -f "$W/r/usr/lib/systemd/system/polkit-agent-helper@.service.d/50-moarchy-pin.conf"
# 16. a second sudoers file granting `moarchy-pin set` with no password
printf '%%wheel ALL=(root) NOPASSWD: /usr/lib/moarchy/bin/moarchy-pin set\n' > $W/r/etc/sudoers.d/99-planted
umount $W/r

echo "==> re-sparsing"
img2simg $W/root.raw $W/bad/rootfs.simg || { echo "img2simg failed"; exit 1; }
# Freed before verify.sh expands its own copy, so the peak is two rootfs and
# not three.
rm -f $W/root.raw

echo "==> running verify.sh against it (it MUST fail)"
# DEVICE is explicit because this directory is called `bad` on purpose --
# verify.sh otherwise infers the device from the artifact's name
# (docs/devices.md D12) and would refuse it before running any of the checks
# below, so this suite would fail without ever testing what it exists to test.
DEVICE=sargo WORK=/ntverify bash /repo/image/verify.sh $W/bad > $W/out.txt 2>&1
rc=$?
sed -e 's/\x1b\[[0-9;]*m//g' $W/out.txt > $W/plain.txt

echo
echo "==> did each break get caught?"
catches() {
  if grep -q "FAIL.*$1" $W/plain.txt; then ok "caught: $2"; else no "MISSED: $2"; fi
}
catches "ANDROID!"                     "corrupted boot image header"
catches "vbmeta flags"                 "AVB verification left enabled"
catches "set-active"                   "flash.sh no longer resets the retry counter"
catches "network profile"              "leaked wifi credential"
catches "DEBUG image"                  "debug-image marker"
catches "real password hash"           "a real password in the image"
# Matched on the shape of the message, not a count: the check used to say
# "expected 9 plugins" and now derives the number from the repo.
catches "plugins, image has"           "a missing shell plugin"
# The full message is "not enabled in either tree: <target>.wants/<name>" and
# <target> is `system/sysinit.target`, not `sysinit.target`. A pattern missing
# that `system/` matches nothing, which reads as "the verifier is blind" about
# a check that is working -- [[empty-grep-is-not-absence]], costing one run.
catches "not enabled in either tree: system/sysinit.target.wants/moarchy-grow-rootfs" \
        "a disabled first-boot unit"
catches "share one pacman master key"  "a pacman keyring shipped in the image"
catches "plain-HTTP Server line"       "a plain-HTTP Arch Linux ARM mirror"
catches "LLMNR or mDNS re-enabled"     "an mDNS responder turned back on"
catches "USB dev link is in this image" "the USB dev link in a release image"
catches "not exactly the check, first-PIN and state rule" "a widened lock-screen sudo rule"
catches "su is setuid"                 "su setuid again"
catches "system-auth checks a password with pam_unix" "system-auth back on pam_unix"
catches "every polkit prompt fails"     "polkit's agent helper unable to write the count"
catches "two lockers"                   "upstream's omarchy-lock-password planted"
catches "other sudoers files name moarchy-pin: /etc/sudoers.d/99-planted" \
                                        "a second sudoers file granting moarchy-pin set"

echo
if [ $rc -ne 0 ]; then ok "verify.sh exited non-zero ($rc)"; else no "verify.sh exited 0 on a broken image"; fi
echo
if [ $FAIL = 0 ]; then
  printf '  \033[32mthe verifier detects every planted defect\033[0m\n'
else
  printf '  \033[31mthe verifier is blind to something\033[0m\n'
fi
exit $FAIL
