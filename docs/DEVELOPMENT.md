# Development

## Build and run

```sh
swift script/bundle.swift --install   # build and install /Applications/Eden.app, the Eden you use
swift script/bundle.swift             # build/Eden.app as "Eden Dev", for trying changes
open -n build/Eden.app                # run Eden Dev next to your Eden
swift run --package-path App Eden     # the bare binary, without the app bundle
```

Eden Dev has its own bundle ID (`com.phantasyco.eden.dev`), so it keeps its own settings and sessions and never stands in for the installed app when you open "Eden". Worktree builds made by agents building Eden are Eden Dev builds too.

Open `Eden.xcworkspace` in Xcode to work on the app and both packages together.

## Smoke test

Headless smoke test, no UI:

```sh
swift build --package-path App
App/.build/debug/Eden --smoke <repo> <model id or name> "first prompt" ["follow-up" ...]
```

It creates a worktree, runs each prompt as a turn, and prints the transcript, session, cost, and final diff.

Launch arguments open a project and optionally start a session: `Eden --repo <path> [--model <id or name>] [--prompt <text> | --idle-thread] [--changes]`. `--idle-thread` opens an empty session and `--changes` opens the Changes panel, for layout tests. Add `-hasSeenWelcome YES` to skip the welcome sheet for one launch, and `-EdenOpenPicker Model|Reasoning|Access|Repository` to open that picker at launch for screenshots.

## Building Eden with Eden

Add this repo in Eden, start a session with Auto or Full Access (or approve the build commands as they come up), and ask for a change. The agent works in its own worktree, and `AGENTS.md` tells it how to build and test. Open the result with `swift script/bundle.swift` in the worktree, then `open -n <worktree>/build/Eden.app`, to try it next to your running copy, then commit and merge the branch. Worktrees branch from HEAD, so the repo needs at least one commit.
