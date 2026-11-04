# rex-history

The focused [Rex](https://www.superlogical.com/rex) pane's full history, in a floating Neovim that runs your own config.

Full-screen coding agents draw in the terminal's alternate screen, so the terminal keeps only what is on screen now. Scrolling up, `Cmd+F` and `rex capture` never see the earlier conversation. rex-history reads it from the agent's own transcript instead:

| Agent | Transcript it reads | How the pane is matched |
|---|---|---|
| Claude Code | `~/.claude/projects/*/<session>.jsonl` | `~/.claude/sessions/<pid>.json` names the session |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` | thread id in the pane title, else the newest rollout for the pane's cwd |
| pi | `~/.pi/agent/sessions/<cwd>/*.jsonl` | session name in the pane title, else the newest session for the cwd |
| agy (Antigravity CLI) | `~/.gemini/antigravity-cli/brain/<id>/…/transcript.jsonl` | the conversation id in the log file the process holds open |

Any other pane, such as a shell, shows its scrollback (`rex capture --unwrap`), with soft-wrapped lines joined so copied text has no stray line breaks.

The transcript renders as Markdown: your messages and the agent's replies stay open, while tool calls, tool results and thinking start folded.

| Key | Action |
|---|---|
| `Cmd+Shift+C` | Open the history of the focused pane |
| `zR` / `zM` / `za` | Open all / close all / toggle folds |
| `v` … `Enter` | Copy the selection to the clipboard and close |
| `q` | Close |

Everything else is your Neovim: search, motions, `y`, your plugins.

## Requirements

- macOS. Tested with Rex server API revision 10 and Neovim 0.12.6. Linux and other versions have not been tested.
- `nvim` on your login shell's `PATH`, or set the `nvim` option.
- `lsof`, which macOS ships, for agy.

Agent versions tested: Claude Code 2.1.318, Codex 0.166.0, pi 1.4.0, agy 1.5.0.

## Install

With Homebrew:

```sh
brew install est7/tap/rex-history
```

Then add the line `brew info rex-history` prints to your Rex `init.lua` (`~/.config/rex/init.lua` by default) and reload. On Apple Silicon it is:

```lua
dofile("/opt/homebrew/opt/rex-history/share/rex-history/init.lua").setup()
```

```sh
rex config check && rex config reload
```

Without Homebrew, clone this repository anywhere and `dofile` its `init.lua` by absolute path. Keep `init.lua`, `view.lua` and `transcripts.lua` together; they find each other relative to their own location.

## Configuration

All options are optional. These are the defaults:

```lua
dofile(".../rex-history/init.lua").setup({
  key = "cmd+shift+c",                -- Rex shortcut; false to bind "history_view" yourself
  nvim = "nvim",                      -- command or absolute path
  bounds = { 0.05, 0.05, 0.9, 0.9 },  -- floating layer: x, y, width, height
})
```

`setup` registers the `history_view` action, which is also in the command palette and runs with `rex do history_view`.

The layer starts Neovim through your login shell's environment rather than the Rex server's, so plugins that shell out (input-method switchers, `rg`, …) find their tools.

## Limitations

- The transcript formats are private to each agent and change between releases. Records rex-history does not recognize show up as folded `### ? <kind>` JSON sections instead of failing, but a format change can still hide content until rex-history is updated.
- The view is a snapshot taken when it opens.
- agy truncates very large fields in its own transcript, so some tool output is incomplete there.
- Claude Code subagent (sidechain) records are not shown.
- The buffer uses a private filetype with Vim's regex Markdown syntax, not `filetype=markdown`. With a full LazyVim Markdown setup (treesitter, render-markdown, ftplugins), a 20,000-line transcript took over a minute to open; this way a 170,000-line one opens in about a second.

## Tests

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua   # unit: rendering and resolution, synthetic fixtures
tests/integration.sh                               # needs a running local Rex server
```

The integration test creates and kills its own session; it does not select it in the app or reload your config.

## Uninstall

Remove the `dofile(...).setup()` line from your Rex `init.lua`, reload the config, then `brew uninstall rex-history` (or delete the checkout).

## License

[MIT](LICENSE)
