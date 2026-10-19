#!/usr/bin/env bash
# The PIN's one door through real PAM: real sudo, real pam_exec, the real
# system-auth after bin/moarchy-harden-auth (docs/structure.md I8).
#
#   docker run --rm --platform linux/arm64 -v "$PWD:/repo:ro" --entrypoint bash \
#     moarchy-image /repo/scripts/test-pam-door.sh
#
# It rewrites system-auth, strips setuid bits and adds a user, so it runs only
# as root in a throwaway container, and refuses anywhere else.

set -uo pipefail
[[ -e /.dockerenv && $EUID -eq 0 ]] || { echo "FAIL: run this as root in a throwaway container; it rewrites system-auth"; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pacman -Sy --noconfirm --needed sudo python >/dev/null 2>&1 || { echo "FAIL: could not install sudo and python"; exit 1; }
id tester >/dev/null 2>&1 || useradd -m -G wheel tester
printf 'tester:246813\n' | chpasswd
printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
install -Dm755 "$REPO/bin/moarchy-pin" /usr/lib/moarchy/bin/moarchy-pin
G=/var/lib/moarchy/pin/pin-guard

fail=0
expect() {
  if [[ $2 == $3 ]]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s: got "%s", want "%s"\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
as_tester() { su tester -s /bin/bash -c "$1" </dev/null >/dev/null 2>&1; echo $?; }
nonzero() { [[ $1 -ne 0 ]] && echo nonzero || echo zero; }
fresh() { faillock --user tester --reset 2>/dev/null; rm -f "$G"; }

# The control: before hardening, these doors are open, so the checks below
# that they are shut are measuring something.
UNIXCHK='printf "246813\0" | /usr/bin/unix_chkpwd tester nonull'
SU='printf "246813\n" | su tester -c true'
expect "control: unix_chkpwd checks the PIN for its user, uncounted" "$(as_tester "$UNIXCHK")" "0"
expect "control: so does su" "$(as_tester "$SU")" "0"

"$REPO/bin/moarchy-harden-auth" || { echo "FAIL: moarchy-harden-auth"; exit 1; }

fresh
expect "sudo takes the right PIN" "$(as_tester 'printf "246813\n" | sudo -S -k -p "" true')" "0"
expect "sudo refuses a wrong one" "$(as_tester 'printf "111111\n" | sudo -S -k -p "" true')" "1"
expect "and the wrong one is in moarchy-pin's count" "$(cat "$G")" "1 0"
expect "the right PIN resets it" "$(as_tester 'printf "246813\n" | sudo -S -k -p "" true') $(cat "$G")" "0 0 0"

# The tenth wrong PIN through sudo pauses everything, the lock screen's
# keypad included: one count, whichever door the guess came in by.
fresh; printf '9 0\n' >"$G"
expect "the tenth wrong PIN through sudo pauses entry" "$(as_tester 'printf "111111\n" | sudo -S -k -p "" true') $(cut -d' ' -f1 "$G")" "1 10"
faillock --user tester --reset
expect "a paused count refuses sudo the right PIN" "$(as_tester 'printf "246813\n" | sudo -S -k -p "" true')" "1"
out=$(printf '246813\n' | SUDO_USER=tester /usr/lib/moarchy/bin/moarchy-pin check); rc=$?
expect "and the lock screen's check too" "$rc" "3"

# The doors that are shut: none of these can check tester's PIN for tester.
fresh
expect "su cannot check a PIN for an unprivileged caller" "$(nonzero "$(as_tester "$SU")")" "nonzero"
expect "unix_chkpwd cannot either" "$(nonzero "$(as_tester "$UNIXCHK")")" "nonzero"
expect "passwd cannot be used to test the current one" "$(nonzero "$(as_tester 'printf "246813\n111111\n111111\n" | passwd')")" "nonzero"
suid=$(find /usr/bin/unix_chkpwd /usr/bin/su /usr/bin/chfn /usr/bin/chsh /usr/bin/passwd /usr/bin/ksu -perm /6000 2>/dev/null)
expect "none of the six is setuid" "${suid:-none}" "none"

if [[ $fail -gt 0 ]]; then
  echo "$fail failed"
  exit 1
fi
echo "all passed"
