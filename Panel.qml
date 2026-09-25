import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons

// omarchy-pointer-scroll — "Pointer & Scroll" bar button + panel for Omarchy.
//
// Thin view over bin/pointer-scroll (shipped next to this file): state comes from
// `pointer-scroll get` (JSON) and every change is `pointer-scroll set KEY VALUE`, which regenerates
// ~/.config/hypr/pointer_scroll.lua, reloads Hyprland and rolls back if Hyprland reports an error.
//
// Sliders preview live in the graph while dragging; the setting is applied on release.
Panel {
  id: root
  moduleName: "angusforbes.pointer-scroll"
  ipcTarget: "angusforbes.pointer-scroll"
  manageIpc: false          // we own the IpcHandler below (adds outsideClick)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string glyph: "󰍽"   // nf-md-mouse

  // ---- state ---------------------------------------------------------------------------
  property var st: ({ accel: true, pointer_slow: 0.35, pointer_fast: 1.6, pointer_ramp: 1.5,
                      scroll_slow: 0.6, scroll_fast: 1.6, scroll_ramp: 1.0, scroll_speed: 0.4,
                      terminal_scroll: 1.5, sensitivity: 0.0, curve_points: 16, installed: true, touchpads: [] })
  // backend script shipped inside the plugin folder
  readonly property string cli: String(Qt.resolvedUrl("bin/pointer-scroll")).replace(/^file:\/\//, "")
  // set up = input.lua loads the generated config (the panel offers a one-click "Set up" otherwise)
  readonly property bool ready: st.installed !== false
  property var draft: ({})          // values being dragged, not yet applied
  property string lastError: ""
  property bool busy: false
  property bool sliderActive: false    // a slider is being dragged: the scroll area must not steal it
  property bool confirmReset: false   // Reset asks "are you sure?" first

  function val(key) { return draft[key] !== undefined ? draft[key] : st[key] }
  function preview(key, v) { v = clampPair(key, v); var d = Object.assign({}, draft); d[key] = v; draft = d }

  // ---- plumbing ------------------------------------------------------------------------
  function refresh() { if (!getProc.running) getProc.running = true }

  property var pending: ({})        // key -> value waiting to be applied (latest wins)
  // Fast speed may not drop below careful speed (the curve would slope downwards): whichever of the
  // two is being changed stops at the other one.
  function clampPair(key, v) {
    var m = /^(pointer|scroll)_(slow|fast)$/.exec(key)
    if (!m) return v
    var other = Number(root.val(m[1] + (m[2] === "slow" ? "_fast" : "_slow")))
    return m[2] === "slow" ? Math.min(v, other) : Math.max(v, other)
  }
  function setKey(key, v) {
    v = clampPair(key, v)
    var p = Object.assign({}, pending); p[key] = v; pending = p
    preview(key, v)
    pump()
  }
  function pump() {
    if (setProc.running) return
    var keys = Object.keys(pending)
    if (keys.length === 0) return
    var args = ["python3", root.cli, "set"]
    for (var i = 0; i < keys.length; i++) args.push(keys[i], String(pending[keys[i]]))
    pending = ({})
    busy = true
    setProc.command = args
    setProc.running = true
  }
  function resetAll() {
    if (setProc.running) return
    pending = ({}); draft = ({})
    busy = true
    setProc.command = ["python3", root.cli, "reset"]
    setProc.running = true
  }
  function install() {
    if (setProc.running) return
    busy = true
    lastError = ""
    setProc.command = ["python3", root.cli, "install"]
    setProc.running = true
  }

  Process {
    id: getProc
    command: ["python3", root.cli, "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          if (parsed && typeof parsed === "object" && parsed.pointer_slow !== undefined) root.st = parsed
        } catch (e) { /* keep last good state */ }
      }
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "{}"))
          if (parsed && parsed.pointer_slow !== undefined) { root.st = Object.assign({}, root.st, parsed); root.lastError = "" }
        } catch (e) { }
      }
    }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (String(text).trim() !== "") root.lastError = String(text).trim() }
    onExited: function(code) {
      root.busy = false
      if (Object.keys(root.pending).length === 0) root.draft = ({})
      if (code !== 0) { if (root.lastError === "") root.lastError = "pointer-scroll exited " + code; root.refresh() }
      root.pump()
    }
  }

  // ---- open/close behaviour like the other bar panels -----------------------------------
  // * one panel at a time: register with the bar's popout coordinator, so opening volume /
  //   wifi / ... closes this one and opening this one closes them;
  // * any click outside the card closes it: Hyprland's non-consuming mouse binds (generated by
  //   bin/pointer-scroll into hypr/pointer_scroll.lua) call outsideClick() while the flag file exists.
  //   Moving the pointer and scrolling elsewhere are untouched.
  readonly property string openFlag: "${XDG_RUNTIME_DIR:-/tmp}/omarchy-pointer-scroll-open"
  Process { id: flagProc }
  function setFlag(on) {
    flagProc.command = ["sh", "-c", on ? "touch \"" + openFlag + "\"" : "rm -f \"" + openFlag + "\""]
    flagProc.running = true
  }
  // A click on our own bar icon is also an "outside click": Hyprland's bind fires on press
  // (~40 ms later via qs ipc) while the icon toggles on release, so the outside click closed the
  // panel and the release re-opened it. Remember when an outside click closed it and let the
  // icon ignore a toggle that follows within half a second.
  property real outsideClosedAt: 0
  function outsideClick() {
    if (!root.opened || cardHover.hovered) return
    root.outsideClosedAt = Date.now()
    root.close()
  }
  function iconToggle() {
    if (!root.opened && Date.now() - root.outsideClosedAt < 500) return
    root.toggle()
  }
  Connections {
    target: root
    function onOpenedChanged() {
      root.confirmReset = false
      root.setFlag(root.opened)
      if (root.opened) {
        root.refresh()
        if (root.bar && root.bar.requestPopout) root.bar.requestPopout(root)
      } else if (root.bar && root.bar.activePopout === root && root.bar.releasePopout) {
        root.bar.releasePopout(root)
      }
    }
  }
  IpcHandler {
    target: "angusforbes.pointer-scroll"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function outsideClick(): void { root.outsideClick() }
  }
  Component.onCompleted: { refresh(); setFlag(false) }

  // ---- curve maths (mirrors bin/pointer-scroll) ------------------------------------------------
  // amplification at finger speed x (units/ms, 1 ~ 25 mm/s), exactly as libinput computes it from the
  // points bin/pointer-scroll generates: `curve_points` knots spread over x = 0..8 (the first knot is the
  // careful speed, the last the fast speed), straight lines (in output speed) between them, linear
  // extrapolation beyond x = 8.
  function gainAt(slow, fast, ramp, x) {
    var n = root.knotCount()
    var step = 8 / n
    function g(v) { return v <= step ? slow : slow + (fast - slow) * Math.pow((v - step) / (8 - step), ramp) }
    function yk(k) { return k * step * g(k * step) }          // output speed at knot k
    var kf = x / step
    var y
    if (kf >= n) y = yk(n) + (kf - n) * (yk(n) - yk(n - 1))
    else { var i = Math.floor(kf), f = kf - i; y = yk(i) * (1 - f) + yk(i + 1) * f }
    return y / x
  }
  function pointerGain(x) {
    return root.val("accel") ? gainAt(root.val("pointer_slow"), root.val("pointer_fast"), root.val("pointer_ramp"), x) : NaN
  }
  function scrollGain(x) {
    return root.val("accel") ? gainAt(root.val("scroll_slow"), root.val("scroll_fast"), root.val("scroll_ramp"), x) * root.val("scroll_speed") : NaN
  }
  function fmt(v, digits) { return Number(v).toFixed(digits === undefined ? 2 : digits) }

  // ---- chart levers ------------------------------------------------------------------------
  // Each curve has three draggable levers, one per slider:
  //   careful   at the first libinput point, height = careful speed      (always on the curve)
  //   fast      at the last point (x = 8),   height = fast speed         (always on the curve)
  //   speeds up halfway between them,        height = the smooth formula there,
  //             slow + (fast - slow) * 0.5 ^ ramp. The real curve is straight segments between
  //             libinput's points, so it can pass a little above/below this lever.
  function knotCount() { return Math.max(4, Math.min(32, Math.round(Number(root.st.curve_points) || 16))) }
  readonly property var leverNames: ["slow", "ramp", "fast"]
  function leverX(lever) {
    var step = 8 / knotCount()
    return lever === "slow" ? step : lever === "fast" ? 8 : (step + 8) / 2
  }
  function leverValue(which, lever, change) {
    var pre = which === "pointer" ? "pointer_" : "scroll_"
    function pv(k) { return change && change[pre + k] !== undefined ? change[pre + k] : Number(root.val(pre + k)) }
    var mul = which === "scroll" ? Number(root.val("scroll_speed")) : 1
    var slow = pv("slow"), fast = pv("fast")
    if (lever === "slow") return slow * mul
    if (lever === "fast") return fast * mul
    return (slow + (fast - slow) * Math.pow(0.5, pv("ramp"))) * mul
  }
  readonly property var sliderLimits: ({
    pointer_slow: [0.1, 1.0], pointer_fast: [0.5, 4.0], pointer_ramp: [0.15, 5.0],
    scroll_slow: [0.1, 2.0], scroll_fast: [0.3, 5.0], scroll_ramp: [0.15, 5.0] })
  // slider change that puts `lever` at chart height v
  function solveDrag(which, lever, v) {
    var pre = which === "pointer" ? "pointer_" : "scroll_"
    if (which === "scroll") v = v / Math.max(0.01, root.val("scroll_speed"))
    function put(key, val) {
      var r = root.sliderLimits[key]
      var o = {}; o[key] = Math.round(Math.max(r[0], Math.min(r[1], val)) * 100) / 100
      return o
    }
    if (lever === "slow") return put(pre + "slow", v)
    if (lever === "fast") return put(pre + "fast", v)
    var slow = Number(root.val(pre + "slow")), fast = Number(root.val(pre + "fast"))
    if (Math.abs(fast - slow) < 0.005) return ({})
    var ratio = Math.max(0.002, Math.min(0.998, (v - slow) / (fast - slow)))
    return put(pre + "ramp", Math.log(ratio) / Math.log(0.5))
  }
  // Lever drags only stop at real limits: each slider's range (applied in solveDrag) and fast never
  // below careful. The curve's far end may rise above the chart while dragging; it is clipped there and
  // the chart rescales when you let go.
  function dragAllowed(which, change) {
    var pre = which === "pointer" ? "pointer_" : "scroll_"
    function pv(k) { return change[pre + k] !== undefined ? change[pre + k] : Number(root.val(pre + k)) }
    return pv("fast") >= pv("slow")
  }
  function constrainedDrag(which, lever, current, target) {
    var ch = solveDrag(which, lever, target)
    if (dragAllowed(which, ch)) return ch
    var lo = current, hi = target, best = ({})         // lo is allowed: it is where the lever is now
    for (var it = 0; it < 24; it++) {
      var mid = (lo + hi) / 2
      var c = solveDrag(which, lever, mid)
      if (dragAllowed(which, c)) { lo = mid; best = c } else hi = mid
    }
    return best
  }

  // ---- bar button ------------------------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: "Pointer & scroll speed"
    onPressed: function(b) { root.iconToggle() }
  }

  // ---- panel ---------------------------------------------------------------------------
  // Deliberately NOT KeyboardPanel: that one covers the whole screen with an invisible
  // click-to-dismiss layer, which also swallows two-finger scrolling in other windows.
  // This is a card-sized, non-modal layer window: the rest of the desktop keeps working
  // while it is open, so you can test scrolling live. Close with the bar icon or Esc.
  PanelWindow {
    id: win
    readonly property var barWin: button.QsWindow.window
    readonly property real barH: barWin ? barWin.height : Style.space(30)
    readonly property real gap: Style.gapsOut
    readonly property real screenW: screen ? screen.width : 1800
    readonly property real screenH: screen ? screen.height : 1100
    readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    readonly property real pad: Style.spacing.popupPadding
    readonly property real cardW: Math.min(Style.space(380), screenW - gap * 2)   // same card width as volume / wifi / bluetooth
    readonly property real inset: pad * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)
    readonly property real cardH: Math.min(column.implicitHeight + inset, screenH - barH - gap * 3)
    property real iconCenterX: screenW - gap - cardW / 2

    function placeUnderIcon() {
      if (!barWin || !barWin.contentItem) return
      var p = button.mapToItem(barWin.contentItem, 0, 0)
      iconCenterX = p.x + button.width / 2
    }

    screen: barWin ? barWin.screen : null
    visible: root.opened
    onVisibleChanged: if (visible) { placeUnderIcon(); keyCatcher.forceActiveFocus() }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-pointer-scroll"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    anchors { top: true; right: true }
    margins.top: barH + gap
    margins.right: Math.max(gap, Math.min(screenW - cardW - gap, screenW - iconCenterX - cardW / 2))
    implicitWidth: cardW
    implicitHeight: cardH

    BorderSurface {
      id: card
      anchors.fill: parent
      color: Color.popups.background
      borderSpec: win.borderSpec
      padding: win.pad
      radius: Style.cornerRadius
      HoverHandler { id: cardHover }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      focus: true
      onCloseRequested: root.close()

      Flickable {
        id: scroller
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        // Only scroll when the panel is taller than the screen. A scrollable Flickable takes over a
        // slider drag that wobbles vertically: the slider never sees the release, so its value is
        // shown but never applied.
        interactive: contentHeight > height + 1 && !root.sliderActive

        Column {
          id: column
          width: parent.width
          spacing: Style.space(6)

          // ---------- Hero ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, accelSwitch.implicitHeight)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.glyph
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
            }
            ToggleSwitch {
              id: accelSwitch
              visible: root.ready
              checked: !!root.val("accel")
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setKey("accel", !root.val("accel"))
              PanelToolTip {
                visible: accelSwitch.containsMouse
                text: root.val("accel") ? "Turn smart acceleration off (plain speed)" : "Turn smart acceleration on (slow = precise, fast = far)"
                fontFamily: root.bar.fontFamily
              }
            }
            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(12)
              anchors.right: accelSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                text: "Pointer & Scroll"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }
              Text {
                text: (root.busy ? "APPLYING…" : !root.ready ? "SETUP NEEDED" : root.val("accel") ? "SMART ACCELERATION ON" : "PLAIN SPEED")
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- First-run setup ----------
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.ready

            PanelSeparator { width: parent.width }
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.st.lua_config === false
                    ? "This widget needs Omarchy's Lua Hyprland config (~/.config/hypr/hyprland.lua)."
                    : "One-time setup: this adds one line to ~/.config/hypr/input.lua so Hyprland loads the settings from this panel. Your input.lua is backed up first, and uninstalling removes the line again."
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Button {
              visible: root.st.lua_config !== false
              text: root.busy ? "Setting up…" : "Set up"
              bordered: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.install()
            }
            Text {
              width: parent.width
              visible: root.lastError !== ""
              text: root.lastError
              color: "#FF6B6B"
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: mainContent
            width: parent.width
            spacing: Style.space(6)
            visible: root.ready

            // ---------- Graph ----------
            Item {
              width: parent.width
              height: root.val("accel") ? Style.space(118) : 0
              visible: root.val("accel")

              Canvas {
                id: graph
                anchors.fill: parent
                property color fg: root.bar.foreground
                property color accent: Color.accent
                property color bg: Color.popups.background
                readonly property real padL: 30
                readonly property real padB: 16
                readonly property real padT: 8
                readonly property real gw: width - padL - 4
                readonly property real gh: height - padB - padT
                readonly property real xmax: 16
                property real ymax: 1.5            // frozen while a dot is being dragged
                property string hotWhich: ""       // lever under the pointer / being dragged
                property string hotLever: ""
                property bool dragging: false

                function px(x) { return padL + gw * x / xmax }
                function py(y) { return padT + gh * (1 - y / ymax) }
                function valueAt(Y) { return ymax * (1 - (Y - padT) / gh) }
                function computeYmax() {
                  var m = 0
                  for (var i = 1; i <= 64; i++) { var x = i / 4; m = Math.max(m, root.pointerGain(x), root.scrollGain(x)) }
                  return Math.max(1.5, Math.ceil(m * 2) / 2)
                }
                function gainOf(which, x) { return which === "pointer" ? root.pointerGain(x) : root.scrollGain(x) }
                function leverAt(mx, my) {
                  var best = null, bestD = 13
                  var order = ["scroll", "pointer"]          // pointer wins ties (drawn on top)
                  for (var o = 0; o < order.length; o++)
                    for (var l = 0; l < root.leverNames.length; l++) {
                      var lv = root.leverNames[l]
                      var d = Math.hypot(px(root.leverX(lv)) - mx, py(root.leverValue(order[o], lv)) - my)
                      if (d <= bestD) { bestD = d; best = { which: order[o], lever: lv } }
                    }
                  return best
                }

                onPaint: {
                  if (!dragging) ymax = computeYmax()
                  var ctx = getContext("2d")
                  ctx.reset()
                  var w = width, h = height
                  ctx.font = "10px " + root.bar.fontFamily
                  ctx.lineWidth = 1
                  // grid + labels
                  ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.12)
                  ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.55)
                  for (var g = 0.5; g <= ymax + 0.001; g += 0.5) {
                    ctx.beginPath(); ctx.moveTo(padL, py(g)); ctx.lineTo(w - 4, py(g)); ctx.stroke()
                    if (Math.abs(g - Math.round(g)) < 0.01) ctx.fillText(g.toFixed(0) + "×", 2, py(g) + 3)
                  }
                  ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.35)
                  ctx.beginPath(); ctx.moveTo(padL, py(1)); ctx.lineTo(w - 4, py(1)); ctx.stroke()
                  // axis labels: "careful" at the left edge, "flick" at the right edge, "swipe" exactly between them
                  var wC = ctx.measureText("careful").width, wS = ctx.measureText("swipe").width, wF = ctx.measureText("flick").width
                  var edge = 8   // inset from the graph edges
                  var cCareful = padL + edge + wC / 2, cFlick = (w - 4) - edge - wF / 2
                  ctx.fillText("careful", cCareful - wC / 2, h - 3)
                  ctx.fillText("swipe", (cCareful + cFlick) / 2 - wS / 2 - 6, h - 3)   // 6 px ~ 1 mm left of centre
                  ctx.fillText("flick", cFlick - wF / 2 - 6, h - 3)   // extra 1 mm in from the right
                  // curves: libinput's amplification evaluated at every pixel column, from zero finger speed
                  // (flat up to the first point) through the points and on into the extrapolated part
                  function curve(which, color) {
                    ctx.strokeStyle = color; ctx.lineWidth = 2
                    ctx.beginPath()
                    var cols = Math.max(2, Math.round(gw))
                    for (var c = 0; c <= cols; c++) {
                      var xx = Math.max(1e-4, xmax * c / cols), yy = gainOf(which, xx)
                      if (c === 0) ctx.moveTo(px(xx), py(yy)); else ctx.lineTo(px(xx), py(yy))
                    }
                    ctx.stroke()
                  }
                  // levers: careful + fast sit on the curve; speeds up shows the smooth formula's bend
                  function levers(which, color) {
                    for (var l = 0; l < root.leverNames.length; l++) {
                      var lv = root.leverNames[l]
                      var hot = hotWhich === which && hotLever === lv
                      var cx = px(root.leverX(lv)), cy = py(root.leverValue(which, lv))
                      var r = hot ? 6.5 : 5
                      ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI)
                      ctx.fillStyle = bg; ctx.fill()
                      ctx.lineWidth = 2; ctx.strokeStyle = color; ctx.stroke()
                      if (lv === "ramp") {          // a bar across the ring marks the bend lever
                        ctx.beginPath(); ctx.moveTo(cx - r + 2, cy); ctx.lineTo(cx + r - 2, cy); ctx.stroke()
                      } else {
                        ctx.beginPath(); ctx.arc(cx, cy, r - 3, 0, 2 * Math.PI); ctx.fillStyle = color; ctx.fill()
                      }
                    }
                  }
                  ctx.save()
                  ctx.beginPath(); ctx.rect(padL, 0, w - 4 - padL, py(0)); ctx.clip()
                  curve("scroll", accent)
                  curve("pointer", fg)
                  ctx.restore()
                  levers("scroll", accent)
                  levers("pointer", fg)
                  // name + value of the hot lever
                  if (hotLever !== "" && hotWhich !== "") {
                    var pre = hotWhich === "pointer" ? "pointer_" : "scroll_"
                    var hv = root.leverValue(hotWhich, hotLever)
                    var label = hotLever === "slow" ? "careful " + hv.toFixed(2) + "×"
                              : hotLever === "fast" ? "fast " + hv.toFixed(2) + "×"
                              : "speeds up " + Number(root.val(pre + "ramp")).toFixed(2)
                    var lw = ctx.measureText(label).width
                    var hxp = px(root.leverX(hotLever))
                    var lx = Math.min(w - 4 - lw, Math.max(padL, hxp - lw / 2))
                    var ly = py(hv) - 11 < padT + 8 ? py(hv) + 19 : py(hv) - 11
                    ctx.fillStyle = hotWhich === "pointer" ? fg : accent
                    ctx.fillText(label, lx, ly)
                  }
                }
                Connections {
                  target: root
                  function onStChanged() { graph.requestPaint() }
                  function onDraftChanged() { graph.requestPaint() }
                }
                onWidthChanged: requestPaint()
                onHotLeverChanged: requestPaint()
                onHotWhichChanged: requestPaint()
                Component.onCompleted: requestPaint()
              }

              MouseArea {
                id: leverMouse
                anchors.fill: graph
                hoverEnabled: true
                preventStealing: true
                acceptedButtons: Qt.LeftButton
                cursorShape: graph.hotLever !== "" ? Qt.SizeVerCursor : Qt.ArrowCursor
                property var pendingChange: ({})

                function hover(mx, my) {
                  var l = graph.leverAt(mx, my)
                  graph.hotWhich = l ? l.which : ""
                  graph.hotLever = l ? l.lever : ""
                }
                onPositionChanged: function(mouse) {
                  if (!graph.dragging) { hover(mouse.x, mouse.y); return }
                  var target = Math.max(0.02, Math.min(graph.ymax, graph.valueAt(mouse.y)))
                  var current = root.leverValue(graph.hotWhich, graph.hotLever)
                  var change = root.constrainedDrag(graph.hotWhich, graph.hotLever, current, target)
                  for (var k in change) root.preview(k, change[k])
                  pendingChange = Object.assign({}, pendingChange, change)
                }
                onPressed: function(mouse) {
                  hover(mouse.x, mouse.y)
                  if (graph.hotLever === "") { mouse.accepted = false; return }
                  pendingChange = ({})
                  graph.dragging = true
                }
                onReleased: function(mouse) {
                  if (!graph.dragging) return
                  graph.dragging = false
                  for (var k in pendingChange) root.setKey(k, pendingChange[k])
                  pendingChange = ({})
                  hover(mouse.x, mouse.y)
                  graph.requestPaint()
                }
                onExited: if (!graph.dragging) { graph.hotWhich = ""; graph.hotLever = "" }
              }
            }
            Row {
              visible: root.val("accel")
              spacing: Style.space(14)
              Text { text: "━ pointer"; color: root.bar.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption }
              Text { text: "━ scroll"; color: Color.accent; font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption }
              Text { text: "drag a lever to reshape"; color: Qt.darker(root.bar.foreground, 1.6); font.family: root.bar.fontFamily; font.pixelSize: Style.font.caption }
            }

            PanelSeparator { width: parent.width }

            // ---------- Pointer ----------
            PanelSectionHeader { width: parent.width; text: (root.st.touchpads && root.st.touchpads.length === 0) ? "POINTER (ALL DEVICES)" : "POINTER (TOUCHPAD)"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; visible: root.val("accel") }
            TuneRow { key: "pointer_slow"; label: "Careful speed"; hint: "Selecting text, small moves"; minimum: 0.1; maximum: 1.0; visible: root.val("accel") }
            TuneRow { key: "pointer_fast"; label: "Fast speed"; hint: "Flicking across the screen"; minimum: 0.5; maximum: 4.0; visible: root.val("accel") }
            TuneRow { key: "pointer_ramp"; label: "Speeds up"; hint: "Left = sooner, right = stays precise longer"; minimum: 0.15; maximum: 5.0; suffix: ""; visible: root.val("accel") }

            // ---------- Scroll ----------
            PanelSectionHeader { width: parent.width; text: "TWO-FINGER SCROLL"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }
            TuneRow { key: "scroll_speed"; label: "Overall scroll speed"; hint: "Scales everything below"; minimum: 0.1; maximum: 2.0 }
            TuneRow { key: "scroll_slow"; label: "Careful scroll"; hint: "Slow two-finger drag"; minimum: 0.1; maximum: 2.0; visible: root.val("accel") }
            TuneRow { key: "scroll_fast"; label: "Fast scroll"; hint: "Quick swipe"; minimum: 0.3; maximum: 5.0; visible: root.val("accel") }
            TuneRow { key: "scroll_ramp"; label: "Scroll speeds up"; hint: "Left = sooner, right = stays fine longer"; minimum: 0.15; maximum: 5.0; suffix: ""; visible: root.val("accel") }
            TuneRow { key: "terminal_scroll"; label: "Terminal scroll"; hint: "Replaces overall scroll speed in Alacritty, kitty and foot"; minimum: 0.1; maximum: 4.0 }

            // ---------- Other ----------
            // Plain pointer speed: only shown when smart acceleration is off (then it is the touchpad's speed).
            PanelSectionHeader { width: parent.width; text: "POINTER"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily; visible: !root.val("accel") }
            TuneRow { key: "sensitivity"; label: "Pointer speed"; hint: "-1 slowest · 0 default · 1 fastest"; minimum: -1.0; maximum: 1.0; suffix: ""; visible: !root.val("accel") }

            PanelSeparator { width: parent.width }

            // Footer: status text + Reset, which asks "are you sure?" before doing anything.
            Item {
              width: parent.width
              implicitHeight: Math.max(resetBtn.implicitHeight, yesBtn.implicitHeight)
              Text {
                anchors.left: parent.left
                anchors.right: root.confirmReset ? noBtn.left : resetBtn.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.confirmReset ? "Reset all settings to the defaults?"
                      : root.lastError   // empty unless something went wrong
                color: root.confirmReset ? root.bar.foreground : root.lastError !== "" ? "#FF6B6B" : Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: root.confirmReset ? Style.font.body : Style.font.caption
                font.bold: root.confirmReset
                wrapMode: Text.WordWrap
              }
              Button {
                id: resetBtn
                visible: !root.confirmReset
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Reset"
                tooltipText: "Back to the defaults (asks first)"
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: { root.confirmReset = true; confirmTimeout.restart() }
              }
              Button {
                id: noBtn
                visible: root.confirmReset
                anchors.right: yesBtn.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "No"
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.confirmReset = false
              }
              Button {
                id: yesBtn
                visible: root.confirmReset
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Yes, reset"
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: { root.confirmReset = false; root.resetAll() }
              }
              Timer { id: confirmTimeout; interval: 8000; onTriggered: root.confirmReset = false }
            }
          }
        }
      }
    }
    }
  }

  // ---- one labelled slider -------------------------------------------------------------
  component TuneRow: Column {
    id: row
    property string key: ""
    property string label: ""
    property string hint: ""
    property real minimum: 0
    property real maximum: 1
    property string suffix: "×"
    width: column.width
    spacing: Style.space(1)

    Item {
      width: parent.width
      implicitHeight: rowLabel.implicitHeight
      Text {
        id: rowLabel
        anchors.left: parent.left
        text: row.label
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        anchors.right: parent.right
        anchors.baseline: rowLabel.baseline
        text: root.fmt(slider.liveValue) + row.suffix
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
    }
    PanelSlider {
      id: slider
      bar: root.bar
      width: parent.width
      minimum: row.minimum
      maximum: row.maximum
      step: (row.maximum - row.minimum) / 40
      value: Number(root.val(row.key))
      onDraggingChanged: root.sliderActive = dragging
      onMoved: function(v) { root.preview(row.key, Math.round(v * 100) / 100) }
      onReleased: function(v) { root.setKey(row.key, Math.round(v * 100) / 100); liveValue = Number(root.val(row.key)) }
      // If a drag was ever interrupted (no release), don't keep showing an unapplied value.
      Connections {
        target: root
        function onOpenedChanged() { slider.dragging = false; slider.liveValue = slider.value }
        function onStChanged() { if (!slider.dragging) slider.liveValue = slider.value }
      }
    }
    Text {
      text: row.hint
      color: Qt.darker(root.bar.foreground, 1.6)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      width: parent.width
      elide: Text.ElideRight
    }
  }
}
