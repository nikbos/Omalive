"use strict";

const { test } = require("node:test");
const assert = require("node:assert");

const M = require("../Model.js");

test("clampInt clamps into range and falls back on garbage", () => {
  assert.strictEqual(M.clampInt(5, 1, 10, 2), 5);
  assert.strictEqual(M.clampInt(0, 1, 10, 2), 1);
  assert.strictEqual(M.clampInt(99, 1, 10, 2), 10);
  assert.strictEqual(M.clampInt("nope", 1, 10, 2), 2);
  assert.strictEqual(M.clampInt(undefined, 1, 10, 2), 2);
  assert.strictEqual(M.clampInt("4.9", 1, 10, 2), 4);
});

test("safeName trims, rejects empty and over-long names", () => {
  assert.strictEqual(M.safeName("  DP-1  ", "all"), "DP-1");
  assert.strictEqual(M.safeName("", "all"), "all");
  assert.strictEqual(M.safeName(null, "all"), "all");
  assert.strictEqual(M.safeName("x".repeat(300), "all"), "all");
  assert.strictEqual(M.safeName(undefined, "all"), "all");
});

test("safePath rejects null and over-long paths", () => {
  assert.strictEqual(M.safePath("/tmp/a.mp4"), "/tmp/a.mp4");
  assert.strictEqual(M.safePath(""), "");
  assert.strictEqual(M.safePath(null), "");
  assert.strictEqual(M.safePath("x".repeat(M.DEFAULT_MAX_PATH + 1)), "");
  assert.strictEqual(M.safePath("x".repeat(M.DEFAULT_MAX_PATH)).length, M.DEFAULT_MAX_PATH);
});

test("resolvePath expands ~ and passes absolute paths through", () => {
  assert.strictEqual(M.resolvePath("~/Videos/a.mp4", "/home/u"), "/home/u/Videos/a.mp4");
  assert.strictEqual(M.resolvePath("/abs/b.mp4", "/home/u"), "/abs/b.mp4");
  assert.strictEqual(M.resolvePath("", "/home/u"), "");
});

test("toFileUrl encodes spaces and leaves remote urls alone", () => {
  assert.strictEqual(M.toFileUrl("~/Videos/my clip.mp4", "/home/u"),
    "file:///home/u/Videos/my%20clip.mp4");
  assert.strictEqual(M.toFileUrl("https://example.com/v.mp4", "/home/u"), "https://example.com/v.mp4");
});

test("optimizedSibling appends .opt.mp4 and handles empties", () => {
  assert.strictEqual(M.optimizedSibling("/tmp/a.mp4"), "/tmp/a.mp4.opt.mp4");
  assert.strictEqual(M.optimizedSibling("/tmp/a.mp4.opt.mp4"), "/tmp/a.mp4.opt.mp4.opt.mp4");
  assert.strictEqual(M.optimizedSibling(""), "");
  assert.strictEqual(M.optimizedSibling(null), "");
  assert.strictEqual(M.optimizedSibling(undefined), "");
});

test("normalizeMap accepts only plain objects and caps entries", () => {
  assert.deepStrictEqual(M.normalizeMap(null, (x) => x), {});
  assert.deepStrictEqual(M.normalizeMap([1, 2], (x) => x), {});
  assert.deepStrictEqual(M.normalizeMap({}, (x) => x), {});

  const src = {};
  for (let i = 0; i < M.DEFAULT_MAX_ENTRIES + 5; i++) src["mon" + i] = i;
  const out = M.normalizeMap(src, (x) => x);
  assert.strictEqual(Object.keys(out).length, M.DEFAULT_MAX_ENTRIES);

  assert.deepStrictEqual(
    M.normalizeMap({ "  DP-1 ": "/a.mp4", "DP-2": "/b.mp4" }, (x) => x),
    { "DP-1": "/a.mp4", "DP-2": "/b.mp4" });
});

test("normalizeScreenVideos applies safePath to values", () => {
  assert.deepStrictEqual(
    M.normalizeScreenVideos({ "DP-1": "/a.mp4", "DP-2": "" }),
    { "DP-1": "/a.mp4", "DP-2": "" });
  assert.deepStrictEqual(M.normalizeScreenVideos({ "DP-1": null }), { "DP-1": "" });
  assert.deepStrictEqual(M.normalizeScreenVideos("nope"), {});
});

test("normalizeScreenPositions coerces integers and clamps negatives", () => {
  assert.deepStrictEqual(M.normalizeScreenPositions({ "DP-1": "1200", "DP-2": -5, "DP-3": "junk" }),
    { "DP-1": 1200, "DP-2": 0, "DP-3": 0 });
});

test("configuredPathForScreen: override wins, empty override blanks, else default", () => {
  const sv = { "DP-1": "/a.mp4", "DP-2": "" };
  assert.strictEqual(M.configuredPathForScreen(sv, "/default.mp4", "DP-1"), "/a.mp4");
  assert.strictEqual(M.configuredPathForScreen(sv, "/default.mp4", "DP-2"), "");
  assert.strictEqual(M.configuredPathForScreen(sv, "/default.mp4", "HDMI-A-1"), "/default.mp4");
  assert.strictEqual(M.configuredPathForScreen({}, "", "DP-1"), "");
  assert.strictEqual(M.configuredPathForScreen(null, null, "DP-1"), "");
});

test("frozenPositionFor: per-screen position wins, bad values fall back", () => {
  const sp = { "DP-1": 5000 };
  assert.strictEqual(M.frozenPositionFor(sp, 100, "DP-1"), 5000);
  assert.strictEqual(M.frozenPositionFor(sp, 100, "DP-2"), 100);
  assert.strictEqual(M.frozenPositionFor({ "DP-1": -3 }, 100, "DP-1"), 100);
  assert.strictEqual(M.frozenPositionFor(null, 0, "DP-1"), 0);
});

test("defaultPositionFrom picks the first usable position, else fallback", () => {
  assert.strictEqual(M.defaultPositionFrom({ "DP-1": 5000, "DP-2": 7000 }, 0), 5000);
  assert.strictEqual(M.defaultPositionFrom({ "DP-1": "junk", "DP-2": 1500 }, 0), 1500);
  assert.strictEqual(M.defaultPositionFrom({ "DP-1": -3 }, 42), 42);
  assert.strictEqual(M.defaultPositionFrom({}, 42), 42);
  assert.strictEqual(M.defaultPositionFrom(null, 42), 42);
  assert.strictEqual(M.defaultPositionFrom({ "DP-1": "2500" }, 0), 2500);
});

test("decelRate eases 1 -> 0 with the Sonoma curve", () => {
  assert.strictEqual(M.decelRate(0), 1);
  assert.strictEqual(M.decelRate(1), 0);
  assert.ok(Math.abs(M.decelRate(0.5) - 0.125) < 1e-9); // (1-0.5)^3
  assert.ok(Math.abs(M.decelRate(0.25) - Math.pow(0.75, 3)) < 1e-9);
  assert.strictEqual(M.decelRate(-1), 1);
  assert.strictEqual(M.decelRate(2), 0);
});

test("transitionMs converts seconds to ms and clamps", () => {
  assert.strictEqual(M.transitionMs(2, 2, 1, 10), 2000);
  assert.strictEqual(M.transitionMs(0, 2, 1, 10), 1000);
  assert.strictEqual(M.transitionMs(20, 2, 1, 10), 10000);
  assert.strictEqual(M.transitionMs(undefined, 2, 1, 10), 2000);
});

test("stateWord picks the right human state", () => {
  assert.strictEqual(M.stateWord({ enabled: false }), "stopped");
  assert.strictEqual(M.stateWord({ enabled: true, screensaverActive: true }), "screensaver");
  assert.strictEqual(M.stateWord({ enabled: true, manualPaused: true }), "paused");
  assert.strictEqual(M.stateWord({ enabled: true, wallpaperFrozen: true }), "frozen");
  assert.strictEqual(M.stateWord({ enabled: true, liveWallpaper: true, wallpaperFrozen: false }), "live");
  assert.strictEqual(M.stateWord({ enabled: true, screens: [{ video: "", fileExists: true }] }), "no video set");
  assert.strictEqual(M.stateWord({ enabled: true, screens: [{ video: "/a.mp4", fileExists: true }] }), "playing");
  assert.strictEqual(M.stateWord({}), "stopped");
});