.pragma library

// Pure helpers for Keycue: read the config and the keybinding list, and
// build the rows shown for one set of held modifiers. No QML types here, so
// the file can be tested with node (tests/model.test.js).

var SHIFT = 1, CTRL = 4, ALT = 8, SUPER = 64

var MODIFIER_BITS = { SUPER: SUPER, SHIFT: SHIFT, CTRL: CTRL, CONTROL: CTRL, ALT: ALT }

// Header/footer order follows Omarchy's own cheat sheet: SUPER SHIFT CTRL ALT.
var MODIFIERS = [
  { id: "super", bit: SUPER, word: "SUPER", name: "Super", glyph: "❖" },
  { id: "shift", bit: SHIFT, word: "SHIFT", name: "Shift", glyph: "⇧" },
  { id: "ctrl", bit: CTRL, word: "CTRL", name: "Ctrl", glyph: "⌃" },
  { id: "alt", bit: ALT, word: "ALT", name: "Alt", glyph: "⌥" }
]

// ------------------------------------------------------------------ config

// JSON with // and /* */ comments and trailing commas. Returns null when the
// text isn't valid even after that.
function parseJsonc(text) {
  var src = String(text || "")
  var out = ""
  var i = 0
  var inString = false
  while (i < src.length) {
    var c = src.charAt(i)
    var next = src.charAt(i + 1)
    if (inString) {
      out += c
      if (c === "\\") { out += next; i += 2; continue }
      if (c === "\"") inString = false
      i++
    } else if (c === "\"") {
      inString = true
      out += c
      i++
    } else if (c === "/" && next === "/") {
      while (i < src.length && src.charAt(i) !== "\n") i++
    } else if (c === "/" && next === "*") {
      var end = src.indexOf("*/", i + 2)
      i = end < 0 ? src.length : end + 2
    } else {
      out += c
      i++
    }
  }
  out = out.replace(/,(\s*[}\]])/g, "$1")
  if (out.trim() === "") return {}
  try { return JSON.parse(out) } catch (e) { return null }
}

function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)) }

function isPlainObject(v) { return v !== null && typeof v === "object" && !Array.isArray(v) }

function copyDefault(v) {
  if (Array.isArray(v)) return v.slice()
  if (isPlainObject(v)) { var o = {}; for (var k in v) o[k] = v[k]; return o }
  return v
}

// One value checked against its schema option; anything unusable falls back
// to the default.
function coerce(opt, value) {
  var d = copyDefault(opt["default"])
  if (value === undefined || value === null) return d
  switch (opt.type) {
  case "int":
  case "float": {
    var n
    if (typeof value === "string" && /%\s*$/.test(value)) n = Number(value.replace(/%\s*$/, ""))
    else n = Number(value)
    if (typeof value === "boolean" || !isFinite(n)) return d
    // Percentages may also be written as fractions (0.65 for 65%).
    if (opt.unit === "%" && n > 0 && n < 1) n = n * 100
    if (opt.type === "int") n = Math.round(n)
    return clamp(n, opt.min, opt.max)
  }
  case "bool":
    return typeof value === "boolean" ? value : d
  case "enum":
    for (var i = 0; i < opt.choices.length; i++)
      if (opt.choices[i].value === value) return value
    return d
  case "flags": {
    if (!Array.isArray(value)) return d
    var allowed = opt.choices.map(function (c) { return c.value })
    var picked = []
    for (var j = 0; j < value.length; j++)
      if (allowed.indexOf(value[j]) !== -1 && picked.indexOf(value[j]) === -1) picked.push(value[j])
    return picked.length > 0 ? picked : d
  }
  case "string":
    return typeof value === "string" ? value : d
  case "color":
    return typeof value === "string" && value.trim() !== "" ? value.trim() : d
  case "list": {
    if (!Array.isArray(value)) return d
    return value.filter(function (x) { return typeof x === "string" && x !== "" })
  }
  case "map": {
    if (!isPlainObject(value)) return d
    var m = {}
    for (var key in value)
      if (typeof value[key] === "string") m[key] = value[key]
    return m
  }
  }
  return d
}

// Settings from the text of keycue.jsonc: every schema option, defaulted
// and validated. `ok` is false when the file couldn't be parsed.
function settingsFrom(configText, schema) {
  var parsed = parseJsonc(configText)
  var user = isPlainObject(parsed) ? parsed : {}
  var out = { ok: parsed !== null }
  var options = (schema && schema.options) || []
  for (var i = 0; i < options.length; i++)
    out[options[i].key] = coerce(options[i], user[options[i].key])
  return out
}

function triggerMask(triggers) {
  var mask = 0
  var list = triggers || []
  for (var i = 0; i < MODIFIERS.length; i++)
    if (list.indexOf(MODIFIERS[i].id) !== -1) mask |= MODIFIERS[i].bit
  return mask || SUPER
}

// ------------------------------------------------------------------ colours

// colors.toml: `name = "#rrggbb"` lines; only plain colour entries are kept.
function parseColorsToml(text) {
  var roles = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = /^\s*([A-Za-z0-9_]+)\s*=\s*"(#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?)"/.exec(lines[i])
    if (m) roles[m[1]] = m[2]
  }
  return roles
}

// "theme" (or anything unknown) gives null: use the built-in default. A role
// name resolves through colors.toml; #rgb / #rrggbb pass through.
function resolveColor(value, roles) {
  var v = String(value || "").trim()
  if (v === "" || v === "theme") return null
  if (/^#[0-9A-Fa-f]{3}$/.test(v)) return "#" + v.charAt(1) + v.charAt(1) + v.charAt(2) + v.charAt(2) + v.charAt(3) + v.charAt(3)
  if (/^#[0-9A-Fa-f]{6}$/.test(v)) return v
  if (roles && roles[v]) return roles[v].slice(0, 7)
  return null
}

// ------------------------------------------------------------------- keymap

// Which keycodes act as Shift / Control / Alt (Mod1) / Super (Mod4), from
// `xkbcli compile-keymap` output, so remaps like caps:super are honoured.
function parseKeymapModifiers(text) {
  var src = String(text || "")
  var codes = {}
  var re = /<([A-Za-z0-9_+-]+)>\s*=\s*(\d+)\s*;/g
  var m
  while ((m = re.exec(src)) !== null) codes[m[1]] = parseInt(m[2], 10)
  var aliasRe = /alias\s+<([A-Za-z0-9_+-]+)>\s*=\s*<([A-Za-z0-9_+-]+)>\s*;/g
  while ((m = aliasRe.exec(src)) !== null) if (codes[m[2]] !== undefined) codes[m[1]] = codes[m[2]]
  var bits = { Shift: SHIFT, Control: CTRL, Mod1: ALT, Mod4: SUPER }
  var out = {}
  var mapRe = /modifier_map\s+(\w+)\s*\{([^}]*)\}/g
  var found = false
  while ((m = mapRe.exec(src)) !== null) {
    var bit = bits[m[1]]
    if (!bit) continue
    var names = m[2].match(/<[A-Za-z0-9_+-]+>/g) || []
    for (var i = 0; i < names.length; i++) {
      var code = codes[names[i].slice(1, -1)]
      if (code === undefined) continue
      out[code] = (out[code] || 0) | bit
      found = true
    }
  }
  return found ? out : null
}

// Standard evdev/pc105 positions, for when the keymap can't be compiled.
var DEFAULT_MODIFIER_CODES = { 50: SHIFT, 62: SHIFT, 37: CTRL, 105: CTRL, 64: ALT, 108: ALT, 133: SUPER, 134: SUPER }

// `local CONFIG = {...}` for watcher.lua.
function luaConfig(cfg) {
  function lua(v) {
    if (typeof v === "boolean" || typeof v === "number") return String(v)
    if (typeof v === "string")
      return "\"" + v.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\n/g, "\\n") + "\""
    var parts = []
    for (var k in v) {
      var key = /^\d+$/.test(k) ? "[" + k + "]" : k
      parts.push(key + " = " + lua(v[k]))
    }
    return "{ " + parts.join(", ") + " }"
  }
  return "local CONFIG = " + lua(cfg) + "\n"
}

// ----------------------------------------------------------------- bindings

var NAMED = {
  "RETURN": ["Enter", 3, 0], "ENTER": ["Enter", 3, 0], "KP_ENTER": ["Enter", 3, 0],
  "SPACE": ["Space", 3, 1],
  "TAB": ["Tab", 3, 2],
  "ESCAPE": ["Esc", 3, 3],
  "BACKSPACE": ["Bksp", 3, 4],
  "DELETE": ["Del", 3, 5],
  "INSERT": ["Ins", 3, 6],
  "HOME": ["Home", 3, 7],
  "END": ["End", 3, 8],
  "PRIOR": ["PgUp", 3, 9], "PAGE_UP": ["PgUp", 3, 9],
  "NEXT": ["PgDn", 3, 10], "PAGE_DOWN": ["PgDn", 3, 10],
  "PRINT": ["PrtSc", 3, 11],
  "LEFT": ["←", 4, 0], "RIGHT": ["→", 4, 1], "UP": ["↑", 4, 2], "DOWN": ["↓", 4, 3],
  "MINUS": ["-", 2, 0], "EQUAL": ["=", 2, 1], "BRACKETLEFT": ["[", 2, 2], "BRACKETRIGHT": ["]", 2, 3],
  "SEMICOLON": [";", 2, 4], "APOSTROPHE": ["'", 2, 5], "GRAVE": ["`", 2, 6], "BACKSLASH": ["\\", 2, 7],
  "COMMA": [",", 2, 8], "PERIOD": [".", 2, 9], "SLASH": ["/", 2, 10], "PLUS": ["+", 2, 11],
  "LEFT MOUSE BUTTON": ["LMB", 6, 0], "RIGHT MOUSE BUTTON": ["RMB", 6, 1], "MIDDLE MOUSE BUTTON": ["MMB", 6, 2],
  "MOUSE:272": ["LMB", 6, 0], "MOUSE:273": ["RMB", 6, 1], "MOUSE:274": ["MMB", 6, 2],
  "MOUSE_UP": ["Wheel ↑", 6, 3], "MOUSE_DOWN": ["Wheel ↓", 6, 4],
  "MOUSE_LEFT": ["Wheel ←", 6, 5], "MOUSE_RIGHT": ["Wheel →", 6, 6]
}

var DIGIT_ORDER = "1234567890"

// Sort group and display label for a key. Groups: 0 letters, 1 digits,
// 2 punctuation, 3 named keys, 4 arrows, 5 function keys, 6 mouse,
// 7 media (XF86), 8 anything else.
function keyInfo(key, labels) {
  var raw = String(key || "")
  var upper = raw.toUpperCase()
  var info
  if (NAMED[upper]) info = { label: NAMED[upper][0], group: NAMED[upper][1], order: NAMED[upper][2] }
  else if (/^[A-Z]$/.test(upper)) info = { label: upper, group: 0, order: upper.charCodeAt(0) }
  else if (/^[0-9]$/.test(upper)) info = { label: upper, group: 1, order: DIGIT_ORDER.indexOf(upper) }
  else if (/^F([0-9]{1,2})$/.test(upper)) info = { label: upper, group: 5, order: parseInt(upper.slice(1), 10) }
  else if (upper.indexOf("XF86") === 0) info = { label: raw.slice(4), group: 7, order: 0 }
  else info = { label: raw, group: 8, order: 0 }
  if (labels) {
    for (var k in labels)
      if (k.toUpperCase() === upper) { info.label = labels[k]; break }
  }
  return info
}

// The cheat-sheet spelling of a combo: "SUPER SHIFT + RETURN".
function comboText(mods, key) {
  var words = []
  for (var i = 0; i < MODIFIERS.length; i++)
    if (mods & MODIFIERS[i].bit) words.push(MODIFIERS[i].word)
  return words.length > 0 ? words.join(" ") + " + " + key : String(key)
}

// "super+shift + return" and "SUPER SHIFT + RETURN" both become the latter.
function normalizeCombo(text) {
  var parts = String(text || "").split("+").map(function (p) { return p.trim() }).filter(function (p) { return p !== "" })
  var mods = 0
  var keyParts = []
  for (var i = 0; i < parts.length; i++) {
    var words = parts[i].split(/\s+/)
    var allMods = words.every(function (w) { return MODIFIER_BITS[w.toUpperCase()] !== undefined })
    if (allMods && i < parts.length - 1) {
      for (var j = 0; j < words.length; j++) mods |= MODIFIER_BITS[words[j].toUpperCase()]
    } else {
      keyParts.push(parts[i])
    }
  }
  return comboText(mods, keyParts.join(" + ").toUpperCase())
}

// One line of `omarchy-menu-keybindings --print`:
//   "SUPER SHIFT + RETURN              → Browser"
function parseLine(line) {
  var text = String(line || "")
  var arrow = text.indexOf("→")
  if (arrow < 0) return null
  var combo = text.slice(0, arrow).trim()
  var desc = text.slice(arrow + 1).trim()
  if (combo === "") return null
  var mods = 0
  var key = combo
  var plus = combo.indexOf(" + ")
  if (plus >= 0) {
    var words = combo.slice(0, plus).trim().split(/\s+/)
    for (var i = 0; i < words.length; i++) {
      var bit = MODIFIER_BITS[words[i].toUpperCase()]
      if (bit === undefined) return null
      mods |= bit
    }
    key = combo.slice(plus + 3).trim()
  }
  if (key === "") return null
  return { mods: mods, key: key, desc: desc }
}

function dedupe(list) {
  var out = []
  var seen = {}
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    // Press/release pairs (push-to-talk) list the same combo twice.
    var id = b.mods + "\u0000" + b.key.toUpperCase() + "\u0000" + b.desc
    if (seen[id]) continue
    seen[id] = true
    b.index = out.length
    out.push(b)
  }
  return out
}

function parseBindings(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var b = parseLine(lines[i])
    if (b) out.push(b)
  }
  return dedupe(out)
}

// Fallback source: `hyprctl binds -j`. It loses the key of code:N binds, so
// those are skipped; Lua binds without a description are skipped too.
function parseHyprctlBinds(text) {
  var list
  try { list = JSON.parse(String(text || "")) } catch (e) { return [] }
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (!b || b.submap || !b.key) continue
    var desc = b.has_description ? String(b.description || "") : ""
    if (desc === "" && b.dispatcher && b.dispatcher !== "__lua")
      desc = String(b.dispatcher) + (b.arg ? " " + b.arg : "")
    if (desc === "") continue
    out.push({ mods: Number(b.modmask) & (SHIFT | CTRL | ALT | SUPER), key: String(b.key), desc: desc })
  }
  return dedupe(out)
}

// ------------------------------------------------------------------- levels

function compileRegexes(list) {
  var out = []
  for (var i = 0; i < (list || []).length; i++) {
    try { out.push(new RegExp(list[i], "i")) } catch (e) {}
  }
  return out
}

function matchesAny(regexes, text) {
  for (var i = 0; i < regexes.length; i++)
    if (regexes[i].test(text)) return true
  return false
}

// The number in `desc` that a digit key stands for (workspace 10 sits on 0),
// replaced by "N", or null when the description doesn't carry it.
function digitTemplate(key, desc) {
  var digit = parseInt(key, 10)
  var wanted = digit === 0 ? ["10", "0"] : [String(digit)]
  for (var w = 0; w < wanted.length; w++) {
    var re = new RegExp("(^|[^0-9])" + wanted[w] + "(?![0-9])")
    var m = re.exec(desc)
    if (m) {
      var at = m.index + m[1].length
      return desc.slice(0, at) + "N" + desc.slice(at + wanted[w].length)
    }
  }
  return null
}

// Rows like "Switch to workspace 1" … "10" on keys 1…0 become a single
// "1–0  Switch to workspace N" row. Runs must be contiguous in keyboard order
// and at least `minRun` long; anything else stays as separate rows.
function collapseDigits(rows, minRun) {
  var groups = {}
  var order = []
  var rest = []
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    var tmpl = r.group === 1 ? digitTemplate(r.key, r.desc) : null
    if (tmpl === null) { rest.push(r); continue }
    if (!groups[tmpl]) { groups[tmpl] = []; order.push(tmpl) }
    groups[tmpl].push(r)
  }
  for (var g = 0; g < order.length; g++) {
    var members = groups[order[g]]
    members.sort(function (a, b) { return a.order - b.order })
    var first = members[0].order
    var last = members[members.length - 1].order
    var contiguous = last - first === members.length - 1
    if (members.length >= minRun && contiguous) {
      var index = members[0].index
      for (var k = 1; k < members.length; k++) index = Math.min(index, members[k].index)
      rest.push({
        key: members[0].key,
        label: members[0].label + "–" + members[members.length - 1].label,
        desc: order[g],
        group: 1,
        order: first,
        index: index,
        count: members.length
      })
    } else {
      for (var j = 0; j < members.length; j++) rest.push(members[j])
    }
  }
  return rest
}

function compareByKey(a, b) {
  if (a.group !== b.group) return a.group - b.group
  if (a.order !== b.order) return a.order - b.order
  if (a.label !== b.label) return a.label < b.label ? -1 : 1
  return a.desc < b.desc ? -1 : (a.desc > b.desc ? 1 : 0)
}

function compareByDescription(a, b) {
  var x = a.desc.toLowerCase(), y = b.desc.toLowerCase()
  if (x !== y) return x < y ? -1 : 1
  return compareByKey(a, b)
}

function compareByIndex(a, b) { return a.index - b.index }

function modifierLabel(mod, opts) {
  var names = opts.modifierNames || {}
  var glyphs = opts.modifierGlyphs || {}
  var name = typeof names[mod.id] === "string" ? names[mod.id] : mod.name
  var glyph = typeof glyphs[mod.id] === "string" ? glyphs[mod.id] : mod.glyph
  if (opts.modifierStyle === "glyph") return glyph || name
  if (opts.modifierStyle === "name") return name || glyph
  return glyph && name ? glyph + " " + name : (glyph || name)
}

// Bindings that remain after `hide`, with `rename` applied.
function visibleBindings(bindings, opts) {
  var hide = compileRegexes(opts.hide)
  var rename = {}
  for (var combo in (opts.rename || {})) rename[normalizeCombo(combo)] = opts.rename[combo]
  var out = []
  for (var i = 0; i < (bindings || []).length; i++) {
    var b = bindings[i]
    var text = comboText(b.mods, b.key)
    if (hide.length > 0 && (matchesAny(hide, b.desc) || matchesAny(hide, text))) continue
    var renamed = rename[normalizeCombo(text)]
    out.push({ mods: b.mods, key: b.key, desc: renamed !== undefined ? renamed : b.desc, index: b.index === undefined ? i : b.index })
  }
  return out
}

function rowsFor(list, mods, opts) {
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var b = list[i]
    if (b.mods !== mods) continue
    var info = keyInfo(b.key, opts.keyLabels)
    rows.push({ key: b.key, label: info.label, desc: b.desc, group: info.group, order: info.order, index: b.index, count: 1 })
  }
  if (opts.collapseRuns !== false) rows = collapseDigits(rows, opts.minRun || 3)
  var sort = opts.sort === "description" ? compareByDescription : (opts.sort === "config" ? compareByIndex : compareByKey)
  rows.sort(sort)
  return rows
}

// What to show while `mods` is held: the rows that finish right here, the held
// modifiers for the header, and for each modifier not yet held, whether (and
// how much) lies behind adding it. `opts` is the settings object.
function level(bindings, mods, opts) {
  opts = opts || {}
  var list = visibleBindings(bindings, opts)
  var rows = rowsFor(list, mods, opts)

  var deeper = []
  for (var m = 0; m < MODIFIERS.length; m++) {
    var mod = MODIFIERS[m]
    if (mods & mod.bit) continue
    var want = mods | mod.bit
    var reachable = 0
    for (var j = 0; j < list.length; j++)
      if ((list[j].mods & want) === want) reachable++
    if (reachable === 0) continue
    var count = null
    if (opts.footerCount === "reachable") count = reachable
    else if (opts.footerCount !== "none") count = rowsFor(list, want, opts).length
    // A modifier whose own level is empty still leads somewhere deeper.
    deeper.push({ id: mod.id, bit: mod.bit, label: modifierLabel(mod, opts), count: count })
  }

  var held = []
  for (var h = 0; h < MODIFIERS.length; h++)
    if (mods & MODIFIERS[h].bit) held.push({ id: MODIFIERS[h].id, bit: MODIFIERS[h].bit, label: modifierLabel(MODIFIERS[h], opts) })

  return { mods: mods, held: held, rows: rows, deeper: deeper }
}
