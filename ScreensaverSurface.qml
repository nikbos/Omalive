import QtMultimedia
import QtQuick
import Quickshell
import Quickshell.Wayland

// Overlay-layer video surface for OmaLive — the aerial screensaver. Sits above
// all windows. When inactive the window is transparent and unmapped underneath
// (color flips to transparent so no black box lingers); when active the video
// fades in over black. On dismissal the service decelerates this player to a
// stop, captures its frozen frame, then parks it on the background layer as
// the wallpaper. One instance per monitor.
PanelWindow {
    id: surface

    required property var modelData
    // Injected by the service.
    property var owner: null
    property string monName: ""
    property string clipUrl: ""
    property bool active: false
    readonly property bool shouldPlay: active && clipUrl !== ""
    // A seek requested before the media finished loading; applied once the
    // player reports seekable (see applySeek + onSeekableChanged).
    property int pendingSeek: -1

    function sync() {
        if (shouldPlay) {
            if (player.source !== clipUrl)
                player.source = clipUrl;

            if (player.playbackState !== MediaPlayer.PlayingState)
                player.play();

        } else if (player.playbackState === MediaPlayer.PlayingState) {
            player.pause();
        }
    }

    function setRate(r) {
        if (player.source !== "")
            player.playbackRate = r;

    }

    function position() {
        return player.position;
    }

    // Seek immediately; if the media isn't seekable yet (source still loading),
    // remember the position and land it once the player reports seekable.
    function applySeek(ms) {
        surface.pendingSeek = -1;
        player.position = ms;
        if (!player.seekable)
            surface.pendingSeek = ms;
    }

    function seekTo(ms) {
        if (clipUrl !== "")
            surface.applySeek(ms);

    }

    function play() {
        if (clipUrl !== "" && player.playbackState !== MediaPlayer.PlayingState)
            player.play();

    }

    function pause() {
        if (player.playbackState === MediaPlayer.PlayingState)
            player.pause();

    }

    function freezeAt(ms) {
        if (clipUrl === "")
            return ;

        if (player.source !== clipUrl)
            player.source = clipUrl;

        surface.applySeek(ms);
        player.pause();
    }

    // Any pointer or key activity dismisses the screensaver. Required for
    // manual starts (menu / CLI): the system isn't idle then, so IdleMonitor
    // alone never fires the idle->active transition that ends an idle-start.
    // `primed` guards against the overlay firing one synthetic position sample
    // the moment it maps under the pointer.
    property bool primed: false
    function requestDismiss() {
        if (surface.owner)
            surface.owner.exitScreensaver();
    }

    screen: modelData
    property bool mapped: false
    visible: surface.mapped
    color: surface.active ? "black" : "transparent"
    updatesEnabled: true
    WlrLayershell.namespace: "omalive-screensaver"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: surface.active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    onClipUrlChanged: {
        // Warm the player as soon as a clip is configured so the first
        // screensaver entry is a fast seek+play, not a cold load (which would
        // hold a black surface for a beat). Mirrors the wallpaper surface.
        if (clipUrl === "") {
            player.stop();
            player.source = "";
        } else {
            player.source = clipUrl;
        }
        sync();
    }
    onActiveChanged: {
        sync();
        surface.primed = false;
        if (surface.active) {
            surface.mapped = true;
            unmapTimer.stop();
        } else {
            unmapTimer.restart();
        }
    }
    Component.onCompleted: {
        sync();
        if (surface.owner)
            surface.owner.registerScreensaverSurface(surface);

    }
    Component.onDestruction: {
        if (surface.owner) {
            surface.owner.unregisterScreensaverSurface(surface);
        }
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    Timer {
        id: unmapTimer

        interval: 250
        onTriggered: surface.mapped = false
    }

    Item {
        id: fadeRoot

        anchors.fill: parent
        opacity: surface.active ? 1 : 0

        VideoOutput {
            id: out

            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectCrop
        }

        Behavior on opacity {
            NumberAnimation {
                duration: 220
                easing.type: Easing.InOutQuad
            }

        }

    }

    // Grabs pointer and key activity while active so any real input dismisses
    // the screensaver (matching how a screensaver should behave; the window is
    // unmapped when inactive so this never eats desktop input). The first
    // position sample when the overlay maps under the pointer primes instead of
    // dismissing; only movement past it (or a press/click/key) dismisses.
    Item {
        anchors.fill: parent
        visible: surface.active
        focus: true

        Keys.onPressed: function(event) {
            surface.requestDismiss();
            event.accepted = true;
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            property real lastX: 0
            property real lastY: 0
            onPositionChanged: function(mouse) {
                if (!surface.primed) {
                    surface.primed = true;
                    lastX = mouse.x;
                    lastY = mouse.y;
                    return;
                }
                if (Math.abs(mouse.x - lastX) > 2 || Math.abs(mouse.y - lastY) > 2)
                    surface.requestDismiss();
                lastX = mouse.x;
                lastY = mouse.y;
            }
            onPressed: surface.requestDismiss()
            onClicked: surface.requestDismiss()
        }
    }

    MediaPlayer {
        id: player

        videoOutput: out
        loops: MediaPlayer.Infinite
        onSeekableChanged: {
            if (player.seekable && surface.pendingSeek >= 0) {
                player.position = surface.pendingSeek;
                surface.pendingSeek = -1;
            }
        }
        onErrorOccurred: function(err, str) {
            if (err !== MediaPlayer.NoError)
                console.warn("omalive: screensaver player error on", surface.monName, ":", str);

        }

    }

}
