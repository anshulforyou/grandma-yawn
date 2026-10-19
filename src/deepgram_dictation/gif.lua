-- Grandma's animated GIFs in hs.canvas, played by her own clock.
--
-- hs.canvas can animate a GIF by itself (imageAnimates), but its animators leak: every canvas that
-- shows an image steps the image's one frame counter on its own timer, a deleted canvas keeps
-- its timer until Lua collects it, and replacing an image element (the badge morphs by rebuilding
-- its elements 50 times a second) can start another that nothing stops. Each leaked animator
-- makes the GIF play faster: grandma and her yarn ran 10 to 20 times too fast after a day's use
-- (2026-10-20, tests/integration/gif_speed.sh). So GIFs are drawn as still images and their frame
-- is set from the clock (core.gifFrame), by one timer per visible canvas, at the GIF's own frame
-- time. Their speed can't drift, whatever is made, rebuilt or deleted.

local core = require("deepgram_dictation.core")

local M = {}

local timing = {} -- path -> { frames, seconds }, or false when it isn't an animated GIF

local function info(path)
  if timing[path] == nil then
    local f = io.open(path, "rb")
    local frames, seconds = core.gifTiming(f and f:read("a"))
    if f then f:close() end
    timing[path] = frames and { frames = frames, seconds = seconds } or false
  end
  return timing[path] or nil
end

local images = {}

-- The image at `path`, for an element made with M.element.
function M.load(path)
  if images[path] == nil then images[path] = hs.image.imageFromPath(path) or false end
  return images[path] or nil
end

-- An image element showing the GIF at `path` at the current moment of its animation. Other
-- fields of the element (frame, alpha, ...) come from `fields`.
function M.element(path, fields)
  local element = { type = "image", image = M.load(path), imageAnimates = false, id = "gif:" .. path,
                    imageScaling = "scaleProportionally" }
  for k, v in pairs(fields or {}) do element[k] = v end
  local gif = info(path)
  if gif then element.imageAnimationFrame = core.gifFrame(hs.timer.secondsSinceEpoch(), gif.frames, gif.seconds) end
  return element
end

-- Keeps the GIF elements of `canvas` (made with M.element) moving. Returns the timer: stop it
-- (M.stop) when the canvas goes. Elements may be replaced meanwhile; each tick finds them again.
function M.play(canvas)
  local fastest
  for i = 1, #canvas do
    local id = canvas[i].id
    local gif = type(id) == "string" and id:sub(1, 4) == "gif:" and info(id:sub(5))
    if gif and (not fastest or gif.seconds < fastest) then fastest = gif.seconds end
  end
  if not fastest then return nil end
  return hs.timer.doEvery(fastest, function()
    local now = hs.timer.secondsSinceEpoch()
    for i = 1, #canvas do
      local id = canvas[i].id
      local gif = type(id) == "string" and id:sub(1, 4) == "gif:" and info(id:sub(5))
      if gif then
        local frame = core.gifFrame(now, gif.frames, gif.seconds)
        if canvas[i].imageAnimationFrame ~= frame then canvas[i].imageAnimationFrame = frame end
      end
    end
  end)
end

function M.stop(timer)
  if timer then timer:stop() end
end

return M
