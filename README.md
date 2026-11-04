# rex-history

Press `Cmd+Shift+C` in any [Rex](https://www.superlogical.com/rex) pane to read its full history in a floating Neovim that runs your own config. In a Claude Code, Codex, pi or agy pane, the view shows the agent's whole conversation, including what scrolled away long ago.

## What it is

A small Rex extension: one Rex action (`history_view`), bound to `Cmd+Shift+C`, that opens a floating layer over the current tab. The layer runs your `nvim` on a read-only scratch buffer holding one of these:

- **In an agent pane:** the agent's conversation rendered as Markdown. Your messages and the agent's replies are open. Tool calls (`### ▸ Bash`), tool results (`### ◂ Bash`) and thinking start folded.
- **In any other pane** (a shell, a log tail, a REPL): the pane's scrollback. Lines the terminal soft-wrapped are joined again, so copied text has no stray line breaks.

It is a snapshot of the moment you open it; press `R` in the view to pick up newer output.

## Why

Full-screen TUI agents draw in the terminal's alternate screen. The terminal then keeps only the current screen. Scrolling up, `Cmd+F` and `rex capture` never see the earlier conversation, and each agent's in-app scrolling and search work differently. Every one of them writes a complete transcript to disk, so rex-history reads that instead. You get one viewer, with the keys you already know, for every agent.

## Which agents

| Agent | Versions tested | Transcript it reads |
|---|---|---|
| Claude Code | 2.1.318 | `~/.claude/projects/*/<session>.jsonl` |
| Codex | 0.166.0 | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| pi | 1.4.0 | `~/.pi/agent/sessions/<cwd>/*.jsonl` |
| agy (Antigravity CLI) | 1.5.0 | `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl` |

Agents are recognized by the pane's foreground process (`claude`, `codex`, `agy`, and `node` started as `pi`). Any other program gets the scrollback view.

## How to install

Requirements: macOS, Rex (tested with server API revision 10), Neovim 0.12 (tested with 0.12.6). agy support also uses `lsof`, which macOS ships.

```sh
brew install est7/tap/rex-history
```

Add the line that `brew info rex-history` prints to your Rex config (`~/.config/rex/init.lua` by default). On Apple Silicon it is:

```lua
dofile("/opt/homebrew/opt/rex-history/share/rex-history/init.lua").setup()
```

Then check and reload the config:

```sh
rex config check && rex config reload
```

Without Homebrew: clone this repository and `dofile` its `init.lua` by absolute path. Keep `init.lua`, `view.lua` and `transcripts.lua` together, because they find each other relative to their own location.

To upgrade, run `brew upgrade rex-history`, then `rex config reload`. To uninstall, remove the `dofile` line, reload, then `brew uninstall rex-history`.

## How to use

1. Focus a pane and press `Cmd+Shift+C`. You can also pick **History View** from the command palette, or run `rex do history_view`.
2. Read and search it as you would any Neovim buffer. The cursor starts at the end, which is the latest output.
3. If the agent is still working, press `R` to re-read its transcript. New output appears at the end; the cursor, the scroll position and the folds you opened stay where they were. A record the agent is still writing shows up on the next `R`.
4. Copy what you need, then close.

| Key | Action |
|---|---|
| `]]` / `[[` | Next / previous turn (your messages); a count such as `3]]` skips turns |
| `R` | Reload: re-read the transcript (or scrollback), keeping the cursor and open folds |
| `za` / `zR` / `zM` | Toggle the fold under the cursor / open all / close all |
| `/` `n` `N`, `gg` `G`, … | Search and move as usual |
| `v` / `V`, then `Enter` | Copy the selection to the system clipboard and close |
| `y` | Yank as usual (to the system clipboard if your Neovim uses `clipboard=unnamedplus`) and keep the view open |
| `q` | Close; focus returns to the pane you came from |

## How to configure

Every option is optional. These are the defaults:

```lua
dofile(".../rex-history/init.lua").setup({
  key = "cmd+shift+c",                -- Rex shortcut; false to bind "history_view" yourself
  nvim = "nvim",                      -- command or absolute path
  bounds = { 0.05, 0.05, 0.9, 0.9 },  -- floating layer: x, y, width, height (fractions of the window)
})
```

The agents' own environment variables are respected: `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `PI_CODING_AGENT_DIR`.

## How it works

```
Cmd+Shift+C
  └─ init.lua (runs in Rex)       reads the pane's foreground process (pid, name, argv0, cwd) and title,
                                  opens a floating layer: nvim -c "dofile(view.lua)"
       └─ view.lua (runs in nvim) agent pane? → transcripts.lua: resolve the file, render Markdown
                                  otherwise   → rex capture --unwrap
                                  fills a read-only buffer, sets folds and keys
```

**Finding the transcript.** `transcripts.lua` maps a pane to the agent's transcript file:

| Agent | How the pane is matched to its session |
|---|---|
| Claude Code | `~/.claude/sessions/<pid>.json` names the session ID |
| Codex | the thread ID in the pane title, if your Codex terminal title includes it; otherwise the newest rollout whose `session_meta.cwd` matches the pane |
| pi | the session name in the pane title; otherwise the newest session file for the pane's cwd |
| agy | the conversation ID in the log file the process holds open, among the `brain/<id>` directories it holds open (via `lsof`) |

If no transcript is found, the view falls back to the scrollback and says why.

**Rendering.** Each agent has a small renderer that turns its records into Markdown. Harness context is left out, such as system prompts, `AGENTS.md` injections and `<system-reminder>` blocks. For pi, which stores conversations as a tree, only the current branch is shown. Code fences are made longer than any backtick run inside them, so Markdown in tool output cannot break the layout. Records of a kind the renderer does not know show up as folded `### ? <kind>` JSON, so new formats degrade rather than vanish.

**Performance.** The buffer uses a private filetype (`rexhistory`) with Vim's regex Markdown syntax, not `filetype=markdown`. With a full LazyVim Markdown setup (treesitter, render-markdown, ftplugins), a 20,000-line transcript took over a minute to open. This way a 170,000-line transcript (a 206 MB session file) opens in about a second, and searching or jumping through it stays instant.

**Environment.** The layer starts Neovim through your login shell's environment rather than the Rex server's, so plugins that run other programs (input-method switchers, `rg`, …) can find them on `PATH`.

## Limitations

- Transcript formats are private to each agent and change between releases. A format change can hide content until rex-history is updated.
- agy truncates very large fields in its own transcript, so some tool output is incomplete there.
- Claude Code subagent (sidechain) records are not shown.
- Only macOS has been tested.

## How to test

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua   # unit tests: rendering and resolution on synthetic fixtures
tests/integration.sh                               # needs a running local Rex server
```

The integration test creates and kills its own Rex session. It does not select that session in the app or reload your config. The fixtures are synthetic: never add real transcripts, because they contain private conversations.

## License

[MIT](LICENSE)
