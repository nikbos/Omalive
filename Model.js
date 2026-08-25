// Pure, dependency-free helpers shared by Service.qml (runtime) and the Node
// unit tests. Everything here is side-effect free; clamping and state boundaries
// belong to the callers.

var DEFAULT_MAX_NAME = 256;
var DEFAULT_MAX_PATH = 4096;
var DEFAULT_MAX_ENTRIES = 64;

function clampInt(v, lo, hi, fallback) {
  var n = parseInt(v, 10);
  if (!isFinite(n)) return fallback;
  return Math.max(lo, Math.min(hi, n));
}

function safeName(v, fallback) {
  var t = String(v === null || v === undefined ? "" : v).trim();
  if (t === "" || t.length > DEFAULT_MAX_NAME) return fallback;
  return t;
}

function safePath(v) {
  if (v === null || v === undefined) return "";
  var t = String(v);
  if (t.length > DEFAULT_MAX_PATH) return "";
  return t;
}

function resolvePath(p, home) {
  if (!p) return "";
  var s = String(p);
  if (s.charAt(0) === "~") s = home + s.substring(1);
  return s;
}

function toFileUrl(p, home) {
  if (!p) return "";
  var s = String(p);
  if (s.indexOf("://") !== -1) return s;
  return "file://" + resolvePath(s, home).replace(/ /g, "%20");
}

// The optimized sibling OmaLive prefers for playback: <clip>.opt.mp4, written
// by `omalive optimize` (60fps + seamless loop). Pure path transform; the
// existence check is the caller's job (the service keeps an async stat set).
function optimizedSibling(p) {
  var s = String(p === null || p === undefined ? "" : p);
  if (s === "") return "";
  return s + ".opt.mp4";
}

// Normalize a flat { name: value } map with per-key length limits and an entry
// cap. Returns {} on anything that is not a plain object.
function normalizeMap(v, valueMapper) {
  var out = {};
  if (!v || typeof v !== "object" || Array.isArray(v)) return out;
  var n = 0;
  for (var k in v) {
    var name = String(k).trim();
    if (name === "" || name.length > DEFAULT_MAX_NAME) continue;
    if (n >= DEFAULT_MAX_ENTRIES) break;
    out[name] = valueMapper(v[k]);
    n++;
  }
  return out;
}

function normalizeScreenVideos(v) {
  return normalizeMap(v, safePath);
}

function normalizeScreenPositions(v) {
  return normalizeMap(v, function (x) {
    var ms = parseInt(x, 10);
    return isFinite(ms) && ms >= 0 ? ms : 0;
  });
}

// The clip configured for a monitor: its own override ("" = static) or the
// default clip.
function configuredPathForScreen(screenVideos, videoPath, name) {
  var n = String(name);
  var sv = screenVideos || {};
  if (Object.prototype.hasOwnProperty.call(sv, n)) return String(sv[n] || "");
  return String(videoPath || "");
}

// The frozen-frame position for a monitor: its own override or the default.
function frozenPositionFor(screenPositions, frozenPosition, name) {
  var sv = screenPositions || {};
  var n = String(name);
  if (Object.prototype.hasOwnProperty.call(sv, n)) {
    var v = parseInt(sv[n], 10);
    if (isFinite(v) && v >= 0) return v;
  }
  return frozenPosition;
}

// The shared default frozen position from a per-screen positions map: the first
// finite, non-negative entry (mirrors captureFrozenFrames taking the first
// surface's position). Returns fallback when nothing qualifies.
function defaultPositionFrom(positions, fallback) {
  var v = positions || {};
  for (var k in v) {
    var n = parseInt(v[k], 10);
    if (isFinite(n) && n >= 0) return n;
  }
  return fallback;
}

// Deceleration curve for the Sonoma "glide to a stop": rate starts at 1 and
// reaches 0 at t=1. A sqrt eases down slower than a cubic — a cubic sits below
// ~15fps for most of the transition, which QtMultimedia renders as a choppy
// slideshow; sqrt keeps the rate high (≥20fps) until the very end, so the
// glide looks smooth and only stops at the last moment.
function decelRate(t) {
  var p = Math.min(1, Math.max(0, t));
  return Math.sqrt(1 - p);
}

// Duration of the transition in ms from a config value in seconds.
function transitionMs(seconds, fallbackSeconds, lo, hi) {
  return clampInt(seconds, lo, hi, fallbackSeconds) * 1000;
}

// The seek target that lands the player closest to `target`, accounting for the
// looping timeline: when two players drift apart across the loop seam (one at
// 25s, the other just wrapped to 2s), a plain `target - current` delta would
// seek the wrong way. Returns a position in [0, duration) reached with the
// smallest circular step. With no (or invalid) duration the target passes
// through unchanged.
function correctedSeek(current, target, duration) {
  var d = Number(duration);
  if (!isFinite(d) || d <= 0) return Number(target);
  var cur = Number(current) % d;
  var tgt = Number(target) % d;
  if (tgt < 0) tgt += d;
  if (cur < 0) cur += d;
  var delta = tgt - cur;
  while (delta > d / 2) delta -= d;
  while (delta <= -d / 2) delta += d;
  return ((cur + delta) % d + d) % d;
}

// A single human-readable state word from a status object.
function stateWord(o) {
  if (!o || !o.enabled) return "stopped";
  if (o.screensaverActive) return "screensaver";
  if (o.manualPaused) return "paused";
  if (o.wallpaperFrozen) return "frozen";
  if (o.liveWallpaper) return "live";
  var assigned = (o.screens || []).filter(function (s) { return (s.video || "") !== ""; }).length;
  if (assigned === 0) return "no video set";
  return "playing";
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULT_MAX_NAME: DEFAULT_MAX_NAME,
    DEFAULT_MAX_PATH: DEFAULT_MAX_PATH,
    DEFAULT_MAX_ENTRIES: DEFAULT_MAX_ENTRIES,
    clampInt: clampInt,
    safeName: safeName,
    safePath: safePath,
    resolvePath: resolvePath,
    toFileUrl: toFileUrl,
    optimizedSibling: optimizedSibling,
    normalizeMap: normalizeMap,
    normalizeScreenVideos: normalizeScreenVideos,
    normalizeScreenPositions: normalizeScreenPositions,
    configuredPathForScreen: configuredPathForScreen,
    frozenPositionFor: frozenPositionFor,
    defaultPositionFrom: defaultPositionFrom,
    decelRate: decelRate,
    transitionMs: transitionMs,
    correctedSeek: correctedSeek,
    stateWord: stateWord
  };
}