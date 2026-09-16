"use strict";
// What the spread must do, checked against real geometry rather than by eye.
const assert = require("assert");
const { spread, overlaps, inReadingOrder, nextIn, groupBy, columns } = require("../app/Layout.js");

const AREA = { width: 1600, height: 820 };

// The windows actually on this laptop's workspace 1, from `hyprctl clients`.
const REAL = [
  { key: "foot", x: 12, y: 39, w: 518, h: 949 },
  { key: "warp", x: 544, y: 39, w: 513, h: 949 },
  { key: "quickshell", x: 1071, y: 39, w: 517, h: 949 },
];

function inside(slots, area) {
  return slots.every(s => s.x >= -0.5 && s.y >= -0.5
    && s.x + s.w <= area.width + 0.5 && s.y + s.h <= area.height + 0.5);
}

function aspectOf(slot) { return slot.w / slot.h; }

const tests = {
  "nothing overlaps, for any window count"() {
    for (let n = 1; n <= 12; n++) {
      const windows = [];
      for (let i = 0; i < n; i++) {
        windows.push({ key: "w" + i, x: (i % 4) * 400, y: Math.floor(i / 4) * 300,
                       w: 300 + (i % 3) * 260, h: 260 + (i % 2) * 420 });
      }
      const slots = spread(windows, AREA);
      assert.strictEqual(slots.length, n, `${n} windows in, ${slots.length} out`);
      assert.strictEqual(overlaps(slots), null, `overlap with ${n} windows`);
      assert.ok(inside(slots, AREA), `a slot left the area with ${n} windows`);
    }
  },

  "every thumbnail keeps its window's shape"() {
    const slots = spread(REAL, AREA);
    slots.forEach(slot => {
      const win = REAL.find(w => w.key === slot.key);
      const wanted = win.w / win.h;
      assert.ok(Math.abs(aspectOf(slot) - wanted) < 0.02,
        `${slot.key}: aspect ${aspectOf(slot).toFixed(3)} want ${wanted.toFixed(3)}`);
    });
  },

  "reading order: top to bottom, then left to right"() {
    const windows = [
      { key: "topright", x: 900, y: 10, w: 400, h: 300 },
      { key: "topleft", x: 20, y: 30, w: 400, h: 300 },
      { key: "bottom", x: 400, y: 600, w: 400, h: 300 },
    ];
    const order = inReadingOrder(windows, AREA.height / 6).map(w => w.key);
    assert.deepStrictEqual(order, ["topleft", "topright", "bottom"]);
  },

  "a window that was on the left stays on the left"() {
    const slots = spread(REAL, AREA);
    const byX = slots.slice().sort((a, b) => a.x - b.x).map(s => s.key);
    assert.deepStrictEqual(byX, ["foot", "warp", "quickshell"]);
  },

  "one window does not become a banner"() {
    const [slot] = spread([{ key: "only", x: 0, y: 0, w: 1600, h: 900 }], AREA);
    assert.ok(slot.h <= AREA.height * 0.87, `a lone window took ${slot.h} of ${AREA.height}`);
    assert.ok(slot.w <= AREA.width, "and it must still fit");
  },

  "many small windows still fit"() {
    const windows = [];
    for (let i = 0; i < 24; i++) windows.push({ key: "w" + i, x: (i * 97) % 1500, y: (i * 53) % 900, w: 500, h: 400 });
    const slots = spread(windows, AREA);
    assert.strictEqual(overlaps(slots), null, "24 windows overlapped");
    assert.ok(inside(slots, AREA), "24 windows did not fit");
  },

  "windows with no size are dropped rather than drawn as nothing"() {
    const slots = spread([{ key: "ok", x: 0, y: 0, w: 800, h: 600 },
                          { key: "zero", x: 0, y: 0, w: 0, h: 0 }], AREA);
    assert.deepStrictEqual(slots.map(s => s.key), ["ok"]);
  },

  "no windows is not a crash"() {
    assert.deepStrictEqual(spread([], AREA), []);
  },

  "the spread is centred in its area"() {
    const slots = spread(REAL, AREA);
    const left = Math.min(...slots.map(s => s.x));
    const right = Math.max(...slots.map(s => s.x + s.w));
    const top = Math.min(...slots.map(s => s.y));
    const bottom = Math.max(...slots.map(s => s.y + s.h));
    assert.ok(Math.abs(left - (AREA.width - right)) < 1.5, "not centred horizontally");
    assert.ok(Math.abs(top - (AREA.height - bottom)) < 1.5, "not centred vertically");
  },

  "rows can be spaced further apart than the windows on them"() {
    const windows = [];
    for (let i = 0; i < 8; i++) {
      windows.push({ key: "w" + i, x: (i % 4) * 400, y: Math.floor(i / 4) * 400, w: 600, h: 400 });
    }
    const slots = spread(windows, AREA, { gap: 26, rowGap: 62 });
    const tops = [...new Set(slots.map(s => Math.round(s.y)))].sort((a, b) => a - b);
    assert.ok(tops.length > 1, "expected more than one row");
    const height = slots.find(s => Math.round(s.y) === tops[0]).h;
    assert.ok(Math.abs((tops[1] - (tops[0] + height)) - 62) < 1.5,
      `rows are ${tops[1] - (tops[0] + height)} apart, wanted 62`);
    assert.ok(inside(slots, AREA), "a wider row gap pushed a slot out of the area");
  },

  "a caption under one row cannot touch the row beneath it"() {
    // What the overview actually asks for, at the size it actually uses.
    const windows = [];
    for (let i = 0; i < 8; i++) {
      windows.push({ key: "w" + i, x: (i % 4) * 620, y: Math.floor(i / 4) * 500, w: 900, h: 600 });
    }
    const slots = spread(windows, { width: 1544, height: 814 }, { gap: 26, rowGap: 62, maxScale: 0.8 });
    const caption = 40; // the pill, plus the margin above it
    for (const a of slots) {
      for (const b of slots) {
        if (a === b || b.y <= a.y) continue;
        const captionBottom = a.y + a.h + caption;
        const overlapsBelow = b.x < a.x + a.w && a.x < b.x + b.w && b.y < captionBottom;
        assert.ok(!overlapsBelow, `${a.key}'s caption runs into ${b.key}`);
      }
    }
  },

  "arrow keys walk the spread by geometry, not by index"() {
    const slots = [
      { key: "tl", x: 0, y: 0, w: 300, h: 200 },
      { key: "tr", x: 400, y: 0, w: 300, h: 200 },
      { key: "bl", x: 0, y: 300, w: 300, h: 200 },
      { key: "br", x: 400, y: 300, w: 300, h: 200 },
    ];
    assert.strictEqual(nextIn(slots, "tl", 1, 0), "tr", "right from top-left");
    assert.strictEqual(nextIn(slots, "tr", -1, 0), "tl", "left from top-right");
    assert.strictEqual(nextIn(slots, "tl", 0, 1), "bl", "down from top-left");
    assert.strictEqual(nextIn(slots, "br", 0, -1), "tr", "up from bottom-right");
    assert.strictEqual(nextIn(slots, "tr", 1, 0), null, "nothing to the right of the last one");
    assert.strictEqual(nextIn(slots, "nobody", 1, 0), "tl", "an unknown start selects the first");
    assert.strictEqual(nextIn([], "tl", 1, 0), null, "an empty spread has nowhere to go");
  },

  "windows gather into their workspaces, in order"() {
    const windows = [
      { key: "a", workspace: 3, x: 0, y: 0, w: 400, h: 300 },
      { key: "b", workspace: 1, x: 0, y: 0, w: 400, h: 300 },
      { key: "c", workspace: 3, x: 500, y: 0, w: 400, h: 300 },
    ];
    const groups = groupBy(windows, w => w.workspace);
    assert.deepStrictEqual(groups.map(g => g.key), [1, 3]);
    assert.deepStrictEqual(groups[1].windows.map(w => w.key), ["a", "c"]);
  },

  "every workspace gets its own column, and columns do not collide"() {
    const windows = [];
    for (let i = 0; i < 9; i++) {
      windows.push({ key: "w" + i, workspace: (i % 3) + 1,
                     x: (i % 3) * 500, y: 0, w: 700, h: 900 });
    }
    const groups = groupBy(windows, w => w.workspace);
    const laid = columns(groups, AREA, { gap: 26, rowGap: 62, maxScale: 0.78 });
    assert.strictEqual(laid.length, 3, "one column per workspace");

    const all = [];
    laid.forEach(column => column.slots.forEach(slot => {
      // Slots come back relative to their column; the surface adds column.x.
      all.push({ key: slot.key, x: slot.x + column.x, y: slot.y, w: slot.w, h: slot.h });
      assert.ok(slot.x + slot.w <= column.width + 0.5,
        `${slot.key} overflows its column (${slot.x + slot.w} > ${column.width})`);
    }));
    assert.strictEqual(all.length, 9, "no window lost");
    assert.strictEqual(overlaps(all), null, "columns overlapped each other");
    const right = Math.max(...all.map(s => s.x + s.w));
    assert.ok(right <= AREA.width + 0.5, `columns ran past the area (${right})`);
  },

  "a column is used more fully than a band would be"() {
    // The reason for columns: tall windows on a wide screen.
    const windows = [];
    for (let i = 0; i < 8; i++) {
      windows.push({ key: "w" + i, workspace: Math.floor(i / 2) + 1,
                     x: 0, y: 0, w: 520, h: 950 });
    }
    const groups = groupBy(windows, w => w.workspace);
    const laid = columns(groups, AREA, { gap: 26, rowGap: 62, maxScale: 0.78 });
    const tallest = Math.max(...laid.map(c => Math.max(...c.slots.map(s => s.h))));
    assert.ok(tallest > AREA.height * 0.3,
      `windows only reached ${Math.round(tallest)} of ${AREA.height}; columns are not being filled`);
  },

  "no groups is not a crash"() {
    assert.deepStrictEqual(columns([], AREA, {}), []);
  },

  "the same input lays out the same way twice"() {
    assert.deepStrictEqual(spread(REAL, AREA), spread(REAL, AREA));
  },
};

let failed = 0;
for (const [name, run] of Object.entries(tests)) {
  try {
    run();
    console.log("  ok   " + name);
  } catch (e) {
    failed++;
    console.log("  FAIL " + name + "\n       " + e.message);
  }
}
console.log(failed ? `\n${failed} failing` : `\n${Object.keys(tests).length} passing`);
process.exit(failed ? 1 : 0);
