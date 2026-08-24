import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dropdown content for the OmaLive bar widget. Loaded (by string URL) into
// BarWidget.qml's KeyboardPanel, so this is plain content — open/close and IPC
// coordination live in BarWidget.qml. All state reads and mutations go through
// `widget` (the BarWidget), which owns the service handle.
Item {
    id: panel

    property var widget: null
    property QtObject bar: null
    readonly property var service: widget ? widget.service : null
    readonly property bool keysBlocked: screenDropdown.popupOpen
    readonly property color fg: bar ? bar.foreground : Color.foreground
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
    readonly property color dim: Qt.darker(fg, 1.5)
    // ---- screen scope ------------------------------------------------------
    property string scope: "all"
    readonly property bool multiScreen: Quickshell.screens.length > 1
    readonly property string videoPath: {
        if (!service)
            return "";

        if (scope === "all")
            return String(service.videoPath || "");

        return String(service.configuredPathForScreen(scope) || "");
    }
    readonly property string videoName: videoPath !== "" ? plainName(videoPath.split("/").pop()) : ""
    readonly property bool videoExists: !!service && videoPath !== "" && service.pathExists(videoPath)
    readonly property string stateText: {
        if (!service)
            return "Service unavailable";

        if (videoPath === "")
            return scope === "all" ? "No video selected" : "Screen off";

        if (!videoExists)
            return "File missing";

        if (!service.enabled)
            return "Stopped";

        if (service.screensaverActive)
            return "Screensaver";

        if (service.wallpaperFrozen)
            return "Frozen";

        if (service.liveWallpaper)
            return "Live";

        return "Playing";
    }
    readonly property string metaText: {
        if (scope === "all" && screensDiffer)
            return stateText + "  ·  set per screen";

        return stateText + (videoName !== "" ? "  ·  " + videoName : "");
    }
    readonly property bool isPlaying: !!service && service.enabled && service.rendering === true && !service.screensaverActive && service.wallpaperFrozen !== true
    readonly property bool isFrozen: !!service && service.enabled && !service.screensaverActive && service.wallpaperFrozen === true
    readonly property bool screensDiffer: {
        if (!service || !multiScreen)
            return false;

        var s = Quickshell.screens;
        var first = null;
        for (var i = 0; i < s.length; i++) {
            var p = String(service.configuredPathForScreen(String(s[i].name)) || "");
            if (first === null)
                first = p;
            else if (p !== first)
                return true;
        }
        return false;
    }
    readonly property var screenOptions: {
        var o = [{
            "value": "all",
            "label": "All screens"
        }];
        var s = Quickshell.screens;
        for (var i = 0; i < s.length; i++) {
            var n = String(s[i].name);
            var p = service ? String(service.configuredPathForScreen(n) || "") : "";
            o.push({
                "value": n,
                "label": n + " · " + (p === "" ? "off" : plainName(p.split("/").pop()))
            });
        }
        return o;
    }
    // ---- video discovery ---------------------------------------------------
    readonly property int scanLimit: 500
    readonly property int entryLimit: 20000
    readonly property int scanSeconds: 5
    property bool videosTruncated: false
    property var videos: []
    readonly property string scanScript: 'lim=$1; emax=$2\n' + 'for d in "$3" "$HOME/Videos/Wallpapers" "$HOME/Videos"; do\n' + '  [ -d "$d" ] || continue\n' + '  entries=$(ls -U -1 -- "$d" 2>/dev/null | head -n "$emax")\n' + '  [ -n "$entries" ] || continue\n' + '  if [ "$(printf "%s\\n" "$entries" | wc -l)" -ge "$emax" ]; then\n' + '    printf "TRUNC\\n" >&2\n' + '  fi\n' + '  printf "%s\\n" "$entries" |\n' +
    '    grep -iE "\\.(mp4|mkv|webm|mov|avi)$" | grep -viE "\\.opt\\.mp4$" | head -n "$lim" |\n' +
    '    while IFS= read -r f; do\n' + '      [ -f "$d/$f" ] && printf "%s/%s\\n" "$d" "$f"\n' + '    done\n' + 'done | sort -u | head -n "$lim"\n'
    readonly property string videoDirResolved: service ? service.resolvePath(service.videoDir || "~/Videos/Aerial") : "~/Videos/Aerial"

    function scopeValid() {
        if (panel.scope === "all")
            return true;

        var s = Quickshell.screens;
        for (var i = 0; i < s.length; i++) if (String(s[i].name) === panel.scope) {
            return true;
        }
        return false;
    }

    function resetScope() {
        var own = panel.widget ? String(panel.widget.screenName || "") : "";
        panel.scope = (panel.multiScreen && panel.screensDiffer && own !== "") ? own : "all";
    }

    function plainName(s) {
        return String(s).replace(/[<>]/g, "");
    }

    function rescan() {
        scanProc.running = true;
    }

    onScopeChanged: {
        if (!scopeValid())
            scope = "all";

    }
    Component.onCompleted: {
        rescan();
        resetScope();
    }
    implicitWidth: Style.space(320)
    implicitHeight: col.implicitHeight

    Connections {
        function onOpenedChanged() {
            if (!panel.widget || !panel.widget.opened)
                return ;

            panel.rescan();
            panel.resetScope();
        }

        target: panel.widget || null
    }

    Process {
        id: scanProc

        command: ["timeout", "-k", "1", String(panel.scanSeconds), "bash", "-c", panel.scanScript, "_", String(panel.scanLimit + 1), String(panel.entryLimit), panel.videoDirResolved]
        onExited: function(code) {
            if (code !== 0)
                panel.videosTruncated = true;

        }

        stderr: StdioCollector {
            onStreamFinished: {
                if (String(text || "").indexOf("TRUNC") !== -1)
                    panel.videosTruncated = true;

            }
        }

        stdout: StdioCollector {
            onStreamFinished: {
                var seen = ({
                });
                var list = [];
                panel.videosTruncated = false;
                var lines = String(text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].trim();
                    if (!p || seen[p])
                        continue;

                    seen[p] = true;
                    if (list.length >= panel.scanLimit) {
                        panel.videosTruncated = true;
                        break;
                    }
                    list.push({
                        "path": p,
                        "name": p.split("/").pop()
                    });
                }
                panel.videos = list;
            }
        }

    }

    Column {
        id: col

        width: parent.width
        spacing: Style.spacing.panelGap

        PanelHero {
            width: parent.width
            title: "OmaLive"
            detail: panel.multiScreen && panel.scope !== "all" ? panel.scope : ""
            meta: panel.metaText
            foreground: panel.fg
            fontFamily: panel.fontFamily

            iconComponent: Component {
                Text {
                    textFormat: Text.PlainText
                    text: "󰕧"
                    color: panel.widget ? panel.widget.iconColor : panel.fg
                    font.family: panel.fontFamily
                    font.pixelSize: Style.font.display
                }

            }

        }

        // ---------- transport ----------
        Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            Button {
                id: playBtn

                foreground: panel.fg
                fontFamily: panel.fontFamily
                iconText: "󰐊"
                text: "Play"
                bordered: true
                onClicked: {
                    if (panel.widget)
                        panel.widget.playPath("");

                }
            }

            Button {
                id: freezeBtn

                foreground: panel.fg
                fontFamily: panel.fontFamily
                iconText: "󰏤"
                text: "Freeze"
                bordered: true
                onClicked: {
                    if (panel.widget)
                        panel.widget.freezeNow();

                }
            }

            Button {
                id: screenBtn

                foreground: panel.fg
                fontFamily: panel.fontFamily
                iconText: "󰙧"
                text: "Screensaver"
                bordered: true
                opacity: (panel.service && panel.service.screensaverActive) ? 1 : 0.6
                onClicked: {
                    if (panel.widget && panel.service) {
                        if (panel.service.screensaverActive)
                            panel.service.exitScreensaver();
                        else
                            panel.service.enterScreensaver();
                    }
                }
            }

        }

        // ---------- screen selector ----------
        Dropdown {
            id: screenDropdown

            visible: panel.multiScreen
            width: parent.width
            label: "SCREEN"
            options: panel.screenOptions
            value: panel.scope
            onChanged: function(v) {
                panel.scope = String(v);
            }
        }

        Text {
            textFormat: Text.PlainText
            visible: panel.multiScreen && panel.scope === "all" && panel.screensDiffer
            width: parent.width
            text: "Screens are set individually — pick one above to change just it."
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
        }

        // ---------- toggles ----------
        Toggle {
            width: parent.width
            label: "Screensaver"
            description: "Show aerial footage when idle"
            foreground: panel.fg
            checked: panel.service ? panel.service.screensaverEnabled === true : true
            onClicked: {
                if (panel.widget)
                    panel.widget.setScreensaver(checked);

            }
        }

        Toggle {
            width: parent.width
            label: "Live wallpaper"
            description: "Keep the wallpaper drifting instead of freezing"
            foreground: panel.fg
            checked: panel.service ? panel.service.liveWallpaper === true : false
            onClicked: {
                if (panel.widget)
                    panel.widget.setLiveWallpaper(checked);

            }
        }

        Toggle {
            width: parent.width
            label: "Pause on fullscreen"
            description: "Pause while a window is fullscreen on that monitor"
            foreground: panel.fg
            checked: panel.service ? panel.service.pauseOnFullscreen === true : true
            onClicked: {
                if (panel.widget && panel.service)
                    panel.service.setPauseOnFullscreen(checked);

            }
        }

        // ---------- transition length ----------
        PanelSlider {
            id: transitionSlider

            width: parent.width
            minimum: 1
            maximum: 6
            step: 1
            integer: true
            tickCount: 6
            value: panel.service ? Math.round((panel.service.effectiveTransitionMs || 2000) / 1000) : 2
            onReleased: function(v) {
                if (panel.service)
                    panel.service.setTransitionSeconds(Math.round(v));

            }
        }

        Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Freeze transition: " + Math.round(transitionSlider.liveValue) + "s"
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
        }

        // ---------- video library ----------
        PanelSeparator {
            foreground: panel.fg
        }

        PanelSectionHeader {
            text: !panel.multiScreen ? "VIDEOS" : (panel.scope === "all" ? "VIDEOS · ALL SCREENS" : "VIDEOS · " + panel.scope)
            foreground: panel.fg
            fontFamily: panel.fontFamily
        }

        Text {
            textFormat: Text.PlainText
            visible: panel.videos.length === 0
            width: parent.width
            text: "Drop clips in " + panel.videoDirResolved + " (or run: omalive fetch)"
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
        }

        ListView {
            id: videoList

            visible: panel.videos.length > 0 || panel.scope !== "all"
            width: parent.width
            height: Math.min(contentHeight, Style.space(240))
            clip: true
            spacing: Style.spacing.xxs
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            model: panel.videos

            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
            }

            header: Rectangle {
                id: offRow

                readonly property bool current: panel.videoPath === ""

                visible: panel.scope !== "all"
                width: videoList.width
                height: visible ? Style.spacing.controlHeight + videoList.spacing : 0
                color: "transparent"

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    height: Style.spacing.controlHeight
                    radius: Style.cornerRadius
                    color: offRow.current ? Style.selectedFillFor(panel.fg, Color.accent) : (offMouse.containsMouse ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent")

                    Text {
                        textFormat: Text.PlainText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.spacing.controlPaddingX
                        anchors.rightMargin: Style.spacing.controlPaddingX
                        text: "Off — static wallpaper"
                        color: offRow.current ? Style.selectedStateColor(panel.fg, Color.accent) : panel.dim
                        font.family: panel.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: offRow.current
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: offMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (panel.widget)
                                panel.widget.offScreen(panel.scope);

                        }
                    }

                }

            }

            delegate: Rectangle {
                id: vrow

                required property var modelData
                required property int index
                readonly property bool current: modelData.path === panel.videoPath

                width: videoList.width
                height: Style.spacing.controlHeight
                radius: Style.cornerRadius
                color: current ? Style.selectedFillFor(panel.fg, Color.accent) : (rowMouse.containsMouse ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent")

                Text {
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.right: playMark.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.spacing.controlPaddingX
                    anchors.rightMargin: Style.spacing.sm
                    text: vrow.modelData.name
                    color: vrow.current ? Style.selectedStateColor(panel.fg, Color.accent) : panel.fg
                    font.family: panel.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: vrow.current
                    elide: Text.ElideMiddle
                }

                Text {
                    id: playMark

                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.rightMargin: Style.spacing.controlPaddingX
                    visible: vrow.current
                    text: panel.isFrozen ? "󰏤" : "󰐊"
                    color: Style.selectedStateColor(panel.fg, Color.accent)
                    font.family: panel.fontFamily
                    font.pixelSize: Style.font.body
                }

                MouseArea {
                    id: rowMouse

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!panel.widget)
                            return ;

                        if (panel.scope === "all")
                            panel.widget.playAll(vrow.modelData.path);
                        else
                            panel.widget.playPathOn(panel.scope, vrow.modelData.path);
                    }
                }

            }

        }

        Text {
            textFormat: Text.PlainText
            visible: panel.videosTruncated
            width: parent.width
            text: "Showing the first " + panel.scanLimit + " clips. Play others with: omalive play <path>"
            color: panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
        }

    }

}
