#!/usr/bin/env bash
# The sudo rules a release image ships, through real sudo: the few root
# actions that skip the PIN, that each skips it for exactly its own command
# line and nothing else, and that the helpers behind them do what the tile, the
# keypad and the drawer ask (docs/structure.md I8).
#
#   docker run --rm --platform linux/arm64 -v "$PWD:/repo:ro" --entrypoint bash \
#     moarchy-image /repo/scripts/test-sudo-grants.sh
#
# Upstream's rules come out of the built omarchy-config package in packages/.
# It replaces nmcli, mmcli, timedatectl and waydroid with stubs and adds a
# user, so it runs only as root in a throwaway container, and refuses anywhere
# else.

set -uo pipefail
[[ -e /.dockerenv && $EUID -eq 0 ]] || { echo "FAIL: run this as root in a throwaway container; it replaces system tools"; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pacman -Sy --noconfirm --needed sudo >/dev/null 2>&1 || { echo "FAIL: could not install sudo"; exit 1; }
pkg=$(ls "$REPO"/packages/omarchy-config-*.pkg.tar.* 2>/dev/null | head -1)
[[ -n $pkg ]] || { echo "FAIL: no omarchy-config package in packages/; build the packages first"; exit 1; }

id tester >/dev/null 2>&1 || useradd -m -G wheel tester
printf 'tester:246813\n' | chpasswd
rm -f /etc/sudoers.d/*
for f in 00-moarchy-wheel 20-moarchy-pin 30-moarchy-grants; do
  install -m440 "$REPO/default/sudoers/$f" "/etc/sudoers.d/$f"
done
install -m440 "$REPO/pkgbuilds/moarchy-waydroid/moarchy-android-launch.sudoers" /etc/sudoers.d/moarchy-android-launch
bsdtar -xf "$pkg" -C / etc/sudoers.d/omarchy-dns etc/sudoers.d/omarchy-tzupdate etc/sudoers.d/omarchy-theme-browser ||
  { echo "FAIL: upstream's sudoers rules are not in $pkg"; exit 1; }
# Where sudo writes what it ran, so the SIM PIN's absence from it can be read.
printf 'Defaults logfile=/var/log/sudo-test.log, loglinelen=0\n' >/etc/sudoers.d/99-test-log
chmod 440 /etc/sudoers.d/*; chown root:root /etc/sudoers.d/*
out=$(visudo -c 2>&1) || { echo "FAIL: the rules do not parse together:"; printf '%s\n' "$out"; exit 1; }

fail=0
expect() {
  if [[ $2 == $3 ]]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s: got "%s", want "%s"\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
as_tester() { su tester -s /bin/bash -c "$1" </dev/null 2>/dev/null; }

# Every command a rule names, stubbed to say who ran it and with what.
LOG=/tmp/ran.log
reset() { : >"$LOG"; chmod 666 "$LOG"; }
stub() {
  install -d "$(dirname "$1")"
  printf '#!/bin/bash\necho "$(id -u) %s $*" >>%s\n%s\n' "$(basename "$1")" "$LOG" "${2:-}" >"$1"
  chmod 755 "$1"
}
for p in /usr/lib/moarchy/bin/moarchy-data /usr/lib/moarchy/bin/moarchy-sim \
         /usr/lib/moarchy/bin/moarchy-android-launch /usr/bin/timedatectl /usr/bin/omarchy-dns \
         /usr/bin/nmcli /usr/bin/mmcli /usr/bin/pacman-stub; do stub "$p"; done
granted() {
  reset
  as_tester "sudo -n $1" >/dev/null
  [[ $(cut -d' ' -f1 "$LOG" 2>/dev/null) == 0 ]] && echo root || echo refused
}

echo "== the rules"
expect "sudo itself asks for the PIN" "$(as_tester 'sudo -n true' >/dev/null; echo $?)" "1"
expect "and takes it" "$(as_tester 'printf "246813\n" | sudo -S -k -p "" true'; echo $?)" "0"
for c in "/usr/lib/moarchy/bin/moarchy-data on" "/usr/lib/moarchy/bin/moarchy-data off" \
         "/usr/lib/moarchy/bin/moarchy-sim unlock" \
         "/usr/bin/timedatectl set-timezone Europe/Berlin" "/usr/bin/timedatectl set-timezone UTC" \
         "/usr/bin/timedatectl set-timezone America/Argentina/Buenos_Aires" "/usr/bin/timedatectl set-timezone Etc/GMT+5" \
         "/usr/bin/omarchy-dns Cloudflare" "/usr/bin/omarchy-dns Google" "/usr/bin/omarchy-dns DHCP" \
         "/usr/lib/moarchy/bin/moarchy-android-launch --start com.example.app_2"; do
  expect "no PIN: $c" "$(granted "$c")" "root"
done
for c in "/usr/lib/moarchy/bin/moarchy-data status" "/usr/lib/moarchy/bin/moarchy-data on now" \
         "/usr/lib/moarchy/bin/moarchy-data" "/usr/lib/moarchy/bin/moarchy-sim unlock 1234" \
         "/usr/lib/moarchy/bin/moarchy-sim status" "/usr/bin/nmcli c down x" "/usr/bin/mmcli -i 0 --pin=1234" \
         "/usr/bin/timedatectl set-timezone ../../etc/shadow" "/usr/bin/timedatectl set-timezone Europe/Berlin now" \
         "/usr/bin/timedatectl set-timezone -h" "/usr/bin/timedatectl set-ntp false" "/usr/bin/timedatectl set-time 2020-01-01" \
         "/usr/bin/omarchy-dns Custom" "/usr/bin/omarchy-dns Cloudflare 1.2.3.4" \
         "/usr/lib/moarchy/bin/moarchy-android-launch --start 'a;b'" "/usr/lib/moarchy/bin/moarchy-android-launch --start a b" \
         "/usr/lib/moarchy/bin/moarchy-android-launch --start -x" "/usr/lib/moarchy/bin/moarchy-android-launch com.example.app" \
         "/usr/lib/moarchy/bin/moarchy-android-launch --start" "/usr/bin/pacman-stub -Rns x"; do
  expect "PIN needed: $c" "$(granted "$c")" "refused"
done
# What upstream's omarchy-dns asks before it picks sudo over pkexec, and what
# moarchy-sim asks before it tries: the long listing's !authenticate.
lists() { as_tester "sudo -n -l -l $1 | grep -q '!authenticate'" && echo grant || echo none; }
expect "omarchy-dns sees its grant for a preset" "$(lists '/usr/bin/omarchy-dns Cloudflare')" "grant"
expect "and none for Custom, which asks in a terminal" "$(lists '/usr/bin/omarchy-dns Custom')" "none"
expect "moarchy-sim sees its grant" "$(lists '/usr/lib/moarchy/bin/moarchy-sim unlock')" "grant"

echo "== mobile data"
install -m755 "$REPO/bin/moarchy-data" /usr/lib/moarchy/bin/moarchy-data
U=11111111-2222-3333-4444-555555555555
stub /usr/bin/nmcli "case \"\$*\" in *'UUID,TYPE,ACTIVE c show'*) echo '$U:gsm:no' ;; esac"
reset; as_tester '/usr/lib/moarchy/bin/moarchy-data on' >/dev/null
expect "on writes the setting as root" "$(grep -c "^0 nmcli c modify $U connection.autoconnect yes$" "$LOG")" "1"
expect "and brings it up as root" "$(grep -c "^0 nmcli --wait 0 c up $U$" "$LOG")" "1"
reset; as_tester '/usr/lib/moarchy/bin/moarchy-data off' >/dev/null
expect "off writes the setting as root" "$(grep -c "^0 nmcli c modify $U connection.autoconnect no$" "$LOG")" "1"
expect "and takes it down as root" "$(grep -c "^0 nmcli c down $U$" "$LOG")" "1"
reset; as_tester '/usr/lib/moarchy/bin/moarchy-data status' >/dev/null
expect "status reads as the user, never root" "$(grep -c '^0 ' "$LOG") $(grep -q ' nmcli ' "$LOG" && echo read)" "0 read"

echo "== SIM keypad"
install -m755 "$REPO/bin/moarchy-sim" /usr/lib/moarchy/bin/moarchy-sim
SIM=/tmp/sim.state; printf 'locked 3\n' >"$SIM"; chmod 666 "$SIM"
stub /usr/bin/mmcli "read -r st left <$SIM
case \"\$*\" in
  '-m any --output-keyvalue')
    if [ \"\$st\" = locked ]; then u=sim-pin; else u=--; fi
    printf 'modem.generic.state : %s\nmodem.generic.unlock-required : %s\nmodem.generic.unlock-retries.value[1] : sim-pin (%s)\nmodem.generic.sim : /org/freedesktop/ModemManager1/SIM/0\n' \"\$st\" \"\$u\" \"\$left\" ;;
  '-i /org/freedesktop/ModemManager1/SIM/0 --pin=1234') echo \"registered \$left\" >$SIM; echo 'successfully sent PIN code to the SIM' ;;
  '-i '*) echo \"locked \$((left - 1))\" >$SIM; echo 'error: couldnt send PIN code: IncorrectPassword'; exit 1 ;;
esac"
: >/var/log/sudo-test.log
out=$(as_tester '/usr/lib/moarchy/bin/moarchy-sim unlock 9999 2>&1'); rc=$?
expect "a wrong PIN is wrong, with what it cost" "$rc $out" "1 Wrong PIN — 2 attempts left."
expect "and it was sent as root" "$(grep -c '^0 mmcli -i /org/freedesktop/ModemManager1/SIM/0 --pin=9999$' "$LOG")" "1"
out=$(as_tester '/usr/lib/moarchy/bin/moarchy-sim unlock 1234 2>&1'); rc=$?
expect "the right PIN unlocks" "$rc $out" "0 unlocked"
expect "sudo logged the unlock" "$(grep -c 'COMMAND=/usr/lib/moarchy/bin/moarchy-sim unlock$' /var/log/sudo-test.log)" "2"
expect "and neither PIN" "$(grep -cE '1234|9999' /var/log/sudo-test.log)" "0"
printf 'locked 3\n' >"$SIM"
mv /etc/sudoers.d/30-moarchy-grants /tmp/
out=$(as_tester '/usr/lib/moarchy/bin/moarchy-sim unlock 9999 2>&1'); rc=$?
expect "with no rule it says so, and spends no attempt" "$rc $(cut -d' ' -f2 "$SIM")" "3 3"
expect "rather than calling a PIN wrong" "$(grep -c 'no rule' <<<"$out")" "1"
# A dev image's passwordless sudo is a grant too.
printf 'tester ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/10-moarchy; chmod 440 /etc/sudoers.d/10-moarchy
out=$(as_tester '/usr/lib/moarchy/bin/moarchy-sim unlock 1234 2>&1'); rc=$?
expect "on a dev image it unlocks with no grant file" "$rc $out" "0 unlocked"
rm -f /etc/sudoers.d/10-moarchy; mv /tmp/30-moarchy-grants /etc/sudoers.d/

echo "== time zone"
install -m755 "$REPO/bin/moarchy-timezone" /usr/lib/moarchy/bin/moarchy-timezone
stub /usr/local/bin/omarchy-shell
reset; as_tester '/usr/lib/moarchy/bin/moarchy-timezone set Europe/Berlin' >/dev/null; rc=$?
expect "a zone is set as root, and the clock told" "$rc $(grep -c '^0 timedatectl set-timezone Europe/Berlin$' "$LOG") $(grep -c ' omarchy-shell ' "$LOG")" "0 1 1"
reset; as_tester '/usr/lib/moarchy/bin/moarchy-timezone set ../../etc/shadow' >/dev/null; rc=$?
expect "a path is refused, not prompted for" "$(( rc != 0 )) $(grep -c '^0 ' "$LOG")" "1 0"

echo "== Android launch"
install -m755 "$REPO/pkgbuilds/moarchy-waydroid/moarchy-android-launch" /usr/lib/moarchy/bin/moarchy-android-launch
stub /usr/bin/waydroid; stub /usr/bin/gdbus
reset; as_tester '/usr/lib/moarchy/bin/moarchy-android-launch com.example.app' >/dev/null; rc=$?
expect "the window is named as the user" "$(grep -c "^$(id -u tester) waydroid prop set waydroid.active_apps com.example.app$" "$LOG")" "1"
expect "and the app started in the container as root" "$rc $(grep -c '^0 waydroid shell -- sh -c ' "$LOG")" "0 1"
reset; as_tester '/usr/lib/moarchy/bin/moarchy-android-launch "a;b"' >/dev/null; rc=$?
expect "a name that is not a package runs nothing" "$rc $(wc -l <"$LOG")" "2 0"
expect "and --start is not the user's to call" "$(as_tester '/usr/lib/moarchy/bin/moarchy-android-launch --start com.example.app' >/dev/null; echo $?)" "2"

if [[ $fail -gt 0 ]]; then
  echo "$fail failed"
  exit 1
fi
echo "all passed"
