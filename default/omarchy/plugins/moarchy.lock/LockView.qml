// What the lock surface draws: the time, a keypad, and a call when one is up.
//
// The keypad stays on screen during a call, under the call's buttons, so a
// call card that outlives its call (a lost message from the phone plugin) can
// never stand between the person holding the phone and the PIN.
//
// A keypad of its own for the reasons moarchy.sim gives, plus one that is this
// screen's alone: ext-session-lock hides the on-screen keyboard, so there is no
// other way to type here. The keys are the SIM screen's keys, 1-9 then
// backspace, 0 and OK, so the two PIN screens on this phone are one shape.
//
// The state lives in Service.qml; this reads it through `lock` and calls back
// into it, and keeps nothing a PIN could be read back out of.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import "../moarchy.common/Theme.js" as Theme
import "../moarchy.common" as Shared

Item {
  id: root

  property var lock: null

  // The lock layer has its own block in upstream's palette, the one its lock
  // screen draws with, so a theme that styles the lock styles this too (C1).
  readonly property color surface: Commons.Color.lock.background
  readonly property color textOnSurface: Commons.Color.lock.text
  readonly property color container: Util.alpha(Commons.Color.lock.text, 0.08)
  readonly property color containerHigh: Util.alpha(Commons.Color.lock.text, 0.14)
  readonly property color accent: Commons.Color.accent
  readonly property color textOnAccent: Commons.Color.background
  readonly property color danger: Commons.Color.lock.textError
  readonly property color scrim: Util.alpha(Commons.Color.background, 0.35)
  readonly property color subdued: Theme.readableOn(
    Qt.rgba(root.surface.r, root.surface.g, root.surface.b, 1), root.textOnSurface, 0.6, 4.5)

  readonly property int textWeight: Font.DemiBold
  Shared.UiFile { id: ui }
  readonly property int radiusTile: ui.radiusTile
  readonly property int radiusCard: ui.radiusCard

  readonly property bool onCall: !!root.lock && root.lock.callState !== ""
  readonly property bool keysLive: !!root.lock && !root.lock.busy && !root.lock.paused
  readonly property string prompt: {
    if (!root.lock) return ""
    if (root.lock.busy) return root.lock.setupMode ? "Setting the PIN" : "Checking"
    if (root.lock.setupMode) return root.lock.setupFirst === "" ? "Choose a PIN" : "Enter it again"
    return "Enter PIN"
  }

  property date now: new Date()

  // Same cache-busting as upstream's lock: a new query string makes Image
  // reload the file when the wallpaper changes while the phone is locked.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + (root.lock ? root.lock.backgroundVersion : 0)
  }

  Timer {
    interval: 1000
    repeat: true
    running: !!root.lock && root.lock.locked
    triggeredOnStart: true
    onTriggered: root.now = new Date()
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.lock && root.lock.locked ? root.fileUrl(root.lock.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: wallpaper.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
    }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }
  }

  // ------------------------------------------------------------------ time
  // Not during a call: the card needs the height, and the call is the news.
  Column {
    visible: !root.onCall
    anchors.top: parent.top
    anchors.topMargin: Style.space(56)
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: Style.space(4)

    // Twice the largest token: the time is the one thing on this screen read
    // from arm's length, and no token is drawn for that distance.
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: Qt.formatTime(root.now, "HH:mm")
      color: root.textOnSurface
      font.family: Style.font.family
      font.pixelSize: Math.round(Style.font.displayLarge * 2)
      font.weight: root.textWeight
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: Qt.formatDate(root.now, "dddd d MMMM")
      color: root.textOnSurface
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.weight: root.textWeight
    }
  }

  // ------------------------------------------------------------------ card
  Rectangle {
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(32)
    anchors.horizontalCenter: parent.horizontalCenter
    width: Math.min(parent.width - Style.space(24), Style.space(320))
    height: body.implicitHeight + Style.space(40)
    radius: root.radiusCard
    color: root.surface

    Column {
      id: body
      anchors.centerIn: parent
      width: parent.width - Style.space(32)
      spacing: Style.space(10)

      // --------------------------------------------------- an incoming call
      Text {
        width: parent.width
        visible: root.onCall
        horizontalAlignment: Text.AlignHCenter
        text: root.lock && root.lock.callState === "call" ? "On call" : "Incoming call"
        color: root.subdued
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.weight: root.textWeight
      }

      Text {
        width: parent.width
        visible: root.onCall
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        // A contact's name is the one string here from outside the phone.
        textFormat: Text.PlainText
        text: root.lock ? (root.lock.caller || "Unknown") : ""
        color: root.textOnSurface
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.weight: root.textWeight
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.onCall
        spacing: Style.space(16)

        Shared.Pill {
          width: Style.space(120)
          height: Style.space(52)
          color: root.danger
          ink: root.textOnAccent
          pixelSize: Style.font.body
          text: root.lock && root.lock.callState === "call" ? "Hang up" : "Decline"
          onClicked: root.lock.hangUp()
        }

        Shared.Pill {
          width: Style.space(120)
          height: Style.space(52)
          visible: !!root.lock && root.lock.callState === "ringing"
          color: root.accent
          ink: root.textOnAccent
          pixelSize: Style.font.body
          text: "Answer"
          onClicked: root.lock.answer()
        }
      }

      // ------------------------------------------------------- the keypad
      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: root.prompt
        color: root.textOnSurface
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.weight: root.textWeight
      }

      Text {
        width: parent.width
        visible: !!root.lock && root.lock.setupMode
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: "6 to 12 digits. It unlocks the phone from now on."
        color: root.subdued
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.weight: root.textWeight
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(9)
        height: Style.space(22)

        Repeater {
          model: root.lock ? Math.max(root.lock.pinMin, root.lock.entered.length) : 0
          Rectangle {
            required property int index
            width: Style.space(11)
            height: Style.space(11)
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: index < root.lock.entered.length ? root.accent : root.containerHigh
          }
        }
      }

      Text {
        width: parent.width
        visible: !!root.lock && root.lock.failureMessage !== ""
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.lock ? root.lock.failureMessage : ""
        color: root.danger
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.weight: root.textWeight
      }

      Grid {
        anchors.horizontalCenter: parent.horizontalCenter
        columns: 3
        spacing: Style.space(10)

        Repeater {
          model: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "OK"]

          Rectangle {
            id: key
            required property string modelData

            readonly property bool isOk: modelData === "OK"
            readonly property bool isBack: modelData === "⌫"
            readonly property bool enabledKey: root.keysLive
              && (key.isBack ? root.lock.entered.length > 0
                : key.isOk ? root.lock.entered.length >= root.lock.pinMin
                : root.lock.entered.length < root.lock.pinMax)

            width: Style.space(64)
            height: Style.space(52)
            radius: root.radiusTile
            opacity: key.enabledKey ? 1 : 0.35
            color: key.isOk ? root.accent : root.container

            Shared.PressVeil {
              anchors.fill: parent
              radius: parent.radius
              ink: key.isOk ? root.textOnAccent : root.textOnSurface
              on: tap.pressed
            }

            Text {
              anchors.centerIn: parent
              text: key.modelData
              color: key.isOk ? root.textOnAccent : root.textOnSurface
              font.family: Style.font.family
              font.pixelSize: key.isOk || key.isBack ? Style.font.iconLarge : Style.font.display
              font.weight: root.textWeight
            }

            MouseArea {
              id: tap
              anchors.fill: parent
              enabled: key.enabledKey
              onClicked: {
                if (key.isOk) root.lock.submit()
                else if (key.isBack) root.lock.backspace()
                else root.lock.press(key.modelData)
              }
            }
          }
        }
      }
    }
  }
}
