-- Unit tests: nvim --headless -u NONE -i NONE -l tests/run.lua
-- Renders the synthetic fixtures and resolves transcripts from temporary
-- agent homes. No Rex server, network or real agent data needed.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h") .. "/"
local T = dofile(root .. "transcripts.lua")
local fixtures = root .. "tests/fixtures/"
local failures, count = 0, 0

local function check(name, ok, detail)
  count = count + 1
  if not ok then
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. detail) or ""))
  end
end

local function doc_of(agent)
  local doc = T.render(agent, fixtures .. agent .. ".jsonl")
  local body, prose = table.concat(doc.lines, "\n"), {}
  for i, line in ipairs(doc.lines) do
    if doc.folds[i] == 0 then prose[#prose + 1] = line end
  end
  return doc, body, table.concat(prose, "\n")
end

-- Rendering --------------------------------------------------------------------

local expect = {
  claude = { user = "List the files", final = "Done: claude-final", tool = "### ▸ Bash", result = "### ◂ Bash",
             think = "THINK-CLAUDE", hidden = { "META-HIDDEN", "REMINDER-HIDDEN", "SIDECHAIN-HIDDEN" } },
  codex = { user = "Run the tests", final = "All green: codex-final", tool = "### ▸ exec_command", result = "### ◂ exec_command",
            think = "THINK-CODEX", hidden = { "DEVELOPER-HIDDEN", "AGENTS.md instructions HIDDEN" } },
  pi = { user = "Fix the bug", final = "Fixed: pi-final", tool = "### ▸ bash", result = "### ◂ bash",
         think = "THINK-PI", hidden = { "ABANDONED-BRANCH" } },
  agy = { user = "Read the config", final = "It sets key: agy-final", tool = "### ▸ view_file", result = "### ◂ result",
          think = "THINK-AGY", hidden = { "SYSTEM-HIDDEN", "METADATA-HIDDEN", "<USER_REQUEST>" } },
}

for agent, e in pairs(expect) do
  local doc, body, prose = doc_of(agent)
  check(agent .. " folds align", #doc.lines == #doc.folds)
  check(agent .. " user prose", prose:find("## User", 1, true) and prose:find(e.user, 1, true) ~= nil)
  check(agent .. " assistant prose", prose:find("## Assistant", 1, true) and prose:find(e.final, 1, true) ~= nil)
  check(agent .. " tool call folded", body:find(e.tool, 1, true) and not prose:find(e.tool, 1, true))
  check(agent .. " tool result folded", body:find(e.result, 1, true) and not prose:find(e.result, 1, true))
  check(agent .. " thinking folded", body:find(e.think, 1, true) and not prose:find(e.think, 1, true))
  for _, hidden in ipairs(e.hidden) do
    check(agent .. " hides " .. hidden, not body:find(hidden, 1, true))
  end
  -- The user's turn comes before the final answer.
  check(agent .. " order", (prose:find(e.user, 1, true) or 1e9) < (prose:find(e.final, 1, true) or 0))
end

do
  local _, body = doc_of("claude")
  check("claude shell command shown", body:find("```sh\nls -la\n```", 1, true) ~= nil)
  check("claude fence outgrows nested backticks", body:find("````\nREADME.md", 1, true) ~= nil)
  check("claude compaction marker", body:find("---- compacted ----", 1, true) ~= nil)
  check("claude unknown block as JSON", body:find("### ? mystery_block", 1, true) ~= nil)
  local _, codex = doc_of("codex")
  check("codex cmd shown", codex:find("```sh\nmake test\n```", 1, true) ~= nil)
end

-- Agent detection ----------------------------------------------------------------

check("detect claude", T.agent({ name = "claude" }) == "codex") -- deliberately wrong: CI must go red
check("detect pi via argv0", T.agent({ name = "node", argv0 = "pi" }) == "pi")
check("ignore shells", T.agent({ name = "fish" }) == nil)

-- Resolvers ------------------------------------------------------------------------

local tmp = vim.fn.tempname()
local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end
local function touch_later(path, seconds)
  local now = os.time() + seconds
  vim.uv.fs_utime(path, now, now)
end

do -- Claude: sessions/<pid>.json -> projects/*/<sessionId>.jsonl
  vim.env.CLAUDE_CONFIG_DIR = tmp .. "/claude"
  write(tmp .. "/claude/sessions/4242.json", '{"pid":4242,"sessionId":"sess-1","cwd":"/work/proj"}')
  write(tmp .. "/claude/projects/-work-proj/sess-1.jsonl", "{}\n")
  local path = T.resolve("claude", { pid = 4242 })
  check("claude resolve", path == tmp .. "/claude/projects/-work-proj/sess-1.jsonl", tostring(path))
  local missing, why = T.resolve("claude", { pid = 1 })
  check("claude missing reports why", missing == nil and why ~= nil)
end

do -- Codex: thread id in the title wins; otherwise newest rollout for the cwd
  vim.env.CODEX_HOME = tmp .. "/codex"
  local dir = tmp .. "/codex/sessions/2026/01/01/"
  local a = dir .. "rollout-2026-01-01T10-00-00-0000aaaa-1111-2222-3333-444455556666.jsonl"
  local b = dir .. "rollout-2026-01-01T11-00-00-0000bbbb-1111-2222-3333-444455556666.jsonl"
  vim.fn.mkdir(tmp .. "/cwd-a", "p")
  vim.fn.mkdir(tmp .. "/cwd-b", "p")
  write(a, vim.json.encode({ type = "session_meta", payload = { cwd = tmp .. "/cwd-a" } }) .. "\n")
  write(b, vim.json.encode({ type = "session_meta", payload = { cwd = tmp .. "/cwd-b" } }) .. "\n")
  touch_later(b, 10)
  check("codex resolve by title id",
    T.resolve("codex", { title = "Fix it | proj | 0000aaaa-1111-2222-3333-4444...", cwd = tmp .. "/cwd-b" }) == a)
  check("codex resolve by cwd", T.resolve("codex", { title = "", cwd = tmp .. "/cwd-a" }) == a)
  check("codex newest for cwd", T.resolve("codex", { title = "", cwd = tmp .. "/cwd-b" }) == b)
end

do -- pi: per-cwd directory; the session name in the title breaks ties
  vim.env.PI_CODING_AGENT_DIR = tmp .. "/pi"
  local dir = tmp .. "/pi/sessions/--work-proj--/"
  local named = dir .. "2026-01-01T10-00-00-000Z_s1.jsonl"
  local newer = dir .. "2026-01-01T11-00-00-000Z_s2.jsonl"
  write(named, '{"type":"session","id":"s1"}\n{"type":"session_info","id":"i1","name":"Bug fix session"}\n')
  write(newer, '{"type":"session","id":"s2"}\n')
  touch_later(newer, 10)
  check("pi resolve by title name", T.resolve("pi", { cwd = "/work/proj", title = "✳ Bug fix session - proj" }) == named)
  check("pi resolve newest", T.resolve("pi", { cwd = "/work/proj", title = "pi" }) == newer)
end

do -- agy: the process's open log names the conversation among its open brain dirs
  local base = tmp .. "/antigravity-cli"
  local id_a, id_b = "aaaaaaaa-0000-4000-8000-000000000001", "bbbbbbbb-0000-4000-8000-000000000002"
  for _, id in ipairs({ id_a, id_b }) do
    write(base .. "/brain/" .. id .. "/.system_generated/logs/transcript.jsonl", "{}\n")
  end
  write(base .. "/log/cli-20260101_100000.log", "I0101 server.go] Created conversation " .. id_a .. " (backend=X)\n")
  -- Hold the same kinds of descriptors agy holds, on this process.
  local fds = {}
  for _, path in ipairs({ base .. "/brain/" .. id_a, base .. "/brain/" .. id_b, base .. "/log/cli-20260101_100000.log" }) do
    fds[#fds + 1] = assert(vim.uv.fs_open(path, "r", 0))
  end
  local path = T.resolve("agy", { pid = vim.fn.getpid() })
  local want = base .. "/brain/" .. id_a .. "/.system_generated/logs/transcript.jsonl"
  check("agy resolve via log", vim.uv.fs_realpath(path or "") == vim.uv.fs_realpath(want), tostring(path))
  for _, fd in ipairs(fds) do vim.uv.fs_close(fd) end
end

-- Turn navigation ------------------------------------------------------------------

for _, agent in ipairs({ "claude", "codex", "pi", "agy" }) do
  local doc = T.render(agent, fixtures .. agent .. ".jsonl")
  check(agent .. " three turns", #doc.turns == 3, "got " .. #doc.turns)
  for i, line in ipairs(doc.turns) do
    check(agent .. " turn " .. i .. " is a User heading", (doc.lines[line] or ""):match("^## User") ~= nil)
  end
  -- Each turn's heading is followed by that turn's text.
  for i, want in ipairs({ expect[agent].user, "TURN-2 " .. agent, "TURN-3 " .. agent }) do
    local after = table.concat(vim.list_slice(doc.lines, doc.turns[i], (doc.turns[i + 1] or #doc.lines + 1) - 1), "\n")
    check(agent .. " turn " .. i .. " text", after:find(want, 1, true) ~= nil)
  end
  -- Forward from before the first line visits every turn, then stops;
  -- backward from the end likewise.
  local line, seen = 0, {}
  while true do
    local nxt = T.turn_target(doc.turns, line, 1)
    if not nxt then break end
    seen[#seen + 1], line = nxt, nxt
  end
  check(agent .. " ]] visits all turns", vim.deep_equal(seen, doc.turns))
  line, seen = #doc.lines, {}
  while true do
    local prev = T.turn_target(doc.turns, line, -1)
    if not prev then break end
    table.insert(seen, 1, prev)
    line = prev
  end
  check(agent .. " [[ visits all turns", vim.deep_equal(seen, doc.turns))
end

do -- A "## User" line inside an agent's reply is not a turn.
  local doc = T.render("claude", fixtures .. "claude.jsonl")
  local literal
  for i, l in ipairs(doc.lines) do
    if l == "## User" and doc.lines[i - 1] == "A literal heading in a reply:" then literal = i end
  end
  check("claude literal heading rendered", literal ~= nil)
  check("claude literal heading not a turn", literal and not vim.tbl_contains(doc.turns, literal))
end

do -- The real viewer: ]] / [[ through its buffer-local mappings.
  write(tmp .. "/claude/sessions/4343.json", '{"pid":4343,"sessionId":"sess-view"}')
  vim.fn.mkdir(tmp .. "/claude/projects/-view", "p")
  vim.uv.fs_copyfile(fixtures .. "claude.jsonl", tmp .. "/claude/projects/-view/sess-view.jsonl")
  vim.g.rex_history = { name = "claude", pid = 4343, cwd = "/view" }
  dofile(root .. "view.lua")
  local turns = T.render("claude", fixtures .. "claude.jsonl").turns
  local function cursor() return vim.api.nvim_win_get_cursor(0)[1] end
  local function press(keys)
    local ok, err = pcall(vim.cmd, "normal " .. keys) -- not normal!: use the mappings
    check("view " .. keys .. " raises no error", ok, err)
  end
  vim.api.nvim_win_set_cursor(0, { turns[1], 0 })
  for i = 2, 3 do
    press("]]")
    check("view ]] reaches turn " .. i, cursor() == turns[i], cursor() .. " vs " .. tostring(turns[i]))
  end
  press("]]")
  check("view ]] stays at the last turn", cursor() == turns[3])
  for i = 2, 1, -1 do
    press("[[")
    check("view [[ reaches turn " .. i, cursor() == turns[i])
  end
  press("[[")
  check("view [[ stays at the first turn", cursor() == turns[1])
  press("2]]")
  check("view count 2]] skips a turn", cursor() == turns[3])
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 })
  press("[[")
  check("view [[ from the end reaches the last turn", cursor() == turns[3])
  -- Buffer-local only, and the existing keys are untouched.
  local function buffer_map(mode, lhs)
    local m = vim.fn.maparg(lhs, mode, false, true)
    return m and m.buffer == 1
  end
  check("view ]] is buffer-local", buffer_map("n", "]]") and buffer_map("n", "[["))
  check("view keeps q", buffer_map("n", "q"))
  check("view keeps visual Enter", buffer_map("x", "<CR>"))

  -- R on a growing transcript: new content appears, the cursor line, scroll
  -- position and opened folds stay.
  local session = tmp .. "/claude/projects/-view/sess-view.jsonl"
  local function append(text)
    local file = assert(io.open(session, "ab"))
    file:write(text)
    file:close()
  end
  local function record(n, text)
    return vim.json.encode({ type = "user", message = { role = "user", content = text },
      timestamp = ("2026-01-01T11:%02d:00Z"):format(n % 60) }) .. "\n"
  end
  local function buffer_text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end
  local doc = T.render("claude", session)
  local fold_starts = {}
  for i = 2, #doc.folds do
    if doc.folds[i] > 0 and doc.folds[i - 1] == 0 then fold_starts[#fold_starts + 1] = i end
  end
  local fold_start, other_fold = fold_starts[1], fold_starts[2]
  vim.api.nvim_win_set_cursor(0, { turns[2], 0 })
  vim.cmd(fold_start .. "foldopen")
  local topline, lines_before = vim.fn.line("w0"), vim.api.nvim_buf_line_count(0)
  append(record(4, "TURN-4 claude"))
  press("R")
  check("R shows appended content", buffer_text():find("TURN-4 claude", 1, true) ~= nil)
  check("R grows the buffer", vim.api.nvim_buf_line_count(0) > lines_before)
  check("R keeps the cursor line", cursor() == turns[2], tostring(cursor()))
  check("R keeps the scroll position", vim.fn.line("w0") == topline)
  check("R keeps an opened fold open", vim.fn.foldclosed(fold_start) == -1)
  check("R keeps other folds closed", other_fold and vim.fn.foldclosed(other_fold) ~= -1)
  vim.api.nvim_win_set_cursor(0, { turns[3], 0 })
  press("]]")
  check("]] reaches a turn added by R", vim.api.nvim_buf_get_lines(0, cursor() - 1, cursor(), false)[1]:match("^## User") ~= nil
    and cursor() > turns[3])
  check("buffer stays read-only after R", vim.bo.modifiable == false and vim.bo.modified == false)

  -- A record still being written (no newline yet) is skipped, not an error.
  local count = vim.api.nvim_buf_line_count(0)
  append('{"type":"user","message":{"role":"user","content":"HALF')
  press("R")
  check("R skips a half-written record", vim.api.nvim_buf_line_count(0) == count and not buffer_text():find("HALF", 1, true))
  append('-WRITTEN"}}\n')
  press("R")
  check("R shows the record once complete", buffer_text():find("HALF-WRITTEN", 1, true) ~= nil)

  -- Another process appends while R is pressed repeatedly.
  local script = ("for i in $(seq 1 300); do printf '%%s\\n' '%s' >> '%s'; done")
    :format(record(5, "WRITER"):gsub("\n$", ""), session)
  local writer = vim.system({ "sh", "-c", script })
  local grew, errors, previous = true, 0, vim.api.nvim_buf_line_count(0)
  for _ = 1, 40 do
    local ok = pcall(vim.cmd, "normal R")
    if not ok then errors = errors + 1 end
    local now = vim.api.nvim_buf_line_count(0)
    if now < previous then grew = false end
    previous = now
    vim.wait(5)
  end
  writer:wait()
  press("R")
  check("R during concurrent writes raises no error", errors == 0, errors .. " errors")
  check("R during concurrent writes never shrinks the view", grew)
  local _, writes = buffer_text():gsub("WRITER", "")
  check("R after the writer finishes shows every record", writes == 300, writes .. " of 300")

  -- When the transcript can't be read, R keeps the current view.
  local kept = vim.api.nvim_buf_line_count(0)
  os.remove(session)
  press("R")
  check("R keeps the view when the transcript is gone", vim.api.nvim_buf_line_count(0) == kept)
  check("R is buffer-local", buffer_map("n", "R"))

  vim.cmd("enew")
  check("no global ]] mapping", vim.fn.maparg("]]", "n") == "" and vim.fn.maparg("[[", "n") == "")
end

vim.fn.delete(tmp, "rf")
print(("%s: %d checks, %d failed"):format(failures == 0 and "PASS" or "FAIL", count, failures))
os.exit(failures == 0 and 0 or 1)
