// node tests/model.test.js [bindings.txt]
// Without a file the last part reads `omarchy-menu-keybindings --print` live
// (skipped when the command is missing).
const fs = require("fs")
const path = require("path")
const assert = require("assert")
const { execFileSync } = require("child_process")

const root = path.join(__dirname, "..")
const src = fs.readFileSync(path.join(root, "KeycueModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const M = new Function(src + `
return { parseJsonc, settingsFrom, triggerMask, parseColorsToml, resolveColor, parseKeymapModifiers,
  luaConfig, keyInfo, comboText, normalizeCombo, parseLine, parseBindings, parseHyprctlBinds,
  digitTemplate, level, SUPER, SHIFT, CTRL, ALT }`)()
const schemaText = fs.readFileSync(path.join(root, "Schema.js"), "utf8")
const schema = JSON.parse(schemaText.slice(schemaText.indexOf("{", schemaText.indexOf("var SCHEMA")), schemaText.lastIndexOf("}") + 1))
let passed = 0
const test = (name, fn) => { fn(); passed++ }

test("jsonc", () => {
  assert.deepStrictEqual(M.parseJsonc('{\n // c\n "a": "x // not a comment", /* b */ "b": [1, 2,],\n}'), { a: "x // not a comment", b: [1, 2] })
  assert.deepStrictEqual(M.parseJsonc('{"s": "a \\" /* q */"}'), { s: 'a " /* q */' })
  assert.deepStrictEqual(M.parseJsonc(""), {})
  assert.strictEqual(M.parseJsonc("{ broken"), null)
})

test("settings defaults and validation", () => {
  const d = M.settingsFrom("", schema)
  assert.strictEqual(d.ok, true)
  for (const o of schema.options) assert.deepStrictEqual(d[o.key], o.default, o.key)
  const s = M.settingsFrom(`{
    "delay": "250", "triggers": ["alt", "bogus", "alt"], "afterKey": "nope",
    "backgroundOpacity": 0.65, "maxHeight": "70%", "scale": 9, "margin": -40,
    "hide": ["Universal", 3, ""], "rename": {"SUPER + RETURN": "Alacritty", "x": 1},
    "showHeader": "yes", "position": "center", "textColor": " red "
  }`, schema)
  assert.strictEqual(s.delay, 250)
  assert.deepStrictEqual(s.triggers, ["alt"])
  assert.strictEqual(s.afterKey, "hide")
  assert.strictEqual(s.backgroundOpacity, 65)
  assert.strictEqual(s.maxHeight, 70)
  assert.strictEqual(s.scale, 3)
  assert.strictEqual(s.margin, -1)
  assert.deepStrictEqual(s.hide, ["Universal"])
  assert.deepStrictEqual(s.rename, { "SUPER + RETURN": "Alacritty" })
  assert.strictEqual(s.showHeader, true)
  assert.strictEqual(s.position, "center")
  assert.strictEqual(s.textColor, "red")
  const broken = M.settingsFrom("{ nope", schema)
  assert.strictEqual(broken.ok, false)
  assert.strictEqual(broken.delay, 400)
  assert.strictEqual(M.triggerMask(["super", "ctrl"]), 68)
  assert.strictEqual(M.triggerMask([]), 64)
})

test("colours", () => {
  const roles = M.parseColorsToml('accent = "#89b4fa"\nmode = "dark"\nred = "#f38ba8cc"\n# x = "#000000"')
  assert.deepStrictEqual(roles, { accent: "#89b4fa", red: "#f38ba8cc" })
  assert.strictEqual(M.resolveColor("theme", roles), null)
  assert.strictEqual(M.resolveColor("accent", roles), "#89b4fa")
  assert.strictEqual(M.resolveColor("red", roles), "#f38ba8")
  assert.strictEqual(M.resolveColor("#abc", roles), "#aabbcc")
  assert.strictEqual(M.resolveColor("#123456", roles), "#123456")
  assert.strictEqual(M.resolveColor("nonsense", roles), null)
})

test("keymap modifiers", () => {
  const km = `xkb_keycodes { <LFSH> = 50; <LALT> = 64; <CAPS> = 66; <LWIN> = 133; <SUPR> = 206; alias <ALIASCAPS> = <CAPS>; };
    xkb_symbols { modifier_map Shift { <LFSH> }; modifier_map Lock { <LFSH> };
    modifier_map Mod1 { <LWIN> }; modifier_map Mod4 { <LALT>, <CAPS>, <SUPR> }; modifier_map Mod5 { <LVL3> }; };`
  assert.deepStrictEqual(M.parseKeymapModifiers(km), { 50: 1, 133: 8, 64: 64, 66: 64, 206: 64 })
  assert.strictEqual(M.parseKeymapModifiers("garbage"), null)
  const lua = M.luaConfig({ version: "1.0", mods: { 133: 64 }, trigger: 64, pointer: true, namespace: 'a"b\\c' })
  assert.strictEqual(lua, 'local CONFIG = { version = "1.0", mods = { [133] = 64 }, trigger = 64, pointer = true, namespace = "a\\"b\\\\c" }\n')
})

test("combos", () => {
  assert.strictEqual(M.comboText(65, "RETURN"), "SUPER SHIFT + RETURN")
  assert.strictEqual(M.comboText(0, "XF86AudioMute"), "XF86AudioMute")
  assert.strictEqual(M.normalizeCombo("shift+super + return"), "SUPER SHIFT + RETURN")
  assert.strictEqual(M.normalizeCombo("SUPER + LEFT MOUSE BUTTON"), "SUPER + LEFT MOUSE BUTTON")
  assert.deepStrictEqual(M.parseLine("SUPER SHIFT + RETURN   → Browser"), { mods: 65, key: "RETURN", desc: "Browser" })
  assert.strictEqual(M.parseLine("BOGUS + K → x"), null)
  assert.strictEqual(M.keyInfo("return", { RETURN: "⏎" }).label, "⏎")
})

test("hyprctl fallback", () => {
  const json = JSON.stringify([
    { modmask: 64, key: "K", has_description: true, description: "Keys", submap: "", dispatcher: "__lua", arg: "1" },
    { modmask: 64, key: "", has_description: true, description: "Workspace 1", submap: "", dispatcher: "__lua", arg: "2" },
    { modmask: 65, key: "Q", has_description: false, description: "", submap: "", dispatcher: "killactive", arg: "" },
    { modmask: 64, key: "Z", has_description: false, description: "", submap: "", dispatcher: "__lua", arg: "3" },
    { modmask: 64, key: "R", has_description: true, description: "Resize", submap: "resize", dispatcher: "x", arg: "" },
  ])
  const b = M.parseHyprctlBinds(json)
  assert.deepStrictEqual(b.map(x => [x.mods, x.key, x.desc]), [[64, "K", "Keys"], [65, "Q", "killactive"]])
  assert.deepStrictEqual(M.parseHyprctlBinds("nope"), [])
})

const synth = M.parseBindings([
  "SUPER + K → Keys", "SUPER + K → Keys",
  "SUPER + 1 → Go 1", "SUPER + 2 → Go 2", "SUPER + 3 → Go 3",
  "SUPER + 5 → Hop 5", "SUPER + 7 → Hop 7", "SUPER + 8 → Hop 8",
  "SUPER + RETURN → Terminal", "SUPER + A → Zeta",
  "SUPER SHIFT + B → Browser", "SUPER SHIFT + 1 → Move 1", "SUPER SHIFT ALT + X → Deep",
  "SUPER CTRL ALT + Y → Deeper",
].join("\n"))

test("levels: collapse, sort, hide, rename, labels", () => {
  assert.strictEqual(synth.length, 13, "duplicate line dropped")
  const opts = M.settingsFrom("", schema)
  let l = M.level(synth, 64, opts)
  assert.deepStrictEqual(l.rows.map(r => r.label), ["A", "K", "1–3", "5", "7", "8", "Enter"])
  assert.deepStrictEqual(l.held.map(h => h.label), ["❖ Super"])
  l = M.level(synth, 64, { ...opts, minRun: 4 })
  assert.deepStrictEqual(l.rows.map(r => r.label), ["A", "K", "1", "2", "3", "5", "7", "8", "Enter"])
  l = M.level(synth, 64, { ...opts, collapseRuns: false })
  assert.strictEqual(l.rows.length, 9)
  l = M.level(synth, 64, { ...opts, sort: "description" })
  assert.deepStrictEqual(l.rows.map(r => r.desc), ["Go N", "Hop 5", "Hop 7", "Hop 8", "Keys", "Terminal", "Zeta"])
  l = M.level(synth, 64, { ...opts, sort: "config" })
  assert.deepStrictEqual(l.rows.map(r => r.desc), ["Keys", "Go N", "Hop 5", "Hop 7", "Hop 8", "Terminal", "Zeta"])
  l = M.level(synth, 64, { ...opts, hide: ["^hop", "SUPER \\+ A$", "(bad"], rename: { "super+return": "Alacritty" }, keyLabels: { RETURN: "⏎" } })
  assert.deepStrictEqual(l.rows.map(r => r.label + " " + r.desc), ["K Keys", "1–3 Go N", "⏎ Alacritty"])
})

test("levels: footer counts and modifier labels", () => {
  const opts = M.settingsFrom("", schema)
  let l = M.level(synth, 64, opts)
  assert.deepStrictEqual(l.deeper.map(d => [d.label, d.count]), [["⇧ Shift", 2], ["⌃ Ctrl", 0], ["⌥ Alt", 0]])
  l = M.level(synth, 64, { ...opts, footerCount: "reachable" })
  assert.deepStrictEqual(l.deeper.map(d => d.count), [3, 1, 2])
  l = M.level(synth, 64, { ...opts, footerCount: "none", modifierStyle: "glyph", modifierGlyphs: { shift: "S" } })
  assert.deepStrictEqual(l.deeper.map(d => [d.label, d.count]), [["S", null], ["⌃", null], ["⌥", null]])
  l = M.level(synth, 64 | 1, { ...opts, modifierStyle: "name", modifierNames: { super: "Win" } })
  assert.deepStrictEqual(l.held.map(h => h.label), ["Win", "Shift"])
  assert.deepStrictEqual(l.rows.map(r => r.label), ["B", "1"])
  // With Alt as the trigger, Super shows up as a way deeper too.
  l = M.level(synth, 8, opts)
  assert.deepStrictEqual(l.deeper.map(d => d.label), ["❖ Super", "⇧ Shift", "⌃ Ctrl"])
})

let liveText = null
if (process.argv[2]) liveText = fs.readFileSync(process.argv[2], "utf8")
else { try { liveText = execFileSync("omarchy-menu-keybindings", ["--print"], { encoding: "utf8" }) } catch (e) {} }
if (liveText) {
  test("live bindings", () => {
    const all = M.parseBindings(liveText)
    const opts = M.settingsFrom("", schema)
    const top = M.level(all, 64, opts)
    assert(top.rows.some(r => r.label === "1–0" && r.desc === "Switch to workspace N"))
    assert(top.rows.every(r => r.label !== ""))
    console.log(`live: ${all.length} bindings, Super level ${top.rows.length} rows, footer ` +
      top.deeper.map(d => `${d.label} ${d.count}`).join(", "))
  })
}
console.log(`${passed} test groups passed`)
