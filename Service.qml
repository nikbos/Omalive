// OmaLive service plugin for omarchy-shell.
// A macOS Sonoma-style aerial screensaver + live wallpaper. Two layer-shell
// surfaces per monitor:
//   * WallpaperSurface  - Wayland background layer (namespace "omalive-background"),
//     normally PAUSED at a frozen frame. This is the desktop wallpaper. After a
//     login flourish it plays briefly and decelerates to a stop, leaving the
//     exact frame where the footage stopped.
//   * ScreensaverSurface - Wayland overlay layer (namespace "omalive-screensaver"),
//     above all windows. Shown when the system is idle; on dismissal the footage
//     decelerates over `transitionSeconds` and the frozen frame is handed back to
//     the wallpaper surface.
// Idle detection uses the same Quickshell IdleMonitor as omarchy's own idle
// service. The stock ttfx screensaver is suppressed at install time by writing
// the omarchy `screensaver-off` toggle; OmaLive then owns the screensaver.

import "Model.js" as Model
import QtMultimedia
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

// State model (mirrors Motion-Wallpaper):
//   * shell.json plugins[] entry for this id seeds videoPath/enabled/screenVideos
//     and carries the config-only options (transitionSeconds, pauseOnFullscreen,
//     liveWallpaper, shuffle, videoDir, flourishOnLogin).
//   * ~/.local/state/omalive/state.json is the runtime truth for videoPath,
//     enabled, screenVideos, screenPositions, frozenPosition and the config
//     options when changed from the panel/CLI. Atomic writes, survives restarts.
Item {
    id: root

    // ---- injected by shell.qml (_syncServices/ensureService) ----
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null
    property var pluginRegistry: null
    readonly property string pluginId: "omalive"
    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: home + "/.local/state/omalive"
    readonly property string statePath: stateDir + "/state.json"
    readonly property string togglesDir: home + "/.local/state/omarchy/toggles"
    readonly property string indicatorsDir: home + "/.local/state/omarchy/indicators"
    // ---------------------------------------------------------------- config
    readonly property var pluginConfig: {
        var cfg = shell && shell.shellConfig ? shell.shellConfig : null;
        if (!cfg || !Array.isArray(cfg.plugins))
            return ({
        });

        for (var i = 0; i < cfg.plugins.length; i++) {
            var e = cfg.plugins[i];
            if (e && String(e.id).replace(/^@/, "") === pluginId)
                return e;

        }
        return ({
        });
    }
    // ------------------------------------------------------------- bounds
    readonly property int maxStateBytes: 262144
    readonly property int maxPathLength: 4096
    readonly property int maxScreenVideos: 64
    readonly property int maxNameLength: 256
    readonly property int helperSeconds: 5
    readonly property var timeoutPrefix: ["timeout", "-k", "1", String(root.helperSeconds)]
    // Descriptor-bound state read. The open is O_NOFOLLOW (a symlink cannot be
    // followed), then type/owner/size are validated on the opened descriptor
    // and the content is read through that same descriptor — there is no
    // separate check-then-read window for an attacker to race (state.json lives
    // under a predictable, user-writable path).
    readonly property string stateReadScript:
        "import os, stat, sys\n" +
        "p = sys.argv[1]; limit = int(sys.argv[2])\n" +
        "try:\n" +
        "    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)\n" +
        "except OSError:\n" +
        "    sys.exit(0)\n" +
        "try:\n" +
        "    st = os.fstat(fd)\n" +
        "    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():\n" +
        "        sys.exit(0)\n" +
        "    if st.st_size > limit:\n" +
        "        sys.exit(0)\n" +
        "    data = os.read(fd, limit + 1)\n" +
        "    if len(data) > limit:\n" +
        "        sys.exit(0)\n" +
        "    sys.stdout.write(data.decode('utf-8', 'replace'))\n" +
        "finally:\n" +
        "    os.close(fd)\n"
    // Descriptor-bound state write (mirrors the read). The payload arrives on
    // stdin (never argv — argv caps per-argument at ~128KiB), written to a
    // fresh mkstemp file in the state directory, fsynced, then atomically
    // renamed over the target (os.replace replaces any symlink there, it never
    // writes through one), and finally re-opened O_NOFOLLOW and validated on
    // the descriptor (regular file, our uid, exact size) before the result is
    // accepted. The mkstemp+rename leaves no check-then-use window for an
    // attacker to redirect the write.
    readonly property string stateWriteScript:
        "import os, stat, sys, tempfile\n" +
        "p = sys.argv[1]; want = int(sys.argv[2])\n" +
        "d = os.path.dirname(p) or '.'\n" +
        "try:\n" +
        "    data = sys.stdin.buffer.read(want)\n" +
        "    if len(data) != want:\n" +
        "        raise ValueError('short read')\n" +
        "    os.makedirs(d, exist_ok=True)\n" +
        "    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(p) + '.', dir=d)\n" +
        "    try:\n" +
        "        with os.fdopen(fd, 'wb') as f:\n" +
        "            f.write(data)\n" +
        "            f.flush()\n" +
        "            os.fsync(f.fileno())\n" +
        "        os.replace(tmp, p)\n" +
        "    except BaseException:\n" +
        "        os.unlink(tmp)\n" +
        "        raise\n" +
        "    vfd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)\n" +
        "    try:\n" +
        "        st = os.fstat(vfd)\n" +
        "    finally:\n" +
        "        os.close(vfd)\n" +
        "    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size != want:\n" +
        "        os.unlink(p)\n" +
        "        sys.exit(1)\n" +
        "except (OSError, ValueError):\n" +
        "    sys.exit(1)\n"
    // Descriptor-bound atomic install for a file (used for the lock frozen-frame
    // PNG). The source is validated on an O_NOFOLLOW descriptor (regular file,
    // our uid, under the byte cap), moved over the destination with os.replace
    // (rename replaces any pre-existing symlink at the destination, it never
    // writes through one), then the destination is re-opened O_NOFOLLOW and
    // re-validated. Prints the destination on success; the source is cleaned up
    // on any failure.
    readonly property string atomicInstallScript:
        "import os, stat, sys\n" +
        "src = sys.argv[1]; dst = sys.argv[2]; cap = int(sys.argv[3])\n" +
        "try:\n" +
        "    sfd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)\n" +
        "    try:\n" +
        "        st = os.fstat(sfd)\n" +
        "        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > cap:\n" +
        "            os.unlink(src)\n" +
        "            sys.exit(1)\n" +
        "    finally:\n" +
        "        os.close(sfd)\n" +
        "    os.replace(src, dst)\n" +
        "    vfd = os.open(dst, os.O_RDONLY | os.O_NOFOLLOW)\n" +
        "    try:\n" +
        "        vst = os.fstat(vfd)\n" +
        "    finally:\n" +
        "        os.close(vfd)\n" +
        "    if not stat.S_ISREG(vst.st_mode) or vst.st_uid != os.getuid():\n" +
        "        os.unlink(dst)\n" +
        "        sys.exit(1)\n" +
        "    sys.stdout.write(dst)\n" +
        "except OSError:\n" +
        "    try:\n" +
        "        os.unlink(src)\n" +
        "    except OSError:\n" +
        "        pass\n" +
        "    sys.exit(1)\n"
    // ---------------------------------------------------------------- config
    // Config-only options. `transitionSeconds` is the deceleration length; the
    // login flourish plays the footage for a beat and then decelerates to a stop.
    readonly property int transitionMs: clampInt(cfg("transitionSeconds", 2), 1, 10, 2) * 1000
    property bool pauseOnFullscreen: cfg("pauseOnFullscreen", true) === true || String(cfg("pauseOnFullscreen", "true")) === "true"
    property bool liveWallpaper: cfg("liveWallpaper", false) === true || String(cfg("liveWallpaper", "false")) === "true"
    property bool shuffle: cfg("shuffle", true) === true || String(cfg("shuffle", "true")) === "true"
    property bool flourishOnLogin: cfg("flourishOnLogin", true) === true || String(cfg("flourishOnLogin", "true")) === "true"
    // Stop transitions (screensaver dismissal, unlock/login flourish):
    // default plays the footage at normal speed for `stopDelaySeconds` then
    // freezes it on the spot; `glideToStop: true` restores the old Sonoma
    // deceleration over `transitionSeconds` instead.
    property bool glideToStop: cfg("glideToStop", false) === true || String(cfg("glideToStop", "false")) === "true"
    property int stopDelayMs: clampInt(cfg("stopDelaySeconds", 2), 0, 10, 2) * 1000
    property string videoDir: cfg("videoDir", "~/Videos/Aerial")
    // Slow drift speed for live-wallpaper mode; configurable via shell.json
    // liveRate (clamped 0.1–2.0, default 0.35).
    property real liveRate: (function() {
        var v = parseFloat(cfg("liveRate", 0.35));
        return isFinite(v) ? Math.max(0.1, Math.min(2, v)) : 0.35;
    })()
    readonly property int shuffleIntervalMs: 300000
    // Idle timeout mirrors omarchy's own idle service (shell.json idle.screensaver).
    readonly property int idleScreensaverSeconds: (function() {
        var idle = shell && shell.shellConfig && shell.shellConfig.idle ? shell.shellConfig.idle : null;
        var v = idle ? parseInt(idle.screensaver, 10) : NaN;
        return isFinite(v) && v > 0 ? v : 150;
    })()
    // ---------------------------------------------------------------- state
    // Runtime truth. Seeded from the shell.json plugins[] entry on first run and
    // re-seeded when that entry is edited; mutated by IPC/panel thereafter.
    property string videoPath: ""
    property bool enabled: true
    property bool manualPaused: false
    property var screenVideos: ({
    }) // { "HDMI-A-1": "/path/clip.mp4" | "" }
    property var screenPositions: ({
    }) // { "HDMI-A-1": 12345 } frozen frame positions
    property int frozenPosition: 0 // ms; where the default clip froze
    property var lockFramePaths: ({
    }) // { "DP-1": "/…/lockframe-DP-1.png" } frozen-frame captures for the lock screen
    // Byte cap for a captured lock-frame PNG (a 2560×1440 frame is ~6 MB; the
    // cap is generous but bounded so a hostile capture can never exhaust disk).
    readonly property int maxLockFrameBytes: 268435456
    // Serialized atomic-install queue for lock-frame PNGs (one python helper at
    // a time) plus a fire-and-forget temp-file cleanup queue.
    property var _pendingAtomicInstalls: []
    property var _atomicInstallJob: null
    property int _atomicInstallSeq: 0
    property string _pendingAtomicTemp: ""
    property string _pendingAtomicFinal: ""
    property var _pendingAtomicCb: null
    property var _rmQueue: []
    property bool _stateLoaded: false
    property bool _stateStreamDone: false // state.json stream finished (guards the read fallback)
    property string _seedSig: ""
    // Runtime display state.
    property bool wallpaperFrozen: true
    // desktop wallpaper is a paused frame
    property bool wallpaperVisible: true
    // opacity gate on the background surfaces
    property bool screensaverActive: false
    // overlay surfaces shown + playing
    property bool flourishActive: false
    property bool decelActive: false
    property bool locked: false
    property bool wallpaperFollowingLock: false // wallpaper tracks the lock screen (Sonoma continuity)
    property bool screensaverEnabled: true // OmaLive's own screensaver toggle
    property bool screensaverOffFlag: false // omarchy's screensaver-off indicator
    property bool stayAwake: false // omarchy stay-awake indicator
    property string _decelTarget: "screensaver" // which surface set to ramp
    property real _decelProgress: 0
    property bool _pendingInitialFlourish: false
    // Live service handles registered by the surface components.
    property var wallpaperSurfaces: []
    property var screensaverSurfaces: []
    property bool _surfacesReady: false
    // Shuffle library (bounded scan of the configured video dir).
    property var clips: []
    property bool clipsTruncated: false
    readonly property int scanLimit: 500
    readonly property int entryLimit: 20000
    readonly property int scanSeconds: 5
    // ------------------------------------------------------- file existence
    property var existingPaths: ({
    })
    readonly property bool videoFileExists: pathExists(videoPath)
    property var activeScreens: {
        var out = [];
        if (!root.enabled)
            return out;

        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) {
            var s = screens[i];
            if (root.urlForScreen(String(s.name)) !== "")
                out.push(s);

        }
        return out;
    }
    readonly property bool rendering: activeScreens.length > 0
    // Wallpaper playback request, global (per-monitor fullscreen ANDs in-surface).
    readonly property bool wallpaperPlayRequest: root.enabled && root.wallpaperVisible && !root.manualPaused && !root.wallpaperFrozen
    property int transitionMsOverride: -1
    readonly property int effectiveTransitionMs: root.transitionMsOverride >= 0 ? root.transitionMsOverride : root.transitionMs
    property string _pendingState: ""
    // ------------------------------------------- flags (screensaver/stay-awake)
    // The omarchy `screensaver-off` toggle suppresses the stock ttfx screensaver;
    // OmaLive's own screensaver is gated by `omalive-screensaver-off`. stay-awake
    // disables auto-screensaver just like it disables omarchy's idle.
    readonly property string flagsScript: 'd="$HOME/.local/state/omarchy/toggles"; i="$HOME/.local/state/omarchy/indicators"; ' + 'printf "off=%s\\n" "$([ -f "$d/screensaver-off" ] && echo 1 || echo 0)"; ' + 'printf "omalive=%s\\n" "$([ -f "$d/omalive-screensaver-off" ] && echo 1 || echo 0)"; ' + 'printf "stayawake=%s\\n" "$([ -f "$i/stay-awake" ] && echo 1 || echo 0)";'
    // ------------------------------------------------------- idle detection
    // Same mechanism as omarchy's own idle service: the compositor's idle notify
    // protocol, honouring inhibitors, at the configured screensaver timeout.
    readonly property bool idleEnabled: root.screensaverEnabled && !root.stayAwake
    // ------------------------------------------------------- fullscreen watch
    property var fullscreenMonitors: ({
    })
    readonly property string fsScript: "import json,subprocess\n" + "def q(c):\n" + "    return json.loads(subprocess.check_output(['hyprctl','-j',c]))\n" + "try:\n" + "    mons=q('monitors'); wss=q('workspaces')\n" + "    fs={w.get('id'): bool(w.get('hasfullscreen')) for w in wss}\n" + "    for m in mons:\n" + "        aw=m.get('activeWorkspace') or {}\n" + "        if fs.get(aw.get('id')):\n" + "            print(m.get('name'))\n" + "except Exception:\n" + "    pass\n"
    // ------------------------------------------------------- clip library (shuffle)
    // Bounded scan of the configured video dir, same triple-cap as the panel:
    // entries examined, matches held, wall-clock time. Hostile filenames are
    // plain text and never parsed as rich text anywhere.
    readonly property string scanScript: 'lim=$1; emax=$2; d=$3\n' + '[ -d "$d" ] || exit 0\n' + 'entries=$(ls -U -1 -- "$d" 2>/dev/null | head -n "$emax")\n' + '[ -n "$entries" ] || exit 0\n' + 'if [ "$(printf "%s\\n" "$entries" | wc -l)" -ge "$emax" ]; then printf "TRUNC\\n" >&2; fi\n' + 'printf "%s\\n" "$entries" |\n' + '  grep -iE "\\.(mp4|mkv|webm|mov|avi)$" | grep -viE "\\.opt\\.mp4$" | head -n "$lim" |\n' + '  while IFS= read -r f; do\n' + '    [ -f "$d/$f" ] && printf "%s/%s\\n" "$d" "$f"\n' + '  done | sort -u | head -n "$lim"\n'

    function cfg(name, fallback) {
        var v = pluginConfig ? pluginConfig[name] : undefined;
        return (v === undefined || v === null) ? fallback : v;
    }

    function clampInt(v, lo, hi, fallback) {
        return Model.clampInt(v, lo, hi, fallback);
    }

    function safeName(v, fallback) {
        return Model.safeName(v, fallback);
    }

    function safePath(v) {
        return Model.safePath(v);
    }

    function resolvePath(p) {
        return Model.resolvePath(p, root.home);
    }

    function toFileUrl(p) {
        return Model.toFileUrl(p, root.home);
    }

    // Byte length of the UTF-8 encoding of a string, for sizing the state
    // payload handed to the python writer over stdin.
    function utf8ByteLength(s) {
        var str = String(s || "");
        var len = 0;
        for (var i = 0; i < str.length; i++) {
            var c = str.charCodeAt(i);
            if (c < 0x80)
                len += 1;
            else if (c < 0x800)
                len += 2;
            else if (c >= 0xD800 && c <= 0xDBFF) {
                len += 4;
                i++;
            } else
                len += 3;
        }
        return len;
    }

    // ------------------------------------------------------- surface registry
    function registerWallpaperSurface(s) {
        root.wallpaperSurfaces.push(s);
        root.checkSurfacesReady();
    }

    function unregisterWallpaperSurface(s) {
        root.wallpaperSurfaces = root.wallpaperSurfaces.filter(function(x) {
            return x !== s;
        });
    }

    function registerScreensaverSurface(s) {
        root.screensaverSurfaces.push(s);
        root.checkSurfacesReady();
    }

    function unregisterScreensaverSurface(s) {
        root.screensaverSurfaces = root.screensaverSurfaces.filter(function(x) {
            return x !== s;
        });
    }

    function checkSurfacesReady() {
        if (root._surfacesReady)
            return ;

        var want = 0;
        for (var i = 0; i < Quickshell.screens.length; i++) {
            if (root.urlForScreen(String(Quickshell.screens[i].name)) !== "")
                want++;

        }
        if (want > 0 && root.wallpaperSurfaces.length === want && root.screensaverSurfaces.length === want) {
            root._surfacesReady = true;
            if (root._pendingInitialFlourish) {
                root._pendingInitialFlourish = false;
                Qt.callLater(root.startWallpaperFlourish);
            }
        }
    }

    function pathExists(p) {
        var r = resolvePath(p);
        return r !== "" && root.existingPaths[r] === true;
    }

    function candidatePaths() {
        var seen = ({});
        var out = [];
        var paths = [root.videoPath];
        var sv = root.screenVideos || ({});
        for (var k in sv) paths.push(sv[k]);
        for (var i = 0; i < paths.length; i++) {
            var r = resolvePath(paths[i]);
            if (r === "" || seen[r]) continue;
            seen[r] = true;
            out.push(r);
            // The optimized sibling (omalive optimize) is preferred for
            // playback, so the existence probe must know about it too.
            var opt = Model.optimizedSibling(r);
            if (!seen[opt]) {
                seen[opt] = true;
                out.push(opt);
            }
        }
        return out;
    }

    function checkVideoFiles() {
        var paths = candidatePaths();
        if (paths.length === 0) {
            root.existingPaths = ({
            });
            return ;
        }
        if (statProc.running) {
            statDebounce.restart();
            return ;
        }
        statProc.command = root.timeoutPrefix.concat(["bash", "-c", 'for p in "$@"; do [ -f "$p" ] && printf "%s\\n" "$p"; done', "_"]).concat(paths);
        statProc.running = true;
    }

    // --------------------------------------------------------- clip resolution
    function configuredPathForScreen(name) {
        return Model.configuredPathForScreen(root.screenVideos, root.videoPath, name);
    }

    function pathForScreen(name) {
        return root.enabled ? root.configuredPathForScreen(name) : "";
    }

    // The file actually played for a configured path: the .opt.mp4 sibling
    // (omalive optimize) when it exists, else the original.
    function playbackPath(p) {
        var r = resolvePath(p);
        if (r === "")
            return "";

        var opt = Model.optimizedSibling(r);
        if (opt !== r && root.existingPaths[opt] === true)
            return opt;

        return r;
    }

    function urlForScreen(name) {
        var p = pathForScreen(name);
        if (p === "" || !pathExists(p))
            return "";

        return toFileUrl(root.playbackPath(p));
    }

    function frozenPositionFor(name) {
        return Model.frozenPositionFor(root.screenPositions, root.frozenPosition, name);
    }

    // ------------------------------------------------------- live positions
    // Where a monitor's footage currently is. Live from the playing surface
    // (screensaver first — it sits above the wallpaper while active), falling
    // back to the persisted frozen frame. Used by the OmaLive lock screen to
    // resume the aerial exactly where it was when the session locks.
    function surfacePosition(list, name) {
        for (var i = 0; i < list.length; i++) {
            if (list[i].monName === name)
                return list[i].position();

        }
        return -1;
    }

    function currentPositionFor(name) {
        var p = -1;
        if (root.screensaverActive)
            p = root.surfacePosition(root.screensaverSurfaces, name);

        if (p < 0)
            p = root.surfacePosition(root.wallpaperSurfaces, name);

        if (p < 0)
            p = root.frozenPositionFor(name);

        return p;
    }

    function positionsObject() {
        var out = {
        };
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) {
            var n = String(screens[i].name);
            if (root.configuredPathForScreen(n) === "")
                continue;

            out[n] = root.currentPositionFor(n);
        }
        return out;
    }

    // ------------------------------------------------------- persistence
    function persistState() {
        var payload = JSON.stringify({
            "videoPath": root.videoPath,
            "enabled": root.enabled,
            "screenVideos": root.screenVideos || ({
            }),
            "screenPositions": root.screenPositions || ({
            }),
            "frozenPosition": root.frozenPosition,
            "transitionSeconds": root.effectiveTransitionMs / 1000,
            "pauseOnFullscreen": root.pauseOnFullscreen,
            "liveWallpaper": root.liveWallpaper,
            "shuffle": root.shuffle,
            "flourishOnLogin": root.flourishOnLogin
        }, null, 2) + "\n";
        root.writeState(payload);
    }

    function normalizeScreenVideos(v) {
        return Model.normalizeScreenVideos(v);
    }

    function normalizeScreenPositions(v) {
        return Model.normalizeScreenPositions(v);
    }

    function applyStateText(txt) {
        var t = String(txt || "").trim();
        if (!t)
            return false;

        if (t.length > root.maxStateBytes) {
            console.warn("omalive: state.json is", t.length, "bytes, over the", root.maxStateBytes, "limit - ignoring it");
            return false;
        }
        try {
            var o = JSON.parse(t);
            if (o && typeof o === "object") {
                // runtime override of the config transition (persisted from the panel)

                if (o.videoPath !== undefined)
                    root.videoPath = root.safePath(o.videoPath);

                if (o.enabled !== undefined)
                    root.enabled = (o.enabled === true || String(o.enabled) === "true");

                if (o.screenVideos !== undefined)
                    root.screenVideos = root.normalizeScreenVideos(o.screenVideos);

                if (o.screenPositions !== undefined)
                    root.screenPositions = root.normalizeScreenPositions(o.screenPositions);

                if (o.frozenPosition !== undefined) {
                    var fp = parseInt(o.frozenPosition, 10);
                    root.frozenPosition = isFinite(fp) && fp >= 0 ? fp : 0;
                }
                if (o.transitionSeconds !== undefined)
                    root.transitionMsOverride = root.clampInt(o.transitionSeconds, 1, 10, root.transitionMs / 1000) * 1000;

                if (o.pauseOnFullscreen !== undefined)
                    root.pauseOnFullscreen = (o.pauseOnFullscreen === true || String(o.pauseOnFullscreen) === "true");

                if (o.liveWallpaper !== undefined)
                    root.liveWallpaper = (o.liveWallpaper === true || String(o.liveWallpaper) === "true");

                if (o.shuffle !== undefined)
                    root.shuffle = (o.shuffle === true || String(o.shuffle) === "true");

                if (o.flourishOnLogin !== undefined)
                    root.flourishOnLogin = (o.flourishOnLogin === true || String(o.flourishOnLogin) === "true");

                return true;
            }
        } catch (e) {
            console.warn("omalive: bad state.json:", e);
        }
        return false;
    }

    function syncSeedFromConfig() {
        var vp = root.safePath(cfg("videoPath", ""));
        var en = cfg("enabled", true) === true || String(cfg("enabled", "true")) === "true";
        var sv = normalizeScreenVideos(cfg("screenVideos", null));
        var sig = JSON.stringify([vp, en, sv]);
        if (!root._stateLoaded)
            return ;

        if (root._seedSig === "") {
            root._seedSig = sig;
            if (!root.videoPath && vp) {
                root.videoPath = vp;
                root.enabled = en;
            }
            if (Object.keys(root.screenVideos).length === 0)
                root.screenVideos = sv;

            persistState();
            return ;
        }
        if (sig !== root._seedSig) {
            root._seedSig = sig;
            root.videoPath = vp;
            root.enabled = en;
            root.screenVideos = sv;
            persistState();
        }
    }

    function finishStateLoad(txt) {
        if (root._stateLoaded)
            return ;

        root.applyStateText(txt);
        root._stateLoaded = true;
        root.syncSeedFromConfig();
        root.probeFlags();
    }

    function writeState(payload) {
        if (stateWriteProc.running) {
            root._pendingState = payload;
            return ;
        }
        stateWriteProc.command = root.timeoutPrefix.concat(["python3", "-c", root.stateWriteScript, root.statePath, String(root.utf8ByteLength(payload))]);
        stateWriteProc.payload = payload;
        stateWriteProc.running = true;
    }

    function probeFlags() {
        if (!flagsProc.running)
            flagsProc.running = true;

    }

    function runToggleWrite(flag, on) {
        if (toggleWriteProc.running)
            return ;

        var action = on ? "touch" : "rm -f";
        toggleWriteProc.command = root.timeoutPrefix.concat(["bash", "-c", 'd="$HOME/.local/state/omarchy/toggles"; mkdir -p -- "$d" || exit 1; ' + action + ' -- "$d/$1"', "_", flag]);
        toggleWriteProc.running = true;
    }

    function handleIdle() {
        if (idleMon.isIdle)
            root.enterScreensaver();
        else
            root.scheduleScreensaverDismiss();
    }

    function scheduleScreensaverDismiss() {
        if (!root.screensaverActive)
            return ;

        // Entering the screensaver maps the overlay surface, which can make the
        // compositor report an idle->active transition (same reason omarchy's
        // idle service arms a grace window after launching its screensaver).
        // Ignore activity during the grace period so the aerial isn't dismissed
        // by its own appearance.
        if (screensaverGraceTimer.running)
            return ;

        if (dismissDebounce.running)
            return ;

        dismissDebounce.restart();
    }

    function enterScreensaver() {
        if (root.locked || !root.rendering)
            return ;

        if (root.screensaverActive)
            return ;

        root.stopFlourish();
        root.stopDecel();
        root.screensaverActive = true;
        root.wallpaperVisible = false;
        root.hideCursor();
        screensaverGraceTimer.restart();
        console.log("omalive: screensaver enter, screensaverSurfaces=" + root.screensaverSurfaces.length + " wallpaperSurfaces=" + root.wallpaperSurfaces.length);
        // Resume the aerial from where the wallpaper froze (Sonoma continuity).
        var i = 0, ss = root.screensaverSurfaces;
        for (; i < ss.length; i++) {
            ss[i].seekTo(root.frozenPositionFor(ss[i].monName));
            ss[i].setRate(1);
            ss[i].play();
        }
        if (root.shuffle && root.clips.length > 1)
            shuffleTimer.restart();

        root.persistState();
    }

    function exitScreensaver() {
        if (!root.screensaverActive)
            return ;

        shuffleTimer.stop();
        if (root.glideToStop) {
            // Glide to a stop first (the Sonoma deceleration). The overlay
            // grabs input now, so a moving mouse fires this repeatedly; once
            // the deceleration is underway, let it run to completion.
            if (root.decelActive && root._decelTarget === "screensaver")
                return ;

            root.startDecel("screensaver");
            return;
        }
        if (root.decelActive && root._decelTarget === "screensaver")
            root.stopDecel();

        if (screensaverStopTimer.running)
            return;

        // Hand the footage straight over to the desktop: seed the wallpaper at
        // the screensaver's current position and drop the overlay NOW, so the
        // screensaver ends immediately and the SAME playback continues on the
        // wallpaper (crossfading in as the overlay fades out) for stopDelayMs
        // before freezing in place.
        var wl = root.wallpaperSurfaces;
        for (var i = 0; i < wl.length; i++) {
            var pos = root.surfacePosition(root.screensaverSurfaces, wl[i].monName);
            if (pos < 0)
                pos = wl[i].position();

            wl[i].setRate(1);
            wl[i].playFrom(pos);
        }
        root.screensaverActive = false;
        root.wallpaperFrozen = false;
        root.wallpaperVisible = true;
        root.showCursor();
        screensaverGraceTimer.stop();

        if (root.stopDelayMs > 0) {
            screensaverStopTimer.interval = root.stopDelayMs;
            screensaverStopTimer.restart();
        } else {
            root.parkWallpaperAfterScreensaver();
        }
    }

    // Called when the system locks over the screensaver: no decel, just yield.
    function forceExitScreensaver() {
        shuffleTimer.stop();
        root.stopDecel();
        if (!root.screensaverActive)
            return ;

        if (root.wallpaperFollowingLock) {
            // The wallpaper is already tracking the lock; just drop the
            // screensaver overlay without re-parking the frozen frame.
            root.screensaverActive = false;
            root.wallpaperVisible = true;
            root.showCursor();
            screensaverGraceTimer.stop();
            console.log("omalive: screensaver force-exit (following lock)");
            return;
        }

        root.captureFrozenFrames();
        root.screensaverActive = false;
        root.wallpaperVisible = true;
        root.wallpaperFrozen = true;
        root.showCursor();
        screensaverGraceTimer.stop();
        console.log("omalive: screensaver force-exit");
        root.persistState();
    }

    // Freeze the screensaver frame, then hand it to the wallpaper surfaces.
    function captureFrozenFrames() {
        var i = 0, ss = root.screensaverSurfaces;
        var first = -1;
        for (; i < ss.length; i++) {
            var p = ss[i].position();
            if (first < 0)
                first = p;

            var m = {
            };
            var sp = root.screenPositions || ({
            });
            for (var k in sp) m[k] = sp[k]
            m[ss[i].monName] = p;
            root.screenPositions = m;
            ss[i].freezeAt(p);
        }
        if (first >= 0)
            root.frozenPosition = first;

        var ws = root.wallpaperSurfaces;
        for (i = 0; i < ws.length; i++) {
            ws[i].seekTo(root.frozenPositionFor(ws[i].monName));
            ws[i].pause();
        }
    }

    function finishScreensaverExit() {
        root.captureFrozenFrames();
        root.screensaverActive = false;
        root.wallpaperVisible = true;
        if (root.liveWallpaper)
            root.resumeLiveDrift();
        else
            root.wallpaperFrozen = true;

        root.showCursor();
        screensaverGraceTimer.stop();
        console.log("omalive: screensaver exit");
        root.persistState();
    }

    // Freeze the wallpaper where the footage currently is after the stop delay
    // played out on the desktop (the overlay was already handed off in
    // exitScreensaver, so the frame is captured from the wallpaper itself, not
    // the screensaver surfaces).
    function parkWallpaperAfterScreensaver() {
        root.stopDecel();
        root.captureWallpaperFrames();
        if (root.liveWallpaper)
            root.resumeLiveDrift();
        else
            root.wallpaperFrozen = true;

        root.showCursor();
        screensaverGraceTimer.stop();
        console.log("omalive: screensaver exit");
        root.persistState();
    }

    // --------------------------------------------------- wallpaper / flourish
    // The login flourish: play the footage from the frozen frame, then
    // decelerate to a stop over `transitionSeconds` — the Sonoma effect.
    function startWallpaperFlourish() {
        if (root.locked || !root.rendering)
            return ;

        if (root.screensaverActive)
            return ;

        root.stopDecel();
        root.stopFlourish();
        root.wallpaperFrozen = false;
        root.wallpaperVisible = true;
        root.manualPaused = false;
        root.flourishActive = true;
        var i = 0, ws = root.wallpaperSurfaces;
        for (; i < ws.length; i++) {
            ws[i].setRate(1);
            ws[i].playFrom(root.frozenPositionFor(ws[i].monName));
        }
        flourishTimer.interval = root.glideToStop ? Math.max(300, Math.floor(root.effectiveTransitionMs * 0.4)) : Math.max(300, root.stopDelayMs);
        flourishTimer.restart();
    }

    function stopFlourish() {
        if (flourishTimer.running)
            flourishTimer.stop();

        root.flourishActive = false;
    }

    function finishWallpaperFlourish() {
        root.captureWallpaperFrames();
        if (root.liveWallpaper)
            root.resumeLiveDrift();
        else
            root.wallpaperFrozen = true;

        root.flourishActive = false;
        root.persistState();
    }

    // Park the wallpaper surfaces where they currently are and record those
    // positions so the frozen frame survives a restart.
    function captureWallpaperFrames() {
        var i = 0, ws = root.wallpaperSurfaces;
        var first = -1;
        var m = {
        };
        var sp = root.screenPositions || ({
        });
        for (var k in sp) m[k] = sp[k]
        for (; i < ws.length; i++) {
            var p = ws[i].position();
            if (first < 0)
                first = p;

            m[ws[i].monName] = p;
            ws[i].pause();
        }
        if (first >= 0)
            root.frozenPosition = first;

        root.screenPositions = m;
    }

    // Live mode was interrupted by a flourish or screensaver exit; resume the
    // slow drift from where the footage currently is instead of leaving the
    // wallpaper frozen.
    function resumeLiveDrift() {
        root.wallpaperFrozen = false;
        var i = 0, ws = root.wallpaperSurfaces;
        for (; i < ws.length; i++) {
            ws[i].setRate(root.liveRate);
            ws[i].play();
        }
    }

    // ------------------------------------------------------------- deceleration
    function startDecel(target) {
        root.stopDecel();
        root._decelTarget = target;
        root._decelProgress = 0;
        root.decelActive = true;
        // The screensaver exit hands the frozen frame to the wallpaper. Seed
        // the wallpaper at the screensaver's current position and glide both
        // together, so when the overlay fades out the wallpaper is already
        // parked on the exact frame — no post-hoc seek + visible snap.
        if (target === "screensaver") {
            var wl = root.wallpaperSurfaces;
            for (var i = 0; i < wl.length; i++) {
                var pos = root.surfacePosition(root.screensaverSurfaces, wl[i].monName);
                if (pos < 0)
                    pos = wl[i].position();

                wl[i].setRate(1);
                wl[i].playFrom(pos);
            }
        }
        decelTimer.interval = 30;
        decelTimer.restart();
    }

    function stopDecel() {
        decelTimer.stop();
        root.decelActive = false;
    }

    function decelTick() {
        root._decelProgress += 30 / Math.max(300, root.effectiveTransitionMs);
        var t = Math.min(1, root._decelProgress);
        var rate = Model.decelRate(t); // rate stays high most of the glide so the video doesn't turn into a slideshow
        var i = 0, list = root._decelTarget === "screensaver" ? root.screensaverSurfaces : root.wallpaperSurfaces;
        for (; i < list.length; i++) list[i].setRate(rate)
        // Mirror the screensaver's glide onto the wallpaper so the handoff in
        // finishScreensaverExit lands on the exact final frame.
        if (root._decelTarget === "screensaver") {
            var wl = root.wallpaperSurfaces;
            for (i = 0; i < wl.length; i++) wl[i].setRate(rate)
        }
        if (t >= 1) {
            decelTimer.stop();
            root.decelActive = false;
            if (root._decelTarget === "screensaver")
                root.finishScreensaverExit();
            else
                root.finishWallpaperFlourish();
        }
    }

    function refreshFullscreen() {
        if (fsProc.running) {
            fsDebounce.restart();
            return ;
        }
        fsProc.running = true;
    }

    function checkLocked() {
        if (lockProc.running)
            return ;

        lockProc.command = root.timeoutPrefix.concat(["bash", "-c", "[[ $(omarchy-shell lock isLocked 2>/dev/null) == \"true\" ]] && echo locked || echo unlocked"]);
        lockProc.running = true;
    }

    function applyLockState(state) {
        var isLocked = state === "locked";
        // A follow was requested but the lock is gone (released without a
        // handoff, or never engaged): stop drifting and park / flourish.
        if (root.wallpaperFollowingLock && !isLocked) {
            root.wallpaperFollowingLock = false;
            root.locked = false;
            if (root.flourishOnLogin)
                root.startWallpaperFlourish();
            else
                root.parkWallpaperAt(root.screenPositions);
        }
        if (isLocked === root.locked)
            return ;

        root.locked = isLocked;
        if (isLocked)
            root.forceExitScreensaver();
        else if (root.flourishOnLogin)
            root.startWallpaperFlourish();
    }

    function hideCursor() {
        if (!cursorProc.running) {
            cursorProc.command = root.timeoutPrefix.concat(["bash", "-c", "hyprctl eval 'hl.config({ cursor = { invisible = true } })' >/dev/null 2>&1 || hyprctl keyword cursor:invisible true >/dev/null 2>&1 || true"]);
            cursorProc.running = true;
        }
    }

    function showCursor() {
        if (!cursorProc.running) {
            cursorProc.command = root.timeoutPrefix.concat(["bash", "-c", "hyprctl eval 'hl.config({ cursor = { invisible = false } })' >/dev/null 2>&1 || hyprctl keyword cursor:invisible false >/dev/null 2>&1 || true"]);
            cursorProc.running = true;
        }
    }

    function rescanClips() {
        if (!scanProc.running)
            scanProc.running = true;

    }

    function shuffleClip() {
        if (!root.screensaverActive || root.clips.length < 2)
            return ;

        var pick = root.clips[Math.floor(Math.random() * root.clips.length)];
        if (pick && pick !== root.videoPath) {
            root.videoPath = pick;
            root.persistState();
        }
    }

    // ---------------------------------------------------------------- IPC
    function statusObject() {
        return {
            "enabled": root.enabled,
            "videoPath": root.videoPath,
            "videoFileExists": root.videoFileExists,
            "screenVideos": root.screenVideos || ({
            }),
            "screensaverEnabled": root.screensaverEnabled,
            "screensaverActive": root.screensaverActive,
            "locked": root.locked,
            "stayAwake": root.stayAwake,
            "liveWallpaper": root.liveWallpaper,
            "pauseOnFullscreen": root.pauseOnFullscreen,
            "transitionSeconds": root.effectiveTransitionMs / 1000,
            "shuffle": root.shuffle,
            "flourishOnLogin": root.flourishOnLogin,
            "wallpaperFrozen": root.wallpaperFrozen,
            "manualPaused": root.manualPaused,
            "idleEnabled": root.idleEnabled,
            "screensaverSurfaces": root.screensaverSurfaces.length,
            "wallpaperSurfaces": root.wallpaperSurfaces.length,
            "videoDir": root.videoDir,
            "clipCount": root.clips.length,
            "clipsTruncated": root.clipsTruncated,
            "screens": root.screensObject()
        };
    }

    function screensObject() {
        var out = [];
        var sv = root.screenVideos || ({
        });
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) {
            var n = String(screens[i].name);
            var own = Object.prototype.hasOwnProperty.call(sv, n);
            var p = root.pathForScreen(n);
            var state = "off";
            if (p !== "" && pathExists(p)) {
                if (root.screensaverActive)
                    state = "screensaver";
                else if (root.wallpaperFrozen)
                    state = "frozen";
                else if (root.liveWallpaper)
                    state = "live";
                else
                    state = "playing";
            } else if (p !== "") {
                state = "missing";
            }
            out.push({
                "name": n,
                "video": p,
                "playback": p !== "" ? root.playbackPath(p) : "",
                "source": own ? "screen" : (p === "" ? "none" : "default"),
                "fileExists": p !== "" && root.pathExists(p),
                "state": state
            });
        }
        return out;
    }

    // ------------------------------------------------------- root mutators
    function applyPlay(path) {
        var p = root.safePath(String(path || "").trim());
        if (p)
            root.videoPath = p;

        root.enabled = true;
        root.manualPaused = false;
        root.wallpaperFrozen = false;
        root.wallpaperVisible = true;
        root.screensaverActive = false;
        root.stopFlourish();
        root.stopDecel();
        var i = 0, ws = root.wallpaperSurfaces;
        for (; i < ws.length; i++) {
            ws[i].setRate(root.liveWallpaper ? root.liveRate : 1);
            ws[i].playFrom(root.frozenPositionFor(ws[i].monName));
        }
        root.persistState();
        return root.statusObject();
    }

    function applyPlayAll(path) {
        var p = root.safePath(String(path || "").trim());
        if (p)
            root.videoPath = p;

        root.screenVideos = ({
        });
        root.enabled = true;
        root.manualPaused = false;
        root.persistState();
        return root.applyPlay("");
    }

    function applySetScreenVideo(name, path) {
        var n = String(name || "").trim();
        if (n === "" || n === "all")
            return root.applyPlayAll(path);

        if (n.length > root.maxNameLength)
            return root.statusObject();

        var p = root.safePath(String(path || "").trim());
        var m = ({
        });
        var sv = root.screenVideos || ({
        });
        for (var k in sv) m[k] = sv[k]
        if (!m.hasOwnProperty(n) && Object.keys(m).length >= root.maxScreenVideos)
            return root.statusObject();

        m[n] = p;
        root.screenVideos = m;
        if (p !== "") {
            root.enabled = true;
            root.manualPaused = false;
            root.wallpaperFrozen = false;
            root.wallpaperVisible = true;
            root.screensaverActive = false;
        }
        root.persistState();
        return root.statusObject();
    }

    function applyClearScreenVideo(name) {
        var n = String(name || "").trim();
        if (n === "" || n === "all") {
            root.screenVideos = ({
            });
        } else {
            var m = ({
            });
            var sv = root.screenVideos || ({
            });
            for (var k in sv) if (k !== n) {
                m[k] = sv[k];
            }
            root.screenVideos = m;
        }
        root.persistState();
        return root.statusObject();
    }

    function applyFreeze() {
        if (root.screensaverActive) {
            root.exitScreensaver();
            return root.statusObject();
        }
        root.stopFlourish();
        if (root.wallpaperFrozen)
            return root.statusObject();

        // Glide to a stop when the wallpaper is actually moving (Sonoma feel);
        // otherwise just park the current frame. Live mode drifts at
        // liveRate (0.35), so decelerating there would first snap the rate up
        // to 1.0 — park it instead.
        if (root.wallpaperPlayRequest && !root.liveWallpaper) {
            root.startDecel("wallpaper");
            return root.statusObject();
        }
        root.captureWallpaperFrames();
        root.wallpaperFrozen = true;
        root.persistState();
        return root.statusObject();
    }

    function applyStop() {
        root.enabled = false;
        root.manualPaused = false;
        root.screensaverActive = false;
        root.wallpaperFollowingLock = false;
        root.wallpaperFrozen = true;
        root.stopFlourish();
        root.stopDecel();
        root.persistState();
    }

    function applyToggle() {
        root.enabled = !root.enabled;
        if (!root.enabled)
            root.manualPaused = false;

        root.persistState();
        return root.enabled;
    }

    function applyPause() {
        root.manualPaused = true;
        root.persistState();
    }

    function applyResume() {
        root.manualPaused = false;
        root.persistState();
    }

    function applyScreensaver(arg) {
        var a = String(arg || "").toLowerCase();
        switch (a) {
        case "on":
        case "forceon":
            // persist the flag via a helper (state file for toggles is not ours)
            runToggleWrite("omalive-screensaver-off", false);
            root.screensaverEnabled = true;
            break;
        case "off":
        case "forceoff":
            // persist the flag via a helper (state file for toggles is not ours)
            runToggleWrite("omalive-screensaver-off", true);
            root.screensaverEnabled = false;
            root.forceExitScreensaver();
            break;
        case "start":
        case "show":
            root.enterScreensaver();
            break;
        case "stop":
        case "dismiss":
            root.exitScreensaver();
            break;
        case "status":
            break;
        }
        return root.statusObject().screensaverEnabled ? "on" : "off";
    }

    function applySetScreensaverEnabled(on) {
        var enable = (on === true || String(on) === "true");
        if (enable === root.screensaverEnabled)
            return root.statusObject().screensaverEnabled ? "on" : "off";

        runToggleWrite("omalive-screensaver-off", !enable);
        root.screensaverEnabled = enable;
        if (!enable)
            root.forceExitScreensaver();

        return enable ? "on" : "off";
    }

    // ------------------------------------------------------- lock handoff
    // Called by the OmaLive lock screen the moment a lock engages (before the
    // session lock is confirmed): the wallpaper starts playing the aerial in
    // lockstep with the lock surface, so unlocking later is a seamless
    // continuation instead of a cold seek. Each surface is seeded to where the
    // lock starts; the small drift between the two decoders is corrected on
    // unlock via applyLockHandoff.
    function startWallpaperFollow(txt, play) {
        var t = String(txt || "").trim();
        if (!t || t.length > root.maxStateBytes)
            return "bad-payload";

        var positions;
        try {
            positions = root.normalizeScreenPositions(JSON.parse(t));
        } catch (e) {
            return "bad-payload";
        }
        if (Object.keys(positions).length === 0)
            return "empty";

        // A pending screensaver-dismissal stop must not freeze the wallpaper
        // while it is tracking the lock.
        screensaverStopTimer.stop();

        var first = Model.defaultPositionFrom(positions, -1);
        if (first >= 0)
            root.frozenPosition = first;

        root.screenPositions = positions;
        root.wallpaperFollowingLock = true;
        root.wallpaperVisible = true;
        root.manualPaused = false;
        root.stopFlourish();
        root.stopDecel();
        // `play === false` only arms the follow (used at beginLock): the
        // wallpaper stays frozen/drifting so locking doesn't visibly snap it to
        // 1x during the ~2s before the session-lock surface maps. The lock
        // service re-calls this with play=true the moment the lock video
        // actually starts (realignWallpaper), seeding both decoders in lockstep.
        if (play !== false) {
            root.wallpaperFrozen = false;
            var i = 0, ws = root.wallpaperSurfaces;
            for (; i < ws.length; i++) {
                ws[i].setRate(1);
                ws[i].playFrom(root.frozenPositionFor(ws[i].monName));
            }
        }
        // The lock is engaging and will cover every surface; the screensaver
        // overlay must yield NOW (not on the 3s lock poll) so a fast
        // lock->unlock never leaves the aerial up over the desktop.
        if (root.screensaverActive)
            root.forceExitScreensaver();

        root.persistState();
        return "ok";
    }

    // Called by the OmaLive lock screen the moment the session unlocks: the
    // lock surfaces played the aerial while locked, so continue the footage
    // on the wallpaper from the exact frames the user last saw (Sonoma
    // continuity). This runs BEFORE the compositor releases the lock, so the
    // wallpaper players' seek/startup latency is hidden underneath the
    // still-visible lock video — when the lock lifts, the wallpaper is already
    // in motion at the right frame and glides to a stop. No frozen wait for
    // the 3s lock poll.
    function applyLockHandoff(txt) {
        var t = String(txt || "").trim();
        if (!t || t.length > root.maxStateBytes)
            return "bad-payload";

        var positions;
        try {
            positions = root.normalizeScreenPositions(JSON.parse(t));
        } catch (e) {
            return "bad-payload";
        }
        if (Object.keys(positions).length === 0)
            return "empty";

        var wasLocked = root.locked;
        var wasFollowing = root.wallpaperFollowingLock;
        var first = Model.defaultPositionFrom(positions, -1);
        if (first >= 0)
            root.frozenPosition = first;

        root.screenPositions = positions;
        // The lock is releasing; align state now so the poll becomes a no-op
        // and the flourish can run immediately instead of waiting for it.
        root.locked = false;
        root.wallpaperFollowingLock = false;
        if (root.flourishOnLogin) {
            if (wasFollowing) {
                // The wallpaper already tracked the lock; correct the small
                // drift (wrap-aware) and glide to a stop — no cold seek, so
                // the footage continues seamlessly.
                root.correctWallpaperDrift(positions);
                root.continueWallpaperFlourish();
            } else if (wasLocked) {
                root.startWallpaperFlourish();
            } else {
                root.parkWallpaperAt(positions);
            }
        } else {
            root.parkWallpaperAt(positions);
        }
        root.persistState();
        return "ok";
    }

    // Align the following wallpaper to the exact frames the lock last showed,
    // seeking only the small drift between the two decoders (wrap-aware across
    // the loop seam). Seeks are near-instant on the optimized clips.
    function correctWallpaperDrift(positions) {
        var i = 0, ws = root.wallpaperSurfaces;
        for (; i < ws.length; i++) {
            var want = root.frozenPositionFor(ws[i].monName);
            var have = ws[i].position();
            var target = Model.correctedSeek(have, want, ws[i].duration());
            var delta = Math.abs(target - have);
            if (delta > 120)
                ws[i].seekTo(target);

            ws[i].setRate(1);
        }
    }

    // Park every wallpaper surface on the given frozen frames (used when the
    // lock released without a flourish).
    function parkWallpaperAt(positions) {
        var i = 0, ws = root.wallpaperSurfaces;
        for (; i < ws.length; i++) ws[i].freezeAt(root.frozenPositionFor(ws[i].monName));
        root.wallpaperFrozen = true;
    }

    // The wallpaper is already moving (it tracked the lock); just arm the
    // glide-to-stop so the footage decelerates from where it is — no cold
    // seek, so the unlock is a seamless continuation.
    function continueWallpaperFlourish() {
        if (!root.rendering)
            return ;

        root.stopDecel();
        root.stopFlourish();
        root.wallpaperFrozen = false;
        root.wallpaperVisible = true;
        root.manualPaused = false;
        root.flourishActive = true;
        var i = 0, ws = root.wallpaperSurfaces;
        for (; i < ws.length; i++) {
            ws[i].setRate(1);
            ws[i].play();
        }
        flourishTimer.interval = root.glideToStop ? Math.max(300, Math.floor(root.effectiveTransitionMs * 0.4)) : Math.max(300, root.stopDelayMs);
        flourishTimer.restart();
    }

    // ------------------------------------------------------- lock frozen frame
    // A predictable per-screen path for the lock's frozen-frame PNG. Written by
    // captureFrozenFramesForLock, read by the OmaLive lock screen the instant
    // its surface maps so it can show the exact aerial frame (no dark decode
    // gap) before the live video fades in and continues.
    function lockFramePathFor(name) {
        var n = root.safeName(String(name || ""), "");
        return n ? root.stateDir + "/lockframe-" + n + ".png" : "";
    }

    function frozenFramePath(name) {
        var n = String(name || "");
        var p = root.lockFramePaths ? root.lockFramePaths[n] : "";
        return p ? root.toFileUrl(p) : "";
    }

    // Capture each monitor's current aerial frame to a PNG for the lock screen
    // (macOS continuity: the lock appears frozen at the exact frame, then goes
    // live). Grabs the screensaver overlay while it is still mapped/rendering,
    // else the wallpaper surface. The grabs are async but land well inside the
    // lock's 500ms screen-stabilize window. Failures leave "" (the lock falls
    // back to its stock blurred wallpaper).
    function captureFrozenFramesForLock() {
        var out = ({
        });
        var list = root.screensaverActive ? root.screensaverSurfaces : root.wallpaperSurfaces;
        for (var i = 0; i < list.length; i++) {
            var s = list[i];
            var n = String(s.monName || "");
            var path = root.lockFramePathFor(n);
            if (path === "")
                continue;

            out[n] = "";
            root.captureOneLockFrame(s, n, path, out);
        }
        root.lockFramePaths = out;
    }

    // Run one surface grab and fold the result into the shared map (bound per
    // iteration — QML closures share the loop's `s`, so the surface is passed
    // in as a parameter, never captured). The grab writes to a UNIQUE temp
    // path, then a descriptor-bound python helper validates it and atomically
    // renames it over the final predictable path — a pre-planted symlink at
    // the final path is replaced, never written through. Each completion
    // publishes a fresh map so property-change notifications fire and the
    // lock's frozenFrameUrl binding re-evaluates even if the grab lands after
    // the lock surface maps.
    function captureOneLockFrame(surface, name, path, out) {
        root._atomicInstallSeq += 1;
        // saveToFile infers the format from the file extension, so the temp
        // must keep a real .png suffix (it is unique, so no pre-planted
        // symlink can target it).
        var temp = path + "-" + root._atomicInstallSeq + "-" + Math.floor(Math.random() * 1000000) + ".png";
        surface.captureFrame(temp, function(resultPath) {
            if (resultPath === "") {
                root.cleanupTemp(temp);
                out[name] = "";
                root.publishLockFrames(out);
                return;
            }
            root.runAtomicInstall(temp, path, function(finalPath) {
                root.cleanupTemp(temp);
                out[name] = finalPath;
                root.publishLockFrames(out);
            });
        });
    }

    function publishLockFrames(out) {
        var m = ({
        });
        for (var k in out) m[k] = out[k];
        root.lockFramePaths = m;
    }

    // Queue an atomic-install job (validate temp, os.replace over final) and
    // run the queue one job at a time through a single python helper process.
    // Each job is a plain [temp, final, cb] array. The parameters are stashed
    // into properties first and the queue mutated from a parameterless helper
    // (qmllint segfaults on parameters named temp/final/cb fed into arrays).
    function runAtomicInstall(t0, f0, c0) {
        root._pendingAtomicTemp = t0;
        root._pendingAtomicFinal = f0;
        root._pendingAtomicCb = c0;
        root.enqueueAtomicInstall();
    }

    function enqueueAtomicInstall() {
        var job = [];
        job.push(root._pendingAtomicTemp);
        job.push(root._pendingAtomicFinal);
        job.push(root._pendingAtomicCb);
        root._pendingAtomicInstalls.push(job);
        root.pumpAtomicInstalls();
    }

    function pumpAtomicInstalls() {
        if (atomicInstallProc.running || root._pendingAtomicInstalls.length === 0)
            return;

        var job = root._pendingAtomicInstalls[0];
        root._atomicInstallJob = job;
        atomicInstallProc.command = root.timeoutPrefix.concat(["python3", "-c", root.atomicInstallScript, job[0], job[1], String(root.maxLockFrameBytes)]);
        atomicInstallProc.running = true;
    }

    // Best-effort removal of a temp file (no-op once it was renamed over the
    // final path). Queued so bursts of failed grabs still drain their temps.
    function cleanupTemp(p) {
        if (!p)
            return;

        root._rmQueue.push(p);
        root.pumpRm();
    }

    function pumpRm() {
        if (rmTempProc.running || root._rmQueue.length === 0)
            return;

        rmTempProc.command = ["rm", "-f", "--"].concat(root._rmQueue.shift());
        rmTempProc.running = true;
    }

    function setTransitionSeconds(v) {
        root.transitionMsOverride = root.clampInt(v, 1, 10, 2) * 1000;
        root.persistState();
        return String(root.effectiveTransitionMs / 1000);
    }

    function setPauseOnFullscreen(on) {
        root.pauseOnFullscreen = (on === true || String(on) === "true");
        root.persistState();
        return root.pauseOnFullscreen ? "on" : "off";
    }

    function setLiveWallpaper(on) {
        root.liveWallpaper = (on === true || String(on) === "true");
        if (root.liveWallpaper) {
            root.wallpaperFrozen = false;
            var i = 0, ws = root.wallpaperSurfaces;
            for (; i < ws.length; i++) {
                ws[i].setRate(root.liveRate);
                ws[i].play();
            }
        } else {
            root.applyFreeze();
        }
        root.persistState();
        return root.liveWallpaper ? "on" : "off";
    }

    function setShuffle(on) {
        root.shuffle = (on === true || String(on) === "true");
        root.persistState();
        return root.shuffle ? "on" : "off";
    }

    function setFlourishOnLogin(on) {
        root.flourishOnLogin = (on === true || String(on) === "true");
        root.persistState();
        return root.flourishOnLogin ? "on" : "off";
    }

    onVideoPathChanged: checkVideoFiles()
    onScreenVideosChanged: checkVideoFiles()
    onPluginConfigChanged: syncSeedFromConfig()
    Component.onCompleted: {
        mkStateDir.running = true;
        // Restore a cursor a crash mid-screensaver may have left hidden.
        root.showCursor();
        // Once state + surfaces are ready, run the "2s after login" flourish so
        // the footage plays and glides to a stop on the fresh desktop.
        root._pendingInitialFlourish = true;
        initialFlourishGuard.restart();
    }
    onIdleEnabledChanged: idleMon.enabled = root.idleEnabled
    onVideoDirChanged: rescanClips()

    Process {
        id: statProc

        stdout: StdioCollector {
            onStreamFinished: {
                var set = ({
                });
                var lines = String(text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].trim();
                    if (p)
                        set[p] = true;

                }
                root.existingPaths = set;
            }
        }

    }

    Timer {
        id: statDebounce

        interval: 80
        repeat: false
        onTriggered: root.checkVideoFiles()
    }

    Process {
        id: stateReadProc

        command: root.timeoutPrefix.concat(["python3", "-c", root.stateReadScript, root.statePath, String(root.maxStateBytes)])
        // Only arm the fallback if the state read produced no output. Without
        // the guard, a 250ms fallback firing first (onExited can beat
        // onStreamFinished) would apply empty state and overwrite the good
        // state.json with it.
        onExited: if (!root._stateStreamDone) stateReadFallback.restart()

        stdout: StdioCollector {
            onStreamFinished: {
                root._stateStreamDone = true;
                stateReadFallback.stop();
                root.finishStateLoad(text);
            }
        }

    }

    Timer {
        id: stateReadFallback

        interval: 250
        onTriggered: {
            root._stateStreamDone = true;
            root.finishStateLoad("");
        }
    }

    Process {
        id: stateWriteProc

        property string payload: ""
        stdinEnabled: true
        onStarted: {
            write(stateWriteProc.payload);
            stateWriteProc.payload = "";
        }
        onExited: {
            if (root._pendingState !== "") {
                var q = root._pendingState;
                root._pendingState = "";
                root.writeState(q);
            }
        }
    }

    // Descriptor-bound atomic install of a lock-frame PNG (see
    // atomicInstallScript / runAtomicInstall). One job at a time; stdout carries
    // the final path on success.
    Process {
        id: atomicInstallProc

        stdout: StdioCollector {
            onStreamFinished: {
                var p = String(text || "").trim();
                var job = root._atomicInstallJob;
                var cb = job ? job[2] : null;
                if (cb)
                    cb(p === job[1] ? p : "");
            }
        }
        onExited: {
            root._atomicInstallJob = null;
            if (root._pendingAtomicInstalls.length > 0)
                root._pendingAtomicInstalls.shift();
            root.pumpAtomicInstalls();
        }
    }

    // Fire-and-forget removal of failed-capture temp files (queued).
    Process {
        id: rmTempProc

        onExited: root.pumpRm()
    }

    Process {
        id: mkStateDir

        command: root.timeoutPrefix.concat(["mkdir", "-p", root.stateDir])
        onExited: {
            root._stateStreamDone = false;
            stateReadProc.running = true;
        }
    }

    // Belt-and-braces: if surfaces never become ready (no clip assigned), don't
    // sit on the pending flourish flag forever.
    Timer {
        id: initialFlourishGuard

        interval: 6000
        repeat: false
        onTriggered: root._pendingInitialFlourish = false
    }

    Process {
        id: flagsProc

        command: root.timeoutPrefix.concat(["bash", "-c", root.flagsScript])

        stdout: StdioCollector {
            onStreamFinished: {
                var off = false, oma = false, aw = false;
                var lines = String(text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var l = lines[i].trim();
                    if (l === "off=1")
                        off = true;
                    else if (l === "omalive=1")
                        oma = true;
                    else if (l === "stayawake=1")
                        aw = true;
                }
                root.screensaverOffFlag = off;
                root.screensaverEnabled = !oma;
                root.stayAwake = aw;
            }
        }

    }

    // Write/remove an omarchy toggle flag (used for OmaLive's own screensaver
    // on/off state so it survives restarts without a state-file dependency).
    Process {
        id: toggleWriteProc

        onExited: root.probeFlags()
    }

    FileView {
        path: root.togglesDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.probeFlags()
    }

    FileView {
        path: root.indicatorsDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.probeFlags()
    }

    IdleMonitor {
        id: idleMon

        enabled: root.idleEnabled
        timeout: root.idleScreensaverSeconds
        respectInhibitors: true
        onIsIdleChanged: root.handleIdle()
    }

    // ------------------------------------------------------------ screensaver
    // Grace window after the screensaver enters during which idle->active
    // transitions are ignored (see scheduleScreensaverDismiss).
    Timer {
        id: screensaverGraceTimer

        interval: 2000
        repeat: false
    }

    Timer {
        id: dismissDebounce

        interval: 300
        repeat: false
        onTriggered: {
            if (!idleMon.isIdle)
                root.exitScreensaver();

        }
    }

    Timer {
        id: flourishTimer

        repeat: false
        onTriggered: {
            if (!root.flourishActive)
                return;

            if (root.glideToStop)
                root.startDecel("wallpaper");
            else
                root.finishWallpaperFlourish();
        }
    }

    Timer {
        id: screensaverStopTimer

        repeat: false
        onTriggered: {
            // The overlay is gone; freeze the wallpaper where the footage is now.
            if (!root.screensaverActive)
                root.parkWallpaperAfterScreensaver();
        }
    }

    Timer {
        id: decelTimer

        repeat: true
        onTriggered: root.decelTick()
    }

    Process {
        id: fsProc

        command: root.timeoutPrefix.concat(["python3", "-c", root.fsScript])

        stdout: StdioCollector {
            onStreamFinished: {
                var set = ({
                });
                var lines = String(text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var n = lines[i].trim();
                    if (n)
                        set[n] = true;

                }
                root.fullscreenMonitors = set;
            }
        }

    }

    Timer {
        id: fsDebounce

        interval: 120
        repeat: false
        onTriggered: root.refreshFullscreen()
    }

    Connections {
        function onRawEvent(event) {
            switch (event.name) {
            case "fullscreen":
            case "fullscreenv2":
            case "activewindow":
            case "activewindowv2":
            case "openwindow":
            case "closewindow":
            case "movewindowv2":
            case "changefloatingmode":
            case "workspace":
            case "workspacev2":
            case "focusedmon":
            case "focusedmonv2":
                fsDebounce.restart();
                break;
            }
        }

        target: Hyprland
    }

    Timer {
        interval: 400
        running: true
        repeat: false
        onTriggered: root.refreshFullscreen()
    }

    // ------------------------------------------------------- lock watch
    Timer {
        id: lockPoll

        interval: 3000
        running: true
        repeat: true
        onTriggered: root.checkLocked()
    }

    Process {
        id: lockProc

        stdout: StdioCollector {
            onStreamFinished: root.applyLockState(String(text || "").trim())
        }

    }

    // ------------------------------------------------------- cursor control
    Process {
        id: cursorProc
    }

    Process {
        id: scanProc

        command: ["timeout", "-k", "1", String(root.scanSeconds), "bash", "-c", root.scanScript, "_", String(root.scanLimit + 1), String(root.entryLimit), root.resolvePath(root.videoDir)]
        onExited: function(code) {
            if (code !== 0)
                root.clipsTruncated = true;

        }

        stderr: StdioCollector {
            onStreamFinished: {
                if (String(text || "").indexOf("TRUNC") !== -1)
                    root.clipsTruncated = true;

            }
        }

        stdout: StdioCollector {
            onStreamFinished: {
                var seen = ({
                });
                var list = [];
                root.clipsTruncated = false;
                var lines = String(text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var p = lines[i].trim();
                    if (!p || seen[p])
                        continue;

                    seen[p] = true;
                    if (list.length >= root.scanLimit) {
                        root.clipsTruncated = true;
                        break;
                    }
                    list.push(p);
                }
                root.clips = list;
            }
        }

    }

    FileView {
        path: root.resolvePath(root.videoDir)
        watchChanges: true
        printErrors: false
        onFileChanged: {
            // `omalive optimize` drops .opt.mp4 siblings here; re-probe so the
            // playback preference switches to them without a restart.
            root.rescanClips();
            root.checkVideoFiles();
        }
    }

    Timer {
        id: shuffleTimer

        interval: root.shuffleIntervalMs
        repeat: true
        onTriggered: root.shuffleClip()
    }

    // ---------------------------------------------------------------- render
    Variants {
        model: root.activeScreens

        WallpaperSurface {
            owner: root
            monName: String(modelData.name)
            clipUrl: root.urlForScreen(String(modelData.name))
            playRequest: root.wallpaperPlayRequest
            rate: root.liveWallpaper ? root.liveRate : 1
            opacityVisible: root.wallpaperVisible
            blocked: root.pauseOnFullscreen && !root.wallpaperFollowingLock && (root.fullscreenMonitors[String(modelData.name)] === true)
        }

    }

    Variants {
        model: root.activeScreens

        ScreensaverSurface {
            owner: root
            monName: String(modelData.name)
            clipUrl: root.urlForScreen(String(modelData.name))
            active: root.screensaverActive
        }

    }

    IpcHandler {
        function status() : string {
            return JSON.stringify(root.statusObject());
        }

        function ping() : string {
            return "ok";
        }

        function play(path: string) : string {
            return JSON.stringify(root.applyPlay(path));
        }

        function playAll(path: string) : string {
            return JSON.stringify(root.applyPlayAll(path));
        }

        function playOn(screen: string, path: string) : string {
            return JSON.stringify(root.applySetScreenVideo(screen, path));
        }

        function clearScreen(screen: string) : string {
            return JSON.stringify(root.applyClearScreenVideo(screen));
        }

        function freeze() : string {
            return JSON.stringify(root.applyFreeze());
        }

        function flourish() : string {
            root.startWallpaperFlourish();
            return "ok";
        }

        function stop() : string {
            root.applyStop();
            return "stopped";
        }

        function toggle() : string {
            return root.applyToggle() ? "on" : "off";
        }

        function pause() : string {
            root.applyPause();
            return "paused";
        }

        function resume() : string {
            root.applyResume();
            return "playing";
        }

        function screens() : string {
            return JSON.stringify(root.screensObject());
        }

        function positions() : string {
            return JSON.stringify(root.positionsObject());
        }

        function lockHandoff(payload : string) : string {
            return root.applyLockHandoff(payload);
        }

        function followLock(payload : string) : string {
            return root.startWallpaperFollow(payload);
        }

        function screensaver(arg: string) : string {
            return root.applyScreensaver(arg);
        }

        function setTransitionSeconds(v: string) : string {
            return root.setTransitionSeconds(v);
        }

        function setPauseOnFullscreen(on: string) : string {
            return root.setPauseOnFullscreen(on);
        }

        function setLiveWallpaper(on: string) : string {
            return root.setLiveWallpaper(on);
        }

        function setShuffle(on: string) : string {
            return root.setShuffle(on);
        }

        function setFlourishOnLogin(on: string) : string {
            return root.setFlourishOnLogin(on);
        }

        target: "omalive"
    }

}
