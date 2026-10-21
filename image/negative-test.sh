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
# 19. a dev image's passwordless sudo, in a release image
printf 'moarchy ALL=(ALL) NOPASSWD: ALL\n' > $W/r/etc/sudoers.d/10-moarchy
chmod 440 $W/r/etc/sudoers.d/10-moarchy
# 20. the tile and keypad grants widened by one more command. Appended to the
#     rule line, for the same reason as 13.
sed -i '/NOPASSWD/s|$|, /usr/bin/nmcli|' $W/r/etc/sudoers.d/30-moarchy-grants
# 21. passwordless sudo in the package's own /etc/sudoers
printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' >> $W/r/etc/sudoers
# 23. a sudoers file whose name, split at its space, is two files the image
#     ships
printf 'moarchy ALL=(ALL) NOPASSWD: ALL\n' > "$W/r/etc/sudoers.d/20-moarchy-pin 30-moarchy-grants"
# 24. nothing to end Settings' timed passwordless sudo at boot
rm -f $W/r/usr/lib/tmpfiles.d/omarchy-nopasswd-sudo.conf
# 22. a polkit rule that installs store apps with no PIN
mkdir -p $W/r/etc/polkit-1/rules.d
printf 'polkit.addRule(function (a, s) { if (a.id == "org.moarchy.store.manage") return polkit.Result.YES; });\n' \
  > $W/r/etc/polkit-1/rules.d/49-planted.rules
# 25. a packaged-looking polkit rule giving wheel everything
printf 'polkit.addRule(function (a, s) { if (s.isInGroup("wheel")) return polkit.Result.YES; });\n' \
  > $W/r/usr/share/polkit-1/rules.d/49-wheel.rules
# 26. the user in the group empower.rules gives everything to
sed -i 's/^empower:x:\([0-9]*\):$/empower:x:\1:moarchy/' $W/r/etc/group
# 27. pkexec with no PIN, in its own policy
sed -i '/action id="org.freedesktop.policykit.exec"/,/<\/action>/s|<allow_active>auth_admin</allow_active>|<allow_active>yes</allow_active>|' \
  $W/r/usr/share/polkit-1/actions/org.freedesktop.policykit.policy
# 28. a rule in another directory polkitd reads
mkdir -p $W/r/usr/local/share/polkit-1/rules.d
printf 'polkit.addRule(function (a, s) { return polkit.Result.YES; });\n' \
  > $W/r/usr/local/share/polkit-1/rules.d/49-local.rules
# 29. an action that has pkexec run a shell as root with no PIN
cat > $W/r/usr/share/polkit-1/actions/org.example.planted.policy <<'POLICY'
<?xml version="1.0" encoding="UTF-8"?>
<policyconfig>
  <action id="org.example.planted.shell">
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/bin/bash</annotate>
  </action>
</policyconfig>
POLICY
# 30. a rule written to read as a comment: sudo takes #-1 for a user ID
printf '#-1,%%wheel ALL=(ALL) NOPASSWD: ALL\n' >> $W/r/etc/sudoers.d/00-moarchy-wheel
# 31. a sudoers file whose name ends in a newline
printf 'moarchy ALL=(ALL) NOPASSWD: ALL\n' > "$W/r/etc/sudoers.d/00-moarchy-wheel"$'\n'
# 32. a no-PIN target's directory writable by its group
chmod g+w $W/r/usr/lib/moarchy/bin
# 33. sudo.conf pointing sudo at another policy file
printf 'Plugin sudoers_policy sudoers.so sudoers_file=/tmp/sudoers\n' >> $W/r/etc/sudo.conf
# 34. upstream's DNS rule widened, and its time zone rule left readable
sed -i '/NOPASSWD/s|$|, /usr/bin/omarchy-dns Custom|' $W/r/etc/sudoers.d/omarchy-dns
chmod 444 $W/r/etc/sudoers.d/omarchy-tzupdate
# 35. the store with no PIN, in its own policy
sed -i 's|<allow_active>auth_self_keep</allow_active>|<allow_active>yes</allow_active>|' \
  $W/r/usr/share/polkit-1/actions/org.moarchy.Store.policy
# 36. an account whose own group is empower
printf 'eve:x:1500:%s::/:/usr/bin/nologin\n' "$(awk -F: '$1 == "empower" { print $3 }' $W/r/etc/group)" >> $W/r/etc/passwd
# 37. a tmpfiles rule writing a polkit rule at boot
printf 'f /run/polkit-1/rules.d/00-x.rules 0644 root root - polkit.addRule(function () { return "yes"; });\n' \
  > $W/r/usr/lib/tmpfiles.d/zz-polkit.conf
# 38. the same through a specifier, from another directory tmpfiles reads
mkdir -p $W/r/usr/local/lib/tmpfiles.d
printf 'f %%t/polkit-1/rules.d/00-y.rules 0644 root root - polkit.addRule(function () { return "yes"; });\n' \
  > $W/r/usr/local/lib/tmpfiles.d/zz-specifier.conf
# 39. a sudoers file that only exists once tmpfiles has run
printf 'f /etc/sudoers.d/99-x 0440 root root - moarchy ALL=(ALL) NOPASSWD: ALL\n' > $W/r/etc/tmpfiles.d/zz-sudo.conf
# 40. the user put in empower at boot
printf 'm moarchy empower\n' > $W/r/usr/lib/sysusers.d/zz-empower.conf
# 41. the user put in empower through systemd's userdb
mkdir -p $W/r/usr/lib/userdb
: > "$W/r/usr/lib/userdb/moarchy:empower.membership"
# 42. sudo's rules from another source
printf 'sudoers: files\n' >> $W/r/etc/nsswitch.conf
# 43. network settings with no PIN again
rm -f $W/r/usr/share/polkit-1/rules.d/49-moarchy-networkmanager.rules
# 44. a sudoers file at boot, its path spelled with an escape
printf 'f /etc/sud\\x6fers.d/99-z 0440 root root - moarchy ALL=(ALL) NOPASSWD: ALL\n' > $W/r/usr/lib/tmpfiles.d/zz-escape.conf
# 45. one line's link carrying the next one's file into sudoers.d
printf 'L /etc/zz-x - - - - /etc/sudoers.d\nf /etc/zz-x/99-w 0440 root root - moarchy ALL=(ALL) NOPASSWD: ALL\n' \
  > $W/r/usr/lib/tmpfiles.d/zz-link.conf
# 46. upstream's boot cleanup of timed passwordless sudo masked from /etc
: > $W/r/etc/tmpfiles.d/omarchy-nopasswd-sudo.conf
# 47. a packaged tmpfiles file replaced by a link to /dev/null
ln -sf /dev/null $W/r/usr/lib/tmpfiles.d/sudo.conf
# 48. root code from the user's home at boot, through a path that names nothing
printf 'f /etc/ld.so.preload 0644 root root - /home/moarchy/.cache/x.so\n' > $W/r/usr/lib/tmpfiles.d/zz-preload.conf
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
catches "sudoers files this image does not ship:.*/etc/sudoers.d/10-moarchy" \
                                        "a dev image's passwordless sudo in a release image"
catches "sudoers 30-moarchy-grants is not exactly its rules" "a widened tile and keypad grant"
catches "/etc/sudoers is not the sudo package's own rules" "passwordless sudo in /etc/sudoers"
catches "sudoers files this image does not ship:.*/etc/sudoers.d/20-moarchy-pin.*30-moarchy-grants" \
                                        "a sudoers file named for two the image ships"
catches "nothing removes Settings' timed passwordless sudo at boot" "no boot cleanup for timed passwordless sudo"
catches "polkit rules this image does not ship: /etc/polkit-1/rules.d/49-planted.rules" \
                                        "a polkit rule granting the store with no PIN"
catches "polkit rules differ from the reviewed set:.*49-wheel.rules" "a new polkit rule giving wheel everything"
catches "the empower group has members.*group empower:moarchy" "the user in the empower group"
catches "pkexec's own policy is not auth_admin: auth_admin yes" "pkexec with no PIN"
catches "polkit rules this image does not ship:.*/usr/local/share/polkit-1/rules.d/49-local.rules" \
                                        "a polkit rule in /usr/local/share"
catches "pkexec runs these as root with no PIN: org.example.planted.shell" "a pkexec action with no PIN"
catches "polkit actions allowed without asking differ from image/polkit-yes-actions:.*> org.example.planted.shell" \
                                        "a new action allowed without asking"
catches "sudoers 00-moarchy-wheel is not exactly its rules" "a rule hidden as a #-1 comment"
catches "sudoers files this image does not ship:.*/etc/sudoers.d/00-moarchy-wheel.n'" "a sudoers file named with a newline"
catches "a no-PIN rule runs something others can change:.* /usr/lib/moarchy/bin" "a no-PIN target's directory others can write"
catches "sudo.conf is not the sudo package's own" "sudo.conf naming another policy file"
catches "sudoers omarchy-dns is not exactly its rules" "a widened DNS rule"
catches "sudoers omarchy-tzupdate is 444" "a sudoers file with the wrong mode"
catches "the store's own policy is not auth_self_keep" "the store with no PIN in its own policy"
catches "the empower group has members.*user eve" "an account whose own group is empower"
catches "boot-time writers differ from image/boot-writers-reviewed:.*> [0-9a-f]*  tmpfiles.d/zz-polkit.conf" "a polkit rule written at boot"
catches "override or replace the packages' own:.*/usr/local/lib/tmpfiles.d/zz-specifier.conf" \
                                        "a polkit rule written at boot from /usr/local/lib"
catches "override or replace the packages' own:.*/etc/tmpfiles.d/zz-sudo.conf" "a sudoers file written at boot from /etc"
catches "boot-time writers differ from image/boot-writers-reviewed:.*> [0-9a-f]*  sysusers.d/zz-empower.conf" "the user put in empower at boot"
catches "boot-time writers differ from image/boot-writers-reviewed:.*> [0-9a-f]*  tmpfiles.d/zz-escape.conf" \
                                        "a sudoers file at boot spelled with an escape"
catches "boot-time writers differ from image/boot-writers-reviewed:.*> [0-9a-f]*  tmpfiles.d/zz-link.conf" "a link carrying a file into sudoers.d"
catches "override or replace the packages' own:.*/etc/tmpfiles.d/omarchy-nopasswd-sudo.conf" \
                                        "the timed sudo cleanup masked from /etc"
catches "override or replace the packages' own:.*/usr/lib/tmpfiles.d/sudo.conf" "a packaged tmpfiles file linked to /dev/null"
catches "boot-time writers differ from image/boot-writers-reviewed:.*> [0-9a-f]*  tmpfiles.d/zz-preload.conf" \
                                        "/etc/ld.so.preload written at boot"
catches "userdb records this image does not ship: /usr/lib/userdb/moarchy:empower.membership" "the user put in empower through userdb"
catches "nsswitch.conf is not the filesystem package's own" "sudo's rules from another source"
catches "polkit rules differ from the reviewed set:.*< [0-9a-f]*  49-moarchy-networkmanager.rules" \
                                        "network settings changeable with no PIN"

echo
if [ $rc -ne 0 ]; then ok "verify.sh exited non-zero ($rc)"; else no "verify.sh exited 0 on a broken image"; fi
echo
if [ $FAIL = 0 ]; then
  printf '  \033[32mthe verifier detects every planted defect\033[0m\n'
else
  printf '  \033[31mthe verifier is blind to something\033[0m\n'
fi
exit $FAIL
