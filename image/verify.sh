#!/bin/bash
# Verify a built image without a phone.
#
#   ./scripts/verify-image.sh [path/to/moarchy-sargo-<version>-<date>]
#
# Three layers, in order of how much they prove:
#
#   structure   the boot image header, the DTB, the AVB flags, the cmdline
#   contents    what pacman placed, and what the image does NOT carry
#   behaviour   the two first-boot scripts, actually run in a chroot
#
# What it cannot prove: that the bootloader accepts the boot image, that this
# kernel brings up this panel, or that the session starts on the Adreno. Those
# need hardware.
set -uo pipefail

IMG_XZ=${1:?usage: verify.sh <image.img.xz>}
WORK=${WORK:-/vwork}
FAIL=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
no()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
sec()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
chk()  { if [ "$1" = 0 ]; then ok "$2"; else no "$2"; fi; }

# Which artifact is this? Inferred from the name rather than passed in, so
# `verify-image.sh <thing>` keeps working without a flag nobody would
# remember. A backend names its output moarchy-<device>-... (image/build.sh
# NAME), which is the one piece of structure every backend shares.
#
# DEVICE in the environment wins, and that is not a convenience flag.
# image/negative-test.sh deliberately hands this a file called `bad.img` -- it
# takes a good image, breaks five specific things and asserts that each one is
# caught. Inference alone would have refused that file before running a single
# check, and the suite whose entire job is proving the checks can FAIL would
# itself have failed for a reason that has nothing to do with the image.
_base=$(basename "$IMG_XZ")
case "${DEVICE:-$_base}" in
  sargo|moarchy-sargo-*)         DEVICE=sargo;     BACKEND=android-bootimg ;;
  *) printf "  \033[31mFAIL\033[0m cannot tell what device %s is for; set DEVICE=\n" "$_base"; exit 1 ;;
esac
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_here/verify/$BACKEND.sh"
# The repo list comes from the same manifest image/configure.sh writes from, so
# this file cannot check for a repo the image was never told to carry -- which
# is how [moarchy-apps] went missing from every image while this suite passed.
. "$_here/../scripts/manifest.sh"
_repos=$(manifest_repos) || _repos=""
for _hook in verify_artifact verify_grow; do
  declare -F "$_hook" >/dev/null || { printf "  \033[31mFAIL\033[0m verify/%s.sh defines no %s\n" "$BACKEND" "$_hook"; exit 1; }
done
# verify_rootfs is OPTIONAL, unlike the two above: it is for facts that are
# true of one device's rootfs and meaningless for another's, and a backend with
# none of those should not have to define an empty function to say so.
printf "\n  device %s, backend %s\n" "$DEVICE" "$BACKEND"

rm -rf "$WORK"; mkdir -p "$WORK"

# Unpack the artifact and assert everything only THIS artifact shape can be
# asked about: a GPT and an SPL, or a boot header and a vbmeta. Leaves a
# mountable filesystem at $WORK/root.img for the shared checks below.
verify_artifact

# ---------------------------------------------------------------------------
sec "rootfs contents"
R="$WORK/root"
mkdir -p "$R"
# Read-write on purpose: root.img is a copy carved out of the image, so the
# behavioural section below can actually run the first-boot scripts in it. The
# published .img.xz is untouched.
mount -o loop "$WORK/root.img" "$R" 2>/dev/null || {
  no "could not mount the rootfs"; exit 1; }

have() { [ -e "$R$1" ] && ok "$1" || no "$1 missing"; }
have /usr/bin/Hyprland
have /usr/bin/quickshell
have /usr/bin/moarchy-keyboard
have /usr/lib/moarchy/bin/moarchy-selftest
have /etc/profile.d/zz-moarchy.sh
have /etc/profile.d/omarchy.sh
have /etc/fonts/conf.d/50-moarchy-weight.conf
have /etc/systemd/logind.conf.d/10-power-key.conf
have /usr/share/moarchy/config/hypr/hyprland.lua
have /usr/share/moarchy/device/hypr/device.lua
have /usr/share/omarchy/config/omarchy/shell.json
have /usr/share/fonts/omarchy/omarchy.ttf
have /usr/share/applications/org.moarchy.Device.plugin.desktop
# A dozen runtime omarchy-* scripts source out of upstream's install/ tree.
have /usr/share/omarchy/install/helpers/browser-policy.sh
have /usr/share/omarchy/shell/shell.qml
# The camera app, and the package it needs that nothing declares -- without
# xdg-user-dirs every photo is captured and silently discarded.
have /usr/bin/megapixels
# The AUR build path. yay's query side works with none of this present, so the
# failure is not that Settings > Packages > Install from AUR does nothing: it
# lists all 119,015 packages, lets you choose one, and then stops at
# `==> ERROR: Cannot find the fakeroot binary.` -- a missing toolchain wearing
# the costume of a dead package. fakeroot and make are the two names `base`
# does not carry that makepkg cannot start without; moarchy-meta pulls the
# other eight beside them.
have /usr/bin/fakeroot
have /usr/bin/make
# Mobile data (docs/devices.md D33). The mode is the check and the file is the
# easy half: NetworkManager refuses a keyfile that the group or the world can
# read, says so once in a journal nobody is tailing, and then behaves exactly
# like a phone with no profile at all -- a SIM in the tray, full bars, and no
# data. 0644 is what the first install of this file shipped.
_md=/usr/lib/NetworkManager/system-connections/moarchy-mobile-data.nmconnection
if [ ! -e "$R$_md" ]; then
  no "$_md missing -- a SIM in this phone would get no data"
elif [ "$(stat -c %a "$R$_md")" = 600 ]; then
  ok "mobile-data profile ships 0600 (NetworkManager loads it)"
else
  no "mobile-data profile is $(stat -c %a "$R$_md"), not 600 -- NetworkManager refuses it"
fi
# Provenance: an image that answers "no commit" cannot be rebuilt or bisected.
if [ -f "$R/usr/share/moarchy/build-info" ]; then
  . "$R/usr/share/moarchy/build-info"
  [ "${dirty:-1}" = 0 ] && ok "built from commit ${commit:0:12}, clean tree" \
                        || no "built from a DIRTY tree (commit ${commit:0:12}) -- corresponds to no commit"
else
  no "no build-info in the image -- it cannot say what commit it is"
fi
have /usr/share/pacman/keyrings/moarchy.gpg
# No keyring in the image. One built in carries a master secret key, and every
# phone flashed from the image would share it: anyone holding the image could
# sign a key all of those phones then trust. moarchy-pacman-init makes each
# phone its own on first boot; the behaviour section runs it and checks the
# moarchy key comes out trusted.
if [ -e "$R/etc/pacman.d/gnupg" ]; then
  no "the image ships /etc/pacman.d/gnupg -- every phone flashed from it would share one pacman master key"
else
  ok "no pacman keyring in the image (each phone generates its own)"
fi
# The mark says "this phone generated its keyring"; shipped, it would stop
# moarchy.install from replacing a keyring that came built into an image.
[ ! -e "$R/var/lib/moarchy/pacman-keyring-generated" ] \
  && ok "no keyring-generated mark in the image" \
  || no "the image ships /var/lib/moarchy/pacman-keyring-generated -- an image-built keyring would never be replaced"
# And no secret key material anywhere else, whatever put it there.
_sk=$(find "$R" -xdev \( -name private-keys-v1.d -o -name secring.gpg \) 2>/dev/null | sed "s|^$R||")
[ -z "$_sk" ] && ok "no GnuPG secret key material in the rootfs" \
              || no "GnuPG secret key material in the image: $(echo $_sk)"
have /usr/share/libalpm/hooks/50-moarchy-shell-reload.hook
# The update path, checked for every repo the manifest names rather than for
# [moarchy] alone. Without a stanza a phone can only be upgraded by reflashing,
# which is what the repo exists to stop -- and for [moarchy-apps] it is worse
# than that: the store lists its packages, so a missing stanza is an Install
# button that fails on a phone whose owner did nothing wrong.
#
# Looped rather than repeated, because a hardcoded name here is exactly the bug
# this section is checking for on the other side.
# An empty list here is a failure, not zero work: a `for` over nothing prints
# nothing and passes, which is the exact shape of the bug this section exists
# to catch. negative-test.sh is the other half of that lesson.
[ -n "$_repos" ] || no "could not read any repo from manifest.toml -- the stanza checks did not run"
for _sec in $_repos; do
  _name=$(manifest_get "$_sec" name) || continue
  if grep -q "^\[$_name\]" "$R/etc/pacman.conf" 2>/dev/null; then
    ok "pacman.conf carries [$_name] ($(grep -A2 "^\[$_name\]" "$R/etc/pacman.conf" | sed -n 's/^SigLevel = //p'))"
  else
    no "no [$_name] repo in pacman.conf -- nothing from it can be installed or updated"
  fi
done
# Package signatures are what HTTPS cannot replace: required globally, and not
# weakened for the Arch Linux ARM repos, whose packages install as root.
_gsig=$(pacman-conf --config "$R/etc/pacman.conf" SigLevel 2>/dev/null | tr '\n' ' ')
_weak=""
for _r in core extra alarm aur; do
  _rsig=$(pacman-conf --config "$R/etc/pacman.conf" --repo "$_r" SigLevel 2>/dev/null | tr '\n' ' ')
  case "$_rsig" in *PackageNever*|*PackageOptional*|*PackageTrustAll*) _weak="$_weak $_r" ;; esac
done
case "$_gsig" in
  *PackageRequired*) [ -z "$_weak" ] && ok "package signatures required (global: $_gsig)" \
                       || no "package signatures weakened for:$_weak" ;;
  *) no "package signatures not required globally (SigLevel: ${_gsig:-unreadable})" ;;
esac
# ALARM's databases are unsigned, so the transport is what keeps them honest:
# every mirror HTTPS, and at least one of them.
_ml="$R/etc/pacman.d/mirrorlist"
_plain=$(grep -cE '^\s*Server\s*=\s*http://' "$_ml" 2>/dev/null)
_tls=$(grep -cE '^\s*Server\s*=\s*https://' "$_ml" 2>/dev/null)
if [ "${_plain:-0}" -gt 0 ]; then
  no "the mirrorlist has $_plain plain-HTTP Server line(s) -- unsigned ALARM databases could be served by anyone on the network"
elif [ "${_tls:-0}" -eq 0 ]; then
  no "the mirrorlist has no Server line -- nothing from core/extra/alarm can be updated"
else
  ok "Arch Linux ARM mirrors are HTTPS only ($_tls)"
fi
# The cached database, and whether it is signed. This is the check that was
# missing while the bug it catches shipped twice.
#
# The stanza above says SigLevel = Required, which implies DatabaseRequired, and
# pacman refuses a database it cannot verify. The build's own repo is file://
# with SigLevel = Never, so the db pacstrap leaves behind has no .sig beside it
# -- and one unverifiable database fails the whole transaction, including
# `pacman -S vim` out of [extra], which has nothing to do with ours. A phone
# like that installs nothing at all until somebody runs `pacman -Sy` by hand,
# and nothing on screen says why.
#
# configure.sh refreshes against the real server to fix exactly this, and it
# failed silently for two different reasons in one evening (no DNS in the
# chroot, then no Landlock on the build host). Both were invisible here,
# because nothing looked.
[ -n "$_repos" ] || no "could not read any repo from manifest.toml -- the database checks did not run"
for _sec in $_repos; do
  _name=$(manifest_get "$_sec" name) || continue
  _db="$R/var/lib/pacman/sync/$_name.db"
  if [ ! -f "$_db" ]; then
    no "no cached $_name.db -- the first install from it must sync first"
  elif [ -f "$_db.sig" ]; then
    ok "cached $_name.db is signed ($(stat -c %s "$_db.sig" 2>/dev/null) byte .sig) -- installs work on first boot"
  else
    no "cached $_name.db has NO .sig -- SigLevel = Required will refuse it, and every install dies until 'pacman -Sy'"
  fi
done
have /usr/bin/xdg-user-dirs-update
# Without /var/log/journal, a boot that fails leaves nothing to read next time.
have /var/log/journal
# The image shipped once with a dangling /etc/resolv.conf and resolved disabled:
# raw IPs routed, no name resolved, and pacman could not reach a mirror. Check
# both halves, because either alone looks fine.
if [ -e "$R/etc/systemd/system/dbus-org.freedesktop.resolve1.service" ] ||
   [ -L "$R/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" ] ||
   [ -e "$R/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" ]; then
  ok "systemd-resolved enabled (so /etc/resolv.conf resolves)"
else
  no "systemd-resolved NOT enabled -- /etc/resolv.conf will dangle and no name will resolve"
fi
have /etc/systemd/journald.conf.d/10-moarchy.conf

# Checked here, in the image AS SHIPPED, not only after the behaviour section
# has run moarchy-firstboot. That is exactly how this was missed: the suite ran
# firstboot, then asserted the drop-in existed, and passed -- while the image
# itself had no autologin, so the first boot on hardware stopped at a login
# prompt that a locked password cannot answer.
if grep -q -- '--autologin' "$R/etc/systemd/system/getty@tty1.service.d/autologin.conf" 2>/dev/null; then
  ok "tty1 autologin is in the image itself (not deferred to first boot)"
else
  no "no autologin drop-in in the shipped image -- first boot stops at a login prompt"
fi

# Counted from the repo rather than hardcoded. The literal 9 here failed the
# build that added a tenth plugin, which is a check reporting on itself.
# One tree since docs/structure.md B6: the apps live in the same directory as
# the shell's own plugins and ship in the same package, so one count covers
# both. It used to be two, because a check that only counted
# default/omarchy/plugins would pass an image that had the phone UI and no
# calculator.
want=$(ls -1d /repo/default/omarchy/plugins/*/ 2>/dev/null | wc -l | tr -d ' ')
n=$(ls -1d "$R"/usr/share/moarchy/plugins/*/ 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = "$want" ] && ok "$n shell plugins (all of the repo's)" \
                   || no "repo has $want plugins, image has $n"

# The default apps the plugins replaced must not sneak back in. Checking the
# desktop entry, not the package name: that is what the app drawer lists.
for e in org.gnome.clocks org.kde.kalk org.kde.calindori org.gnome.Contacts \
         dev.tchx84.Portfolio org.kde.kweather org.gnome.TextEditor \
         org.gnome.Calls sm.puri.Chatty org.gnome.Geary; do
  if [ -e "$R/usr/share/applications/${e}.desktop" ]; then
    no "$e.desktop is still in the image -- the plugin replaced it"
  else
    ok "$e is not a default app"
  fi
done
# And the ones that left with no plugin in their place. ChiPass was never in
# the list at all: geary pulled it in as the org.freedesktop.secrets provider
# whenever gnome-keyring came after geary in moarchy-meta's depends, which is
# exactly the kind of reordering nobody would think to check.
for e in org.gnome.Loupe org.gnome.Papers com.github.johnfactotum.Foliate \
         org.gnome.World.Secrets org.chipass.ChiPass; do
  if [ -e "$R/usr/share/applications/${e}.desktop" ]; then
    no "$e.desktop is in the image -- it left the default set"
  else
    ok "$e is not a default app"
  fi
done
# Calls and Chatty were daemons as well as windows, and the daemons are the
# half that does harm beside the plugins: Chatty deletes every text it takes
# off the modem, so Messages would never see one. The units that started them
# under the compositor were ours, so they are checked by name rather than by package.
for u in calls-daemon.service sm.puri.Chatty-daemon.service; do
  if [ -e "$R/etc/systemd/user/$u" ] || [ -L "$R/usr/lib/systemd/user/default.target.wants/$u" ]; then
    no "$u is still installed or enabled -- Phone and Messages replaced it"
  else
    ok "$u is not in the image"
  fi
done
# And the plugins that replaced them must be launchable, not merely present
# as QML the shell never enables.
for e in org.moarchy.Calculator org.moarchy.Calendar org.moarchy.Clock \
         org.moarchy.Contacts org.moarchy.Files org.moarchy.Editor \
         org.moarchy.Phone org.moarchy.Messages org.moarchy.Mail; do
  have /usr/share/applications/${e}.plugin.desktop
done
# Mail is a window over a command. Every word it says to a server is a run of
# /usr/bin/moarchy-mail, a Python script, so a package that shipped the plugin
# without it -- or an image without python -- is a sign-in screen that can
# never sign in, and nothing above would notice. The mailto: entry is what a
# tapped address opens now that Geary is not there to claim it.
have /usr/bin/moarchy-mail
[ -x "$R/usr/bin/moarchy-mail" ] && ok "moarchy-mail is executable" \
                                 || no "moarchy-mail is not executable"
have /usr/bin/python3
have /usr/share/applications/org.moarchy.Mail.compose.desktop
grep -q '^MimeType=x-scheme-handler/mailto;' "$R/usr/share/applications/org.moarchy.Mail.compose.desktop" \
  && ok "Mail handles mailto: links" \
  || no "nothing in the image handles mailto: links"

# The editor is the one plugin that is also a default for something outside
# the app drawer, and both of those halves are files the package has to lay down:
# the hidden entry xdg-open is pointed at, and the command $EDITOR runs. A
# package that shipped the plugin without them would pass every line above
# and leave `git commit` with an editor that is not there.
have /usr/share/applications/org.moarchy.Editor.open.desktop
have /usr/bin/moarchy-editor
[ -x "$R/usr/bin/moarchy-editor" ] && ok "moarchy-editor is executable" \
                                   || no "moarchy-editor is not executable"
grep -q '^FALLBACK="moarchy-editor"' "$R/usr/lib/moarchy/bin/omarchy-launch-editor" \
  && ok "omarchy-launch-editor falls back to moarchy-editor" \
  || no "omarchy-launch-editor falls back to an editor the image does not ship"
have /usr/share/moarchy/plugins/moarchy.calculator/Calculator.qml
have /usr/share/moarchy/plugins/moarchy.calculator/ui/qmldir
grep -q '"id": "moarchy.calculator"' "$R/usr/share/omarchy/config/omarchy/shell.json" \
  && ok "packaged shell.json enables moarchy.calculator" \
  || no "shell.json does not enable the calculator plugin"
# Every plugin must be in that list -- the apps and the phone UI's own
# surfaces alike, in one loop since docs/structure.md N4 put them in one
# namespace. A directory that ships in the package and is not named in
# shell.json is a surface that never loads, and nothing about the image says
# so: the count above passes, the files are all there, and the phone simply
# does without it. Third-party ids are only enabled by being listed
# (PluginRegistry.isEnabled); upstream's first-party ones are enabled by
# default and ours never are.
#
# And a plugin that ships a .desktop must have a tile a person can reach --
# that entry is what makes it an app rather than a surface, so the test keys
# on the entry and not on the id, which no longer says which is which. A tile
# is an entry that toggles the plugin and is not hidden: the editor's and
# Mail's second entries summon, and do not count.
_shelljson="$R/usr/share/omarchy/config/omarchy/shell.json"
for _pdir in /repo/default/omarchy/plugins/*/; do
  _pid=$(basename "$_pdir")
  # moarchy.common has no manifest, so the registry skips it and so does this.
  [ -f "$_pdir/manifest.json" ] || continue
  grep -q "\"id\": \"$_pid\"" "$_shelljson" \
    && ok "shell.json enables $_pid" \
    || no "shell.json does not enable $_pid -- the plugin ships and never loads"
  ls "$_pdir"*.desktop >/dev/null 2>&1 || continue
  _tile=$(grep -lx "Exec=omarchy-shell shell toggle $_pid" "$R"/usr/share/applications/*.desktop 2>/dev/null \
            | xargs -r grep -Lx 'NoDisplay=true' 2>/dev/null | head -1)
  [ -n "$_tile" ] && ok "$_pid has a appDrawer tile ($(basename "$_tile"))" \
                  || no "$_pid has no appDrawer tile -- a default app nobody can open"
done
unset _pdir _pid _shelljson _tile

hy=$(grep -rl 'import Quickshell.Hyprland' "$R/usr/share/omarchy/shell" --include=*.qml 2>/dev/null | wc -l)
i3=$(grep -rl 'import Quickshell.I3'       "$R/usr/share/omarchy/shell" --include=*.qml 2>/dev/null | wc -l)
# The Sway port is gone (omarchy-config's A2, inverted): the shell runs on
# Hyprland, and an I3 import is a module that can never connect.
[ "$i3" -eq 0 ] && ok "0 QML files left on Quickshell.I3" || no "$i3 files still import Quickshell.I3"
[ "$hy" -gt 0 ] && ok "$hy QML files on Quickshell.Hyprland" || no "no Hyprland imports -- the shell the tree ships is not in the image"

grep -q '"id": "moarchy.bar"' "$R/usr/share/omarchy/config/omarchy/shell.json" \
  && ok "packaged shell.json selects moarchy.bar" || no "shell.json does not select moarchy.bar"

# The Hyprland config is passed with -c. The session lives in zz-moarchy.sh,
# together with the PATH it needs -- see the comment at the top of that file
# for why it is not two files.
sess_cfg=$(grep -oE '/usr/share/moarchy/config/hypr/hyprland.lua' "$R/etc/profile.d/zz-moarchy.sh" | head -1)
[ -n "$sess_cfg" ] && ok "the session names the packaged Hyprland config" || no "zz-moarchy.sh does not exec Hyprland -c"
# And nothing else may exec a session: a second profile.d file that execs would
# reintroduce the ordering bug, sorted earlier or later.
extra=$(grep -lE 'exec (Hyprland|sway)' "$R"/etc/profile.d/*.sh 2>/dev/null | grep -cv 'zz-moarchy.sh')
[ "$extra" = 0 ] && ok "only one profile.d file execs a session" \
                 || no "$extra other profile.d files exec a session -- ordering hazard"
# hyprland.lua requires its siblings by package.path rather than including them
# by absolute path, so the check is that each required file is there.
miss=0
while read -r f; do
  [ -e "$R/usr/share/moarchy/config/hypr/$f.lua" ] || { no "hypr require missing: $f.lua"; miss=1; }
done < <(sed -n 's/^ *require("hypr\.\([a-z]*\)").*/\1/p' "$R/usr/share/moarchy/config/hypr/hyprland.lua")
[ $miss = 0 ] && ok "every hypr require resolves"

sec "units"
# A unit is enabled if the .wants symlink is under EITHER tree: /etc is what
# `systemctl enable` writes, /usr/lib is how a package enables one by default.
# Checking only /etc reported two working units as broken.
# -L as well as -e, and that is the whole point: `systemctl enable` writes an
# ABSOLUTE symlink (/usr/lib/systemd/system/...), which resolves against the
# container's root rather than the mounted image, so -e follows it into nothing
# and reports a correctly enabled unit as missing. The package-shipped links are
# relative and resolve fine, which is what made the false negative look like a
# real difference between the two trees.
unit() {
  local target=$1 name=$2
  if [ -e "$R/etc/systemd/$target.wants/$name" ] || [ -L "$R/etc/systemd/$target.wants/$name" ]; then
    ok "enabled (/etc): $name"
  elif [ -e "$R/usr/lib/systemd/$target.wants/$name" ] || [ -L "$R/usr/lib/systemd/$target.wants/$name" ]; then
    ok "enabled (/usr/lib): $name"
  else
    no "not enabled in either tree: $target.wants/$name"
  fi
}
unit system/multi-user.target moarchy-firstboot.service
unit system/multi-user.target moarchy-led-perms.service
unit system/multi-user.target moarchy-pacman-init.service
unit system/sysinit.target    moarchy-grow-rootfs.service
unit user/default.target      moarchy-user-setup.service
# sysinit.target, which is where systemd-timesyncd.service's own [Install]
# section puts it -- not multi-user like the moarchy units above.
unit system/sysinit.target    systemd-timesyncd.service

# The clock (I10). An image with no NTP client enabled has no time source at
# all: Arch enables none by default, this systemd ships no
# /usr/lib/clock-epoch, and the PMIC RTC reads 1970 and no longer sets the
# system clock (linux-moarchy-sdm670's RTC_HCTOSYS note). Far enough
# out and every TLS handshake fails certificate validation, which is how it
# actually presented -- as `yay` reporting an expired certificate for the AUR on
# a phone flashed the same day.
if [ -f "$R/var/lib/systemd/timesync/clock" ]; then
  ok "clock floor seeded (/var/lib/systemd/timesync/clock)"
else
  no "no clock floor -- an offline first boot gets whatever the RTC says"
fi

sec "credentials -- what must NOT be here"
u=$(grep -c '^moarchy:' "$R/etc/passwd" 2>/dev/null)
[ "$u" = 1 ] && ok "user 'moarchy' exists" || no "user 'moarchy' not in /etc/passwd"
# A locked password is ! or * in the hash field; anything else is a real hash.
for acct in moarchy root; do
  h=$(awk -F: -v a="$acct" '$1==a{print $2}' "$R/etc/shadow" 2>/dev/null)
  case "$h" in
    '!'*|'*'*|'!') ok "$acct password is locked ($h)" ;;
    '')            no "$acct has an EMPTY password" ;;
    *)             no "$acct has a real password hash -- the image ships a credential" ;;
  esac
done

# The lock screen (docs/structure.md I8). The PIN is chosen on the phone at
# first boot, so the image carries none -- the loop above is still the check
# for that. What it must carry is everything that makes the PIN mean something.
#
# One door to the PIN (bin/moarchy-harden-auth). Any other way to test it, at
# yescrypt's speed and uncounted, is root in about an hour, because the PIN is
# also the sudo password.
# What it must be, read out of the script that makes it so, so the two cannot
# drift apart.
_ha="$R/usr/lib/moarchy/bin/moarchy-harden-auth"
_line=$(sed -n "s/^LINE='\(.*\)'$/\1/p" "$_ha" 2>/dev/null)
_checkers=$(sed -n "s/^CHECKERS='\(.*\)'$/\1/p" "$_ha" 2>/dev/null)
if [ -z "$_line" ] || [ -z "$_checkers" ]; then
  no "moarchy-harden-auth is missing, or no longer says LINE= and CHECKERS= -- nothing here can check the one door"
else
  _suid=$(for _b in $_checkers; do
    [ -n "$(find "$R/usr/bin/$_b" -perm /6000 2>/dev/null)" ] && printf '%s ' "$_b"; done)
  _suid=${_suid% }
  [ -z "$_suid" ] && ok "no setuid password checker but sudo (PIN checks are counted)" \
                  || no "$_suid is setuid -- any process can guess the PIN uncounted"
  _sa="$R/etc/pam.d/system-auth"
  grep -qxF "$_line" "$_sa" 2>/dev/null && ! grep -qE '^\s*-?auth\s.*pam_unix\.so' "$_sa" \
    && ok "system-auth checks the PIN through moarchy-pin (sudo and polkit are counted)" \
    || no "system-auth checks a password with pam_unix -- sudo can guess the PIN uncounted, in parallel"
fi
# polkit checks in a sandbox where /var/lib is read-only; without this every
# polkit prompt fails, because moarchy-pin cannot count the attempt.
grep -qx 'ReadWritePaths=-/var/lib/moarchy/pin' \
    "$R/usr/lib/systemd/system/polkit-agent-helper@.service.d/50-moarchy-pin.conf" 2>/dev/null &&
  grep -qx 'd /var/lib/moarchy/pin 0700 root root -' "$R/usr/lib/tmpfiles.d/moarchy-pin.conf" 2>/dev/null \
  && ok "polkit's agent helper can write the PIN's count, and boot makes its directory" \
  || no "polkit's agent helper cannot write the PIN's count -- every polkit prompt fails"
have /usr/share/libalpm/hooks/20-moarchy-harden-auth.hook
have /usr/share/libalpm/hooks/20-moarchy-harden-auth-remove.hook
have /usr/lib/systemd/system/sysinit.target.wants/moarchy-harden-auth.service
# Any PAM stack that checks a password with pam_unix itself, rather than
# through system-auth, is another door. Only those whose program cannot run
# as root for anyone else are allowed one, and only while that holds.
_doors=""
for _p in "$R"/etc/pam.d/* "$R"/usr/lib/pam.d/*; do
  [ -f "$_p" ] && grep -qE '^\s*-?auth\s.*pam_unix\.so' "$_p" || continue
  _n=${_p##*/}
  case $_n in
    su|su-l) _prog=su ;;
    chfn|chsh|vlock) _prog=$_n ;;
    *) _doors="$_doors ${_p#$R}"; continue ;;
  esac
  [ -n "$(find "$R/usr/bin/$_prog" -perm /6000 2>/dev/null)" ] && _doors="$_doors ${_p#$R}"
done
[ -z "$_doors" ] && ok "no PAM stack checks a password outside moarchy-pin" \
                 || no "a PAM stack checks a password uncounted:$_doors"
grep -qx 'NAutoVTs=0' "$R/etc/systemd/logind.conf.d/20-no-spare-consoles.conf" 2>/dev/null \
  && ok "no login prompt on a spare console" || no "logind offers a login prompt on tty2-tty6"
# Upstream's name. Its own lock plugin arms itself when this file exists, and
# two ext-session-lock clients fighting over one session is a phone neither of
# them can unlock.
[ -e "$R/etc/pam.d/omarchy-lock-password" ] \
  && no "/etc/pam.d/omarchy-lock-password exists -- upstream's lock would arm beside moarchy.lock (two lockers)" \
  || ok "no omarchy-lock-password (upstream's lock stays inert)"

# The rule that runs as root with no password. Byte for byte, because
# every way of widening it -- a wildcard after the command, a second command,
# NOPASSWD: ALL on another line -- is root for anyone holding the phone.
_sud="$R/etc/sudoers.d/20-moarchy-pin"
if [ ! -f "$_sud" ]; then
  no "/etc/sudoers.d/20-moarchy-pin missing -- the lock screen can neither check nor set a PIN"
elif printf '%%wheel ALL=(root) NOPASSWD: /usr/lib/moarchy/bin/moarchy-pin check, /usr/lib/moarchy/bin/moarchy-pin first, /usr/lib/moarchy/bin/moarchy-pin state\n' | cmp -s - "$_sud"; then
  ok "20-moarchy-pin is exactly the check, first-PIN and state rule"
else
  no "20-moarchy-pin is not exactly the check, first-PIN and state rule -- a widened rule is root without a PIN"
fi
# And no other sudoers file may name the helper: `moarchy-pin set` granted
# anywhere without a password is a new PIN, and root, for anyone.
_oth=$(grep -ls 'moarchy-pin' "$R/etc/sudoers" "$R"/etc/sudoers.d/* | grep -vxF "$_sud" | sed "s|^$R||" | tr '\n' ' ')
[ -z "$_oth" ] && ok "no other sudoers file names moarchy-pin" || no "other sudoers files name moarchy-pin: $_oth"

# Every rule sudo reads, against the ones this image means to have
# (docs/structure.md I8). A rule that runs something as root with no PIN is
# root for anyone holding an unlocked phone, so each file is held to its exact
# bytes, and a file the image does not ship fails however harmless it looks.
# Bytes rather than rules: what sudo takes for a comment is its parser's call,
# and `#-1,%wheel ...` is a rule that reads as one.
_sha() { sha256sum <"$1" | cut -d' ' -f1; }
# <name> <the repo file it is, or its sha256>
_want_sudoers() {
  local f="$R/etc/sudoers.d/$1" want=$2
  if [ ! -f "$f" ]; then no "/etc/sudoers.d/$1 missing"; return; fi
  [ -f "$want" ] && want=$(_sha "$want")
  if [ "$(_sha "$f")" = "$want" ]; then ok "sudoers $1 is exactly the file shipped"
  else no "sudoers $1 is not exactly its rules -- a widened rule is root without a PIN"; fi
  [ "$(stat -c '%a %u %g' "$f")" = "440 0 0" ] || no "sudoers $1 is $(stat -c '%a %U:%G' "$f"), not 0440 root:root"
}
_want_sudoers 00-moarchy-wheel /repo/default/sudoers/00-moarchy-wheel
_want_sudoers 30-moarchy-grants /repo/default/sudoers/30-moarchy-grants
# Upstream's, at the pinned omarchy ref.
_want_sudoers omarchy-theme-browser b2981edf2d79674071fe747c7de23233a0c82afae24054aa37efa72065544d41
_want_sudoers omarchy-dns 682b4fa259e09966045373448f4c6c2979aabba8f3605f9ffed15a44ff29a7b1
_want_sudoers omarchy-tzupdate 1165973dd928175065693584be95f6ed0ef5e2c9dfeebd9790f1f3ea94a0fe05
_known=" 00-moarchy-wheel 20-moarchy-pin 30-moarchy-grants omarchy-theme-browser omarchy-dns omarchy-tzupdate "
if [ -e "$R/usr/lib/moarchy/bin/moarchy-android-launch" ]; then
  _want_sudoers moarchy-android-launch /repo/pkgbuilds/moarchy-waydroid/moarchy-android-launch.sudoers
  _known="$_known moarchy-android-launch "
fi
# Passwordless sudo is a dev image's alone.
if [ "${DEV_IMAGE:-0}" = 1 ]; then
  _want_sudoers 10-moarchy "$(printf 'moarchy ALL=(ALL) NOPASSWD: ALL\n' | sha256sum | cut -d' ' -f1)"
  _known="$_known 10-moarchy "
fi
# By whole name, and only names made of [A-Za-z0-9_-]: sudo reads a file
# called "20-moarchy-pin 30-moarchy-grants", or one with a newline in its
# name, and no list match may take it for one it knows.
_extra=$(for f in "$R"/etc/sudoers.d/*; do [ -e "$f" ] || [ -L "$f" ] || continue
           n=${f##*/}
           if [[ ! $n =~ ^[A-Za-z0-9_-]+$ ]] || [[ $_known != *" $n "* ]]; then printf '%q ' "${f#$R}"; fi; done)
[ -z "$_extra" ] && ok "no sudoers file this image does not ship" \
                 || no "sudoers files this image does not ship: $_extra"
# The sudo package's own /etc/sudoers and sudo.conf, byte for byte (sudo
# 1.9.17.p2-6 on Arch Linux ARM). No rule there skips the PIN, secure_path
# keeps the caller's PATH out of what root runs, it reads no directory but
# sudoers.d, and sudo.conf names no other policy or file. A sudo upgrade that
# changes either fails here, to be read before these move.
[ -f "$R/etc/sudoers" ] && [ "$(_sha "$R/etc/sudoers")" = 367f88ea6741558538ed9e60ce0515d85d650f6e127a788c1f47d0a09508fcbe ] \
  && ok "/etc/sudoers is the sudo package's own" \
  || no "/etc/sudoers is not the sudo package's own rules"
[ -f "$R/etc/sudo.conf" ] && [ "$(_sha "$R/etc/sudo.conf")" = f688ac6620d09e5bf2a2adf0654cae38f3330a9220a25a529fb0eacd8d8f22f0 ] \
  && ok "sudo.conf is the sudo package's own, so sudo reads /etc/sudoers" \
  || no "sudo.conf is not the sudo package's own"
grep -qE '^[[:space:]]*sudoers[[:space:]]*:' "$R/etc/nsswitch.conf" 2>/dev/null &&
  no "nsswitch.conf gives sudo another source of rules" || ok "nsswitch.conf gives sudo no other source of rules"
# What each no-PIN rule runs, and the directories it is in: root's to write
# alone, or the rule hands root to whoever can rewrite it.
_tgt_bad=""
for t in /usr/lib/moarchy/bin/moarchy-data /usr/lib/moarchy/bin/moarchy-sim /usr/bin/omarchy-dns \
         /usr/bin/timedatectl /usr/bin/omarchy-theme-set-browser-policy /usr/lib/moarchy/bin/moarchy-android-launch; do
  [ -e "$R$t" ] || { [ "$t" = /usr/lib/moarchy/bin/moarchy-android-launch ] && continue; _tgt_bad="$_tgt_bad $t(missing)"; continue; }
  p=$t
  while [ "$p" != / ]; do
    if [ -L "$R$p" ]; then _tgt_bad="$_tgt_bad $p(link)"
    elif [ "$(stat -c %u "$R$p")" != 0 ] || [ $(( 0$(stat -c %a "$R$p") & 022 )) != 0 ]; then _tgt_bad="$_tgt_bad $p"; fi
    p=$(dirname "$p")
  done
done
[ -z "$_tgt_bad" ] && ok "every command a no-PIN rule runs is root's alone to change" \
                   || no "a no-PIN rule runs something others can change:$_tgt_bad"
# The 15-minute passwordless sudo Settings offers ends at boot as well, since
# its timer does not survive one.
grep -qx 'r! /etc/sudoers.d/99-omarchy-nopasswd-\*' "$R/usr/lib/tmpfiles.d/omarchy-nopasswd-sudo.conf" 2>/dev/null \
  && ok "boot removes a timed passwordless sudo left by a reboot" \
  || no "nothing removes Settings' timed passwordless sudo at boot -- a reboot inside it keeps it"
# polkit's rules, byte for byte the ones the packages ship: a rule can answer
# yes for anything, the store and pkexec among them, so a changed or new one is
# reviewed before it is added here. Only NetworkManager's answers yes for
# wheel (system connections, from a local session).
_polkit_want="4192b104907809623aa7ca4c58e1527da19710bae6278abe96f88d9f2d6430e9  50-default.rules
d9a62ab1ec477a4be1657769dfd194c75d1a07a4357e7717aa19ad5c07c3fc26  empower.rules
392e205d6b993b8e629c35ddd2307ad8460bd41ff893801028c2e530fe816567  org.freedesktop.GeoClue2.rules
088713232069609bfc9573bbb1d8cb723963064bb6a6957933db72d0765fe31e  org.freedesktop.NetworkManager.rules
1aa33227c8c09f21c970bb7b3db03fc10710419d7b4b2aa923762dccf38d4633  org.freedesktop.upower.rules
682272c73e766dfb6e1f45cd6e0773d57e96da4073a329c24d42d261907ba52c  systemd-networkd.rules"
_polkit_have=$(cd "$R/usr/share/polkit-1/rules.d" 2>/dev/null && find . -maxdepth 1 -name '*.rules' -printf '%P\0' | sort -z | xargs -0r sha256sum)
[ "$_polkit_have" = "$_polkit_want" ] && ok "polkit's rules are exactly the packages' own" \
  || no "polkit rules differ from the reviewed set: $(diff <(echo "$_polkit_want") <(echo "$_polkit_have") | grep '^[<>]' | tr '\n' '|')"
# polkitd also reads rules and actions from /etc, /run and /usr/local/share,
# where no package puts any.
_polkit_etc=$(for d in etc run usr/local/share; do find "$R/$d/polkit-1/rules.d" "$R/$d/polkit-1/actions" -mindepth 1 2>/dev/null; done | sed "s|^$R||" | tr '\n' ' ')
[ -z "$_polkit_etc" ] && ok "no polkit rules or actions outside /usr/share" || no "polkit rules this image does not ship: $_polkit_etc"
# An action naming a program for pkexec runs it as root with no PIN if any of
# its defaults is yes.
_polkit_exec=$(awk '/<action id=/ { id = $0; sub(/.*<action id="/, "", id); sub(/".*/, "", id); exe = yes = 0 }
  /org\.freedesktop\.policykit\.exec\.path/ { exe = 1 }
  /<allow_(any|inactive|active)>yes</ { yes = 1 }
  /<\/action>/ { if (exe && yes) print id }' "$R"/usr/share/polkit-1/actions/*.policy 2>/dev/null | tr '\n' ' ')
[ -z "$_polkit_exec" ] && ok "pkexec runs no program without asking" || no "pkexec runs these as root with no PIN: $_polkit_exec"
# Every action allowed without asking, against the reviewed list: a package
# that adds one gives every app it, with no PIN.
_polkit_yes=$(awk '/<action id=/ { id = $0; sub(/.*<action id="/, "", id); sub(/".*/, "", id); yes = 0 }
  /<allow_(any|inactive|active)>yes</ { yes = 1 }
  /<\/action>/ { if (yes) print id }' "$R"/usr/share/polkit-1/actions/*.policy 2>/dev/null | LC_ALL=C sort |
  diff "$_here/polkit-yes-actions" - | grep '^[<>]' | tr '\n' ' ')
[ -z "$_polkit_yes" ] && ok "polkit allows without asking only the reviewed actions" \
  || no "polkit actions allowed without asking differ from image/polkit-yes-actions: $_polkit_yes"
# Nor written there at boot.
_polkit_run=$(awk '!/^[ \t]*#/ && $2 ~ /^\/run\/polkit-1/ { print FILENAME }' "$R"/usr/lib/tmpfiles.d/*.conf "$R"/etc/tmpfiles.d/*.conf 2>/dev/null | sed "s|^$R||" | sort -u | tr '\n' ' ')
[ -z "$_polkit_run" ] && ok "no tmpfiles rule writes polkit's /run" || no "tmpfiles rules write polkit's /run: $_polkit_run"
# empower.rules answers yes for everything to that group, whether it is an
# account's own group or one it is listed in.
_emp_gid=$(awk -F: '$1 == "empower" { print $3 }' "$R/etc/group")
_emp=$(awk -F: -v g="$_emp_gid" 'FILENAME ~ /group$/ && $3 == g && ($1 != "empower" || $4 != "") { print "group " $1 ":" $4 }
  FILENAME ~ /passwd$/ && $4 == g { print "user " $1 }' "$R/etc/group" "$R/etc/passwd" | tr '\n' ' ')
[ -n "$_emp_gid" ] && [ -z "$_emp" ] && ok "no account is in the empower group" \
  || no "the empower group has members, and polkit lets them do anything: ${_emp:-no empower group to check}"
# And what an action allows when no rule answers.
_polkit_default() {
  awk -v id="$2" '/<action id=/ { on = index($0, "\"" id "\"") > 0 }
    on && /<allow_(any|inactive|active)>/ { gsub(/.*<allow_[a-z]*>|<\/.*/, ""); print }' "$R/usr/share/polkit-1/actions/$1" 2>/dev/null | sort -u | tr '\n' ' '
}
[ "$(_polkit_default org.freedesktop.policykit.policy org.freedesktop.policykit.exec)" = "auth_admin " ] \
  && ok "pkexec asks for the PIN" || no "pkexec's own policy is not auth_admin: $(_polkit_default org.freedesktop.policykit.policy org.freedesktop.policykit.exec)"
[ "$(_polkit_default org.moarchy.Store.policy org.moarchy.store.manage)" = "auth_self_keep " ] \
  && ok "the store asks for the PIN" || no "the store's own policy is not auth_self_keep: $(_polkit_default org.moarchy.Store.policy org.moarchy.store.manage)"
[ -f "$_sud" ] && { [ "$(stat -c '%a %u %g' "$_sud")" = "440 0 0" ] \
  && ok "20-moarchy-pin is 0440 root:root" \
  || no "20-moarchy-pin is $(stat -c '%a %U:%G' "$_sud"), not 0440 root:root -- sudo ignores it or anyone may edit it"; }
# What that rule runs. Root-owned and writable by root alone, or the rule
# hands root to whoever can rewrite the script.
_pin="$R/usr/lib/moarchy/bin/moarchy-pin"
if [ -x "$_pin" ] && [ "$(stat -c '%u %g' "$_pin")" = "0 0" ] && [ -z "$(find "$_pin" -perm /022)" ]; then
  ok "moarchy-pin is executable, root-owned and writable by root alone"
else
  no "moarchy-pin is missing, not root-owned, or writable by others -- the sudo rule would run whatever it holds"
fi
# -L too: an absolute symlink here would read as absent to -e, turning "sshd is
# enabled" into a silent pass -- the direction that matters for a published image.
_sshd_on() {
  [ -e "$R/etc/systemd/system/multi-user.target.wants/sshd.service" ] ||
    [ -L "$R/etc/systemd/system/multi-user.target.wants/sshd.service" ]
}
# The USB dev link configure.sh writes for MOARCHY_SSH_KEY: the gadget, its
# unit, sshd's binding to it, and NetworkManager's hands-off.
_usbnet="/usr/local/sbin/moarchy-usbnet
/etc/systemd/system/moarchy-usbnet.service
/etc/systemd/system/sshd.service.d/20-moarchy-usbnet.conf
/etc/ssh/sshd_config.d/20-moarchy-usbnet.conf
/etc/NetworkManager/conf.d/90-moarchy-usbnet.conf"
_ak="$R/home/moarchy/.ssh/authorized_keys"
np=$(ls -1 "$R"/etc/NetworkManager/system-connections/ 2>/dev/null | wc -l)

if [ "${DEV_IMAGE:-0}" != 1 ]; then
  [ -e "$R/etc/moarchy-debug-image" ] && no "this is a DEBUG image -- do not publish" \
                                      || ok "not a debug image"
  # An authorized_keys in a PUBLISHED image would make every phone that flashes
  # it trust one person's key. A public key is not a secret, which is why this
  # is easy to wave through and worth checking for anyway.
  [ -s "$_ak" ] && no "an ssh key is authorised in this image -- everyone who flashes it would trust it" \
                || ok "no ssh key authorised (nobody but the owner can log in)"
  # /etc only. The mobile-data profile checked further up ships in /usr/lib and
  # is not a credential -- it names no operator, no APN and no password, and
  # gets all three from the SIM at runtime. A profile HERE was put here by
  # somebody's build, and the only ones that exist are a debug image's wifi and
  # its psk.
  [ "$np" = 0 ] && ok "no preseeded network profiles in /etc" || no "$np network profile(s) baked in"
  _sshd_on && no "sshd is enabled" || ok "sshd not enabled"
  # In a published image the link's sshd drop-in would admit whoever is on the
  # far end of a cable.
  _found=""
  for _f in $_usbnet; do { [ -e "$R$_f" ] || [ -L "$R$_f" ]; } && _found="$_found $_f"; done
  [ -z "$_found" ] && ok "no USB dev link" || no "the USB dev link is in this image:$_found"
else
  # DEV_IMAGE=1: a debug image built with MOARCHY_SSH_KEY. Its whole job is the
  # way in, and that way in must be the USB cable and nothing else.
  [ -e "$R/etc/moarchy-debug-image" ] && ok "a debug image, as DEV_IMAGE=1 expects" \
                                      || no "DEV_IMAGE=1 but no debug marker -- this is not a dev image"
  if [ ! -s "$_ak" ]; then
    no "no ssh key authorised -- a dev image nobody can log in to"
  elif grep -v '^[[:space:]]*$' "$_ak" | grep -qEv '^(ssh-|ecdsa-|sk-)' || grep -qi 'PRIVATE KEY' "$_ak"; then
    no "authorized_keys holds something other than public keys"
  else
    ok "$(grep -c . "$_ak") public key(s) authorised"
  fi
  ok "$np preseeded network profile(s) (allowed in a dev image)"
  _sshd_on && ok "sshd enabled" || no "sshd not enabled -- a dev image with no way in"
  _missing=""
  for _f in $_usbnet; do [ -e "$R$_f" ] || _missing="$_missing $_f"; done
  [ -z "$_missing" ] && ok "the USB dev link is installed" || no "the USB dev link is incomplete:$_missing"
  [ -x "$R/usr/local/sbin/moarchy-usbnet" ] || no "moarchy-usbnet is not executable"
  [ -L "$R/etc/systemd/system/multi-user.target.wants/moarchy-usbnet.service" ] \
    && ok "moarchy-usbnet.service enabled" || no "moarchy-usbnet.service not enabled"
  # Linux delivers a packet for 10.66.0.2 that arrives on wlan0, so the
  # ListenAddress below keeps nobody out on its own; this drop-in does. Exact
  # bytes, because an added line widens it as surely as a missing one: a
  # second RestrictNetworkInterfaces adds an interface.
  _sd="$R/etc/systemd/system/sshd.service.d/20-moarchy-usbnet.conf"
  if cmp -s "$_sd" - <<'EOF'
[Unit]
Requires=moarchy-usbnet.service
After=moarchy-usbnet.service

[Service]
RestrictNetworkInterfaces=usb0
IPAddressDeny=any
IPAddressAllow=10.66.0.1
ExecStartPre=/usr/bin/bash -c 'timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/9" 2>/dev/null; [ $$? = 124 ]'
EOF
  then
    ok "sshd needs the link, is confined to usb0 and 10.66.0.1, and will not start unfiltered"
  else
    no "sshd's drop-in is not the one configure.sh writes -- its filter or its self-test is changed"
  fi
  # Anything else that could reset or widen that: another sshd.service drop-in
  # or a whole replacement unit, and the type-wide or slice drop-ins that name
  # those settings (a slice's IPAddressAllow adds to every unit under it).
  _od=$(find "$R"/etc/systemd/system/sshd.service.d "$R"/usr/lib/systemd/system/sshd.service.d \
    "$R"/usr/local/lib/systemd/system/sshd.service.d "$R"/etc/systemd/system.control/sshd.service.d \
    -mindepth 1 ! -path "$_sd" 2>/dev/null | sed "s|^$R||")
  for _f in /etc/systemd/system/sshd.service /usr/local/lib/systemd/system/sshd.service; do
    { [ -e "$R$_f" ] || [ -L "$R$_f" ]; } && _od="$_od $_f"
  done
  _od="$_od $(for _d in etc/systemd/system usr/lib/systemd/system usr/local/lib/systemd/system etc/systemd/system.control; do
    grep -lsE '^\s*(RestrictNetworkInterfaces|IPAddress(Allow|Deny)|ExecStartPre|SuccessExitStatus)\s*=' \
      "$R/$_d"/service.d/* "$R/$_d"/slice.d/* "$R/$_d"/-.slice.d/* "$R/$_d"/system.slice.d/*
  done | sed "s|^$R||")"
  _od=$(echo $_od)
  [ -z "$_od" ] && ok "nothing else can reset or widen sshd's filter" || no "other units or drop-ins could undo the link's sshd filter: $_od"
  grep -qxF 'echo 1 > "/proc/sys/net/ipv6/conf/$IF/disable_ipv6"' "$R/usr/local/sbin/moarchy-usbnet" 2>/dev/null \
    && ok "usb0 takes no IPv6" || no "usb0 accepts IPv6 router advertisements from the USB host"
  grep -qx 'unmanaged-devices=mac:02:00:00:6d:6f:02' "$R/etc/NetworkManager/conf.d/90-moarchy-usbnet.conf" 2>/dev/null \
    && ok "NetworkManager leaves the link alone" || no "NetworkManager could manage the link and change its address"
  # sshd@ instances from a socket unit get none of sshd.service's drop-ins.
  _ss=$(ls "$R"/etc/systemd/system/sockets.target.wants/ 2>/dev/null | grep -i ssh | tr '\n' ' ')
  [ -z "$_ss" ] && ok "no ssh socket unit enabled" || no "an ssh socket unit is enabled, outside the link's filter: $_ss"
  # sshd's own parser, not a grep: it follows Include, accepts keyword=value
  # and quotes, and applies Match. Probed as the PC and as a LAN host, so a
  # Match that opens sshd to some other address shows up too.
  # sshd opens /dev/null, and nothing mounts /dev in this chroot.
  _dn=0; [ -e "$R/dev/null" ] || { mknod -m 666 "$R/dev/null" c 1 3 && _dn=1; }
  chroot "$R" ssh-keygen -q -t ed25519 -N '' -f /tmp/verify-hostkey </dev/null >/dev/null 2>&1
  for _a in 10.66.0.1 192.168.1.5; do
    _t=$(chroot "$R" /usr/bin/sshd -T -h /tmp/verify-hostkey \
      -C "user=moarchy,addr=$_a,host=probe,laddr=10.66.0.2,lport=22" 2>&1)
    _la=$(printf '%s\n' "$_t" | awk 'tolower($1) == "listenaddress" { print $2 }' | sort -u | tr '\n' ' ')
    _au=$(printf '%s\n' "$_t" | awk 'tolower($1) == "allowusers" { print $2 }' | tr '\n' ' ')
    _pa=$(printf '%s\n' "$_t" | awk 'tolower($1) == "passwordauthentication" { print $2 }')
    [ "$_la" = "10.66.0.2:22 " ] && ok "sshd listens on 10.66.0.2 only (as seen from $_a)" \
                                || no "sshd listens on '${_la:-nothing: $(printf '%s' "$_t" | tail -1)}', not 10.66.0.2 alone (as seen from $_a)"
    [ "$_au" = "moarchy@10.66.0.1 " ] && ok "sshd admits moarchy from 10.66.0.1 only (as seen from $_a)" \
                                     || no "sshd AllowUsers is '${_au:-unset}', not moarchy@10.66.0.1 alone (as seen from $_a)"
    [ "$_pa" = no ] || no "sshd allows password auth (as seen from $_a)"
  done
  rm -f "$R/tmp/verify-hostkey" "$R/tmp/verify-hostkey.pub"
  [ "$_dn" = 0 ] || rm -f "$R/dev/null"
fi
grep -qi '^PasswordAuthentication no' "$R/etc/ssh/sshd_config.d/10-moarchy.conf" 2>/dev/null \
  && ok "sshd password auth disabled" || no "sshd password auth not disabled"
# systemd-resolved's LLMNR and mDNS responders answer on every interface and
# announce the hostname; off, nothing in the image listens on a network.
_rc="$R/usr/lib/systemd/resolved.conf.d/50-moarchy.conf"
_rc_on=$(grep -lsE '^\s*(LLMNR|MulticastDNS)\s*=\s*(yes|resolve|true|1)\s*$' \
  "$R/etc/systemd/resolved.conf" "$R"/etc/systemd/resolved.conf.d/*.conf | sed "s|^$R||")
if ! grep -qx 'LLMNR=no' "$_rc" 2>/dev/null || ! grep -qx 'MulticastDNS=no' "$_rc" 2>/dev/null; then
  no "LLMNR or mDNS is not turned off -- the phone answers name queries on every network it joins"
elif [ -n "$_rc_on" ]; then
  no "LLMNR or mDNS re-enabled by $(echo $_rc_on) -- the phone answers name queries on every network it joins"
else
  ok "systemd-resolved answers no LLMNR or mDNS queries"
fi

# ---------------------------------------------------------------------------
# Everything above reads the image. This runs it. These two scripts do the work
# a package cannot, they have no other test, and a phone is the only other
# place they would ever execute for the first time.
sec "behaviour: the first-boot scripts"

mount --bind /proc "$R/proc" 2>/dev/null
mount --bind /sys  "$R/sys"  2>/dev/null
mount --bind /dev  "$R/dev"  2>/dev/null
cleanup() { umount -l "$R/proc" "$R/sys" "$R/dev" 2>/dev/null; umount -l "$R" 2>/dev/null; }
trap cleanup EXIT

# --- moarchy-firstboot -----------------------------------------------------
# SYSTEMD_OFFLINE stops `systemctl enable` reaching for a bus that is not there.
if chroot "$R" env SYSTEMD_OFFLINE=1 /usr/lib/moarchy/bin/moarchy-firstboot \
     > "$WORK/firstboot.log" 2>&1; then
  ok "moarchy-firstboot ran"
else
  no "moarchy-firstboot exited $?"; sed 's/^/       /' "$WORK/firstboot.log"
fi

# firstboot rewrites the same file; this checks it names the right user, not
# that it is present -- the shipped-state check above owns that.
grep -q -- "--autologin moarchy" \
  "$R/etc/systemd/system/getty@tty1.service.d/autologin.conf" 2>/dev/null \
  && ok "firstboot's autologin drop-in names the user" \
  || no "firstboot wrote a wrong or missing autologin drop-in"

for g in input feedbackd; do
  chroot "$R" id -nG moarchy 2>/dev/null | tr ' ' '\n' | grep -qx "$g" \
    && ok "moarchy is in group $g" || no "moarchy is not in group $g"
done
[ -f "$R/var/lib/moarchy/firstboot-done" ] && ok "firstboot stamped itself" \
                                           || no "no firstboot stamp -- it would run again"

# --- moarchy-pacman-init ---------------------------------------------------
# Run from a state a power cut during first boot leaves: a half-made
# gnupg.new. The script must discard it and still produce a keyring. Then the
# check that matters: SigLevel = Required refuses every package in the repo
# unless the moarchy key is TRUSTED, and the phone's only symptom would be
# `pacman -Syu` stopping. Three outcomes, told apart: trusted, present but not
# trusted (no ownertrust, so gpg validates nothing), absent.
mkdir -p "$R/etc/pacman.d/gnupg.new" && touch "$R/etc/pacman.d/gnupg.new/pubring.gpg"
if chroot "$R" /usr/lib/moarchy/bin/moarchy-pacman-init > "$WORK/pacman-init.log" 2>&1; then
  ok "moarchy-pacman-init generated a keyring over an interrupted run's leftovers"
else
  no "moarchy-pacman-init failed"; sed 's/^/       /' "$WORK/pacman-init.log" 2>/dev/null
fi
[ ! -e "$R/etc/pacman.d/gnupg.new" ] && ok "no gnupg.new left behind" \
                                    || no "gnupg.new left behind -- the keyring was not moved into place"
[ -e "$R/var/lib/moarchy/pacman-keyring-generated" ] && ok "the generated keyring is marked as the phone's own" \
  || no "no keyring-generated mark -- the next upgrade would replace a keyring the phone made itself"
kt="$R/usr/share/pacman/keyrings/moarchy-trusted"
kf=$(sed 's/:.*//' "$kt" 2>/dev/null | head -1)
if [ -z "$kf" ]; then
  no "no moarchy-trusted beside the key -- pacman-key had no fingerprint to trust"
elif pacman-key --gpgdir "$R/etc/pacman.d/gnupg" --list-keys "$kf" 2>/dev/null |
     grep -qE '\[ *(full|ultimate) *\]'; then
  ok "the moarchy signing key is trusted in the phone-generated keyring ($kf)"
elif pacman-key --gpgdir "$R/etc/pacman.d/gnupg" --list-keys "$kf" >/dev/null 2>&1; then
  no "the moarchy key is in the keyring but NOT trusted -- SigLevel = Required will refuse every update"
else
  no "the moarchy key is not in the generated keyring -- pacman -Syu will refuse the repo"
fi
chroot "$R" gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null
# Exactly one ultimately trusted key, the phone's own master; a second would be
# a keyring that was copied in rather than generated.
_ult=$(chroot "$R" gpg --homedir /etc/pacman.d/gnupg --export-ownertrust 2>/dev/null | grep -c ':6:$')
chroot "$R" gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null
[ "$_ult" = 1 ] && ok "one local master key in the generated keyring" \
                || no "$_ult ultimately trusted keys in the generated keyring, expected 1"

# --- moarchy-user-setup ----------------------------------------------------
# Runs as the user, from their own HOME, the way the user unit does.
if chroot "$R" runuser -u moarchy -- env HOME=/home/moarchy \
     PATH=/usr/lib/moarchy/bin:/usr/bin:/bin \
     /usr/lib/moarchy/bin/moarchy-user-setup > "$WORK/usersetup.log" 2>&1; then
  ok "moarchy-user-setup ran"
else
  no "moarchy-user-setup exited $?"; sed 's/^/       /' "$WORK/usersetup.log"
fi

# A theme apply that half-works is the failure mode this project keeps hitting:
# the exit status is 0 and a sub-step printed the reason nobody read.
if grep -qE 'No such file|command not found|does not exist' "$WORK/usersetup.log"; then
  no "moarchy-user-setup logged errors even though it exited 0:"
  grep -E 'No such file|command not found|does not exist' "$WORK/usersetup.log" | sed 's/^/       /'
else
  ok "moarchy-user-setup logged no missing files or commands"
fi

for f in .config/foot/foot.ini .config/btop/btop.conf; do
  [ -e "$R/home/moarchy/$f" ] && ok "user config $f" || no "user config $f missing"
done
# .config/alacritty was checked here until 2026-09-08. It is not a missing check
# now, it is the opposite one: alacritty is not installed (docs/apps.md T1), so a
# seeded config for it would be the bug.
[ -e "$R/home/moarchy/.config/alacritty" ] \
  && no "a config was seeded for alacritty, which is not installed" \
  || ok "no config seeded for an uninstalled terminal (T6)"

# T1: one terminal. Read from pacman's local database, which is the only record
# in an offline rootfs of what was INSTALLED as opposed to what happens to have
# left a file behind.
#
# The count is checked before any of the three names is. A `ls | grep` over a
# directory that is not there answers "no match" for every package, which reads
# exactly like "alacritty is not installed" and would turn a broken check into
# three green lines -- the failure this whole file exists to catch.
_pdb="$R/var/lib/pacman/local"
_pn=$(ls -1 "$_pdb" 2>/dev/null | wc -l)
if [ "$_pn" -lt 100 ]; then
  no "pacman's local db has $_pn entries -- unreadable, so the terminal checks below prove nothing"
else
  ok "pacman local db readable ($_pn packages)"
  _inst() { ls -1 "$_pdb" 2>/dev/null | grep -qE "^$1-[^-]+-[^-]+$"; }
  for t in alacritty qmlkonsole; do
    _inst "$t" && no "$t is installed -- the image should carry foot alone (T1)" \
                || ok "$t is not installed (T1)"
  done
  _inst foot && ok "foot is installed (T1)" \
             || no "foot is missing -- it IS the terminal"
fi

# T2: foot is the default terminal, which is also what stops xdg-terminal-exec
# hanging. The file is the whole mechanism, so the file is what is checked.
if grep -qx 'foot.desktop' "$R/home/moarchy/.config/xdg-terminals.list" 2>/dev/null; then
  ok "foot is the default terminal (T2)"
else
  no "xdg-terminals.list does not name foot -- xdg-terminal-exec will hang (T2)"
fi

# T3: one terminal in the APP_DRAWER, which is a different claim from T1 -- foot
# ships three TerminalEmulator entries, none of them NoDisplay. Upstream hides
# the other two by id, and this asserts that upstream file rather than anything
# of ours: nothing here implements T3, so the only way it regresses is that
# list losing the lines, which no other check would notice.
_hides="$R/usr/share/omarchy/default/omarchy/launcher.hides"
if [ ! -s "$_hides" ]; then
  no "launcher.hides is missing -- footclient and foot-server would both show as apps (T3)"
else
  for e in footclient foot-server; do
    grep -qx "$e" "$_hides" \
      && ok "$e is hidden from the appDrawer by launcher.hides (T3)" \
      || no "$e is not in launcher.hides -- it will show as a second terminal (T3)"
  done
fi
grep -q 'style=Regular' "$R/home/moarchy/.config/foot/foot.ini" 2>/dev/null \
  && ok "foot keeps Regular weight" || no "foot.ini was not adjusted"
grep -q 'shown_boxes = "cpu mem"' "$R/home/moarchy/.config/btop/btop.conf" 2>/dev/null \
  && ok "btop trimmed to cpu+mem" || no "btop.conf was not adjusted"

# ~/.config/omarchy MUST NOT hold a shell.json: a user file overrides the
# packaged defaults, so copying one there would mask the phone UI entirely.
[ -e "$R/home/moarchy/.config/omarchy/shell.json" ] \
  && no "a user shell.json was created -- it masks the packaged defaults" \
  || ok "no user shell.json (packaged defaults stay in force)"

# The theme's compositor colours. Upstream generates hyprland.lua itself and
# config/hypr/hyprland.lua requires it -- moarchy no longer ships a template.
THEME="$R/home/moarchy/.local/state/omarchy/current/theme"
[ -e "$THEME/hyprland.lua" ] && ok "theme generated hyprland.lua" \
                             || no "no hyprland.lua generated -- omarchy-theme-set did not run"
[ -e "$THEME/colors.toml" ] && ok "theme colors.toml (the keyboard reads this)" \
                            || no "no colors.toml -- moarchy-keyboard has no palette"
[ -f "$R/home/moarchy/.local/state/moarchy/user-setup-done" ] \
  && ok "user-setup stamped itself" || no "no user-setup stamp -- it would run again"

# ---------------------------------------------------------------------------
# I7 has no other test. It runs exactly once, on a card, on first boot -- so
# without this the first time it executes is on someone's phone.
# The session is started by /etc/profile.d, and what Hyprland inherits from it is
# the whole ballgame: moarchy-restart-shell lives in /usr/lib/moarchy/bin, so if
# that is not on PATH the shell never starts -- no bar, no gesture strip, and no
# log either, because the script that writes the log is the missing one.
#
# Every static check passed while this was broken. It took the phone to find it,
# so it is simulated here: a login shell on tty1, with Hyprland replaced by a stub
# that reports the environment it was handed instead of starting a compositor.
sec "behaviour: what Hyprland inherits from a tty1 login"

install -Dm755 /dev/stdin "$R/usr/local/bin/Hyprland" <<'STUB'
#!/bin/bash
echo "PATH=$PATH"
echo "OMARCHY_PATH=${OMARCHY_PATH:-<unset>}"
echo "MOARCHY_PATH=${MOARCHY_PATH:-<unset>}"
for c in moarchy-restart-shell moarchy-keyboard omarchy-theme-set hyprctl; do
  command -v "$c" >/dev/null 2>&1 && echo "resolves $c" || echo "MISSING $c"
done
STUB

login_env=$(chroot "$R" runuser -u moarchy -- \
  env -i HOME=/home/moarchy XDG_VTNR=1 TERM=dumb /bin/bash -l -c true 2>&1)
rm -f "$R/usr/local/bin/Hyprland"

if [ -z "$login_env" ]; then
  no "the tty1 login never reached the compositor -- profile.d did not exec it"
else
  # The stub only runs if the session block was reached at all.
  echo "$login_env" | grep -q '^PATH=' \
    && ok "the login shell execs Hyprland" || no "Hyprland was not exec'd from profile.d"
  for c in moarchy-restart-shell moarchy-keyboard omarchy-theme-set hyprctl; do
    if echo "$login_env" | grep -q "^resolves $c$"; then ok "Hyprland would find $c"
    else no "Hyprland would NOT find $c -- it is not on the session PATH"; fi
  done
  for v in OMARCHY_PATH MOARCHY_PATH; do
    val=$(echo "$login_env" | sed -n "s/^$v=//p")
    [ "$val" != "<unset>" ] && [ -n "$val" ] \
      && ok "$v=$val in the session" || no "$v is unset in the session"
  done
fi

# Anything else this device needs to be true of its rootfs, if it has any.
# sargo does: without qbootctl marking the boot slot, the bootloader stops
# booting the phone after a few reboots (D26), and that is invisible in every
# other check here because the image is otherwise perfect.
declare -F verify_rootfs >/dev/null && verify_rootfs

# How this device grows into the storage it was flashed onto. A card that may
# be bigger than the image, or a fixed vendor partition -- different enough
# that the backend owns it (docs/devices.md D12).
verify_grow

sec "result"
if [ $FAIL = 0 ]; then
  printf '  \033[32mall checks passed\033[0m\n'
else
  printf '  \033[31msome checks failed\033[0m\n'
fi
# A DEV_IMAGE=1 left exported would pass a dev image as if it were a release.
[ "${DEV_IMAGE:-0}" = 1 ] && printf '  \033[33mverified as a DEV image (DEV_IMAGE=1): NOT PUBLISHABLE\033[0m\n'
exit $FAIL
