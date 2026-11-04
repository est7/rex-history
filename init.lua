-- rex-history: the focused pane's full history in a floating Neovim.
--
-- Claude Code, Codex, pi and agy draw in the alternate screen, so the
-- terminal keeps only their current screen; their history is read from the
-- agent's own transcript. Any other pane shows its scrollback.
--
-- Load from your Rex init.lua (keep the three .lua files together):
--   dofile("/path/to/rex-history/init.lua").setup()
local root = assert(debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*/)"),
  "rex-history: load init.lua from a file with dofile")
local M = {}

local defaults = {
  key = "cmd+shift+c",                  -- Rex shortcut; false to bind it yourself
  nvim = "nvim",                        -- resolved through your login shell's PATH
  bounds = { 0.05, 0.05, 0.9, 0.9 },    -- floating layer: x, y, width, height
}

function M.setup(user)
  local options = {}
  for key, value in pairs(defaults) do options[key] = value end
  for key, value in pairs(user or {}) do
    assert(defaults[key] ~= nil, "rex-history: unknown option " .. tostring(key))
    options[key] = value
  end
  assert(options.key == false or (type(options.key) == "string" and options.key ~= ""),
    "rex-history: key must be a shortcut or false")
  assert(type(options.nvim) == "string" and options.nvim ~= "", "rex-history: nvim must be a command or path")
  assert(type(options.bounds) == "table" and #options.bounds == 4, "rex-history: bounds must be {x, y, w, h}")

  rex.action{
    name = "history_view",
    title = "History View",
    description = "Show the pane's full history, or a TUI agent's transcript, in a floating Neovim",
    category = "Pane",
    keywords = "history scrollback transcript copy claude codex pi agy",
    run = function(ctx)
      local function method(name)
        local ok, result = pcall(rex.call, "block.method",
          { session_id = ctx.session_id, block_id = ctx.block_id, method = name })
        return ok and result or nil
      end
      local process = method("process")
      local fg = process and process.foreground
      if not fg then return false end
      local source = {
        session = ctx.session_id, block = ctx.block_id,
        pid = fg.pid, name = fg.name, argv0 = fg.argv0, cwd = fg.cwd,
        title = (method("title") or {}).title,
      }
      local tmp = (os.getenv("TMPDIR") or "/tmp/"):gsub("/*$", "/")
      rex.call("session.new_layer", {
        session_id = ctx.session_id,
        bounds = options.bounds,
        focus = true,
        layout = { block = { flavor = "com.superlogical.terminal.shell", label = "history", options = {
          -- Runs through the login shell's environment (no shell = "none"):
          -- Neovim plugins need its PATH, which the Rex server's lacks.
          cwd = fg.cwd,
          exit = { on_completion = true, quick_exit_threshold_ms = 0 },
          command = {
            options.nvim,
            "--cmd", "lua vim.g.rex_history = vim.json.decode(" .. string.format("%q", rex.json.encode(source)) .. ")",
            "-c", "lua dofile(" .. string.format("%q", root .. "view.lua") .. ")",
            -- A buffer name keeps start screens (dashboards) away; nothing is written.
            tmp .. "rex-history-" .. ctx.block_id:gsub("%W", ""),
          },
        } } },
      })
      return true
    end,
  }
  if options.key then rex.bind(options.key, "history_view") end
  return M
end

return M
