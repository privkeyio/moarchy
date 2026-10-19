#!/usr/bin/env bash
# bin/moarchy-harden-auth, which makes moarchy-pin the one door to the PIN
# (docs/structure.md I8), without a phone.
#
#   ./scripts/test-harden-auth.sh
#
# Run as root in a namespace over a scratch /etc/pam.d holding pambase's own
# system-auth, and setuid stand-ins for the six programs it strips. Same two
# backends as test-moarchy-pin.sh, for the same reason.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARDEN="$ROOT/bin/moarchy-harden-auth"
# The six it strips, less any this machine does not have (Ubuntu has no ksu):
# a stand-in with nothing to bind over would read as a bit left behind.
BINS=()
for b in unix_chkpwd su chfn chsh passwd ksu; do [[ -e /usr/bin/$b ]] && BINS+=("$b"); done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/pam.d" "$WORK/bin"

# pambase 20260616-1's system-auth, as the phone ships it.
pambase() {
  cat <<'E'
#%PAM-1.0

auth       required                    pam_faillock.so      preauth
# Optionally use requisite above if you do not want to prompt for the password
# on locked accounts.
-auth      [success=2 default=ignore]  pam_systemd_home.so
auth       [success=1 default=bad]     pam_unix.so          try_first_pass nullok
auth       [default=die]               pam_faillock.so      authfail
auth       optional                    pam_permit.so
auth       required                    pam_env.so
auth       required                    pam_faillock.so      authsucc
# If you drop the above call to pam_faillock.so the lock will be done also
# on non-consecutive authentication failures.

-account   [success=1 default=ignore]  pam_systemd_home.so
account    required                    pam_unix.so
account    optional                    pam_permit.so
account    required                    pam_time.so

-password  [success=1 default=ignore]  pam_systemd_home.so
password   required                    pam_unix.so          try_first_pass nullok shadow
password   optional                    pam_permit.so

-session   optional                    pam_systemd_home.so
session    required                    pam_limits.so
session    required                    pam_unix.so
session    optional                    pam_permit.so
E
}
LINE='auth       [success=1 default=bad]     pam_exec.so          quiet quiet_log expose_authtok seteuid /usr/lib/moarchy/bin/moarchy-pin pam'

setuid_bins() { for b in "${BINS[@]}"; do : >"$WORK/bin/$b"; chmod 4755 "$WORK/bin/$b"; done; }

if bwrap --unshare-user --uid 0 --gid 0 --bind / / true 2>/dev/null; then
  backend=bwrap
elif sudo -n true 2>/dev/null; then
  backend=sudo
else
  echo "FAIL: needs bwrap with user namespaces, or passwordless sudo"
  exit 1
fi

run() {
  local out rc args=()
  if [[ $backend == bwrap ]]; then
    for b in "${BINS[@]}"; do args+=(--bind "$WORK/bin/$b" "/usr/bin/$b"); done
    out=$(bwrap --bind / / --dev /dev --bind "$WORK/pam.d" /etc/pam.d "${args[@]}" \
      --unshare-user --uid 0 --gid 0 "$HARDEN" 2>&1)
  else
    out=$(sudo -n unshare -m --propagation private bash -c '
      w=$1 h=$2; shift 2
      mount --bind "$w/pam.d" /etc/pam.d || exit 99
      for b; do [[ -e /usr/bin/$b ]] || continue; mount --bind "$w/bin/$b" "/usr/bin/$b" || exit 99; done
      exec "$h"' bash "$WORK" "$HARDEN" "${BINS[@]}" 2>&1)
  fi
  rc=$?
  echo "rc=$rc out=$out"
}

fail=0
expect() {
  if [[ $2 == $3 ]]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s: got "%s", want "%s"\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
modes() { for b in "${BINS[@]}"; do stat -c %a "$WORK/bin/$b"; done | sort -u | tr '\n' ' '; }

pambase >"$WORK/pam.d/system-auth"; setuid_bins
expect "pambase's system-auth: rewritten" "$(run)" "rc=0 out="
expect "the pam_unix auth line is now moarchy-pin's" "$(grep -cxF "$LINE" "$WORK/pam.d/system-auth") $(grep -cE '^auth\s.*pam_unix' "$WORK/pam.d/system-auth")" "1 0"
expect "nothing else in system-auth moved" \
  "$(diff <(pambase) "$WORK/pam.d/system-auth" | grep -c '^[<>]')" "2"
expect "no setuid bit left on any of the six" "$(modes)" "755 "

cp "$WORK/pam.d/system-auth" "$WORK/before"; setuid_bins
expect "a second run changes nothing in system-auth" "$(run) $(cmp -s "$WORK/before" "$WORK/pam.d/system-auth" && echo same)" "rc=0 out= same"
expect "and still strips a setuid bit put back" "$(modes)" "755 "

# A system-auth it does not know is left alone, and said so: the PIN is then
# NOT counted through it, which verify.sh fails an image for.
pambase | sed 's/try_first_pass nullok$/try_first_pass/' >"$WORK/pam.d/system-auth"
cp "$WORK/pam.d/system-auth" "$WORK/before"
expect "an unknown system-auth: refused, loudly" "$(run)" "rc=1 out=moarchy-harden-auth: /etc/pam.d/system-auth has no pam_unix auth line in the shape this replaces; PIN checks through it are NOT counted"
expect "and left as it was" "$(cmp -s "$WORK/before" "$WORK/pam.d/system-auth" && echo same)" "same"

if [[ $fail -gt 0 ]]; then
  echo "$fail failed"
  exit 1
fi
echo "all passed"
