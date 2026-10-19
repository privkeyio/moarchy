#!/usr/bin/env bash
# The power button's two meanings (docs/gestures.md Q11), without a phone.
#
#   ./scripts/test-power-press.sh
#
# moarchy-power-press is pure arithmetic over one timestamp file, so what it
# needs stubbing is only the three things it calls. That is the whole reason the
# double-press window lives in a script rather than in the sway binding: a
# 400ms rule nobody can run is a 400ms rule that becomes 4000ms in a refactor
# and is noticed by hand, once, months later.
#
# The screen stub keeps the real flag file, because whether a single press
# locks depends on whether it blanked (Q11d). The lock stub writes `locked` to
# the state file the way moarchy.lock does, so a press after it reads as locked
# (Q11e).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$XDG_STATE_HOME/moarchy" "$XDG_RUNTIME_DIR" "$WORK/bin"

# Stubs that record rather than act.
cat > "$WORK/bin/moarchy-screen" <<'E'
#!/bin/bash
printf 'screen:%s\n' "$1" >>"$XDG_STATE_HOME/moarchy/calls"
flag="$XDG_STATE_HOME/moarchy/screen-locked"
case $1 in
  lock)   : >"$flag" ;;
  unlock) rm -f "$flag" ;;
  toggle) if [[ -e $flag ]]; then rm -f "$flag"; else : >"$flag"; fi ;;
esac
E
cat > "$WORK/bin/moarchy-trigger" <<'E'
#!/bin/bash
printf 'trigger:%s:%s\n' "$1" "$2" >>"$XDG_STATE_HOME/moarchy/calls"
E
cat > "$WORK/bin/omarchy-shell" <<'E'
#!/bin/bash
printf 'shell:%s:%s\n' "$1" "$2" >>"$XDG_STATE_HOME/moarchy/calls"
[[ $1 == moarchy-lock && $2 == lock ]] && echo locked >"$XDG_RUNTIME_DIR/moarchy-lock-state"
echo ok
E
chmod +x "$WORK/bin"/*
export PATH="$WORK/bin:$PATH"

PRESS="$ROOT/bin/moarchy-power-press"
CALLS="$XDG_STATE_HOME/moarchy/calls"
LOCK_STATE="$XDG_RUNTIME_DIR/moarchy-lock-state"

fail=0
ok() { printf '  PASS  %s\n' "$1"; }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
# An unlocked session with the panel lit, which is where a press starts.
reset() {
  : >"$CALLS"
  rm -f "$XDG_STATE_HOME/moarchy/power-press" "$XDG_STATE_HOME/moarchy/power-double" \
        "$XDG_STATE_HOME/moarchy/screen-locked"
  echo unlocked >"$LOCK_STATE"
}
calls() { tr '\n' ' ' <"$CALLS"; }
# Past the delayed lock's sleep, so whatever it was going to do is done.
settle() { sleep 0.8; }

# --- one press on its own -------------------------------------------------
reset
bash "$PRESS" >/dev/null 2>&1
[[ $(calls) == "screen:toggle " ]] \
  && ok "one press toggles the screen at once and fires nothing" \
  || no "one press did, at once: $(calls)"
settle
[[ $(calls) == "screen:toggle shell:moarchy-lock:lock " ]] \
  && ok "a press that blanks locks the session once the window is over (Q11d)" \
  || no "a press that blanks did, after the window: $(calls)"

# --- two presses inside the window ----------------------------------------
reset
bash "$PRESS" >/dev/null 2>&1
bash "$PRESS" >/dev/null 2>&1
settle
[[ $(calls) == "screen:toggle screen:unlock trigger:fire:power " ]] \
  && ok "two fast presses unlock and fire the trigger, and never lock (Q11, Q11d)" \
  || no "two fast presses did: $(calls)"

# Q11a. `unlock`, never a second `toggle`: the first press may have been the
# unlock, and toggling there would blank the screen the trigger is opening on.
reset
bash "$PRESS" >/dev/null 2>&1
bash "$PRESS" >/dev/null 2>&1
settle
[[ $(grep -c 'screen:toggle' "$CALLS") -eq 1 ]] \
  && ok "the second press unlocks rather than toggling again (Q11a)" \
  || no "toggle was called $(grep -c 'screen:toggle' "$CALLS") times"

# --- two presses outside the window ---------------------------------------
# The first blanks and locks; the second lands on a locked session and only
# lights the panel.
reset
bash "$PRESS" >/dev/null 2>&1
settle
bash "$PRESS" >/dev/null 2>&1
settle
[[ $(calls) == "screen:toggle shell:moarchy-lock:lock screen:toggle " ]] \
  && ok "two slow presses are a lock and then a wake" \
  || no "two slow presses did: $(calls)"

# --- a second press just outside the window ------------------------------
# Not a double, so it lights the panel -- and must not cancel the first
# press's lock, or a press at 450ms leaves the phone lit and unlocked.
reset
bash "$PRESS" >/dev/null 2>&1
sleep 0.45
bash "$PRESS" >/dev/null 2>&1
settle
# Order-free: on a loaded runner the second press can start after the lock.
[[ $(grep -c 'screen:toggle' "$CALLS") -eq 2 && $(grep -c 'shell:moarchy-lock:lock' "$CALLS") -eq 1 ]] \
  && ok "a second press just outside the window still leaves the session locked" \
  || no "a second press at 450ms did: $(calls)"

# --- no lock running, or no PIN yet ---------------------------------------
# No state file at all: the panel only, as on a locked session.
reset
rm -f "$LOCK_STATE"
bash "$PRESS" >/dev/null 2>&1
settle
[[ $(calls) == "screen:toggle " ]] \
  && ok "with no lock state a press only toggles the panel" \
  || no "with no lock state a press did: $(calls)"

# --- three fast presses ---------------------------------------------------
# Q11b. A double and then a single, not two overlapping doubles. The single
# blanks, so it is the one press of the three that locks.
reset
bash "$PRESS" >/dev/null 2>&1
bash "$PRESS" >/dev/null 2>&1
bash "$PRESS" >/dev/null 2>&1
settle
[[ $(grep -c 'trigger:fire:power' "$CALLS") -eq 1 ]] \
  && ok "three fast presses fire the trigger once (Q11b)" \
  || no "three fast presses fired it $(grep -c 'trigger:fire:power' "$CALLS") times"
[[ $(grep -c 'shell:moarchy-lock:lock' "$CALLS") -eq 1 ]] \
  && ok "three fast presses lock once, for the single at the end (Q11b, Q11d)" \
  || no "three fast presses locked $(grep -c 'shell:moarchy-lock:lock' "$CALLS") times"

# --- presses on a locked session ------------------------------------------
# Q11e. The panel only: no stamp read, no trigger, nothing locked again.
reset
echo locked >"$LOCK_STATE"
bash "$PRESS" >/dev/null 2>&1
bash "$PRESS" >/dev/null 2>&1
settle
[[ $(calls) == "screen:toggle screen:toggle " ]] \
  && ok "on a locked session two fast presses only toggle the panel (Q11e)" \
  || no "on a locked session two fast presses did: $(calls)"

# --- a press that wakes an unlocked phone ---------------------------------
# A panel blanked with no lock behind it (the shell was down, say). Lighting
# it is a wake, and a wake does not lock.
reset
: >"$XDG_STATE_HOME/moarchy/screen-locked"
bash "$PRESS" >/dev/null 2>&1
settle
[[ $(calls) == "screen:toggle " ]] \
  && ok "a press that lights the panel does not lock (Q11d)" \
  || no "a press that lights the panel did: $(calls)"

# --- a stamp that is not a number -----------------------------------------
# The file is in $HOME and a person may have looked at it; garbage in it must
# read as "no previous press" rather than as an arithmetic error.
reset
echo "not a number" >"$XDG_STATE_HOME/moarchy/power-press"
bash "$PRESS" >/dev/null 2>&1
[[ $(calls) == "screen:toggle " ]] \
  && ok "a corrupt stamp reads as no previous press" \
  || no "a corrupt stamp did: $(calls)"
settle

# --- the very first press of a session ------------------------------------
reset
bash "$PRESS" >/dev/null 2>&1
[[ -s "$XDG_STATE_HOME/moarchy/power-press" ]] \
  && ok "the press is stamped for the next one to measure against" \
  || no "no stamp was written"
settle

if [[ $fail -gt 0 ]]; then
  echo "$fail failed"
  exit 1
fi
echo "all passed"
