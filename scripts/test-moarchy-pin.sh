#!/usr/bin/env bash
# bin/moarchy-pin, the one door to the PIN (docs/structure.md I8), without a
# phone.
#
#   ./scripts/test-moarchy-pin.sh
#
# The helper only runs as root, so it runs here as root inside a namespace of
# its own, over a scratch /etc/shadow, /etc/group and /var/lib, with chpasswd
# and passwd stubbed to record rather than act. Real yescrypt hashes, through
# the same libcrypt the helper calls, so a right PIN is right for the reason it
# would be on the phone.
#
# bwrap with a user namespace where the kernel allows one (this machine);
# otherwise passwordless sudo and a mount namespace (the CI runner, whose
# Ubuntu restricts unprivileged user namespaces). Neither is a skip: a test of
# the lock's count that quietly did not run is the gap it exists to close.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/moarchy-pin"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
U=$(id -un)
mkdir -p "$WORK/varlib" "$WORK/stub"

hash() {
  printf '%s\n' "$1" | python3 -I -c '
import ctypes, ctypes.util, sys
lc = ctypes.CDLL(ctypes.util.find_library("crypt"))
lc.crypt.restype = ctypes.c_char_p
lc.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
lc.crypt_gensalt.restype = ctypes.c_char_p
lc.crypt_gensalt.argtypes = [ctypes.c_char_p, ctypes.c_ulong, ctypes.c_char_p, ctypes.c_int]
print(lc.crypt(sys.stdin.readline().strip().encode(), lc.crypt_gensalt(b"$y$", 5, None, 0)).decode())'
}
printf '%s:%s:20000:0:99999:7:::\n' "$U" "$(hash 246813)" >"$WORK/shadow"
# The user in wheel, whatever the host calls its admin group.
grep -v '^wheel:' /etc/group >"$WORK/group"
printf 'wheel:x:998:%s\n' "$U" >>"$WORK/group"
cat >"$WORK/stub/chpasswd" <<E
#!/bin/bash
cat >"$WORK/chpasswd.in"
E
cat >"$WORK/stub/passwd" <<E
#!/bin/bash
echo "\$2 \$(cat "$WORK/stub/pwstate" 2>/dev/null || echo L) 2026-10-19"
E
# A python that cannot check anything, for the case where libcrypt is broken,
# and one that takes two seconds to say no, for the window between counting a
# guess and answering it.
cat >"$WORK/stub/python3-broken" <<'E'
#!/bin/bash
exit 2
E
cat >"$WORK/stub/python3-slow" <<'E'
#!/bin/bash
sleep 2
exit 1
E
chmod +x "$WORK/stub/"*
# /usr/bin/python3 is a symlink on most systems, and a bind lands on its target.
PYDEST=$(readlink -f /usr/bin/python3)
PY=$PYDEST

if bwrap --unshare-user --uid 0 --gid 0 --bind / / true 2>/dev/null; then
  backend=bwrap
elif sudo -n true 2>/dev/null; then
  backend=sudo
else
  echo "FAIL: needs bwrap with user namespaces, or passwordless sudo"
  exit 1
fi

# What the helper is run with: the caller's environment, and whatever the
# caller wrapped it in (a resource limit, say). `env -i` so nothing of this
# shell's own leaks into what is being tested.
ENVV=("SUDO_USER=$U")
WRAP=()

# run <mode> <stdin> -> "rc=<n> out=<stdout> err=<stderr>"
run() {
  local out rc
  if [[ $backend == bwrap ]]; then
    out=$(printf '%s' "$2" | bwrap --bind / / --dev /dev \
      --bind "$WORK/shadow" /etc/shadow --bind "$WORK/group" /etc/group \
      --bind "$WORK/varlib" /var/lib \
      --bind "$WORK/stub/chpasswd" /usr/bin/chpasswd --bind "$WORK/stub/passwd" /usr/bin/passwd \
      --bind "$PY" "$PYDEST" \
      --unshare-user --uid 0 --gid 0 env -i "${ENVV[@]}" "${WRAP[@]}" "$HELPER" "$1" 2>"$WORK/err")
  else
    out=$(printf '%s' "$2" | sudo -n unshare -m --propagation private bash -c '
      w=$1 py=$2 dest=$3; shift 3
      mount --bind "$w/shadow" /etc/shadow && mount --bind "$w/group" /etc/group &&
      mount --bind "$w/varlib" /var/lib &&
      mount --bind "$w/stub/chpasswd" /usr/bin/chpasswd && mount --bind "$w/stub/passwd" /usr/bin/passwd &&
      mount --bind "$py" "$dest" && exec env -i "$@"' \
      bash "$WORK" "$PY" "$PYDEST" "${ENVV[@]}" "${WRAP[@]}" "$HELPER" "$1" 2>"$WORK/err")
  fi
  rc=$?
  echo "rc=$rc out=$out err=$(cat "$WORK/err")"
}

fail=0
expect() {
  if [[ $2 == $3 ]]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s: got "%s", want "%s"\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
G="$WORK/varlib/moarchy/pin/pin-guard"
guard() { cat "$G"; }

expect "the right PIN" "$(run check $'246813\n')" "rc=0 out= err="
expect "a wrong PIN counts down" "$(run check $'111111\n')" "rc=4 out=9 err="
expect "letters count as a wrong PIN" "$(run check $'abc\n')" "rc=4 out=8 err="
expect "the right PIN resets the count" "$(run check $'246813\n')" "rc=0 out= err="
for _ in 1 2 3 4 5 6 7 8 9; do run check $'111111\n' >/dev/null; done
expect "the tenth wrong PIN pauses for two minutes" "$(run check $'111111\n')" "rc=3 out=120 err="
expect "a pause refuses even the right PIN" "$(run check $'246813\n')" "rc=3 out=1* err="
read -r f _ <"$G"; printf '%s 1\n' "$f" >"$G"
for _ in 1 2 3 4 5 6 7 8 9; do run check $'111111\n' >/dev/null; done
expect "the twentieth pauses twice as long" "$(run check $'111111\n')" "rc=3 out=240 err="
printf '9999 1\n' >"$G"
expect "the pause stops doubling at an hour" "$(run check $'111111\n')" "rc=3 out=3600 err="
printf '0 0\n' >"$G"

# A guard that cannot be read pauses; it does not start the count over.
printf 'garbage\n' >"$G"
expect "a damaged count pauses rather than resetting" "$(run check $'246813\n')" "rc=3 out=120 err="
: >"$G"
expect "so does an empty one" "$(run check $'246813\n')" "rc=3 out=120 err="
printf '0 0\n' >"$G"

PY="$WORK/stub/python3-broken"
expect "a check that cannot be made is not a wrong PIN" "$(run check $'246813\n')" "rc=2 out= err=moarchy-pin: could not check the PIN"
expect "and is refunded" "$(guard)" "0 0"
PY=$PYDEST

# The attacks: stop the helper between counting and checking, and the guess is
# still counted. A python that takes two seconds is the window.
PY="$WORK/stub/python3-slow"
run check $'111111\n' >"$WORK/bg.out" & bg=$!
sleep 0.5
pkill -KILL -f "bash -p $HELPER check"; killed=$?
wait $bg 2>/dev/null
expect "a helper killed before its verdict has still counted the guess" \
  "$killed $(grep -o '^rc=[0-9]*' "$WORK/bg.out") $(guard)" "0 rc=137 1 0"
run check $'111111\n' >"$WORK/bg.out" & bg=$!
sleep 0.5
pkill -TERM -f "bash -p $HELPER check"; termed=$?
pkill -HUP -f "bash -p $HELPER check"; hupped=$?
wait $bg
expect "TERM and HUP are ignored, and the guess is answered" \
  "$termed $hupped $(cat "$WORK/bg.out") $(guard)" "0 0 rc=4 out=8 err= 2 0"
PY=$PYDEST
printf '0 0\n' >"$G"
# A file-size limit of zero would make every write of the count fail. Soft
# only under bwrap, where a user namespace cannot raise a hard limit; the CI
# runner's sudo backend sets both, as an attacker could.
if [[ $backend == sudo ]]; then WRAP=(bash -c 'ulimit -f 0; exec "$@"' x); else WRAP=(bash -c 'ulimit -S -f 0; exec "$@"' x); fi
expect "a zero file-size limit does not stop the count" "$(run check $'111111\n') $(guard)" "rc=4 out=9 err= 1 0"
WRAP=()
printf '0 0\n' >"$G"

# PAM's door: the PIN with no newline, the user from PAM_USER, and no
# SUDO_USER at all.
ENVV=("PAM_TYPE=auth" "PAM_USER=$U")
expect "pam: the right PIN, as pam_exec sends it" "$(run pam '246813')" "rc=0 out= err="
expect "pam: a wrong one is counted with the rest" "$(run pam '135799') $(guard)" "rc=4 out=9 err= 1 0"
printf '%s:%s:20000:0:99999:7:::\n' "$U" "$(hash 'older pass phrase')" >"$WORK/shadow"
expect "pam: a password set before PINs still works for sudo" "$(run pam 'older pass phrase')" "rc=0 out= err="
printf '%s:%s:20000:0:99999:7:::\n' "$U" "$(hash 246813)" >"$WORK/shadow"
ENVV=("PAM_TYPE=account" "PAM_USER=$U")
expect "pam: only from the auth stack" "$(run pam '246813')" "rc=2 out= err=moarchy-pin: pam is for system-auth's auth stack"
ENVV=("PAM_TYPE=auth")
expect "pam: not without PAM_USER" "$(run pam '246813')" "rc=2 out= err=moarchy-pin: no user to check a PIN for"
ENVV=("SUDO_USER=$U")
printf '0 0\n' >"$G"

expect "no PIN on stdin" "$(run check '')" "rc=2 out= err=moarchy-pin: no PIN on stdin"
expect "first: five digits" "$(run first $'12345\n')" "rc=2 out= err=moarchy-pin: a PIN is 6 to 12 digits"
expect "first: thirteen digits" "$(run first $'1234567890123\n')" "rc=2 out= err=moarchy-pin: a PIN is 6 to 12 digits"
echo P >"$WORK/stub/pwstate"
expect "first: refused on an account with a password" "$(run first $'135790\n')" "rc=2 out= err=moarchy-pin: a PIN is already set; change it in Settings"
echo L >"$WORK/stub/pwstate"
expect "first: sets the PIN while the password is locked" "$(run first $'135790\n')" "rc=0 out= err="
expect "first: the PIN reached chpasswd on stdin" "$(cat "$WORK/chpasswd.in")" "$U:135790"
expect "first: the stamp is readable by the lock screen" "$(stat -c %a "$WORK/varlib/moarchy/pin-set")" "644"
expect "first: refused once stamped, even while L" "$(run first $'135790\n')" "rc=2 out= err=moarchy-pin: a PIN is already set; change it in Settings"
grep -v '^wheel:' /etc/group >"$WORK/group"; rm -f "$WORK/varlib/moarchy/pin-set"
expect "first: refused outside wheel" "$(run first $'135790\n')" "rc=2 out= err=moarchy-pin: $U is not in wheel"
expect "set: replaces the PIN" "$(run set $'864201\n')" "rc=0 out= err="
expect "an unknown mode" "$(run bogus $'1\n')" "rc=2 out= err=moarchy-pin: usage: moarchy-pin check|pam|first|set (the PIN on stdin)"
expect "the count's directory is root's alone" "$(stat -c %a "$WORK/varlib/moarchy/pin")" "700"

if [[ $fail -gt 0 ]]; then
  echo "$fail failed"
  exit 1
fi
echo "all passed"
