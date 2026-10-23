-- Keycue key watcher.
--
-- The io.github.reflectionist.keycue shell plugin installs this into the
-- running Hyprland with `hyprctl eval`, prefixed with a generated
-- `local CONFIG = {...}` (see Service.qml). Nothing is written to any config
-- file; a config reload or a re-run replaces it.
--
-- It reports to the shell through custom events on Hyprland's event socket:
--   keycue>>ready <version>           installed
--   keycue>>ctx <fs> <monitor>\t<class>  sent as a trigger goes down
--   keycue>>mods <mask>               held modifiers changed while a trigger
--                                       is involved (SHIFT 1, CTRL 4, ALT 8, SUPER 64)
--   keycue>>key                       anything else went down while a trigger
--                                       was held
--   keycue>>pointer                   the pointer moved while a trigger was held
--                                       (a drag, resize or scroll)
-- It never says which key was pressed, and stays silent while no trigger
-- modifier is held, so ordinary typing produces no events at all.
--
-- CONFIG fields:
--   version    plugin version, echoed in `ready`
--   mods       { [xkb keycode] = modifier bit }, from the active keymap
--   trigger    modifier bits that open the box
--   pointer    report pointer movement
--   threshold  pointer movement, in layout pixels, that counts
--   instant    add a no-animation layer rule for `namespace`
--   namespace  the box's layer-shell namespace
--   reloads    how many Hyprland config reloads the shell has seen
--   owner      token of the shell instance that installed it; the shell only
--              uninstalls a watcher it owns, so a hot reload can't remove
--              its successor's copy

local previous = KEYCUE
if previous then
  if previous.sub then pcall(function() previous.sub:remove() end) end
  if previous.timer then pcall(function() previous.timer:set_enabled(false) end) end
end

local W = {
  version = CONFIG.version,
  owner = CONFIG.owner,
  held = {},   -- keycode -> modifier bit, for modifier keys that are down
  mask = 0,
  origin = nil,
  moved = false,
  reloads = CONFIG.reloads,
  -- Runtime layer rules last until the next config reload; reuse the rule
  -- from a run since then, so re-running doesn't stack copies.
  layerRule = previous and previous.reloads == CONFIG.reloads and previous.layerRule or nil,
}
KEYCUE = W

local MODS = CONFIG.mods
local TRIGGER = CONFIG.trigger

local function emit(text)
  hl.dispatch(hl.dsp.event("keycue>>" .. text))
end

local function currentMask()
  local m = 0
  for _, bit in pairs(W.held) do m = m | bit end
  return m
end

local function sendContext()
  local win = hl.get_active_window()
  local mon = hl.get_monitor_at_cursor()
  local fullscreen = (win and (win.fullscreen or 0) ~= 0) and 1 or 0
  local monName = mon and mon.name or ""
  local class = win and win.class or ""
  emit("ctx " .. fullscreen .. " " .. monName .. "\t" .. class)
end

local function apply()
  local m = currentMask()
  if m == W.mask then return end
  local old = W.mask
  W.mask = m
  local wasOn = (old & TRIGGER) ~= 0
  local isOn = (m & TRIGGER) ~= 0
  if isOn and not wasOn then sendContext() end
  if wasOn or isOn then emit("mods " .. m) end
  if isOn then
    -- Pointer movement counts from the latest modifier change.
    W.origin = hl.get_cursor_pos()
    W.moved = false
  end
  if W.timer then W.timer:set_enabled(isOn) end
end

-- While a trigger is held: catch pointer drags, and drop any modifier whose
-- release we missed (so the box can never stick open).
W.timer = hl.timer(function()
  if (W.mask & TRIGGER) == 0 then return end
  local changed = false
  for code in pairs(W.held) do
    if not hl.is_key_down(code) then
      W.held[code] = nil
      changed = true
    end
  end
  if changed then apply() end
  if (W.mask & TRIGGER) == 0 or not CONFIG.pointer or W.moved or not W.origin then return end
  local p = hl.get_cursor_pos()
  if p and math.abs(p.x - W.origin.x) + math.abs(p.y - W.origin.y) >= CONFIG.threshold then
    W.moved = true
    emit("pointer")
  end
end, { timeout = 60, type = "repeat" })
W.timer:set_enabled(false)

W.sub = hl.on("input.keyboard.key", function(code, _time, state)
  local bit = MODS[code]
  if bit then
    if state == 1 then W.held[code] = bit else W.held[code] = nil end
    apply()
  elseif state == 1 and (W.mask & TRIGGER) ~= 0 then
    emit("key")
  end
end)

if CONFIG.instant then
  if W.layerRule then
    pcall(function() W.layerRule:set_enabled(true) end)
  else
    W.layerRule = hl.layer_rule({ match = { namespace = "^" .. CONFIG.namespace:gsub("%.", "\\.") .. "$" }, no_anim = true, animation = "none" })
  end
elseif W.layerRule then
  pcall(function() W.layerRule:set_enabled(false) end)
end

emit("ready " .. tostring(CONFIG.version))
