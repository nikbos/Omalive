// Lock face for the OmaLive lock screen. Same property/signal contract as the
// stock Omarchy LockView (Service.qml drives it unchanged) plus the OmaLive
// additions: `clipUrl`/`seekMs`/`screenName` and `positionSampled`.
//
// Background is the OmaLive aerial footage playing live (Sonoma style), with a
// light scrim so the password UI stays readable. When OmaLive has no clip for
// this screen or the player errors, it falls back to the stock blurred
// wallpaper — the lock is never a broken surface.

import QtMultimedia
import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false

  // ---- OmaLive additions --------------------------------------------------
  property string screenName: ""
  property string clipUrl: ""
  property int seekMs: 0
  property bool playerFailed: false
  // A seek requested before the media finished loading; applied once the
  // player reports seekable (see applySeek + onSeekableChanged).
  property int pendingSeek: -1
  readonly property bool videoReady: root.clipUrl !== "" && !root.playerFailed
  readonly property bool videoActive: root.loadBackground && root.videoReady

  // Lock service samples the player position while locked and hands it back
  // to OmaLive on unlock, so the wallpaper freezes on the exact last frame.
  signal positionSampled(string screenName, int ms)

  function syncVideo() {
    if (!root.videoReady) {
      if (lockPlayer.playbackState !== MediaPlayer.StoppedState)
        lockPlayer.stop()
      lockPlayer.source = ""
      return
    }
    if (root.loadBackground) {
      if (lockPlayer.source !== root.clipUrl)
        lockPlayer.source = root.clipUrl
      if (lockPlayer.playbackState !== MediaPlayer.PlayingState) {
        root.applySeek(root.seekMs)
        lockPlayer.play()
      }
    } else if (lockPlayer.playbackState === MediaPlayer.PlayingState) {
      lockPlayer.pause()
    }
  }

  // Seek immediately; if the media isn't seekable yet (source still loading),
  // remember the position and land it once the player reports seekable.
  function applySeek(ms) {
    root.pendingSeek = -1
    lockPlayer.position = ms
    if (!lockPlayer.seekable)
      root.pendingSeek = ms
  }

  onClipUrlChanged: {
    root.playerFailed = false
    root.syncVideo()
  }
  onLoadBackgroundChanged: root.syncVideo()
  onVideoReadyChanged: root.syncVideo()
  // -------------------------------------------------------------------------

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, root.outlineThickness, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    root.syncVideo()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    // OmaLive aerial footage — the live lock screen.
    VideoOutput {
      id: videoOut
      anchors.fill: parent
      fillMode: VideoOutput.PreserveAspectCrop
      visible: root.videoActive
    }

    // Stock wallpaper, shown when there is no footage to play.
    Image {
      id: wallpaper
      anchors.fill: parent
      visible: !root.videoActive
      source: root.loadBackground && !root.videoActive ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      visible: !root.videoActive
      autoPaddingEnabled: false
      blurEnabled: !root.videoActive && root.loadBackground && wallpaper.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    // Light scrim over the footage so the password UI stays readable.
    Rectangle {
      anchors.fill: parent
      visible: root.videoActive
      color: "black"
      opacity: root.videoActive ? 0.22 : 0

      Behavior on opacity {
        NumberAnimation { duration: 220; easing.type: Easing.InOutQuad }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    BorderSurface {
      id: inputField
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.round(parent.height * 0.08)
      color: Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "\u25CF"
        passwordMaskDelay: 0
        color: Color.lock.text
        selectionColor: Color.lock.selection
        selectedTextColor: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      Text {
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "Checking…" : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Color.lock.text : (root.failureMessage.length > 0 ? Color.lock.textError : Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }

  MediaPlayer {
    id: lockPlayer

    videoOutput: videoOut
    loops: MediaPlayer.Infinite
    onSeekableChanged: {
      if (lockPlayer.seekable && root.pendingSeek >= 0) {
        lockPlayer.position = root.pendingSeek
        root.pendingSeek = -1
      }
    }
    onErrorOccurred: function(err, str) {
      if (err !== MediaPlayer.NoError) {
        console.warn("omalive-lock: player error on", root.screenName, ":", str)
        root.playerFailed = true
      }
    }
  }

  // Position sampling for the unlock handoff: OmaLive parks the wallpaper on
  // the last frame the lock showed.
  Timer {
    interval: 250
    repeat: true
    running: root.videoActive && lockPlayer.playbackState === MediaPlayer.PlayingState
    onTriggered: root.positionSampled(root.screenName, lockPlayer.position)
  }
}
