"use strict";
// The settings panel's shortcuts: key names, clashes with Hyprland's
// bindings, and the section it keeps in the user's bindings file.
const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

// A QML JavaScript library, not a node module: run it in a context of its own.
const S = (() => {
  const src = fs.readFileSync(path.join(__dirname, "../app/Shortcuts.js"), "utf8").replace(".pragma library", "");
  const context = {};
  vm.createContext(context);
  vm.runInContext(src, context);
  return context;
})();

// The shape `hyprctl binds -j` reports them in, from Omarchy's defaults.
const BINDS = [
  { modmask: 64, key: "TAB", description: "Next workspace", dispatcher: "__lua", arg: "1", mouse: false, submap: "" },
  { modmask: 65, key: "TAB", description: "Previous workspace", dispatcher: "__lua", arg: "2", mouse: false, submap: "" },
  { modmask: 68, key: "left", description: "Move grouped window focus left", dispatcher: "__lua", arg: "3", mouse: false, submap: "" },
  // Num Lock held when it was bound: still the same combination.
  { modmask: 64 | 16, key: "E", description: "File manager", dispatcher: "__lua", arg: "4", mouse: false, submap: "" },
  { modmask: 64, key: "A", description: "Aerial: Overview", dispatcher: "__lua", arg: "5", mouse: false, submap: "" },
  { modmask: 0, key: "Escape", description: "", dispatcher: "submap", arg: "reset", mouse: false, submap: "aerial-record" },
];

const USER_FILE = '-- my bindings\no.bind("SUPER + X", nil, "foo")\n';

const tests = {
  "a key press becomes the name Omarchy writes"() {
    assert.strictEqual(S.format(S.maskOf(0x10000000 | 0x04000000), S.keyName(0x01000014)), "SUPER + CTRL + Right");
    assert.strictEqual(S.format(S.maskOf(0x10000000 | 0x02000000), S.keyName(0x41)), "SUPER + SHIFT + A");
    assert.strictEqual(S.keyName(0x01000031), "F2");
    assert.strictEqual(S.keyName(0x01000001), "TAB");
    assert.strictEqual(S.keyName(0x01000021), "", "a modifier alone is not a key");
    assert.ok(S.isModifierKey(0x01000021));
  },

  "a written combination reads back"() {
    const combo = S.parse("SUPER + CTRL + Right");
    assert.strictEqual(combo.mask, 68);
    assert.strictEqual(combo.key, "Right");
    assert.strictEqual(S.parse("super + control + right").mask, 68);
    assert.strictEqual(S.parse(""), null);
  },

  "a clash names what already has the keys"() {
    const found = S.conflicts(BINDS, "SUPER + TAB");
    assert.strictEqual(found.length, 1);
    assert.strictEqual(found[0].description, "Next workspace");
  },

  "key names match whatever their case"() {
    assert.strictEqual(S.conflicts(BINDS, "SUPER + CTRL + Left")[0].description, "Move grouped window focus left");
  },

  "a lock key held when binding does not hide a clash"() {
    assert.strictEqual(S.conflicts(BINDS, "SUPER + E").length, 1);
  },

  "Aerial's own bindings and submaps are not clashes"() {
    assert.strictEqual(S.conflicts(BINDS, "SUPER + A").length, 0);
    assert.strictEqual(S.conflicts(BINDS, "Escape").length, 0);
  },

  "saving adds a section and leaves the rest of the file alone"() {
    const text = S.write(USER_FILE, { overview: "SUPER + A", next: "SUPER + TAB" }, { next: true });
    assert.ok(text.startsWith(USER_FILE));
    assert.ok(text.includes('o.bind("SUPER + A", "Aerial: Overview", "omarchy-shell shell toggle reidenxerx.aerial")'));
    assert.ok(text.includes('hl.unbind("SUPER + TAB")'), "taken-over keys are unbound first");
    assert.ok(text.indexOf('hl.unbind("SUPER + TAB")') < text.indexOf('o.bind("SUPER + TAB"'));
    assert.ok(!text.includes('hl.unbind("SUPER + A")'), "only taken-over keys are unbound");
  },

  "the section reads back as it was saved"() {
    const text = S.write(USER_FILE, { overview: "SUPER + A", prev: "SUPER + SHIFT + TAB" }, {});
    const read = S.read(text);
    assert.strictEqual(read.overview, "SUPER + A");
    assert.strictEqual(read.prev, "SUPER + SHIFT + TAB");
    assert.strictEqual(read.next, undefined);
  },

  "saving again replaces the section rather than adding another"() {
    const once = S.write(USER_FILE, { overview: "SUPER + A" }, {});
    const twice = S.write(once, { overview: "SUPER + O" }, {});
    assert.strictEqual(twice.split(S.BEGIN).length - 1, 1);
    assert.strictEqual(S.read(twice).overview, "SUPER + O");
    assert.ok(twice.startsWith(USER_FILE));
  },

  "clearing every shortcut gives the file back exactly"() {
    const saved = S.write(USER_FILE, { overview: "SUPER + A", next: "SUPER + TAB" }, { next: true });
    assert.strictEqual(S.write(saved, {}, {}), USER_FILE);
  },

  "nothing to save changes nothing"() {
    assert.strictEqual(S.write(USER_FILE, {}, {}), USER_FILE);
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
