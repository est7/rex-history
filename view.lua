-- Floating history viewer, run inside the user's own Neovim by the Rex
-- `history_view` action (init.lua). vim.g.rex_history describes the source
-- pane: session, block, pid, name, argv0, cwd, title.
--
-- TUI agents (Claude Code, Codex, pi, agy) draw in the alternate screen, so
-- the terminal holds only their current screen; their full history is read
-- from the agent's transcript instead. Any other pane shows its scrollback.
local root = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)")
local transcripts = dofile(root .. "transcripts.lua")
local source = vim.g.rex_history or {}
local buf = vim.api.nvim_get_current_buf()

local function scrollback()
  local rex = (vim.env.REX_BIN_DIR and (vim.env.REX_BIN_DIR .. "/rex")) or "rex"
  local result = vim.system({ rex, "capture", "-s", source.session, "-b", source.block, "--unwrap", "--trim" },
    { text = true }):wait()
  if result.code ~= 0 then error("rex capture failed: " .. (result.stderr or ""), 0) end
  local lines = vim.split((result.stdout or ""):gsub("\n$", ""), "\n", { plain = true })
  return { lines = lines, folds = {} }
end

local function load()
  local agent = transcripts.agent(source)
  if agent then
    local ok, path, why = pcall(transcripts.resolve, agent, source)
    if ok and path then
      local doc = transcripts.render(agent, path)
      return doc, agent, path
    end
    vim.schedule(function()
      vim.notify(("history: %s transcript not found (%s); showing scrollback"):format(agent, tostring(ok and why or path)),
        vim.log.levels.WARN)
    end)
  end
  return scrollback(), nil, nil
end

local doc, agent, path = load()

vim.bo[buf].buftype = "nofile"
pcall(vim.api.nvim_buf_set_name, buf, "history://" .. (agent or "scrollback"))
vim.bo[buf].bufhidden = "wipe"
vim.bo[buf].swapfile = false
vim.bo[buf].undolevels = -1
vim.api.nvim_buf_set_lines(buf, 0, -1, false, doc.lines)
vim.bo[buf].modifiable = false
vim.bo[buf].modified = false
-- Not filetype=markdown: its LazyVim stack (treesitter, render-markdown,
-- ftplugins) took over a minute on a 20k-line transcript. A private filetype
-- plus Vim's regex Markdown syntax opens 170k lines in about a second.
vim.bo[buf].filetype = agent and "rexhistory" or "text"
if agent then vim.bo[buf].syntax = "markdown" end

local win = vim.api.nvim_get_current_win()
vim.wo[win].wrap = true
vim.wo[win].linebreak = true
vim.wo[win].spell = false
vim.wo[win].number = false
vim.wo[win].relativenumber = false
vim.wo[win].signcolumn = "no"

-- Tool calls, results and thinking start folded; zR / zM open and close all.
if agent then
  _G.RexHistoryFold = function(lnum)
    local level = doc.folds[lnum] or 0
    if level > 0 and (doc.folds[lnum - 1] or 0) == 0 then return ">1" end
    return tostring(level)
  end
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr = "v:lua.RexHistoryFold(v:lnum)"
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldenable = true
end

local function quit() vim.cmd("qa!") end
local map = function(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
end
map("n", "q", quit, "Close history")
-- ]] / [[: next / previous user turn; stays put at the last / first one.
if agent then
  local function jump(direction)
    return function()
      local line = vim.api.nvim_win_get_cursor(0)[1]
      for _ = 1, vim.v.count1 do
        line = transcripts.turn_target(doc.turns, line, direction) or line
      end
      if line ~= vim.api.nvim_win_get_cursor(0)[1] then
        vim.cmd("normal! m'")
        vim.api.nvim_win_set_cursor(0, { line, 0 })
      end
    end
  end
  map("n", "]]", jump(1), "Next turn")
  map("n", "[[", jump(-1), "Previous turn")
end
-- Visual Enter: copy the selection to the system clipboard and close.
map("x", "<CR>", function()
  vim.cmd('normal! "+y')
  quit()
end, "Copy selection and close")

local label = agent and (agent .. " · " .. vim.fn.fnamemodify(path, ":~")) or "scrollback"
vim.opt.titlestring = "history · " .. label
vim.opt.title = true
vim.api.nvim_win_set_cursor(win, { math.max(1, vim.api.nvim_buf_line_count(buf)), 0 })
vim.cmd("normal! zb")
