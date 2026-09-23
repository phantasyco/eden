# Testing

Each package has its own tests, written with Swift Testing. They're fast and offline: no agent runs, no network, no UI.

```sh
swift test --package-path Packages/AgentKit       # SSH command lines, git detection, JSON-lines processes
swift test --package-path Packages/EdenRendering  # the Markdown parser, SVG paths
swift test --package-path App                     # model lists, transcript grouping, agent events
```

CI runs all three on every push and pull request (`.github/workflows/ci.yml`).

## What the tests don't cover

Anything that needs a real agent, a signed-in CLI, or a window on screen. For those:

- The smoke test runs real turns without the UI (see [DEVELOPMENT.md](DEVELOPMENT.md)). Use a cheap model.
- UI changes get checked in a running Eden Dev, next to the Eden you use.

Agent turns spend real credits, so none of that runs in CI.
