-- Grandma's daily look back at what went wrong. Failures that used to reach only the Hammerspoon
-- console (gone after a restart) are recorded with M.record in <support>/problems/<day>.jsonl.
-- Once a day, and a minute after Hammerspoon starts, the check reads those, the saved dictation
-- records (cleanup timeouts, slow mic starts) and new crash reports for our apps, and shows her card
-- when something is worth telling (core.healthReport). Never during a call, never a macOS
-- notification, and nothing leaves this Mac. The recorder crashed 21 times over 8 days before
-- anyone noticed (2026-10-20): this is so the next one is seen the next day.
local core = require("deepgram_dictation.core")
local overlay = require("deepgram_dictation.screen_overlay")

local M = {}

local cfg, inCall, startTimer, hourly
local CRASH_DIR = os.getenv("HOME") .. "/Library/Logs/DiagnosticReports"

local function log(fmt, ...) print("[deepgram-dictation] health: " .. string.format(fmt, ...)) end

-- Where problems, dictations and the check state are read from (a test points it elsewhere).
M.dir = nil
local function base() return M.dir or core.supportDir() end
local function statePath() return base() .. "/health.json" end

-- Records a problem: `kind` one of core.HEALTH_KINDS, `detail` a short reason.
function M.record(kind, detail)
  local dir = base() .. "/problems"
  hs.fs.mkdir(base())
  hs.fs.mkdir(dir)
  local f = io.open(string.format("%s/%s.jsonl", dir, os.date("%Y-%m-%d")), "a")
  if not f then return log("could not write a problem: %s", kind) end
  local record = { at = os.time(), kind = kind, detail = detail and tostring(detail):sub(1, 300) or nil }
  f:write(hs.json.encode(record) .. "\n")
  f:close()
end

local function lastCheck()
  local ok, state = pcall(hs.json.read, statePath())
  return ok and type(state) == "table" and tonumber(state.lastCheck) or nil
end

-- Files in `dir` modified after `since`, as { name, path, modified }.
local function newFiles(dir, since, match)
  local found = {}
  if not hs.fs.attributes(dir) then return found end
  for name in hs.fs.dir(dir) do
    if match(name) then
      local path = dir .. "/" .. name
      local attrs = hs.fs.attributes(path)
      if attrs and attrs.modification > since then
        table.insert(found, { name = name, path = path, modified = attrs.modification })
      end
    end
  end
  table.sort(found, function(a, b) return a.modified < b.modified end)
  return found
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local text = f:read("a")
  f:close()
  return text
end

-- Everything that went wrong since `since` (epoch seconds), as { kind, detail, app } items.
function M.problemsSince(since, crashDir)
  local problems = {}
  for _, file in ipairs(newFiles(base() .. "/problems", since, function(n) return n:match("%.jsonl$") end)) do
    for line in io.lines(file.path) do
      local ok, p = pcall(hs.json.decode, line)
      if ok and type(p) == "table" and tonumber(p.at) and p.at > since then table.insert(problems, p) end
    end
  end
  for _, file in ipairs(newFiles(base() .. "/dictations", since, function(n) return n:match("%.json$") end)) do
    local ok, record = pcall(hs.json.read, file.path)
    if ok then
      for _, p in ipairs(core.dictationProblems(record)) do table.insert(problems, p) end
    end
  end
  -- Any report touched since, kept when its name says it crashed since, oldest first.
  local crashes = {}
  for _, file in ipairs(newFiles(crashDir or CRASH_DIR, since, core.crashApp)) do
    local at = core.crashTime(file.name)
    if at and at > since then table.insert(crashes, { at = at, file = file }) end
  end
  table.sort(crashes, function(a, b) return a.at < b.at end)
  for _, c in ipairs(crashes) do
    local detail = core.crashDetail(c.file.name, read(c.file.path))
    table.insert(problems, { kind = "crash", app = core.crashApp(c.file.name), detail = detail })
  end
  return problems
end

-- Looks back over everything since the last check and shows the card when something is worth
-- telling. `force` checks even when a day hasn't passed. Returns the report shown, or nil.
function M.check(force, crashDir)
  local now = hs.timer.secondsSinceEpoch() -- not os.time(): file times have fractions of a second
  local last = lastCheck()
  if not force and not core.healthDue(now, last) then return nil end
  if inCall and inCall() then return nil end -- the hourly tick tries again
  local report = core.healthReport(M.problemsSince(last or (now - 86400), crashDir))
  hs.json.write({ lastCheck = now }, statePath(), true, true)
  if not report then return nil end
  log("%s", report.gist)
  overlay.showCard({ text = { gist = report.gist, body = report.body }, note = "Health", isError = true })
  return report
end

function M.setup(config, isInCall)
  cfg, inCall = config, isInCall
  if not cfg.healthCheck then return end
  startTimer = hs.timer.doAfter(60, function() startTimer = nil M.check() end)
  hourly = hs.timer.doEvery(3600, function() M.check() end)
end

function M.teardown()
  if startTimer then startTimer:stop() startTimer = nil end
  if hourly then hourly:stop() hourly = nil end
end

return M
