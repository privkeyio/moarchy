// The lock's decisions, apart from the QML that acts on them, so each one can
// be tested without a compositor (tests/tst_lock.qml).
.pragma library

// What the account can do, from the probe's one line (Service.qml).
//
//   pin     a PIN set through moarchy-pin: the keypad
//   setup   no password at all yet (L or NP): choose the first PIN
//   legacy  a password set some other way, which may not be digits and so may
//           never open on a keypad. No lock until Settings > Change PIN sets a
//           real one; a phone that cannot be opened is worse than one that does
//           not lock, and before this it never locked at all.
//   norule  sudo will not run moarchy-pin, so nothing could check a PIN: no lock
//   pin     anything else, unreadable included. The keypad is the safe failure:
//           the helper is what decides, and it is asked again after a failure.
function accountMode(line) {
  var t = String(line || "").trim()
  if (t === "pin" || t === "norule") return t
  if (t === "L" || t === "NP") return "setup"
  if (t === "P") return "legacy"
  return "pin"
}

function canLock(mode) {
  return mode === "pin" || mode === "setup"
}

// At shell start, from the state file the last shell left in $XDG_RUNTIME_DIR.
//
//   none    it said unlocked: a shell restart, and the user stays unlocked
//   relock  it said locked: a restart while locked, panel left as it is
//   boot    no file, which tmpfs means a fresh boot: lock, and light the panel
//           autostart.lua blanked until the lock was up
function startupAction(text) {
  var t = String(text || "").trim()
  if (t === "unlocked") return "none"
  if (t === "locked") return "relock"
  return "boot"
}

// `moarchy-pin check`'s answer: 0 yes; 1 wrong, with the tries left before
// the next pause; 3 paused, with the seconds left; anything else is a failure
// to ask, not a wrong PIN.
function checkResult(code, out) {
  var n = parseInt(String(out || "").trim(), 10)
  if (code === 0) return { action: "unlock", seconds: 0, message: "" }
  if (code === 1) {
    var warn = !isNaN(n) && n <= 3
    return { action: "wrong", seconds: 0,
             message: warn ? "Wrong PIN. " + n + (n === 1 ? " try" : " tries") + " before a pause." : "Wrong PIN" }
  }
  if (code === 3) {
    var s = isNaN(n) || n < 1 ? 120 : n
    return { action: "pause", seconds: s, message: pauseMessage(s) }
  }
  return { action: "error", seconds: 0, message: "Could not check the PIN" }
}

function pauseMessage(seconds) {
  var m = Math.ceil(seconds / 60)
  if (m >= 120) return "Too many wrong PINs. Try again in " + Math.ceil(m / 60) + " hours."
  return "Too many wrong PINs. Try again in " + m + (m === 1 ? " minute." : " minutes.")
}

// The phone plugin's call states, in the words the lock screen draws by.
function callState(state) {
  if (state === "ringing") return "ringing"
  if (state === "active") return "call"
  return ""
}
