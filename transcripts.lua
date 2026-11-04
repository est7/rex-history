-- Finds a TUI agent's on-disk transcript from its Rex pane and renders it as
-- Markdown. Runs inside Neovim (vim.json, vim.uv, vim.system).
--
-- The transcript formats are private to each agent and drift between
-- releases, so rendering is lenient: known record shapes become prose, tool
-- calls and results become folded sections, unknown content kinds fall back
-- to folded JSON, and known bookkeeping records are skipped.
local M = {}

local home = vim.env.HOME
local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

local function read_lines(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local lines = {}
  for line in file:lines() do lines[#lines + 1] = line end
  file:close()
  return lines
end

local function first_line(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local line = file:read("*l")
  file:close()
  return line
end

local function decode(line)
  local ok, value = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if ok and type(value) == "table" then return value end
end

local function mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec + stat.mtime.nsec / 1e9 or 0
end

local function newest(paths)
  table.sort(paths, function(a, b) return mtime(a) > mtime(b) end)
  return paths[1]
end

local function realpath(path)
  return path and (vim.uv.fs_realpath(path) or path)
end

-- Agent detection ----------------------------------------------------------

-- pi runs as `node` with argv0 `pi`; the others are native binaries.
function M.agent(source)
  local name = source.name or ""
  if name == "claude" or name == "codex" or name == "agy" then return name end
  if source.argv0 == "pi" or name == "pi" then return "pi" end
end

-- Resolvers: pane -> transcript path ---------------------------------------

local resolve = {}

-- Claude Code records each interactive process in sessions/<pid>.json.
function resolve.claude(source)
  local root = vim.env.CLAUDE_CONFIG_DIR or (home .. "/.claude")
  local meta = decode(first_line(root .. "/sessions/" .. source.pid .. ".json") or "")
  if not (meta and meta.sessionId) then return nil, "no sessions/" .. source.pid .. ".json" end
  local path = vim.fn.glob(root .. "/projects/*/" .. meta.sessionId .. ".jsonl", true, true)[1]
  return path, path == nil and ("no transcript for session " .. meta.sessionId) or nil
end

-- Codex's terminal title can carry the thread id (here via tui.terminal_title);
-- otherwise take the newest rollout whose session_meta cwd matches the pane.
function resolve.codex(source)
  local root = (vim.env.CODEX_HOME or (home .. "/.codex")) .. "/sessions"
  local id = (source.title or ""):match("(%x%x%x%x%x%x%x%x%-%x%x%x%x%-[%x%-]+)")
  if id then
    local hits = vim.fn.glob(root .. "/*/*/*/rollout-*" .. id:gsub("%-+$", "") .. "*.jsonl", true, true)
    if #hits > 0 then return newest(hits) end
  end
  local cwd = realpath(source.cwd)
  local files = vim.fn.glob(root .. "/*/*/*/rollout-*.jsonl", true, true)
  table.sort(files, function(a, b) return mtime(a) > mtime(b) end)
  for i = 1, math.min(#files, 40) do
    local meta = decode(first_line(files[i]) or "")
    local payload = meta and meta.payload
    if payload and realpath(payload.cwd) == cwd then return files[i] end
  end
  return nil, "no rollout for " .. tostring(source.cwd)
end

-- pi keeps one directory per cwd (slashes become dashes, wrapped in "--").
-- Its pane title carries the session name, which breaks ties when several pi
-- sessions share a cwd; otherwise the most recently written file wins.
function resolve.pi(source)
  local root = vim.env.PI_CODING_AGENT_DIR or (home .. "/.pi/agent")
  local cwd = source.cwd or ""
  local slug = "--" .. cwd:gsub("^/", ""):gsub("/", "-") .. "--"
  local files = vim.fn.glob(root .. "/sessions/" .. slug .. "/*.jsonl", true, true)
  if #files == 0 then return nil, "no pi sessions for " .. cwd end
  table.sort(files, function(a, b) return mtime(a) > mtime(b) end)
  local title = source.title or ""
  for i = 1, math.min(#files, 10) do
    for _, line in ipairs(read_lines(files[i]) or {}) do
      local entry = line:find('"session_info"', 1, true) and decode(line)
      if entry and entry.type == "session_info" and entry.name and entry.name ~= ""
          and title:find(entry.name, 1, true) then
        return files[i]
      end
    end
  end
  return files[1]
end

-- agy opens its own log and its conversation's brain/<id> directory. The log
-- names the conversation it created or resumed; failing that, the open brain
-- directory with the freshest transcript wins.
function resolve.agy(source)
  local result = vim.system({ "lsof", "-p", tostring(source.pid), "-Fn" }, { text = true }):wait()
  local brains, logs = {}, {}
  for name in (result.stdout or ""):gmatch("n([^\n]+)") do
    local id = name:match("/brain/(" .. UUID .. ")$")
    if id then brains[id] = name end
    if name:match("/antigravity%-cli/log/cli%-[%d_]+%.log$") then logs[#logs + 1] = name end
  end
  local function transcript(dir) return dir .. "/.system_generated/logs/transcript.jsonl" end
  local chosen
  for _, log in ipairs(logs) do
    for _, line in ipairs(read_lines(log) or {}) do
      local id = line:match("[Cc]onversation (" .. UUID .. ")")
      if id and brains[id] then chosen = brains[id] end
    end
  end
  if chosen and vim.uv.fs_stat(transcript(chosen)) then return transcript(chosen) end
  local candidates = {}
  for _, dir in pairs(brains) do
    if vim.uv.fs_stat(transcript(dir)) then candidates[#candidates + 1] = transcript(dir) end
  end
  if #candidates == 0 then return nil, "no open agy conversation" end
  return newest(candidates)
end

function M.resolve(agent, source)
  return resolve[agent](source)
end

-- Markdown writer ------------------------------------------------------------

-- Collects lines plus a fold level per line: level 1 inside a folded detail
-- section (tool call, tool result, thinking), 0 elsewhere. turns lists the
-- line of each "## User" heading, recorded here rather than matched in the
-- buffer, since an agent's reply can itself contain such a line.
local function writer()
  local w = { lines = {}, folds = {}, turns = {}, role = nil }

  local function push(line, fold)
    w.lines[#w.lines + 1] = line
    w.folds[#w.folds + 1] = fold
  end

  local function text_lines(text, fold)
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do push(line, fold) end
  end

  local function fence_for(text)
    local longest = 2
    for run in text:gmatch("`+") do longest = math.max(longest, #run) end
    return string.rep("`", longest + 1)
  end

  function w.heading(role, stamp)
    if w.role == role then return end
    w.role = role
    if #w.lines > 0 and w.lines[#w.lines] ~= "" then push("", 0) end
    if role == "User" then w.turns[#w.turns + 1] = #w.lines + 1 end
    push("## " .. role .. (stamp and ("  ·  " .. stamp) or ""), 0)
    push("", 0)
  end

  function w.prose(role, text, stamp)
    text = vim.trim(text or "")
    if text == "" then return end
    w.heading(role, stamp)
    text_lines(text, 0)
    push("", 0)
  end

  -- A folded section: the "### title" line opens the fold, the body sits in a
  -- fence so Markdown inside tool output can't break the layout.
  function w.detail(role, title, body, lang)
    w.heading(role)
    body = body or ""
    push("### " .. title, 1)
    if vim.trim(body) ~= "" then
      local fence = fence_for(body)
      push(fence .. (lang or ""), 1)
      text_lines((body:gsub("\n+$", "")), 1)
      push(fence, 1)
    end
    push("", 0)
  end

  function w.marker(text)
    w.role = nil
    if #w.lines > 0 and w.lines[#w.lines] ~= "" then push("", 0) end
    push("---- " .. text .. " ----", 0)
    push("", 0)
  end

  return w
end

local function json(value)
  if type(value) == "string" then return value end
  local ok, encoded = pcall(vim.json.encode, value, { indent = "  " })
  return ok and encoded or vim.inspect(value)
end

-- Tool input: show the command itself for shell tools, JSON for the rest.
local function tool_input(input)
  if type(input) == "string" then
    local decoded = decode(input)
    if decoded then input = decoded else return input, nil end
  end
  if type(input) == "table" and type(input.command) == "string" and vim.tbl_count(input) <= 3 then
    return input.command, "sh"
  end
  if type(input) == "table" and type(input.cmd) == "string" then return input.cmd, "sh" end
  return json(input), "json"
end

local function text_of(content)
  if type(content) == "string" then return content end
  if type(content) ~= "table" then return "" end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "string" then parts[#parts + 1] = item
    elseif item.text then parts[#parts + 1] = item.text
    elseif item.type == "image" or item.type == "input_image" then parts[#parts + 1] = "[image]"
    end
  end
  return table.concat(parts, "\n")
end

local function strip_reminders(text)
  return (text:gsub("<system%-reminder>.-</system%-reminder>", ""))
end

local function clock(iso)
  return type(iso) == "string" and iso:match("T(%d%d:%d%d)") or nil
end

-- Renderers: transcript records -> writer calls -----------------------------

local render = {}

function render.claude(records, w)
  local names = {}
  for _, d in ipairs(records) do
    local m = d.message
    if d.isSidechain or d.isMeta or not m then
      if d.type == "system" and d.subtype == "compact_boundary" then w.marker("compacted") end
    elseif d.isCompactSummary then
      w.detail("User", "Compaction summary", text_of(m.content), "markdown")
    elseif d.type == "user" then
      if type(m.content) == "string" then
        w.prose("User", strip_reminders(m.content), clock(d.timestamp))
      else
        for _, c in ipairs(m.content or {}) do
          if c.type == "text" then
            w.prose("User", strip_reminders(c.text), clock(d.timestamp))
          elseif c.type == "tool_result" then
            local name = names[c.tool_use_id] or "tool"
            w.detail("Assistant", "◂ " .. name .. (c.is_error and " (error)" or ""), strip_reminders(text_of(c.content)))
          elseif c.type == "image" then
            w.prose("User", "[image]", clock(d.timestamp))
          end
        end
      end
    elseif d.type == "assistant" then
      for _, c in ipairs(m.content or {}) do
        if c.type == "text" then
          w.prose("Assistant", c.text, clock(d.timestamp))
        elseif c.type == "thinking" then
          if vim.trim(c.thinking or "") ~= "" then w.detail("Assistant", "Thinking", c.thinking, "markdown") end
        elseif c.type == "tool_use" or c.type == "server_tool_use" then
          names[c.id] = c.name
          local body, lang = tool_input(c.input)
          w.detail("Assistant", "▸ " .. c.name, body, lang)
        elseif type(c.type) == "string" and c.type:match("_tool_result$") then
          w.detail("Assistant", "◂ " .. (names[c.tool_use_id] or c.type), text_of(c.content) ~= "" and text_of(c.content) or json(c.content), nil)
        elseif c.type ~= "redacted_thinking" then
          w.detail("Assistant", "? " .. tostring(c.type), json(c), "json")
        end
      end
    end
  end
end

local function codex_kinds(payload)
  local meta = payload.internal_chat_message_metadata_passthrough
  return meta and meta.content_item_kinds or {}
end

function render.codex(records, w)
  local names = {}
  for _, d in ipairs(records) do
    local p = d.payload or {}
    local stamp = clock(d.timestamp)
    if d.type == "compacted" then
      w.marker("compacted")
    elseif d.type == "response_item" then
      local t = p.type
      if t == "message" and p.role == "user" then
        local kinds = codex_kinds(p)
        -- Harness context (AGENTS.md, environment) also arrives as role=user.
        if vim.tbl_contains(kinds, "user.text") or #kinds == 0 then
          w.prose("User", text_of(p.content), stamp)
        end
      elseif t == "message" and p.role == "assistant" then
        w.prose("Assistant", text_of(p.content), stamp)
      elseif t == "reasoning" then
        local summary = text_of(p.summary)
        if vim.trim(summary) ~= "" then w.detail("Assistant", "Thinking", summary, "markdown") end
      elseif t == "function_call" or t == "custom_tool_call" or t == "local_shell_call" then
        local name = (p.namespace and (p.namespace .. ".") or "") .. tostring(p.name or t)
        names[p.call_id or ""] = name
        local body, lang = tool_input(p.arguments or p.input or p.action)
        w.detail("Assistant", "▸ " .. name, body, lang)
      elseif t == "function_call_output" or t == "custom_tool_call_output" then
        local output = p.output
        if type(output) == "table" and output.content then output = output.content end
        w.detail("Assistant", "◂ " .. (names[p.call_id or ""] or "tool"), text_of(output))
      elseif t == "agent_message" then
        w.detail("Assistant", "✉ " .. tostring(p.author) .. " → " .. tostring(p.recipient), text_of(p.content))
      elseif t ~= "message" and t ~= "additional_tools" then
        w.detail("Assistant", "? " .. tostring(t), json(p), "json")
      end
    end
  end
end

-- pi stores a tree (entries link by parentId; /tree can branch). Show the
-- branch that ends at the most recent entry.
local function pi_branch(records)
  local by_id, last = {}, nil
  for _, d in ipairs(records) do
    if d.id and d.type ~= "session" then by_id[d.id] = d; last = d end
  end
  local branch, seen = {}, {}
  while last and not seen[last.id] do
    seen[last.id] = true
    table.insert(branch, 1, last)
    last = last.parentId and by_id[last.parentId]
  end
  return branch
end

function render.pi(records, w)
  for _, d in ipairs(pi_branch(records)) do
    local m = d.message
    local stamp = clock(d.timestamp)
    if d.type == "compaction" then
      w.marker("compacted")
    elseif d.type == "custom_message" and d.display then
      w.detail("User", tostring(d.customType), text_of(d.content))
    elseif d.type == "message" and m then
      if m.role == "user" then
        w.prose("User", text_of(m.content), stamp)
      elseif m.role == "assistant" then
        for _, c in ipairs(type(m.content) == "table" and m.content or {}) do
          if c.type == "text" then
            w.prose("Assistant", c.text, stamp)
          elseif c.type == "thinking" then
            if vim.trim(c.thinking or "") ~= "" then w.detail("Assistant", "Thinking", c.thinking, "markdown") end
          elseif c.type == "toolCall" then
            local body, lang = tool_input(c.arguments)
            w.detail("Assistant", "▸ " .. tostring(c.name), body, lang)
          else
            w.detail("Assistant", "? " .. tostring(c.type), json(c), "json")
          end
        end
      elseif m.role == "toolResult" then
        w.detail("Assistant", "◂ " .. tostring(m.toolName) .. (m.isError and " (error)" or ""), text_of(m.content))
      elseif m.role == "bashExecution" then
        w.detail("User", "! " .. tostring(m.command), tostring(m.output or ""))
      elseif m.role ~= "system" then
        w.detail("Assistant", "? " .. tostring(m.role), json(m), "json")
      end
    end
  end
end

function render.agy(records, w)
  local skip = { SYSTEM_MESSAGE = true, EPHEMERAL_MESSAGE = true }
  for _, d in ipairs(records) do
    local t, stamp = d.type, clock(d.created_at)
    if t == "USER_INPUT" then
      local content = d.content or ""
      w.prose("User", content:match("<USER_REQUEST>\n?(.-)\n?</USER_REQUEST>") or content, stamp)
    elseif t == "PLANNER_RESPONSE" then
      if vim.trim(d.thinking or "") ~= "" then w.detail("Assistant", "Thinking", d.thinking, "markdown") end
      w.prose("Assistant", d.content, stamp)
      for _, call in ipairs(type(d.tool_calls) == "table" and d.tool_calls or {}) do
        local body, lang = tool_input(call.args)
        w.detail("Assistant", "▸ " .. tostring(call.name), body, lang)
      end
    elseif t == "GENERIC" then
      local body = d.content or ""
      if d.error then body = d.error .. "\n\n" .. body end
      w.detail("Assistant", "◂ result" .. (d.status == "ERROR" and " (error)" or ""), body)
    elseif t == "CHECKPOINT" then
      w.marker("compacted")
    elseif t == "ERROR_MESSAGE" then
      w.detail("Assistant", "⚠ error", d.error or d.content)
    elseif not skip[t] then
      w.detail("Assistant", "? " .. tostring(t), json(d), "json")
    end
  end
end

-- Returns { lines, folds, turns } for the transcript at path.
function M.render(agent, path)
  local records = {}
  for _, line in ipairs(read_lines(path) or {}) do
    local record = decode(line)
    if record then records[#records + 1] = record end
  end
  local w = writer()
  render[agent](records, w)
  return { lines = w.lines, folds = w.folds, turns = w.turns }
end

-- The turn heading after (direction 1) or before (-1) line lnum, or nil
-- when there is none in that direction.
function M.turn_target(turns, lnum, direction)
  if direction > 0 then
    for _, line in ipairs(turns) do
      if line > lnum then return line end
    end
  else
    for i = #turns, 1, -1 do
      if turns[i] < lnum then return turns[i] end
    end
  end
end

return M
