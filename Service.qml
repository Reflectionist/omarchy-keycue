import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "KeycueModel.js" as Model
import "Schema.js" as Schema

// Keycue: hold a trigger modifier (Super by default) and, after a short
// pause, a box lists the keys that finish a binding from there, plus the
// modifiers that lead to more.
//
// Keys are watched inside Hyprland by watcher.lua, installed at runtime with
// `hyprctl eval` (no config files touched). It reports held modifiers through
// custom events on Hyprland's event socket and never says which key was
// pressed. Bindings come from `omarchy-menu-keybindings --print`, the same
// list as the SUPER+K cheat sheet, with `hyprctl binds -j` as a fallback.
// Settings live in ~/.config/omarchy/keycue.jsonc (see Schema.js).
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: "io.github.reflectionist.keycue"
  readonly property string version: root.manifest && root.manifest.version ? String(root.manifest.version) : "dev"
  // Omarchy 4 strips __sourceDir from third-party manifests, so find our own
  // directory from the QML file's URL.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: root.home + "/.config/omarchy/keycue.jsonc"
  readonly property string binDir: (root.omarchyPath || "/usr/share/omarchy") + "/bin"
  // Marks the watcher this instance installed (see watcher.lua `owner`).
  readonly property string owner: Math.random().toString(36).slice(2)

  // ------------------------------------------------------------- settings

  property string configText: ""
  readonly property var settings: Model.settingsFrom(root.configText, Schema.SCHEMA)
  readonly property int triggerMask: Model.triggerMask(root.settings.triggers)
  readonly property var disabledApps: Model.compileRegexes(root.settings.disabledApps)
  property var roles: ({})

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configText = configFile.text()
    onLoadFailed: root.configText = ""
  }

  // Named theme colours, so settings like "keyColor": "red" follow theme switches.
  FileView {
    id: colorsFile
    path: root.home + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.roles = Model.parseColorsToml(colorsFile.text())
  }

  // ---------------------------------------------------------------- state

  property var bindings: []
  property string bindingsSource: ""
  property int mods: 0
  // A key finished the combo: stay hidden until the modifiers change.
  property bool spent: false
  property bool shown: false
  property var targetNames: []
  // From the watcher as a trigger goes down: fullscreen, monitor, class.
  property var context: ({ fullscreen: false, monitor: "", cls: "" })

  readonly property var level: Model.level(root.bindings, root.mods, root.settings)
  readonly property bool hasContent: root.level.rows.length > 0 || root.level.deeper.length > 0
    || (root.settings.showHeader && root.level.held.length > 0)

  function handleLine(line) {
    var text = String(line)
    var space = text.indexOf(" ")
    var verb = space < 0 ? text : text.slice(0, space)
    var rest = space < 0 ? "" : text.slice(space + 1)
    if (verb === "mods") root.setMods(parseInt(rest, 10) || 0)
    else if (verb === "key") root.keyPressed()
    else if (verb === "pointer") root.pointerMoved()
    else if (verb === "ctx") root.setContext(rest)
    else if (verb === "ready") root.watcherReady(rest)
  }

  function setContext(rest) {
    var tab = rest.indexOf("\t")
    var head = (tab < 0 ? rest : rest.slice(0, tab)).split(" ")
    root.context = {
      fullscreen: head[0] === "1",
      monitor: head.slice(1).join(" "),
      cls: tab < 0 ? "" : rest.slice(tab + 1)
    }
  }

  function setMods(next) {
    var prev = root.mods
    root.mods = next
    if (!(next & root.triggerMask)) {
      delayTimer.stop()
      root.spent = false
      root.shown = false
      return
    }
    if (prev === next) return
    root.spent = false
    // Already open: the rows follow the modifiers live. Otherwise the pause
    // counts from the latest change.
    if (!root.shown) delayTimer.restart()
  }

  function keyPressed() {
    root.shown = false
    if (root.settings.afterKey === "reopen" && (root.mods & root.triggerMask)) {
      root.spent = false
      delayTimer.restart()
    } else {
      root.spent = true
      delayTimer.stop()
    }
  }

  // Dragging, resizing or scrolling: keep the box out of the way for the
  // rest of this hold, whatever afterKey says.
  function pointerMoved() {
    if (!root.settings.pointerHides) return
    root.spent = true
    root.shown = false
    delayTimer.stop()
  }

  function focusedName() {
    return Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
  }

  function screenNames() {
    var out = []
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++)
      if (list[i] && list[i].name) out.push(String(list[i].name))
    return out
  }

  function targetsFor(mode) {
    if (mode === "all") return root.screenNames()
    if (mode === "cursor" && root.context.monitor) return [root.context.monitor]
    return [root.focusedName()]
  }

  function open(force) {
    if (!force) {
      if (root.settings.hideInFullscreen && root.context.fullscreen) return
      if (Model.matchesAny(root.disabledApps, root.context.cls)) return
    }
    root.targetNames = root.targetsFor(root.settings.monitor)
    colorsFile.reload()
    root.refreshBindings()
    root.shown = true
  }

  Timer {
    id: delayTimer
    interval: Math.max(1, root.settings.delay)
    onTriggered: if ((root.mods & root.triggerMask) && !root.spent) root.open(false)
  }

  // -------------------------------------------------------------- watcher

  property string watcherStatus: "starting"   // starting | ready | failed
  property string watcherReason: ""
  property string notifiedReason: ""
  property var modifierCodes: Model.DEFAULT_MODIFIER_CODES
  property bool keymapFromSystem: false
  property int reloads: 0
  property bool installPending: false
  readonly property string watcherKey: [root.triggerMask, root.settings.pointerHides, root.settings.pointerThreshold, root.settings.instantAppear].join(",")
  onWatcherKeyChanged: installDebounce.restart()

  FileView {
    id: watcherFile
    path: root.pluginDir + "/watcher.lua"
    blockLoading: true
  }

  // The modifier keycodes come from the active keymap, so remaps such as
  // caps:super or altwin:swap_alt_win are honoured.
  Process {
    id: devicesProc
    command: ["hyprctl", "devices", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.compileKeymap(this.text)
    }
  }

  Process {
    id: keymapProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var codes = Model.parseKeymapModifiers(this.text)
        root.keymapFromSystem = codes !== null
        root.modifierCodes = codes || Model.DEFAULT_MODIFIER_CODES
        installDebounce.restart()
      }
    }
    onExited: (code, status) => {
      if (code !== 0) {
        root.keymapFromSystem = false
        root.modifierCodes = Model.DEFAULT_MODIFIER_CODES
        installDebounce.restart()
      }
    }
  }

  function readKeymap() {
    if (!devicesProc.running) devicesProc.running = true
  }

  function compileKeymap(json) {
    var kb = null
    try {
      var list = JSON.parse(json).keyboards || []
      for (var i = 0; i < list.length && !kb; i++) if (list[i].main) kb = list[i]
      if (!kb && list.length > 0) kb = list[0]
    } catch (e) {}
    if (!kb) {
      root.modifierCodes = Model.DEFAULT_MODIFIER_CODES
      installDebounce.restart()
      return
    }
    var cmd = ["xkbcli", "compile-keymap"]
    var fields = ["rules", "model", "layout", "variant", "options"]
    for (var f = 0; f < fields.length; f++)
      if (kb[fields[f]]) cmd.push("--" + fields[f], String(kb[fields[f]]))
    keymapProc.command = cmd
    keymapProc.running = true
  }

  Timer {
    id: installDebounce
    interval: 150
    onTriggered: root.installWatcher()
  }

  function installWatcher() {
    if (evalProc.running) {
      root.installPending = true
      return
    }
    var source = watcherFile.text()
    if (!source) {
      root.fail("Its watcher.lua file is missing from " + root.pluginDir + ".")
      return
    }
    var config = {
      version: root.version,
      owner: root.owner,
      mods: root.modifierCodes,
      trigger: root.triggerMask,
      pointer: root.settings.pointerHides,
      threshold: root.settings.pointerThreshold,
      instant: root.settings.instantAppear,
      namespace: root.pluginId,
      reloads: root.reloads
    }
    root.watcherStatus = "starting"
    evalProc.command = ["hyprctl", "eval", Model.luaConfig(config) + source]
    evalProc.running = true
    readyTimer.restart()
  }

  Process {
    id: evalProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(this.text).trim()
        if (out !== "ok") root.fail("Hyprland didn't accept the key watcher: " + (out.split("\n")[0] || "no answer") + ".")
      }
    }
    onExited: (code, status) => {
      if (code !== 0 && root.watcherStatus !== "failed")
        root.fail("hyprctl eval failed (exit " + code + ").")
      if (root.installPending) {
        root.installPending = false
        installDebounce.restart()
      }
    }
  }

  Timer {
    id: readyTimer
    interval: 3000
    onTriggered: if (root.watcherStatus === "starting") root.fail("The key watcher didn't report back from Hyprland.")
  }

  function watcherReady(v) {
    readyTimer.stop()
    root.watcherStatus = "ready"
    root.watcherReason = ""
  }

  function fail(reason) {
    readyTimer.stop()
    root.watcherStatus = "failed"
    root.watcherReason = reason
    console.warn("[keycue] " + reason)
    if (!root.settings.notifyOnFailure || root.notifiedReason === reason) return
    root.notifiedReason = reason
    Quickshell.execDetached(["notify-send", "-a", "Keycue", "-i", "input-keyboard",
      "Keycue can't watch your keys",
      reason + "\n\nThings to try:\n"
        + "• Update Omarchy (omarchy update): Keycue needs a Hyprland with Lua config support (0.56 or newer).\n"
        + "• Check that ~/.config/hypr/hyprland.lua is the config Hyprland loads (hyprctl configerrors).\n"
        + "• Restart the shell: omarchy restart shell.\n"
        + "Run keycue-config to see the current status."])
  }

  function uninstallWatcher() {
    Quickshell.execDetached(["hyprctl", "eval",
      "local W = KEYCUE\n"
      + "if W and W.owner == \"" + root.owner + "\" then\n"
      + "  pcall(function() W.sub:remove() end)\n"
      + "  pcall(function() W.timer:set_enabled(false) end)\n"
      + "  if W.layerRule then pcall(function() W.layerRule:set_enabled(false) end) end\n"
      + "  KEYCUE = nil\n"
      + "end"])
  }

  // ------------------------------------------------------------- bindings

  property bool bindingsPending: false

  function refreshBindings() {
    if (bindingsProc.running || fallbackProc.running) {
      root.bindingsPending = true
      return
    }
    bindingsProc.parsed = false
    bindingsProc.running = true
  }

  function bindingsDone() {
    if (!root.bindingsPending) return
    root.bindingsPending = false
    root.refreshBindings()
  }

  Process {
    id: bindingsProc
    command: [root.binDir + "/omarchy-menu-keybindings", "--print"]
    property bool parsed: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = Model.parseBindings(this.text)
        if (list.length > 0) {
          bindingsProc.parsed = true
          root.bindings = list
          root.bindingsSource = "cheat sheet"
        }
      }
    }
    onExited: (code, status) => {
      if (!bindingsProc.parsed) fallbackProc.running = true
      else root.bindingsDone()
    }
  }

  Process {
    id: fallbackProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = Model.parseHyprctlBinds(this.text)
        if (list.length > 0) {
          root.bindings = list
          root.bindingsSource = "hyprctl"
        }
      }
    }
    onExited: (code, status) => root.bindingsDone()
  }

  Timer {
    id: reloadDebounce
    interval: 300
    onTriggered: {
      root.refreshBindings()
      root.readKeymap()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event) return
      var name = String(event.name)
      if (name === "custom") {
        var data = String(event.data)
        if (data.indexOf("keycue>>") === 0) root.handleLine(data.slice("keycue>>".length))
      } else if (name === "configreloaded") {
        root.reloads++
        reloadDebounce.restart()
      } else if (name === "activelayout") {
        reloadDebounce.restart()
      } else if ((name === "workspacev2" || name === "workspace") && (root.mods & root.triggerMask)) {
        // Super+scroll and friends switch workspaces without a key press.
        root.pointerMoved()
      }
    }
  }

  // ------------------------------------------------- keycue-config command

  readonly property bool installCommand: root.settings.installCommand
  onInstallCommandChanged: linkDebounce.restart()

  Timer {
    id: linkDebounce
    interval: 500
    onTriggered: {
      linkProc.command = ["bash", root.pluginDir + "/bin/keycue-link-command",
        root.installCommand ? "link" : "unlink", root.pluginDir]
      linkProc.running = true
    }
  }

  Process { id: linkProc }

  Component.onCompleted: {
    root.refreshBindings()
    root.readKeymap()
    linkDebounce.restart()
  }

  Component.onDestruction: root.uninstallWatcher()

  // ------------------------------------------------------------------ IPC

  function previewMods(mask) {
    if (mask & root.triggerMask) return mask
    var order = [Model.SUPER, Model.ALT, Model.CTRL]
    for (var i = 0; i < order.length; i++)
      if (root.triggerMask & order[i]) return mask | order[i]
    return mask | Model.SUPER
  }

  function stateJson() {
    return JSON.stringify({
      version: root.version, mods: root.mods, shown: root.shown, spent: root.spent,
      watcher: root.watcherStatus, reason: root.watcherReason, keymap: root.keymapFromSystem ? "system" : "default",
      bindings: root.bindings.length, source: root.bindingsSource, rows: root.level.rows.length,
      configOk: root.settings.ok, config: root.configPath, triggers: root.triggerMask,
      context: root.context, targets: root.targetNames,
      behavior: { delay: root.settings.delay, afterKey: root.settings.afterKey,
        hideInFullscreen: root.settings.hideInFullscreen, disabledApps: root.settings.disabledApps }
    })
  }

  // The level for a modmask under the saved settings, plus the resolved
  // look, for keycue-config's live mock.
  function levelJson(mask) {
    var l = Model.level(root.bindings, root.previewMods(mask), root.settings)
    l.style = {
      background: String(root.look.background), text: String(root.look.text),
      muted: String(root.look.muted), key: String(root.look.key), onKey: String(root.look.onKey),
      border: String(Border.color(root.look.border)), borderWidth: Border.uniformWidth(root.look.border),
      radius: root.look.radius
    }
    return JSON.stringify(l)
  }

  // IPC, reachable under the plugin id and as `keycue` for short.
  function ipcPreview(mask) {
    root.mods = root.previewMods(mask)
    root.spent = false
    root.open(true)
    return "ok"
  }
  function ipcHide() { delayTimer.stop(); root.shown = false; return "ok" }
  function ipcReload() {
    configFile.reload()
    root.refreshBindings()
    root.readKeymap()
    return "ok"
  }

  IpcHandler {
    target: root.pluginId
    // Feed a watcher line ("mods 64", "key"), exactly as Hyprland would.
    function feed(line: string): string { root.handleLine(line); return "ok" }
    // Open at once for a modmask (a trigger is added if missing). Stays until
    // the trigger is released, or `hide`.
    function preview(mask: int): string { return root.ipcPreview(mask) }
    function hide(): string { return root.ipcHide() }
    function reload(): string { return root.ipcReload() }
    function reloadConfig(): string { configFile.reload(); return "ok" }
    function state(): string { return root.stateJson() }
    function level(mask: int): string { return root.levelJson(mask) }
  }

  IpcHandler {
    target: "keycue"
    function feed(line: string): string { root.handleLine(line); return "ok" }
    function preview(mask: int): string { return root.ipcPreview(mask) }
    function hide(): string { return root.ipcHide() }
    function reload(): string { return root.ipcReload() }
    function reloadConfig(): string { configFile.reload(); return "ok" }
    function state(): string { return root.stateJson() }
    function level(mask: int): string { return root.levelJson(mask) }
  }

  // ------------------------------------------------------------------ look

  readonly property real scale: root.settings.scale
  function px(value) { return Math.round(Style.space(value) * root.scale) }

  readonly property var look: {
    var s = root.settings
    var roles = root.roles
    var customBg = Model.resolveColor(s.backgroundColor, roles)
    var base = customBg ? Qt.color(customBg) : Color.popups.background
    var alpha = s.backgroundOpacity >= 0 ? s.backgroundOpacity / 100 : Color.popups.background.a
    var text = Model.resolveColor(s.textColor, roles)
    var textColor = text ? Qt.color(text) : Color.popups.text
    var muted = Model.resolveColor(s.mutedColor, roles)
    var key = Model.resolveColor(s.keyColor, roles)
    var themeBorder = Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    var width = s.borderWidth >= 0 ? Math.round(s.borderWidth * root.scale) : Border.uniformWidth(themeBorder)
    var borderColor = Model.resolveColor(s.borderColor, roles)
    var border = width <= 0 ? Border.none()
      : (borderColor ? Border.flat(Qt.color(borderColor), width)
      : (s.borderWidth >= 0 ? Border.withWidth(themeBorder, width) : themeBorder))
    var radius = s.radius >= 0 ? Math.round(s.radius * root.scale) : Style.cornerRadius
    return {
      background: Util.alpha(base, alpha),
      onKey: customBg ? Qt.color(customBg) : Color.background,
      text: textColor,
      muted: muted ? Qt.color(muted) : Util.alpha(textColor, 0.6),
      key: key ? Qt.color(key) : Color.accent,
      border: border,
      radius: radius,
      keyRadius: Math.min(radius, root.px(4))
    }
  }

  readonly property font descFont: Qt.font({
    family: root.settings.fontFamily || Style.font.family,
    pixelSize: Math.max(1, Math.round((root.settings.fontSize > 0 ? root.settings.fontSize : Style.font.body) * root.scale))
  })
  readonly property font keyFont: Qt.font({
    family: root.settings.keyFontFamily || root.settings.fontFamily || Style.font.family,
    pixelSize: Math.max(1, Math.round((root.settings.keyFontSize > 0 ? root.settings.keyFontSize : Style.font.bodySmall) * root.scale)),
    bold: true
  })

  readonly property string hpos: {
    var p = root.settings.position
    return p.indexOf("left") !== -1 ? "left" : (p.indexOf("right") !== -1 ? "right" : "center")
  }
  readonly property string vpos: {
    var p = root.settings.position
    return p.indexOf("top") === 0 ? "top" : (p.indexOf("bottom") === 0 ? "bottom" : "center")
  }
  // Line the box up with the tiled windows' outer edge (Hyprland gaps_out).
  readonly property int margin: root.settings.margin >= 0 ? root.settings.margin : Style.gapsOut * 2

  // ------------------------------------------------------------------- box

  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      visible: root.shown && root.hasContent && root.targetNames.indexOf(String(modelData.name)) !== -1
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: root.pluginId
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      // Normal keeps the window (and so the box) clear of the bar.
      exclusionMode: root.settings.respectBar ? ExclusionMode.Normal : ExclusionMode.Ignore
      exclusiveZone: 0
      // Visual only: an empty input region lets every click through.
      mask: Region {}

      property real appear: 1
      onVisibleChanged: {
        if (!visible) return
        if (root.settings.animation === "none" || root.settings.animationMs <= 0) {
          win.appear = 1
        } else {
          win.appear = 0
          appearAnim.restart()
        }
      }
      NumberAnimation {
        id: appearAnim
        target: win
        property: "appear"
        from: 0
        to: 1
        duration: root.settings.animationMs
        easing.type: Easing.OutCubic
      }

      readonly property real slide: root.settings.animation === "slide" ? (1 - win.appear) * root.px(16) : 0

      Box {
        id: box
        level: root.level
        availableHeight: win.height * root.settings.maxHeight / 100
        maxColumns: root.settings.maxColumns
        showHeader: root.settings.showHeader
        showFooter: root.settings.showFooter
        emptyText: root.settings.emptyText

        pad: root.px(root.settings.padding)
        rowGap: root.px(root.settings.rowSpacing)
        columnGap: root.px(root.settings.columnSpacing)
        keyGap: root.px(root.settings.keyGap)
        maxDescWidth: root.px(root.settings.maxDescriptionWidth)
        sectionGap: root.px(10)
        capPadX: root.px(6)
        capPadY: root.px(2)

        color: root.look.background
        borderSpec: root.look.border
        radius: root.look.radius
        keyRadius: root.look.keyRadius
        textColor: root.look.text
        mutedColor: root.look.muted
        keyColor: root.look.key
        onKeyColor: root.look.onKey
        keyStyle: root.settings.keyStyle
        descFont: root.descFont
        keyFont: root.keyFont

        opacity: root.settings.animation === "none" ? 1 : win.appear

        readonly property real baseX: root.hpos === "left" ? root.margin
          : (root.hpos === "right" ? win.width - box.width - root.margin : (win.width - box.width) / 2)
        readonly property real baseY: root.vpos === "top" ? root.margin
          : (root.vpos === "bottom" ? win.height - box.height - root.margin : (win.height - box.height) / 2)
        // Slide in from the nearest edge (from above when centred).
        readonly property real slideX: root.vpos === "center" && root.hpos !== "center" ? (root.hpos === "left" ? -win.slide : win.slide) : 0
        readonly property real slideY: root.vpos === "bottom" ? win.slide : (root.vpos === "center" && root.hpos !== "center" ? 0 : -win.slide)

        x: Math.round(Math.max(0, Math.min(win.width - box.width, box.baseX + root.settings.offsetX)) + box.slideX)
        y: Math.round(Math.max(0, Math.min(win.height - box.height, box.baseY + root.settings.offsetY)) + box.slideY)
      }
    }
  }
}
