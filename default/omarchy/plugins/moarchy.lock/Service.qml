// The session lock, and the PIN that opens it (docs/structure.md I8).
//
// Upstream's shell/plugins/lock/Service.qml is the base, and what it learned
// about ext-session-lock is kept as it was: the lock waits for a real screen
// and for the outputs to settle, and a lock left behind by a shell that died is
// found through omarchy-hyprland-session-locked and taken over rather than
// left to Hyprland's failsafe. What is not here is the fingerprint flow, the
// preview window and the password field: under ext-session-lock the compositor
// hides every other surface, the on-screen keyboard included, so the keypad is
// drawn on the lock surface itself (LockView.qml).
//
// Upstream's own lock plugin still loads, and stays inert: it refuses to lock
// without /etc/pam.d/omarchy-lock-password, which this phone does not ship.
// This one answers on its own IPC target, `moarchy-lock`, so the two never
// contend for one lock.
//
// A PIN is checked by `moarchy-pin check` through sudo, never through PAM: the
// helper keeps a count only root can write and pauses entry after every tenth
// wrong PIN, and every other way to check one goes through it or is gone
// (bin/moarchy-harden-auth). bin/moarchy-pin says why that matters here.
//
// When it locks: at session start, and whenever moarchy-system-lock asks (the
// power button, the idle timeout, Settings > Power > Lock). A shell restart
// must not lock an unlocked user, so the session's state is written to
// $XDG_RUNTIME_DIR/moarchy-lock-state, which is tmpfs and gone after a reboot.
// moarchy-power-press reads the same file to know a press on a locked phone
// only toggles the panel. The decisions themselves are in Lock.js.
//
// Setup mode is the first boot. The image ships the account with a locked
// password (`passwd -S` says L), so there is no PIN to check; the lock surface
// asks for a new one twice and hands it to `moarchy-pin first` on stdin. There
// is no way past it without one.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "Lock.js" as Lock

Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property string stateFilePath: (Quickshell.env("XDG_RUNTIME_DIR") || "/nonexistent") + "/moarchy-lock-state"

  // Absolute, for the reason moarchy.sim gives at length: a shell restarted
  // outside a login session can come up without /usr/lib/moarchy/bin on PATH.
  readonly property string pinTool: "/usr/lib/moarchy/bin/moarchy-pin"
  readonly property string screenTool: "/usr/lib/moarchy/bin/moarchy-screen"

  readonly property int pinMin: 6
  readonly property int pinMax: 12

  property bool lockRequested: false
  property bool pendingSessionLock: false
  // Lock.accountMode's answer, and whether the probe has given one yet.
  property string accountMode: ""
  property bool probed: false
  property bool lockQueued: false
  property string startup: ""
  // The panel autostart.lua blanked at a fresh boot, lit once the lock is up.
  property bool lightWhenSecure: false
  property bool authenticating: false
  property bool settingPin: false
  readonly property bool setupMode: accountMode === "setup"
  readonly property bool lockable: Lock.canLock(accountMode)
  property string setupFirst: ""
  property string entered: ""
  property string pendingPin: ""
  property string failureMessage: ""
  property bool paused: false
  // "", "ringing" or "call": the phone plugin's call, as it last told us.
  property string callState: ""
  property string caller: ""
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""
  property bool strandedLock: false
  property bool strandedLockResolved: false

  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure
  readonly property bool busy: authenticating || settingPin
  readonly property string mode: {
    if (!root.locked) return "unlocked"
    if (root.callState !== "") return root.callState
    if (root.setupMode) return "setup"
    return root.paused ? "paused" : "pin"
  }

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early is an orphan behind Hyprland's failsafe. Outputs
  // are often still absent here, so ask until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (locked || lockRequested) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !probed) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  // Once the probe has said what the account can do. A phone that cannot be
  // locked (no PIN yet set through moarchy-pin, no sudo rule) is unlocked, and
  // its panel is lit rather than left as autostart.lua blanked it.
  function handleStartup() {
    var action = startup
    startup = ""
    if (action === "" || action === "none" || locked) return
    if (!lockable) {
      logEvent("lock-at-start: not possible (" + accountMode + ")")
      writeState("unlocked")
      releaseKeyboard()
      if (action === "boot") Quickshell.execDetached([root.screenTool, "unlock"])
      return
    }
    logEvent("lock-at-start: " + action)
    lightWhenSecure = action === "boot"
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshAccount() {
    if (!accountProc.running) accountProc.running = true
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("moarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    entered = ""
    pendingPin = ""
    setupFirst = ""
    failureMessage = paused ? failureMessage : ""
  }

  // From this process and synchronously, so a lock right after an unlock can
  // never leave the file saying unlocked.
  function writeState(state) {
    stateFile.setText(state + "\n")
  }

  // Out of the boot submap autostart.lua put the keyboard in (bindings.lua).
  // Harmless when it is not in it.
  function releaseKeyboard() {
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap(\"reset\")"])
  }

  function beginLock() {
    // Before the probe answers there is no telling a keypad from a setup
    // screen, or from an account no keypad could open. Asked again then.
    if (!probed) {
      lockQueued = true
      return true
    }
    // Refused, and asked again: Settings may have just set the PIN this
    // account was missing, and the next lock should not wait for a reboot.
    if (!lockable) {
      logEvent("lock-denied: " + accountMode)
      lockQueued = true
      refreshAccount()
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    // `locked` only once the compositor says the lock is secure, so the
    // power button never wakes the touchscreen over a session still reachable.
    writeState("locking")
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshAccount()
    })

    return true
  }

  function finishUnlock() {
    if (!root.locked && !lockRequested) return

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    sessionLock.locked = false
    writeState("unlocked")
    releaseKeyboard()
    logEvent("unlocked")
  }

  // The panel off and the touchscreen with it, so a phone left on its lock
  // screen in a pocket cannot type PIN attempts into it.
  function runBlank() {
    Quickshell.execDetached([root.screenTool, "lock"])
  }

  function press(digit) {
    if (!lockRequested || busy || paused || entered.length >= pinMax) return
    failureMessage = ""
    entered += digit
  }

  function backspace() {
    if (busy) return
    entered = entered.slice(0, -1)
  }

  function submit() {
    if (setupMode) submitSetup()
    else submitPin()
  }

  function submitPin() {
    var pin = entered
    if (!lockRequested || busy || paused || pin.length < pinMin) return

    entered = ""
    pendingPin = pin
    failureMessage = ""
    authenticating = true
    checkProc.running = true
    helperWatchdog.restart()
  }

  // The helper's count is the real one; this only stops the keys asking
  // while it would refuse anyway.
  function enterPause(seconds, message) {
    entered = ""
    paused = true
    failureMessage = message
    pauseTimer.interval = Math.max(1, seconds) * 1000
    pauseTimer.restart()
  }

  function submitSetup() {
    var pin = entered
    if (!lockRequested || busy || pin.length < pinMin) return

    entered = ""
    failureMessage = ""
    if (setupFirst === "") {
      setupFirst = pin
      return
    }
    if (pin !== setupFirst) {
      setupFirst = ""
      failureMessage = "Those did not match. Choose a PIN again."
      return
    }

    setupFirst = ""
    pendingPin = pin
    settingPin = true
    pinProc.running = true
    helperWatchdog.restart()
  }

  function answer() {
    if (callState !== "ringing") return
    Quickshell.execDetached(["omarchy-shell", "phone", "answer"])
    callState = "call"
  }

  function hangUp() {
    if (callState === "") return
    Quickshell.execDetached(["omarchy-shell", "phone", "hangup"])
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.writeState("locked")
        if (root.lightWhenSecure) {
          root.lightWhenSecure = false
          root.releaseKeyboard()
          Quickshell.execDetached([root.screenTool, "unlock"])
        }
      }
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      // The compositor ended the lock without a PIN. The session is unlocked
      // whatever this shell thinks, so the state file says so, and the next
      // power press locks again.
      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.writeState("unlocked")
      }
    }

    WlSessionLockSurface {
      color: Commons.Color.background

      LockView {
        anchors.fill: parent
        lock: root
      }
    }
  }

  // The PIN goes in on stdin and the pipe is closed behind it; it is never an
  // argument or a variable another process can read.
  Process {
    id: checkProc
    command: ["sudo", "-n", root.pinTool, "check"]
    stdinEnabled: true
    stdout: StdioCollector { id: checkOut; waitForEnd: true }

    onStarted: {
      checkProc.write(root.pendingPin + "\n")
      root.pendingPin = ""
      checkProc.stdinEnabled = false
    }

    // qmllint disable signal-handler-parameters
    onExited: function(code, status) {
      helperWatchdog.stop()
      checkProc.stdinEnabled = true
      root.authenticating = false
      root.pendingPin = ""
      if (!root.lockRequested) return
      var r = Lock.checkResult(code, checkOut.text)
      if (r.action === "unlock") root.finishUnlock()
      else if (r.action === "pause") root.enterPause(r.seconds, r.message)
      else root.failureMessage = r.message
      // A failure to ask may mean the account is not what the keypad assumed.
      if (r.action === "error") root.refreshAccount()
    }
    // qmllint enable signal-handler-parameters
  }

  // A helper that never answers must not leave the keys dead for good.
  Timer {
    id: helperWatchdog
    interval: 30000
    onTriggered: {
      if (checkProc.running) {
        checkProc.running = false
        root.authenticating = false
        root.failureMessage = "Could not check the PIN"
      }
      if (pinProc.running) {
        pinProc.running = false
        root.settingPin = false
        root.failureMessage = "Could not set the PIN"
      }
      root.pendingPin = ""
    }
  }

  Timer {
    id: pauseTimer
    interval: 120000
    onTriggered: {
      root.paused = false
      root.failureMessage = ""
    }
  }

  // The PIN goes in on stdin and the pipe is closed behind it; it is never an
  // argument or a variable another process can read.
  Process {
    id: pinProc
    command: ["sudo", "-n", root.pinTool, "first"]
    stdinEnabled: true
    stderr: StdioCollector { id: pinErr; waitForEnd: true }

    onStarted: {
      pinProc.write(root.pendingPin + "\n")
      root.pendingPin = ""
      pinProc.stdinEnabled = false
    }

    // qmllint disable signal-handler-parameters
    onExited: function(code, status) {
      helperWatchdog.stop()
      root.settingPin = false
      root.pendingPin = ""
      pinProc.stdinEnabled = true
      if (code === 0) {
        root.accountMode = "pin"
        root.logEvent("first-pin-set")
        root.finishUnlock()
        return
      }
      var lines = String(pinErr.text || "").trim().split("\n")
      root.failureMessage = lines[lines.length - 1].replace(/^moarchy-pin: /, "") || "Could not set the PIN"
      root.refreshAccount()
    }
    // qmllint enable signal-handler-parameters
  }

  // What the account can do, in one line Lock.accountMode reads: `pin` once
  // moarchy-pin has set a PIN (its stamp is root's, so nothing the user runs
  // can fake or remove it), otherwise passwd's L, NP or P, all from
  // `moarchy-pin state` as root, since passwd has no setuid bit here and as
  // the user cannot read /etc/shadow. `norule` if sudo will not run it.
  Process {
    id: accountProc
    command: ["sh", "-c", "sudo -n \"$1\" state 2>/dev/null || echo norule", "sh", root.pinTool]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.accountMode = Lock.accountMode(text)
        root.probed = true
        root.logEvent("account=" + root.accountMode)
        if (root.startup !== "") root.handleStartup()
        if (root.lockQueued) {
          root.lockQueued = false
          if (root.lockable) root.beginLock()
        }
        root.recoverStrandedLock()
      }
    }
  }

  FileView {
    id: stateFile
    path: root.stateFilePath
    blockLoading: true
    blockWrites: true
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = String(text || "").trim()
        if (next !== root.backgroundPath) {
          root.backgroundPath = next
          root.backgroundVersion += 1
        }
      }
    }
  }

  Process {
    id: strandedLockCheckProc
    command: ["bash", "-c", "omarchy-hyprland-session-locked"]
    // qmllint disable signal-handler-parameters
    onExited: function(exitCode, status) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked && !root.lockRequested
      root.recoverStrandedLock()
    }
    // qmllint enable signal-handler-parameters
  }

  // Ten seconds on the lock screen with nothing touched turns the panel and the
  // touchscreen off. Not while a call rings, and not in setup mode, where the
  // person holding the phone is reading what it asks.
  IdleMonitor {
    id: idle
    enabled: root.locked && root.callState !== "ringing" && !root.setupMode
    timeout: 10
    respectInhibitors: false
    onIsIdleChanged: if (idle.isIdle && idle.enabled) root.runBlank()
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  Component.onCompleted: {
    refreshBackground()
    startup = Lock.startupAction(stateFile.text())
    refreshAccount()
    checkStrandedLock()
  }

  IpcHandler {
    target: "moarchy-lock"

    function lock(): string {
      if (!root.locked && !root.beginLock())
        return root.accountMode === "norule" ? "no-rule" : "no-pin"
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        account: root.accountMode,
        authenticating: root.busy,
        mode: root.mode,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    // The phone plugin's copy of its call, sent on every change whether or
    // not the session is locked, so a lock taken mid-call still shows Hang
    // up. `state` is ringing, active or none; `caller` is the contact's name
    // when the phone has one, else the number.
    function call(state: string, caller: string): string {
      var next = Lock.callState(state)
      root.callState = next
      root.caller = next === "" ? "" : String(caller || "")
      return "ok"
    }
  }
}
