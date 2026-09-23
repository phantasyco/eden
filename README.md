# Eden

A native macOS workbench for coding agents, by PhantasyCo. Open any folder as a project, pick a model, and Eden runs it right in the folder, or, in a git repository, in a worktree of its own so agents work side by side without touching your checkout or each other. Anthropic models run through Claude Code, OpenAI's through Codex, and xAI's through Grok; Cursor and OpenCode each serve many companies' models, so they get picker tabs of their own. Otherwise the UI shows model names, not CLIs. All Swift, no web views.

## Requirements

- macOS 26 or later (the UI uses Liquid Glass)
- Xcode 26 / Swift 6.2
- At least one agent installed and signed in: `claude` (Claude Code), `codex` (Codex CLI), `cursor-agent` (Cursor CLI), `grok` (Grok CLI), or `opencode` (OpenCode). Eden finds them on your login shell's PATH.

## Build and run

```sh
./scripts/bundle.sh --install   # build and install /Applications/Eden.app, the Eden you use
./scripts/bundle.sh             # build/Eden.app as "Eden Dev", for trying changes
open -n build/Eden.app          # run Eden Dev next to your Eden
```

Eden Dev has its own bundle ID (`com.phantasyco.eden.dev`), so it keeps its own settings and sessions and never stands in for the installed app when you open "Eden". Worktree builds made by agents building Eden are Eden Dev builds too. For quick iteration, `swift run Eden` runs the bare binary without the bundle.

## Using it

1. Pick where the session works with the chips above the prompt card: the machine (This Mac, or a host you reach over SSH), then the project, the folder your code lives in (⌘O adds one). **Don't Work in a Project** gives the session an empty folder of its own in Eden's storage (`Scratch/`), never your home folder; those sessions sit under **No Project** in the sidebar, and deleting one moves its folder to the Trash.
2. Describe a change in the prompt card. The model chip sets the model (it decides which CLI runs) and, inside it, reasoning, the context window (200K or 1M on models that offer it), and Fast mode. The access chip sets what the agent may do without asking. Under the card, choose your current checkout (the default, changeable in Settings) or a new worktree and the branch it starts from. Type `/` for commands. The **+** button attaches files (or drop them on the composer), starts the message with a skill, and lists the agent's MCP servers. The microphone beside Send dictates: what you say appears in the message as you speak, over a live waveform, using the Mac's own speech recognition (on device when the Mac supports it). Stop keeps it after a moment of transcribing, the X (or Escape) puts the message back as it was, and Send sends what you've said so far. Typing ends dictation.
3. Send. The session joins the sidebar under its project and streams the agent's work: text as it's written, subagents as cards, and a status line with what the agent is doing and for how long. Runs of steps fold into one line ("Thought 2 times · ran 2 commands · called 1 tool") that opens into a tree: each command, file, search, or MCP call with its output, and the model's thoughts (Codex's reasoning summaries, Claude's thinking, the others' thought streams). The run the agent is on stays open. Under each of the agent's replies: **Copy** (all its text in that turn), **Branch in New Session**, and the time; hover your own message to copy it. Your last message also has **Edit**, which turns it into a field; sending replaces it and the reply after it, and **Regenerate** under the latest reply runs it again as it is. Claude Code and Codex rewind their own conversation to the end of the turn before (into a copy, as a branch does), the other agents start over with the earlier messages as context, and files the replaced reply changed stay changed. A branch keeps the conversation up to that reply: Claude Code resumes it with `--resume-session-at <message>` and `--fork-session`, Codex forks it with `thread/fork` and `lastTurnId`, OpenCode forks its latest turn, and anything else starts a new session with the conversation so far as context. The transcript follows the newest text as it streams; scroll up and it stops (a **New Messages** pill takes you back), scroll back to the bottom and it follows again.
4. While it works, keep typing. Return sends the message into the running turn and the agent reads it at its next step (steering); **Queue** (⇧⌘Return) holds it until the turn ends instead. When the agent needs you, an approval or its questions appear at the top of the composer and in a notification.
5. Open the right-hand panel (⌥⌘B, or the toolbar's panel button). It opens on a launcher with four tools, then switches with icon tabs; each tool keeps its own state as you move between them:
   - **Changes** (⌘E): the session's diff, file by file, with a commit bar. Long files show their first 2,000 lines.
   - **Files** (⌘P): the project's files as git sees them, in a tree with search, and a viewer that renders Markdown (or shows its source), copies, and opens files in other apps.
   - **Terminal** (⌘J): shells in the session's folder; ⌘D adds another.
   - **Browser** (⇧⌘B): a WebKit page for your dev server, any site, or a local HTML file (type a path like `~/site/index.html`), with Back, Forward, Reload, and an address field. It starts blank. A local address that won't load says to start the dev server, and Reload tries that address again.

   Drag the panel's edge to resize it (double-click for the automatic width), or expand it over the session (⇧⌘E). Subagents you open get their own tabs.

The sidebar button sits beside the window buttons whether the sidebar is open or closed. The selected session is filled with the accent color, like the list in Notes. Settings > Appearance > Glass sets how solid the composer, the pills under it, and the slash menu are, from pure glass to opaque. The sidebar lists projects with their sessions underneath, pinned sessions above them, and archived ones folded away at the bottom. Hover a session to pin or archive it, or a project for its menu and **+** (a new session there; it appears in the sidebar once you send). The filter button sorts sessions and turns previews on or off. A session's context menu also marks it unread, opens it in a new window, forks it (a copy of the conversation that goes its own way), renames it, and copies its session ID.

Sessions are saved as you go (one JSON file each in `~/Library/Application Support/Eden/Threads`, or `Eden Dev/Threads` for dev builds) and come back after a relaunch with their transcripts, settings, queued messages, and agent sessions, so a follow-up continues the same Claude Code or Codex conversation. A turn that was running when Eden quit comes back stopped; quitting also stops every agent and shell.

The composer's footer shows where the agent works and how full its context is: a ring with a percentage, amber from 75% and red from 90%.

### Comparing models

In a new session's model picker, **Compare Models** lets you check more models. Sending starts one session per model with the same prompt, each in its own worktree, so you can read their approaches and diffs side by side. The chip reads "Opus 5.5 + 2".

### Projects on other machines

**Add Project on Another Machine** (in the sidebar's add menu and the File menu) takes a host from your SSH config and a folder on it. Eden then runs that project's agents, git, and terminal on the machine over SSH, with your own SSH config and keys: `ssh -T -o BatchMode=yes <host> 'exec "$SHELL" -lc "cd <folder> && exec claude …"'`, so the machine's login PATH finds `claude`, `codex`, and `git`. Connections to a host are shared (`ControlMaster`), so a diff refresh after each step doesn't pay for a new handshake, and BatchMode means Eden fails with SSH's own message instead of hanging on a password prompt. The machine needs Claude Code or Codex installed and signed in there. Remote projects show as "name @ host" and work in their checkout; new worktrees and attachments are this Mac's for now.

Settings has three tabs: **General** (defaults for new sessions, notifications, the menu bar extra), **Appearance** (light or dark, an accent theme, and diff colors), and **Providers** (each CLI's version and sign-in, and which models the pickers show).

### Shortcuts

| Keys | Action |
|---|---|
| ⌘N | New session |
| ⌘O | Add project |
| ⌘B | Show or hide the sidebar |
| ⌘F | Search sessions |
| ⌥⌘B | Show or hide the panel |
| ⌘E | Changes |
| ⌘P | Files |
| ⌘J | Terminal |
| ⇧⌘B | Browser |
| ⌘D | New terminal |
| ⇧⌘E | Expand or restore the panel |
| ⌘[ / ⌘] | Back / forward through what you've viewed |
| ⌘1 to ⌘9 | Jump to a session |
| ⌘⇧[ / ⌘⇧] | Previous / next session |
| ⌘. | Stop the agent |
| Return | Send, or steer while the agent works (Option-Return for a new line) |
| ⇧⌘Return | Queue for after the current turn |
| 1 to 9 | Pick an answer when the agent asks a question |
| / | Slash commands |

### Slash commands

Type `/` in either composer. Up and Down move through the menu, Return runs the selected command, Tab fills in its name so you can add an argument, and Escape closes the menu.

| Command | What it does |
|---|---|
| `/model <model>` | Switch models. In a session, only models from the same provider, because a session can't change CLIs. |
| `/effort <level>` | Set reasoning effort. Alias `/reasoning`. |
| `/fast` | Turn Fast mode (or a faster service tier) on or off, on models that have one. |
| `/access <mode>` | Set the access mode. Alias `/permissions`. |
| `/new` | Start a new session. |
| `/clear` | Start a fresh agent session in the same folder. The changes stay. Alias `/reset`. |
| `/changes` | Show or hide Changes. Alias `/diff`. |
| `/commit <message>` | Commit all changes in the session's folder. |
| `/rename <title>` | Rename the session. |
| `/stop` | Stop the agent while it works. |

Anthropic models also list Claude Code's own commands and skills: `/compact`, `/context`, `/code-review`, your plugins, and the project's skills. Eden gets them with the same `initialize` request the Agent SDK sends, which Claude Code answers without calling a model or saving a session. They go to the agent exactly as typed. When a name collides, Eden's command wins, because Eden owns the model, effort, and session.

### Access modes

| Mode | Claude Code | Codex |
|---|---|---|
| Supervised | `--permission-mode default`: asks before edits and commands | approval policy `untrusted`, workspace-write sandbox |
| Auto-accept Edits | `--permission-mode acceptEdits`: asks before anything else | `on-request`, workspace-write sandbox |
| Auto | `--permission-mode auto` | `on-request`, with Codex's `auto_review` reviewer answering |
| Full Access | `--dangerously-skip-permissions` | `never`, no sandbox |

The other agents offer the modes they can honor, and the access chip lists only those:

| Mode | Cursor | Grok and OpenCode |
|---|---|---|
| Supervised | not offered: Cursor runs headless and can't stop to ask | Eden asks you about each approval the agent sends, except reads and searches |
| Auto-accept Edits | no flag: edits freely, runs only the commands your Cursor allowlist permits | Eden also approves edits |
| Auto | `--auto-review`: Cursor's reviewer decides | not offered: no reviewer of their own |
| Full Access | `--force` | Eden approves everything; Grok also gets `--always-approve` |

Grok and OpenCode decide themselves whether to ask. Grok's `permission_mode = "always-approve"` in `~/.grok/config.toml`, for example, means it never sends Eden an approval, whatever the chip says.

Whatever the mode, the agent's questions (Claude Code's AskUserQuestion, Codex's request for input) come to you.

## How it talks to agents

Eden spawns the official CLIs and lets them handle their own sign-in. It never reads or reuses their tokens. Each session keeps one agent process running between turns, so steering, approvals, questions, and Stop all go over the same pipe.

- **Claude Code:** `claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --forward-subagent-text --permission-prompt-tool stdio`, with `--model <id>[1m]`, `--effort`, `--settings '{"fastMode":true}'`, and `--resume <session>` as needed. Messages go in as JSON lines; permission prompts and AskUserQuestion come back as `can_use_tool` control requests; Stop sends an `interrupt` control request. A change of model, reasoning, or access starts a new process that resumes the session. Headless runs draw from your plan's Agent SDK credit.
- **Grok and OpenCode:** the Agent Client Protocol (ACP), JSON-RPC over stdio, from `grok agent stdio` and `opencode acp`. Eden sends `initialize`, then `session/new`, or `session/resume` (`session/load`, with the replay ignored, where resume isn't offered, and `session/fork` for OpenCode forks). Each message is a `session/prompt` request, and the turn ends when it returns. The model and reasoning are session options set with `session/set_config_option` before each turn: the model first, since a model's reasoning levels only appear once it's chosen. Text, tool calls, plans, and (OpenCode) context and cost arrive as `session/update` notifications; approvals as `session/request_permission`; Stop is `session/cancel`. Grok's own `_x.ai/session_notification` adds its retries (its free tier rate-limits) and each turn's cost. Messages sent mid-turn wait in the queue.
- **Cursor:** one headless run per turn, `cursor-agent -p --output-format stream-json --stream-partial-output --trust --workspace <folder>`, with `--model`, `--resume <chat>`, and the access flag. Text streams as `assistant` events and arrives again whole, which replaces what streamed; tool calls come as `tool_call` started and completed events. Stop ends the run. Messages sent mid-turn wait in the queue.
- **Codex:** `codex app-server`, JSON-RPC over stdio. Eden sends `initialize`, starts, resumes, or forks the Codex thread, then `turn/start` for each message with the model, effort, service tier, approval policy, and sandbox. Messages sent mid-turn go in with `turn/steer`, Stop is `turn/interrupt`, and approvals and questions arrive as Codex's own requests. `thread/tokenUsage/updated` feeds the context ring.

An idle agent process ends after half an hour; the next message resumes its session. Eden reads each process's output with readability handlers rather than `FileHandle.bytes`, which held short replies in its buffer until the process ended.

Any folder can be a project. In a git repository, a session can work in a worktree of its own, and the Changes tab shows its diff; worktrees live in `~/Library/Application Support/Eden/worktrees/<project>/<session>` on branches named `eden/<session>`, and a project inside a bigger repository works in the same folder of the worktree. Without git, sessions work right in the folder, the Changes tab says the folder isn't tracked, and the Files tab lists the folder itself (hidden files and dependency folders left out).

Attached files are copied into `.eden/attachments` in the session's folder, where the agent can read them without asking, and the message lists their paths. Codex also gets images as `localImage` input. Eden adds `/.eden/` to the repository's `.git/info/exclude`, so attachments never show up in the diff.

Settings > Providers and the **+** menu ask the CLIs themselves: Claude Code's account and model list come from the same `initialize` reply the slash menu uses, Codex's sign-in from `codex login status`, Cursor's from `cursor-agent status`, Grok's from `grok models`, OpenCode's from `opencode auth list` (how many providers it has keys for), and MCP servers from Claude Code's and Codex's `mcp list` (and `mcp add` to add one).

Notifications (a finished, failed, or waiting session you aren't looking at) are regular macOS notifications: Focus and System Settings decide how they appear, and clicking one opens the session.

## Development

Headless smoke test, no UI:

```sh
swift build
.build/debug/Eden --smoke <repo> <model id or name> "first prompt" ["follow-up" ...]
```

It creates a worktree, runs each prompt as a turn, and prints the transcript, session, cost, and final diff.

Launch arguments open a project and optionally start a session: `Eden --repo <path> [--model <id or name>] [--prompt <text> | --idle-thread] [--changes]`. `--idle-thread` opens an empty session and `--changes` opens the Changes panel, for layout tests. Add `-hasSeenWelcome YES` to skip the welcome sheet for one launch, and `-EdenOpenPicker Model|Reasoning|Access|Repository` to open that picker at launch for screenshots.

### Models

Anthropic models start from a built-in list in `Models.swift`, corrected by the model list Claude Code reports in its `initialize` reply (reasoning levels, Fast mode, the 1M window), which Eden saves for the next launch. OpenAI models come from Codex's own cache (`~/.codex/models_cache.json`), including their reasoning levels, service tiers, and context windows. Cursor's models come from `cursor-agent models`, which lists every reasoning level and speed as its own model ("claude-opus-5-5-high-fast"); Eden folds them back into one model with Reasoning and Fast Mode options and picks the matching line when it runs. Grok's come from its cache (`~/.grok/models_cache.json`), and OpenCode's from `opencode models --verbose`, with each model's reasoning variants and context limit, labeled by the provider serving it. Cursor's and OpenCode's lists are saved in `Models/` next to the sessions and refreshed in the background at launch. New models appear without an Eden update; older generations sit under Legacy Models. Stars in the model picker keep favorites in their own tab.

### Layout

```
Sources/Eden/
  Main.swift          entry point and --smoke mode
  EdenApp.swift       scenes (main window, session windows), commands, menu bar extra
  AppModel.swift      projects, sessions, selection, the panel, the new-session draft
  AgentThread.swift   one session: folder, queue, turn lifecycle, Claude Code's command line
  AgentProcess.swift  a CLI speaking JSON lines; ClaudeSession on top of it
  ClaudeEngine.swift  Claude Code turns, streaming, approvals and questions (shared by all)
  RPCProcess.swift    JSON-RPC over the pipe: CodexSession and ACPSession
  CodexEngine.swift   Codex turns, steering, events, approvals
  ACPEngine.swift     Grok and OpenCode over the Agent Client Protocol
  CursorEngine.swift  Cursor's headless runs and their events
  AgentModels.swift   Cursor's, Grok's, and OpenCode's model lists
  Events.swift        Claude Code event parsing
  SlashCommands.swift Eden's slash commands, the menu's rows, Claude Code's command list
  ThreadStore.swift   saving and restoring sessions
  Notifications.swift macOS notifications for sessions
  Terminals.swift     the terminal's shells (SwiftTerm)
  Providers.swift     each CLI's version and sign-in, for Settings
  Appearance.swift    settings keys, themes, color scheme, diff colors
  AgentRunner.swift   one-shot CLI runs (Claude Code's initialize)
  MCP.swift           each CLI's MCP servers
  Machine.swift       this Mac or an SSH host: command lines for running there
  Git.swift, Shell.swift
  Views/              SwiftUI views
scripts/              bundle.sh, make-icon.swift (build tooling only)
```

Layout rules learned the hard way (details in `AGENTS.md`): both split-view columns have a fixed minimum width and height, the window's minimum exceeds their sum, panels inside the detail column size themselves from it (no SwiftUI `.inspector`), and toolbar items never appear or disappear with state. Breaking any of these sends AppKit into an update-constraints loop that widens or clips the window and then aborts.

## Building Eden with Eden

Add this repo in Eden, start a session with Auto or Full Access (or approve the build commands as they come up), and ask for a change. The agent works in its own worktree, and `AGENTS.md` tells it how to build and test. Open the result with `open -n <worktree>/build/Eden.app` to try it next to your running copy, then commit and merge the branch. Worktrees branch from HEAD, so the repo needs at least one commit.

## Not built yet

- No pull requests (T3 Code has them), and no tiled sessions.
- No Codex commands in the slash menu yet (`skills/list` could back them).
- Cursor, Grok, and OpenCode: messages sent mid-turn wait for the turn to end; no subagent cards, slash-menu skills, or MCP list for them yet.
- The **+** menu as a searchable panel over the composer, with sections: files and folders, plan mode, plugins and skills, earlier sessions to attach.
- On other machines: no new worktrees, attachments, slash-menu skills, or MCP list yet.

## Credits

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) draws the terminal.
- Provider and CLI logos come from [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT). The marks belong to Anthropic and OpenAI; Eden uses them only to label their models and tools.
