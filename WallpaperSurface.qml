import QtMultimedia
import QtQuick
import Quickshell
import Quickshell.Wayland

// Background-layer video surface for OmaLive — the desktop wallpaper. Normally
// paused at a frozen frame; the service plays/decels/freezes it via playRequest
// and the rate bindings. The video fades in/out with `opacityVisible`; the
// window itself is always mapped and transparent so hiding is cheap. One
// instance per monitor with an assigned clip.
PanelWindow {
    id: surface

    required property var modelData
    // Injected by the service.
    property var owner: null
    property string monName: ""
    property string clipUrl: ""
    property bool playRequest: false
    property bool blocked: false // pauseOnFullscreen && this monitor fullscreen
    property real rate: 1
    property bool opacityVisible: true
    readonly property bool shouldPlay: playRequest && !blocked && clipUrl !== ""
    // A seek requested before the media finished loading; applied once the
    // player reports seekable (see applySeek + onSeekableChanged).
    property int pendingSeek: -1

    function sync() {
        if (clipUrl === "") {
            if (player.playbackState === MediaPlayer.PlayingState)
                player.pause();

            return ;
        }
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

    function duration() {
        return player.duration;
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

    function pause() {
        if (player.playbackState === MediaPlayer.PlayingState)
            player.pause();

    }

    function play() {
        if (clipUrl !== "" && player.playbackState !== MediaPlayer.PlayingState)
            player.play();

    }

    // Park on the exact frame the service wants (the frozen wallpaper).
    function freezeAt(ms) {
        if (clipUrl === "")
            return ;

        if (player.source !== clipUrl)
            player.source = clipUrl;

        surface.applySeek(ms);
        player.pause();
    }

    // Start playing from a given position (login flourish, live mode).
    function playFrom(ms) {
        if (clipUrl === "")
            return ;

        if (player.source !== clipUrl)
            player.source = clipUrl;

        surface.applySeek(ms);
        player.play();
    }

    // Capture the currently displayed frame to a PNG. Used by the lock screen
    // so it can show the exact aerial frame the instant its surface maps,
    // before the live video fades in and continues. Calls `cb(path)` with the
    // saved path, or "" when the grab/save failed.
    function captureFrame(path, cb) {
        if (typeof cb !== "function" || surface.width <= 0 || surface.height <= 0)
            return ;

        // Cap the grab resolution so the PNG is small and the lock screen can
        // display it instantly (a full 4K frame is ~6MB and would flash the
        // dark background while it loads). 1280px is plenty for a brief frozen
        // frame that is then replaced by the live video.
        var w = surface.width, h = surface.height, m = Math.max(w, h);
        if (m > 1024) {
            var s = 1024 / m;
            w = Math.round(w * s);
            h = Math.round(h * s);
        }
        var grab = out.grabToImage(function(result) {
            cb(result && result.saveToFile(path) ? path : "");
        }, Qt.size(w, h));
        if (!grab)
            cb("");
    }

    screen: modelData
    visible: true
    color: "transparent"
    updatesEnabled: true
    WlrLayershell.namespace: "omalive-background"
    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    onClipUrlChanged: {
        if (clipUrl === "") {
            player.stop();
            player.source = "";
        } else {
            player.source = clipUrl;
        }
    }
    onRateChanged: {
        if (player.source !== "") {
            player.playbackRate = rate;
        }
    }
    onShouldPlayChanged: sync()
    onBlockedChanged: sync()
    Component.onCompleted: {
        sync();
        if (surface.owner)
            surface.owner.registerWallpaperSurface(surface);

    }
    Component.onDestruction: {
        if (surface.owner) {
            surface.owner.unregisterWallpaperSurface(surface);
        }
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    Item {
        id: fadeRoot

        anchors.fill: parent
        opacity: surface.opacityVisible ? 1 : 0

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
                console.warn("omalive: wallpaper player error on", surface.monName, ":", str);

        }

    }

}
