-- lua tests/watcher.test.lua
-- Runs watcher.lua against a mock `hl` and checks the events it sends.

local here = arg[0]:match("(.*/)") or "./"
local source = assert(io.open(here .. "../watcher.lua")):read("a")

local mock
local function newMock()
  local m = { events = {}, down = {}, cursor = { x = 100, y = 100 }, rules = 0, timers = {} }
  m.hl = {
    dsp = { event = function(text) return text end },
    dispatch = function(text) m.events[#m.events + 1] = text:gsub("^keycue>>", "") end,
    on = function(name, cb)
      assert(name == "input.keyboard.key")
      m.cb = cb
      return { remove = function() m.removed = (m.removed or 0) + 1; m.cb = nil end }
    end,
    timer = function(fn, opts)
      assert(opts.type == "repeat" and opts.timeout > 0)
      local t = { fn = fn, enabled = true }
      function t:set_enabled(v) self.enabled = v end
      m.timers[#m.timers + 1] = t
      m.timer = t
      return t
    end,
    is_key_down = function(code) return m.down[code] == true end,
    get_cursor_pos = function() return { x = m.cursor.x, y = m.cursor.y } end,
    get_active_window = function() return m.window end,
    get_monitor_at_cursor = function() return { name = "eDP-1" } end,
    layer_rule = function(spec)
      m.rules = m.rules + 1
      m.lastRule = spec
      local r = { enabled = true }
      function r:set_enabled(v) self.enabled = v end
      return r
    end,
  }
  return m
end

local function install(config)
  local cfg = {
    version = "test", trigger = 64, pointer = true, threshold = 24, instant = true,
    namespace = "io.github.reflectionist.keycue", reloads = 0,
    mods = { [133] = 64, [134] = 64, [50] = 1, [62] = 1, [37] = 4, [105] = 4, [64] = 8, [108] = 8 },
  }
  for k, v in pairs(config or {}) do cfg[k] = v end
  mock.events = {}
  local env = setmetatable({ hl = mock.hl, CONFIG = cfg }, { __index = _G })
  -- KEYCUE must survive between installs, like Hyprland's globals do.
  env.KEYCUE = mock.global
  local chunk = assert(load("local CONFIG = CONFIG\n" .. source, "watcher", "t", env))
  chunk()
  mock.global = env.KEYCUE
end

local function key(code, state)
  if state == 1 then mock.down[code] = true else mock.down[code] = nil end
  mock.cb(code, 0, state)
end

local function tick() if mock.timer.enabled then mock.timer.fn() end end

local failures = 0
local function check(name, got, want)
  local ok = table.concat(got, "|") == table.concat(want, "|")
  if not ok then failures = failures + 1 end
  print((ok and "ok   " or "FAIL ") .. name .. "  [" .. table.concat(got, "|") .. "]" .. (ok and "" or ("  want [" .. table.concat(want, "|") .. "]")))
end

local function step(name, fn, want)
  mock.events = {}
  fn()
  check(name, mock.events, want)
end

mock = newMock()
mock.window = { class = "Alacritty", fullscreen = 0 }
install()
check("install reports ready", mock.events, { "ready test" })
assert(mock.rules == 1 and mock.lastRule.match.namespace == "^io\\.github\\.reflectionist\\.keycue$" and mock.lastRule.no_anim)

step("typing with shift is silent", function() key(50, 1); key(38, 1); key(38, 0); key(50, 0) end, {})
step("super down sends context then mods", function() key(133, 1) end, { "ctx 0 eDP-1\tAlacritty", "mods 64" })
step("duplicate press (IME re-send) is silent", function() key(133, 1) end, {})
step("shift added", function() key(50, 1) end, { "mods 65" })
step("a key while held", function() key(38, 1); key(38, 0) end, { "key" })
step("small pointer move is ignored", function() mock.cursor = { x = 110, y = 105 }; tick() end, {})
step("big pointer move counts once", function() mock.cursor = { x = 140, y = 120 }; tick(); tick() end, { "pointer" })
step("shift released resets the pointer origin", function() key(50, 0); mock.cursor = { x = 150, y = 120 }; tick() end, { "mods 64" })
step("super up", function() key(133, 0) end, { "mods 0" })
assert(not mock.timer.enabled, "timer stops when no trigger is held")
step("alt alone is silent (not a trigger)", function() key(64, 1); key(64, 0) end, {})

mock.window = { class = "steam_app_1", fullscreen = 2 }
step("context reports fullscreen and class", function() key(134, 1) end, { "ctx 1 eDP-1\tsteam_app_1", "mods 64" })
step("missed release is dropped by the timer", function() mock.down[134] = nil; tick() end, { "mods 0" })

-- Re-install with Alt as a trigger too: old subscription removed, rule reused.
install({ trigger = 64 | 8 })
check("reinstall reports ready", mock.events, { "ready test" })
assert(mock.removed == 1, "previous subscription removed")
assert(mock.rules == 1, "layer rule reused within the same reload")
mock.events = {}
step("alt is a trigger now", function() key(64, 1) end, { "ctx 1 eDP-1\tsteam_app_1", "mods 8" })
step("alt up", function() key(64, 0) end, { "mods 0" })

install({ reloads = 1 })
assert(mock.rules == 2, "fresh layer rule after a config reload")
install({ reloads = 1, instant = false })
assert(mock.rules == 2 and mock.global.layerRule.enabled == false, "instant off disables the rule")

install({ pointer = false })
mock.events = {}
step("pointer off: movement ignored", function() key(133, 1); mock.cursor = { x = 900, y = 900 }; tick(); key(133, 0) end, { "ctx 1 eDP-1\tsteam_app_1", "mods 64", "mods 0" })

print(failures == 0 and "all passed" or (failures .. " failed"))
os.exit(failures == 0 and 0 or 1)
