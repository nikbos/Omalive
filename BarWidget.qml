import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar widget for OmaLive. A single film glyph whose color reflects state:
//   accent  = screensaver is showing
//   amber   = wallpaper is playing (live)
//   muted   = wallpaper is frozen or off
// A click opens the control panel; a right-click flips between playing and
// frozen (the Sonoma flourish in reverse is a keybind-friendly toggle).
BarWidget {
    id: root

    readonly property string pluginId: "omalive"
    readonly property var service: (bar && bar.shell) ? bar.shell.serviceFor(pluginId) : null
    property bool opened: false
    readonly property bool hasVideo: !!service && service.enabled === true && service.rendering === true
    readonly property bool isScreensaver: hasVideo && service.screensaverActive === true
    readonly property bool isPlaying: hasVideo && !isScreensaver && service.wallpaperFrozen !== true
    readonly property color warningColor: "#e5c07b"
    readonly property color iconColor: !service ? Color.muted : hasVideo ? (isScreensaver ? Color.accent : isPlaying ? warningColor : Color.muted) : Color.muted
    readonly property string glyph: "󰕧" // nf-md-video
    readonly property string screenName: {
        var w = button.QsWindow ? button.QsWindow.window : null;
        return w && w.screen ? String(w.screen.name || "") : "";
    }

    function open() {
        opened = true;
    }

    function close() {
        opened = false;
    }

    function toggle() {
        opened = !opened;
    }

    // ---- control helpers (direct service call, IPC fallback) ---------------
    function playPath(p) {
        if (service)
            service.applyPlay(p);
        else
            ipc("play", p);
    }

    function playAll(p) {
        if (service)
            service.applyPlayAll(p);
        else
            ipc("playAll", p);
    }

    function playPathOn(screen, p) {
        if (service)
            service.applySetScreenVideo(screen, p);
        else
            ipc("playOn", screen, p);
    }

    function offScreen(screen) {
        if (service)
            service.applySetScreenVideo(screen, "");
        else
            ipc("playOn", screen, "");
    }

    function togglePlayPause() {
        if (!service) {
            ipc("toggle");
            return ;
        }
        if (service.screensaverActive) {
            service.exitScreensaver();
            return ;
        }
        if (service.wallpaperFrozen)
            service.applyPlay("");
        else
            service.applyFreeze();
    }

    function freezeNow() {
        if (service)
            service.applyFreeze();
        else
            ipc("freeze");
    }

    function setLiveWallpaper(on) {
        if (service)
            service.setLiveWallpaper(on);
        else
            ipc("setLiveWallpaper", on ? "true" : "false");
    }

    function setScreensaver(on) {
        if (service)
            service.applySetScreensaverEnabled(on);
        else
            ipc("screensaver", on ? "forceon" : "forceoff");
    }

    function ipc(fn) {
        var cfgPath = (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell";
        var cmd = ["qs", "-p", cfgPath, "ipc", "call", "omalive", fn];
        for (var i = 1; i < arguments.length; i++) {
            var a = arguments[i];
            cmd.push(a === undefined || a === null ? "" : String(a));
        }
        Quickshell.execDetached(cmd);
    }

    moduleName: "omalive"
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarIconButton {
        id: button

        anchors.fill: parent
        bar: root.bar
        text: root.glyph
        tooltipText: "OmaLive"
        useActiveColor: false
        foreground: root.iconColor
        onPressed: function(b) {
            if (b === Qt.RightButton)
                root.togglePlayPause();
            else
                root.toggle();
        }
    }

    KeyboardPanel {
        id: kpanel

        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: kpanel.fittedContentWidth(Style.space(320))
        contentHeight: kpanel.fittedContentHeight(contentLoader.item ? contentLoader.item.implicitHeight : Style.space(200))

        PanelKeyCatcher {
            id: keyCatcher

            anchors.fill: parent
            blocked: contentLoader.item ? contentLoader.item.keysBlocked : false
            onCloseRequested: root.close()

            Loader {
                id: contentLoader

                anchors.fill: parent
                source: "Panel.qml"
                onLoaded: {
                    if (!item)
                        return ;

                    item.widget = root;
                    item.bar = root.bar;
                }
            }

        }

    }

}
