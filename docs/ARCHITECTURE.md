# Architecture

## How Eden talks to agents

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

## Models

Anthropic models start from a built-in list in `Models.swift`, corrected by the model list Claude Code reports in its `initialize` reply (reasoning levels, Fast mode, the 1M window), which Eden saves for the next launch. OpenAI models come from Codex's own cache (`~/.codex/models_cache.json`), including their reasoning levels, service tiers, and context windows. Cursor's models come from `cursor-agent models`, which lists every reasoning level and speed as its own model ("claude-opus-5-5-high-fast"); Eden folds them back into one model with Reasoning and Fast Mode options and picks the matching line when it runs. Grok's come from its cache (`~/.grok/models_cache.json`), and OpenCode's from `opencode models --verbose`, with each model's reasoning variants and context limit, labeled by the provider serving it. Cursor's and OpenCode's lists are saved in `Models/` next to the sessions and refreshed in the background at launch. New models appear without an Eden update; older generations sit under Legacy Models. Stars in the model picker keep favorites in their own tab.

## Layout

```
App/                       the app: Package.swift, sources, tests, packaging
  Sources/Eden/
    App/                   entry point and --smoke mode, scenes and commands, AppModel
    Models/                sessions (AgentThread), models and their lists, saving, changes
    Services/              the engines (Claude Code, Codex, ACP, Cursor), event parsing,
                           slash commands, providers, MCP, notifications, dictation, terminals
    Support/               settings keys, themes, color scheme
    Views/                 SwiftUI views
  Tests/EdenTests/         model lists, transcript grouping, agent events
  Packaging/               AppIcon.icns
Packages/
  AgentKit/                processes speaking JSON lines (stream-json, JSON-RPC for Codex
                           and ACP), the login-shell PATH, this Mac or an SSH host, git
  EdenRendering/           Markdown blocks and SVG brand marks
Config/Info.plist          the app's Info.plist; the bundle script sets its ID and name
Brand/Icons/               the app icon
docs/                      architecture, development, testing, third-party notices
script/                    bundle.swift and make_icon.swift (build tooling, in Swift)
Eden.xcworkspace           opens the app and both packages in Xcode
```

The packages have no UI and no app state, so they build and test on their own. The app depends on both.

Layout rules learned the hard way (details in `AGENTS.md`): both split-view columns have a fixed minimum width and height, the window's minimum exceeds their sum, panels inside the detail column size themselves from it (no SwiftUI `.inspector`), and toolbar items never appear or disappear with state. Breaking any of these sends AppKit into an update-constraints loop that widens or clips the window and then aborts.
