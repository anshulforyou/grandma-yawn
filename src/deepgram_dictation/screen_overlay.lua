-- What the user sees while grandma looks at the screen: a soft rose glow around the edges with
-- two threads of deep-rose yarn running round it, and the panel her answers appear in. Colours come from
-- the yarn in grandma's mascot. Neither ever takes focus; the glow lets clicks through.

local core = require("deepgram_dictation.core")

local M = {}

local function log(fmt, ...) print("[deepgram-dictation] " .. string.format(fmt, ...)) end

local function rgb(hex, alpha)
  return { red = tonumber(hex:sub(1, 2), 16) / 255, green = tonumber(hex:sub(3, 4), 16) / 255,
           blue = tonumber(hex:sub(5, 6), 16) / 255, alpha = alpha or 1 }
end

M.ROSE_DEEP, M.ROSE, M.ROSE_LIGHT = "d2626f", "fa98a3", "feb1bb"
local PANEL_BG, PANEL_TEXT, PANEL_MUTED = "1d1a1c", "f4eef0", "a8999e"

local FPS = 30
local THREAD_LENGTH = 260 -- points
local THREAD_SPEED = 420 -- points per second
local BREATH_SECONDS = 1.8
local HAZE_LAYERS, HAZE_WIDTH, HAZE_ALPHA = 18, 90, 0.04 -- the glow reaches HAZE_WIDTH / 2 into the screen

local glow, glowTimer, panel, panelKeys, pendingCancel

-- Glow ---------------------------------------------------------------------------------------

local function glowElements(frame)
  local rect = { x = 0, y = 0, w = frame.w, h = frame.h }
  local radius = { xRadius = 12, yRadius = 12 }
  local perimeter = 2 * (frame.w + frame.h)
  local function edge(id, color, alpha, width, extra)
    local e = { id = id, type = "rectangle", action = "stroke", frame = rect, roundedRectRadii = radius,
                strokeColor = rgb(color, alpha), strokeWidth = width }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
  end
  local thread = { strokeDashPattern = { THREAD_LENGTH, perimeter / 2 - THREAD_LENGTH }, strokeCapStyle = "round" }
  -- Canvas can't blur, so the glow is many faint strokes: where they overlap, at the very edge,
  -- it is strongest, and it fades out towards the middle of the screen.
  local elements = {}
  for i = 1, HAZE_LAYERS do
    table.insert(elements, edge("haze" .. i, i <= HAZE_LAYERS / 2 and M.ROSE_DEEP or M.ROSE, HAZE_ALPHA,
      HAZE_WIDTH * i / HAZE_LAYERS))
  end
  table.insert(elements, edge("line", M.ROSE_LIGHT, 0.9, 3))
  table.insert(elements, edge("thread", M.ROSE_DEEP, 1, 6, thread))
  return elements
end

function M.showGlow(screen)
  M.hideGlow(0)
  local frame = screen:fullFrame()
  glow = hs.canvas.new(frame)
  glow:level(hs.canvas.windowLevels.overlay)
  glow:behavior({ "canJoinAllSpaces", "stationary" })
  glow:appendElements(glowElements(frame))
  glow:show(0.2)
  local started = hs.timer.secondsSinceEpoch()
  glowTimer = hs.timer.doEvery(1 / FPS, function()
    if not glow then return end
    local t = hs.timer.secondsSinceEpoch() - started
    local breath = 0.5 + 0.5 * math.sin(t * 2 * math.pi / BREATH_SECONDS)
    glow:alpha(0.75 + 0.25 * breath)
    glow["thread"].strokeDashPhase = -(t * THREAD_SPEED)
  end)
end

function M.hideGlow(fade)
  if glowTimer then glowTimer:stop() glowTimer = nil end
  if glow then
    local c = glow
    glow = nil
    c:hide(fade or 0.3)
    hs.timer.doAfter((fade or 0.3) + 0.1, function() c:delete() end)
  end
end

-- Panel --------------------------------------------------------------------------------------

local W, PAD = 440, 20
local HEADER = 22
local BODY_SIZE, LINE_SPACING = 14, 3

local function styled(text, size, color, weight, alignment, alpha)
  return hs.styledtext.new(text, {
    font = { name = weight == "bold" and ".AppleSystemUIFontBold" or ".AppleSystemUIFont", size = size },
    color = rgb(color, alpha),
    paragraphStyle = { lineSpacing = LINE_SPACING, alignment = alignment or "natural" },
  })
end

local GIST_SIZE, GIST_GAP = 15, 10
local DIM = 0.62 -- the rest of the text, when some words are marked

-- The body as styled text: words grandma marked ("**...**") bright and bold, the rest dimmed so
-- the marked words read on their own. Text with no marks keeps its usual colour.
local function bodyText(runs, isError)
  local color = isError and M.ROSE_LIGHT or PANEL_TEXT
  local marked = false
  for _, r in ipairs(runs) do if r.hi then marked = true end end
  local out = styled("", BODY_SIZE, color)
  for _, r in ipairs(runs) do
    out = out .. styled(r.text, BODY_SIZE, r.hi and "ffffff" or color, r.hi and "bold" or nil, nil,
      (marked and not r.hi) and DIM or 1)
  end
  return out
end

-- Height `runs` need at `width`, in `size` (bold throughout when `allBold`). Canvas only measures
-- a single line, so this wraps words the way the text element will, measuring marked words bold.
local function textHeight(c, runs, width, size, allBold)
  c:appendElements({ type = "text", text = "", frame = { x = 0, y = 0, w = width, h = 10 } })
  local function measure(words)
    local st = styled("", size, PANEL_TEXT)
    for i, word in ipairs(words) do
      if i > 1 then st = st .. styled(" ", size, PANEL_TEXT) end
      for _, chunk in ipairs(word) do
        st = st .. styled(chunk.text, size, PANEL_TEXT, (allBold or chunk.hi) and "bold" or nil)
      end
    end
    return c:minimumTextSize(1, st)
  end
  local lineH = measure({ { { text = "Ag" } } }).h
  -- Paragraphs of words, each word a list of chunks (a word can be part marked: "**link**,").
  local paragraphs, word = { {} }, nil
  for _, r in ipairs(runs) do
    for space, piece in r.text:gmatch("(%s*)(%S*)") do
      if space ~= "" then
        word = nil
        for _ in space:gmatch("\n") do table.insert(paragraphs, {}) end
      end
      if piece ~= "" then
        if not word then
          word = {}
          table.insert(paragraphs[#paragraphs], word)
        end
        table.insert(word, { text = piece, hi = r.hi })
      end
    end
  end
  local lines = 0
  for _, words in ipairs(paragraphs) do
    local line = {}
    lines = lines + 1
    for _, w in ipairs(words) do
      table.insert(line, w)
      if #line > 1 and measure(line).w > width - 6 then
        lines = lines + 1
        line = { w }
      end
    end
  end
  c:removeElement(1)
  return math.ceil(lines * (lineH + LINE_SPACING)) + 4
end

function M.closePanel(fade)
  if panelKeys then panelKeys:stop() panelKeys = nil end
  -- A question closed any other way (the next dictation starting) counts as Esc.
  local cancel = pendingCancel
  pendingCancel = nil
  if cancel then log("card closed: replaced") end
  if panel then
    local c = panel
    panel = nil
    c:hide(fade or 0.15)
    hs.timer.doAfter(0.3, function() c:delete() end)
  end
  if cancel then cancel("replaced") end
end

-- Panel text: `text` may be { gist, body }. Returns gist (or nil), body.
local function split(text)
  if type(text) ~= "table" then return nil, text end
  local gist = text.gist and core.unmark(text.gist):match("^%s*(.-)%s*$")
  return gist ~= "" and gist or nil, text.body
end

-- Draws a panel's elements on a new canvas sized to fit, placed later. `footer` is a muted line
-- at the bottom; clicking it is reported with the id "footer". `maxShare` is how much of the
-- screen's height it may take.
local THUMB, CAPTION, FOOTER = 84, 18, 26
local function build(text, note, isError, pictures, footer, frame, maxShare)
  pictures = pictures or {}
  local gist, bodySource = split(text)
  local runs = core.highlightRuns(bodySource or "")
  local body = bodyText(runs, isError)
  local c = hs.canvas.new({ x = 0, y = 0, w = W, h = 100 })
  local gistH = gist and textHeight(c, { { text = gist } }, W - 2 * PAD, GIST_SIZE, true) or 0
  local top = PAD + HEADER + 10 + (gist and gistH + GIST_GAP or 0)
  local footH = footer and FOOTER or 0
  local maxBody = math.floor(frame.h * (maxShare or 0.7)) - top - PAD - footH
  local bodyH = (bodySource or "") ~= "" and math.min(textHeight(c, runs, W - 2 * PAD, BODY_SIZE), maxBody) or 0
  local shelf = #pictures > 0 and (12 + THUMB + CAPTION) or 0
  local h = top + bodyH + shelf + footH + PAD
  c:size({ w = W, h = h })
  c:appendElements({
    { id = "bg", type = "rectangle", action = "strokeAndFill", roundedRectRadii = { xRadius = 14, yRadius = 14 },
      fillColor = rgb(PANEL_BG), strokeColor = rgb(M.ROSE, 0.55), strokeWidth = 1,
      frame = { x = 0.5, y = 0.5, w = W - 1, h = h - 1 }, trackMouseUp = true, trackMouseEnterExit = true },
    { type = "circle", action = "fill", fillColor = rgb(M.ROSE), radius = 5,
      center = { x = PAD + 5, y = PAD + HEADER / 2 } },
    { type = "text", text = styled("grandma", 13, M.ROSE_LIGHT, "bold"),
      frame = { x = PAD + 16, y = PAD + 2, w = 200, h = HEADER } },
    { type = "text", text = styled(note or "", 12, PANEL_MUTED, nil, "right"),
      frame = { x = W - PAD - 200, y = PAD + 3, w = 200, h = HEADER } },
    { type = "text", text = body, frame = { x = PAD, y = top, w = W - 2 * PAD, h = bodyH } },
  })
  if gist then
    c:appendElements({ type = "text", text = styled(gist, GIST_SIZE, "ffffff", "bold"),
                       frame = { x = PAD, y = PAD + HEADER + 10, w = W - 2 * PAD, h = gistH } })
  end
  local slot = math.floor((W - 2 * PAD) / math.max(1, math.min(#pictures, 4)))
  for i, pic in ipairs(pictures) do
    if i > 4 then break end
    local x, y = PAD + (i - 1) * slot, top + bodyH + 12
    local image = hs.image.imageFromPath(pic.path)
    if image then
      c:appendElements({ type = "image", image = image, imageScaling = "scaleProportionally",
                         frame = { x = x, y = y, w = math.min(slot - 10, THUMB * 1.9), h = THUMB } })
    end
    c:appendElements({ type = "text", text = styled(pic.caption or "", 11, PANEL_MUTED),
                       frame = { x = x, y = y + THUMB + 2, w = slot - 10, h = CAPTION } })
  end
  if footer then
    c:appendElements({ id = "footer", type = "text", text = styled(footer, 12, M.ROSE_LIGHT, nil, nil, 0.8),
                       frame = { x = PAD, y = h - PAD - FOOTER + 8, w = W - 2 * PAD, h = FOOTER - 6 },
                       trackMouseUp = true })
  end
  c:level(hs.canvas.windowLevels.floating)
  c:behavior({ "canJoinAllSpaces", "fullScreenAuxiliary" })
  return c, h
end

local typeHandler -- function(ctx): set by init, runs what the user typed under a panel

-- Shows `text` next to the mouse, on whichever display it is on now. `text` may be { gist, body }:
-- the gist is one bold line on top. Words marked "**like this**" stand out from the rest. `note` is the small line in
-- the header ("Copied"). Closes on a click on the panel, on Esc, or when the next dictation starts.
-- With `keys` ({ onReturn, onEscape }) it asks: Return and Esc are answered here and never reach
-- the app underneath (so Return can't submit a form), and a click counts as Esc. `pictures`
-- ({ { path, caption } }) are shown under the text, so a file is seen before it is uploaded.
-- `opts`: corner = true puts it in the top right (her own messages), typeable = a context table
-- ({ replyTo = task id }) adds "click here to type" for an answer typed instead of said.
function M.showPanel(text, note, isError, keys, pictures, opts)
  opts = opts or {}
  M.closePanel()
  local frame = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local footer = opts.typeable and "Hold Fn+Control to reply, or click here to type" or nil
  local c, h = build(text, note, isError, pictures, footer, frame)
  c:topLeft(opts.corner and core.cornerOrigin(W, h, frame)
    or core.panelOrigin(hs.mouse.absolutePosition(), W, h, frame))
  pendingCancel = keys and keys.onEscape
  -- `how` (return, esc, click; "replaced" when a new press closed it) goes to the callback and
  -- the console, so a card nobody answered can be told apart from one the user cancelled.
  local function answer(fn, how)
    pendingCancel = nil
    M.closePanel(0)
    if keys then log("card closed: %s", how) end
    if fn then fn(how) end
  end
  c:mouseCallback(function(_, message, id)
    if message ~= "mouseUp" then return end
    if id == "footer" and opts.typeable and typeHandler then
      local at = c:frame()
      local ctx = opts.typeable
      answer(keys and keys.onEscape, "type")
      return typeHandler(ctx, { x = at.x, y = at.y, w = W })
    end
    answer(keys and keys.onEscape, "click")
  end)
  c:show(0.15)
  panel = c
  panelKeys = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local code = e:getKeyCode()
    if code == hs.keycodes.map.escape then
      answer(keys and keys.onEscape, "esc")
      return keys ~= nil
    end
    if keys and (code == hs.keycodes.map["return"] or code == hs.keycodes.map.padenter) then
      answer(keys.onReturn, "return")
      return true
    end
    return false
  end):start()
end

function M.panelOpen() return panel ~= nil end

function M.setTypeHandler(fn) typeHandler = fn end

-- Her own messages ---------------------------------------------------------------------------
-- When she has something to say on her own (a task finished, a meeting was filed), a card shows
-- in the top right for core.CARD_SECONDS (longer while the mouse is on it), then shrinks into her
-- round bubble in the corner, which stays until it is clicked. A click on either opens it.
-- Nothing here takes keys, so typing anywhere carries on as usual.

local BUBBLE = 64
local SHRINK = 0.45 -- seconds
local card, cardItem, cardTimer, cardAnim, bubble, spacesWatcher, spokeListener
local pending = {} -- items waiting in the bubble, newest last

local function mascot()
  M._mascot = M._mascot or hs.image.imageFromPath(hs.configdir .. "/deepgram_dictation/badges/grandma.gif")
  return M._mascot
end

local function cornerFrame()
  return (hs.screen.mainScreen() or hs.screen.primaryScreen()):frame()
end

local function hideBubble()
  if bubble then bubble:delete() bubble = nil end
end

local function openItem(item)
  if item.onOpen then return item.onOpen() end
  M.showPanel(item.text, item.note, item.isError, nil, nil, { corner = true, typeable = {} })
end

-- The bubble, made fresh each time (a window kept from earlier never shows over a full-screen
-- app it wasn't made on, see badge.lua). `grow` animates it in from nothing.
local function showBubble(grow)
  hideBubble()
  if #pending == 0 then return end
  local f = cornerFrame()
  local pad = 6
  local size = BUBBLE + 2 * pad
  local b = hs.canvas.new({ x = f.x + f.w - size - 12, y = f.y + 12, w = size, h = size })
  local elements = {
    { type = "circle", action = "strokeAndFill", fillColor = rgb(PANEL_BG), strokeColor = rgb(M.ROSE), strokeWidth = 2,
      center = { x = size / 2, y = size / 2 }, radius = BUBBLE / 2, trackMouseUp = true },
    { type = "image", image = mascot(), imageAnimates = true, imageScaling = "scaleProportionally",
      frame = { x = pad + 8, y = pad + 8, w = BUBBLE - 16, h = BUBBLE - 16 } },
  }
  if #pending > 1 then
    table.insert(elements, { type = "circle", action = "fill", fillColor = rgb(M.ROSE_DEEP),
      center = { x = size - 14, y = 14 }, radius = 10 })
    table.insert(elements, { type = "text", text = styled(tostring(#pending), 11, "ffffff", "bold", "center"),
      frame = { x = size - 24, y = 6, w = 20, h = 16 } })
  end
  b:appendElements(elements)
  b:level(hs.canvas.windowLevels.floating)
  b:behavior({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  b:clickActivating(false)
  b:mouseCallback(function(_, message)
    if message ~= "mouseUp" then return end
    local item = table.remove(pending)
    showBubble(false)
    if item then openItem(item) end
  end)
  b:show(grow and 0.2 or 0)
  bubble = b
end

local function stopCard()
  if cardTimer then cardTimer:stop() cardTimer = nil end
  if cardAnim then cardAnim:stop() cardAnim = nil end
  if card then card:delete() card = nil end
  local item = cardItem
  cardItem = nil
  if item and item.onHide then item.onHide() end
end

-- The card shrinks into the corner, and the bubble takes it in.
local function shrinkCard()
  if cardTimer then cardTimer:stop() cardTimer = nil end
  if not card then return end
  local item, c = cardItem, card
  local from = c:frame()
  local f = cornerFrame()
  local to = { x = f.x + f.w - BUBBLE - 18, y = f.y + 18, w = BUBBLE, h = BUBBLE }
  local started = hs.timer.secondsSinceEpoch()
  cardAnim = hs.timer.doEvery(1 / 60, function()
    local p = math.min(1, (hs.timer.secondsSinceEpoch() - started) / SHRINK)
    local e = 1 - (1 - p) ^ 3
    if card then
      card:frame({ x = from.x + (to.x - from.x) * e, y = from.y + (to.y - from.y) * e,
                   w = from.w + (to.w - from.w) * e, h = from.h + (to.h - from.h) * e })
      card:alpha(1 - e)
    end
    if p >= 1 then
      table.insert(pending, item)
      stopCard()
      showBubble(true)
    end
  end)
end

-- Shows `item` as a card: { text = { gist, body } or string, note, isError, onOpen, onShow,
-- onHide }. onShow runs as it appears and onHide when it goes (opened, shrunk or replaced), so a
-- task can take Fn+Control replies only while its card is up. Without onOpen, opening it shows
-- the whole text in a panel in the corner.
function M.showCard(item)
  if card then
    -- One card at a time: the one showing goes into the bubble first.
    table.insert(pending, cardItem)
    stopCard()
    showBubble(false)
  end
  local f = cornerFrame()
  local c, h = build(item.text, item.note, item.isError, nil, item.footer or "Click to open", f, 0.35)
  c:topLeft(core.cornerOrigin(W, h, f))
  c:clickActivating(false)
  local hovering = false
  c:mouseCallback(function(_, message)
    if message == "mouseEnter" then hovering = true
    elseif message == "mouseExit" then hovering = false
    elseif message == "mouseUp" then
      stopCard()
      openItem(item)
    end
  end)
  c:show(0.25)
  card, cardItem = c, item
  if spokeListener then spokeListener(item) end
  if item.onShow then item.onShow() end
  local left = core.CARD_SECONDS
  cardTimer = hs.timer.doEvery(1, function()
    if not hovering then left = left - 1 end
    if left <= 0 then shrinkCard() end
  end)
end

function M.cardOpen() return card ~= nil end

-- Opens the newest message waiting in her bubble, as a click on it would. False if none.
function M.openBubble()
  local item = table.remove(pending)
  if not item then return false end
  showBubble(false)
  openItem(item)
  return true
end

-- The card for task `taskId` goes without a trace (the user is answering it now). Any other
-- card is left alone.
function M.dismissCard(taskId)
  if cardItem and cardItem.taskId == taskId then stopCard() end
end

-- Called with each item as it shows, so init can carry it into the conversation.
function M.onSpoke(fn) spokeListener = fn end

-- Card and bubble out of a screenshot: `hidden` true hides them, false brings them back.
function M.hideForCapture(hidden)
  for _, c in ipairs({ card, bubble }) do
    if c then c:alpha(hidden and 0 or 1) end
  end
end

-- Typing instead of talking ----------------------------------------------------------------------

local box, boxWatch, boxPrev, boxDone, boxFocus -- luacheck: ignore 231

local function closeBox()
  if boxWatch then boxWatch:stop() boxWatch = nil end
  if boxFocus then boxFocus:stop() boxFocus = nil end
  if box then box:delete() box = nil end
end

local BOX_HTML = [[<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;background:#1d1a1c;overflow:hidden}
input{width:100%;height:44px;box-sizing:border-box;border:2px solid #fa98a3;border-radius:0;background:#1d1a1c;
color:#f4eef0;padding:0 14px;font:14px -apple-system,system-ui;outline:none}
input::placeholder{color:#a8999e}
</style></head><body><input id="t" placeholder="Type to grandma. Return sends, Esc cancels" autofocus>
<script>
const t=document.getElementById('t');t.focus();
t.addEventListener('keydown',e=>{
  if(e.key==='Enter'){e.preventDefault();webkit.messageHandlers.grandma.postMessage({text:t.value});}
  else if(e.key==='Escape'){webkit.messageHandlers.grandma.postMessage({cancel:true});}
});
</script></body></html>]]

-- A one-line box at `at` ({ x, y, w }); `done(text)` gets what was typed (nil if cancelled or
-- the user clicked away), after focus is back on the window they were in.
function M.typeBox(at, done)
  closeBox()
  boxPrev = hs.window.focusedWindow()
  local finished = false
  local function finish(text)
    if finished then return end
    finished = true
    closeBox()
    if boxPrev then boxPrev:focus() end
    boxDone = hs.timer.doAfter(0.25, function() boxDone = nil done(text) end)
  end
  local uc = hs.webview.usercontent.new("grandma")
  uc:setCallback(function(msg)
    local body = type(msg) == "table" and msg.body or {}
    if body.cancel then return finish(nil) end
    local text = type(body.text) == "string" and body.text:match("^%s*(.-)%s*$") or ""
    finish(text ~= "" and text or nil)
  end)
  local frame = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):frame()
  local y = math.min(at.y, frame.y + frame.h - 60)
  box = hs.webview.new({ x = at.x, y = y, w = at.w, h = 44 }, { developerExtrasEnabled = false }, uc)
  box:windowStyle({ "borderless" })
  box:allowTextEntry(true)
  box:level(hs.canvas.windowLevels.floating)
  box:behavior(hs.drawing.windowBehaviors.canJoinAllSpaces + hs.drawing.windowBehaviors.fullScreenAuxiliary)
  box:html(BOX_HTML)
  box:show()
  box:bringToFront(true)
  local win = box:hswindow()
  if win then win:focus() end
  -- The page's autofocus doesn't hold once the window takes focus: put the cursor in it again.
  local b = box
  -- Only the box itself loads: a link dropped on it must not bring a page that can post questions.
  local loaded = false
  b:policyCallback(function(action)
    if action == "navigationAction" or action == "navigationResponse" then return not loaded end
    return false
  end)
  b:navigationCallback(function(action)
    if action == "didFinishNavigation" then
      loaded = true
      b:evaluateJavaScript("document.getElementById('t').focus()")
    end
  end)
  boxFocus = hs.timer.doAfter(0.3, function()
    boxFocus = nil
    if box == b then b:evaluateJavaScript("document.getElementById('t').focus()") end
  end)
  -- Clicking into another app cancels it. (The focused window alone reads nil at moments while
  -- typing, so it is the frontmost app that counts.)
  local seen = false
  boxWatch = hs.timer.doEvery(0.4, function()
    local front = hs.application.frontmostApplication()
    local ours = front and front:bundleID() == hs.processInfo.bundleID
    if ours then seen = true elseif seen then finish(nil) end
  end)
end

function M.setup()
  if spacesWatcher then return end
  -- The bubble is long-lived: remake it on each Space change so it shows over full-screen apps.
  spacesWatcher = hs.spaces.watcher.new(function() if bubble then showBubble(false) end end):start()
end

function M.teardown()
  M.hideGlow(0)
  M.closePanel()
  stopCard()
  hideBubble()
  closeBox()
  if boxDone then boxDone:stop() boxDone = nil end
  pending = {}
  if spacesWatcher then spacesWatcher:stop() spacesWatcher = nil end
end

return M
