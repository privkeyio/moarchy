import QtQuick
import QtTest
import "../Lock.js" as Lock

TestCase {
  name: "Lock"

  function test_a_set_pin_gets_the_keypad() {
    compare(Lock.accountMode("pin"), "pin")
    compare(Lock.accountMode("pin\n"), "pin")
  }

  function test_no_password_yet_is_setup() {
    compare(Lock.accountMode("L"), "setup")
    compare(Lock.accountMode("NP"), "setup")
  }

  // A password set with passwd, which the keypad may never be able to type.
  function test_an_old_password_never_locks() {
    compare(Lock.accountMode("P"), "legacy")
    verify(!Lock.canLock("legacy"))
  }

  function test_no_sudo_rule_never_locks() {
    compare(Lock.accountMode("norule"), "norule")
    verify(!Lock.canLock("norule"))
  }

  // The keypad, never setup: setup on an account with a PIN would let anyone
  // holding the phone choose a new one.
  function test_an_unreadable_answer_is_the_keypad() {
    compare(Lock.accountMode(""), "pin")
    compare(Lock.accountMode("garbage"), "pin")
    compare(Lock.accountMode(undefined), "pin")
    verify(Lock.canLock("pin"))
    verify(Lock.canLock("setup"))
  }

  function test_what_a_shell_start_does() {
    compare(Lock.startupAction("unlocked\n"), "none")
    compare(Lock.startupAction("locked\n"), "relock")
    compare(Lock.startupAction(""), "boot")
    compare(Lock.startupAction("nonsense"), "boot")
  }

  function test_a_right_pin_unlocks() {
    compare(Lock.checkResult(0, "").action, "unlock")
  }

  function test_a_wrong_pin_warns_near_the_pause() {
    var far = Lock.checkResult(1, "8\n")
    compare(far.action, "wrong")
    compare(far.message, "Wrong PIN")
    compare(Lock.checkResult(1, "3").message, "Wrong PIN. 3 tries before a pause.")
    compare(Lock.checkResult(1, "1").message, "Wrong PIN. 1 try before a pause.")
    compare(Lock.checkResult(1, "").message, "Wrong PIN")
  }

  function test_a_pause_says_how_long() {
    var p = Lock.checkResult(3, "120\n")
    compare(p.action, "pause")
    compare(p.seconds, 120)
    compare(p.message, "Too many wrong PINs. Try again in 2 minutes.")
    compare(Lock.checkResult(3, "59").message, "Too many wrong PINs. Try again in 1 minute.")
    compare(Lock.checkResult(3, "86400").message, "Too many wrong PINs. Try again in 24 hours.")
    // No number still pauses, for the shortest pause there is.
    compare(Lock.checkResult(3, "").seconds, 120)
  }

  // A sudo that could not run the helper, a crash, a timeout: not a wrong PIN.
  function test_anything_else_is_a_failure_to_ask() {
    compare(Lock.checkResult(2, "").action, "error")
    compare(Lock.checkResult(1 + 0x100, "").action, "error")
    compare(Lock.checkResult(-1, "").action, "error")
  }

  function test_call_states() {
    compare(Lock.callState("ringing"), "ringing")
    compare(Lock.callState("active"), "call")
    compare(Lock.callState("none"), "")
    compare(Lock.callState(""), "")
  }
}
