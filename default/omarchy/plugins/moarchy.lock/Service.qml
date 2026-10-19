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
// This one reads /etc/pam.d/moarchy-lock and answers on its own IPC target,
// `moarchy-lock`, so the two never contend for one lock.
//
// When it locks: at session start, and whenever moarchy-system-lock asks (the
// power button, the idle timeout, Settings > Power > Lock). A shell restart
// must not lock an unlocked user, so unlocking leaves a marker in
// $XDG_RUNTIME_DIR, which is tmpfs and empty again after a reboot. Taking a
// lock removes it. moarchy-power-press reads the same marker to know a press
// on a locked phone only toggles the panel.
//
// Setup mode is the first boot. The image ships the account with a locked
// password (`passwd -S` says L), so there is no PIN to check; the lock surface
// asks for a new one twice and hands it to `moarchy-pin first` on stdin. There
// is no way past it without one.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: home + "/.local/state/omarchy/current/background"
  readonly property string unlockedMarker: (Quickshell.env("XDG_RUNTIME_DIR") || "/nonexistent") + "/moarchy/unlocked"

  // Absolute, for the reason moarchy.sim gives at length: a shell restarted
  // outside a login session can come up without /usr/lib/moarchy/bin on PATH.
  readonly property string pinTool: "/usr/lib/moarchy/bin/moarchy-pin"
  readonly property string screenTool: "/usr/lib/moarchy/bin/moarchy-screen"

  readonly property int pinMin: 6
  readonly property int pinMax: 12

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool pamConfigured: false
  property bool startupLockPending: false
  property bool authenticating: false
  property bool settingPin: false
  property bool setupMode: false
  property string setupFirst: ""
  property string entered: ""
  property string pendingPin: ""
  property string failureMessage: ""
  property bool lockoutSeen: false
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
    if (!strandedLock || locked || !pamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function maybeStartupLock() {
    if (!startupLockPending || !pamConfigured) return
    startupLockPending = false
    if (locked) return
    logEvent("lock-at-start")
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
    lockoutSeen = false
    authenticating = false
    if (pam.active) pam.abort()
  }

  function writeMarker(present) {
    if (present)
      Quickshell.execDetached(["sh", "-c", "mkdir -p \"${1%/*}\" && : >\"$1\"", "sh", root.unlockedMarker])
    else
      Quickshell.execDetached(["rm", "-f", root.unlockedMarker])
  }

  function beginLock() {
    if (!pamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    writeMarker(false)
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
    callState = ""
    caller = ""
    sessionLock.locked = false
    writeMarker(true)
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
    lockoutSeen = false
    authenticating = true

    if (!pam.start()) {
      authenticating = false
      pendingPin = ""
      failureMessage = "Could not check the PIN"
      return
    }

    Qt.callLater(respondToPrompt)
  }

  function respondToPrompt() {
    if (!authenticating || !pam.active || !pam.responseRequired) return
    // faillock announces a locked tally before pam_unix asks. Answering anyway
    // would count one more failure and push the pause out two more minutes.
    if (lockoutSeen) {
      authenticating = false
      pendingPin = ""
      Qt.callLater(function() { if (pam.active) pam.abort() })
      enterPause()
      return
    }
    pam.respond(pendingPin)
  }

  function enterPause() {
    entered = ""
    paused = true
    failureMessage = "Too many wrong PINs. Entry is paused for 2 minutes."
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
      // whatever this shell thinks, so the marker says so, and the next power
      // press locks again.
      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.callState = ""
        root.writeMarker(true)
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

  PamContext {
    id: pam
    config: "moarchy-lock"
    user: root.userName

    onResponseRequiredChanged: root.respondToPrompt()
    // faillock says "The account is locked due to 10 failed logins." as an
    // info message, not an error, before pam_unix prompts (measured against
    // pam_faillock on Arch with a stand-in for pam_unix).
    onPamMessage: {
      if (!pam.responseRequired && /\blocked\b/i.test(pam.message)) root.lockoutSeen = true
      root.respondToPrompt()
    }

    onCompleted: function(result) {
      if (!root.authenticating) return
      root.authenticating = false
      root.pendingPin = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else if (root.lockoutSeen) root.enterPause()
      else root.failureMessage = "Wrong PIN"
    }

    onError: function(error) {
      if (!root.authenticating) return
      root.authenticating = false
      root.pendingPin = ""
      root.failureMessage = "Could not check the PIN"
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
      root.settingPin = false
      root.pendingPin = ""
      pinProc.stdinEnabled = true
      if (code === 0) {
        root.setupMode = false
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

  // L is the image's locked password and NP an empty one: both are what
  // `moarchy-pin first` accepts, and neither has a PIN to check. Anything
  // unreadable stays on the PIN keypad, because the helper decides for itself
  // and a setup screen it refuses would be a phone nobody can open.
  Process {
    id: accountProc
    command: ["passwd", "-S", root.userName]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text || "").trim().split(/\s+/)[1] || ""
        root.setupMode = state === "L" || state === "NP"
        root.logEvent("account=" + (state || "unreadable"))
      }
    }
  }

  Process {
    id: markerProbe
    command: ["test", "-e", root.unlockedMarker]
    // qmllint disable signal-handler-parameters
    onExited: function(code, status) {
      if (code === 0) return
      root.startupLockPending = true
      root.maybeStartupLock()
    }
    // qmllint enable signal-handler-parameters
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
  // touchscreen off. Not while a call is up, and not in setup mode, where the
  // person holding the phone is reading what it asks.
  IdleMonitor {
    id: idle
    enabled: root.locked && root.callState === "" && !root.setupMode
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

  FileView {
    path: "/etc/pam.d/moarchy-lock"
    watchChanges: true
    printErrors: false
    onLoaded: root.pamConfigured = true
    onLoadFailed: root.pamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPamConfiguredChanged: {
    if (!pamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
    maybeStartupLock()
  }

  Component.onCompleted: {
    refreshBackground()
    markerProbe.running = true
    checkStrandedLock()
  }

  IpcHandler {
    target: "moarchy-lock"

    function lock(): string {
      if (!root.pamConfigured) return "missing-pam"
      if (!root.locked && !root.beginLock()) return "failed"
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
        passwordPam: root.pamConfigured,
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
      var next = state === "ringing" ? "ringing" : (state === "active" ? "call" : "")
      root.callState = next
      root.caller = next === "" ? "" : String(caller || "")
      return "ok"
    }
  }
}
