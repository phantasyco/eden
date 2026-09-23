# Using Eden

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

The sidebar button sits beside the window buttons whether the sidebar is open or closed. The selected session is filled with the accent color, like the list in Notes. The sidebar lists projects with their sessions underneath, pinned sessions above them, and archived ones folded away at the bottom. Hover a session to pin or archive it, or a project for its menu and **+** (a new session there; it appears in the sidebar once you send). The filter button sorts sessions and turns previews on or off. A session's context menu also marks it unread, opens it in a new window, forks it (a copy of the conversation that goes its own way), renames it, and copies its session ID.

Sessions are saved as you go (one JSON file each in `~/Library/Application Support/Eden/Threads`, or `Eden Dev/Threads` for dev builds) and come back after a relaunch with their transcripts, settings, queued messages, and agent sessions, so a follow-up continues the same Claude Code or Codex conversation. A turn that was running when Eden quit comes back stopped; quitting also stops every agent and shell.

The composer's footer shows where the agent works and how full its context is: a ring with a percentage, amber from 75% and red from 90%.

## Comparing models

In a new session's model picker, **Compare Models** lets you check more models. Sending starts one session per model with the same prompt, each in its own worktree, so you can read their approaches and diffs side by side. The chip reads "Opus 5.5 + 2".

## Projects on other machines

**Add Project on Another Machine** (in the sidebar's add menu and the File menu) takes a host from your SSH config and a folder on it. Eden then runs that project's agents, git, and terminal on the machine over SSH, with your own SSH config and keys: `ssh -T -o BatchMode=yes <host> 'exec "$SHELL" -lc "cd <folder> && exec claude …"'`, so the machine's login PATH finds `claude`, `codex`, and `git`. Connections to a host are shared (`ControlMaster`), so a diff refresh after each step doesn't pay for a new handshake, and BatchMode means Eden fails with SSH's own message instead of hanging on a password prompt. The machine needs Claude Code or Codex installed and signed in there. Remote projects show as "name @ host" and work in their checkout; new worktrees and attachments are this Mac's for now.

Settings has three tabs: **General** (defaults for new sessions, notifications, the menu bar extra), **Appearance** (light or dark, an accent theme, how much of the desktop shows through the window, the terminal's background, and diff colors), and **Providers** (each CLI's version and sign-in, and which models the pickers show).

## Shortcuts

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

## Slash commands

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

## Access modes

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

## Not built yet

- No pull requests (T3 Code has them), and no tiled sessions.
- No Codex commands in the slash menu yet (`skills/list` could back them).
- Cursor, Grok, and OpenCode: messages sent mid-turn wait for the turn to end; no subagent cards, slash-menu skills, or MCP list for them yet.
- The **+** menu as a searchable panel over the composer, with sections: files and folders, plan mode, plugins and skills, earlier sessions to attach.
- On other machines: no new worktrees, attachments, slash-menu skills, or MCP list yet.
