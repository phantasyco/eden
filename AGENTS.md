# Working on Eden

Eden is a native macOS app (SwiftUI, macOS 26+) that runs coding agents in your projects (any folder; in a git repository, a session can also get its own worktree and diff). Read `README.md` for what it does, `docs/ARCHITECTURE.md` for how it talks to agents and how the code is laid out (the app in `App/`, UI-free code in `Packages/AgentKit` and `Packages/EdenRendering`), and `docs/USING.md` for how it behaves.

## Rules

- **Swift only.** No Rust, no web views for Eden's own interface, no JavaScript. Build tooling is Swift too (`script/bundle.swift`, `script/make_icon.swift`); the only non-Swift files are configs, like the CI workflow. (The Browser tab is the one WebKit view: it shows the user's own pages, like a dev server, not Eden's UI.) Dependencies must be Swift packages too; the one Eden uses is SwiftTerm, for the terminal.
- **Follow Apple's design.** PhantasyCo makes native Apple apps, so Eden should look and behave like Apple made it: the [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), system controls, SF Symbols, and semantic fonts. Color accents with `.tint`, never a fixed color: the accent is the theme chosen in Settings (Eden green by default), and sidebar icons get the theme's color on the image itself (`.foregroundStyle(theme.color)`): `.listItemTint` left project folders in the system blue. Provider logos come from `BrandIcon`, and one-color marks draw as vector shapes (`SVGShape`), never bitmaps shrunk to size: a 24-point SVG rasterized and scaled down to 14 blurs thin strokes like OpenAI's knot. When in doubt, match Apple's own macOS apps (Messages, Mail, Image Playground, Help).
- **Use Liquid Glass the way Apple does** (WWDC25 sessions 219, 356, 310):
  - Glass is for the floating control layer only (toolbar, composer, popovers), never for content like the transcript or diffs.
  - Never glass on glass. Controls sitting on a glass surface use fills and vibrancy, not their own glass. Nearby glass shapes share one `GlassEffectContainer`.
  - Tint only the primary action (Send). Everything else stays neutral; put color in the content layer instead.
  - Shapes are concentric: a nested corner radius is the parent's radius minus the padding (`ConcentricRectangle`). On the Mac, small and medium controls are rounded rectangles; capsules are for large, standout controls.
  - Floating bars over scrolling content use `safeAreaBar`, so the scroll edge effect appears. One scroll edge effect per view.
  - Menus and context menus get SF Symbols for their key actions, one icon per group of related items.
- **Name models, not CLIs.** The UI shows model names (Opus 5.5, GPT-6-Astra). Which CLI runs a model is an implementation detail: Anthropic models run through Claude Code, OpenAI's through Codex, xAI's through Grok. Cursor and OpenCode serve many companies' models, so they're providers of their own in the picker's tabs. The one other exception is Settings > Providers, which names the CLIs because that's what you install and sign in to.
- **Keep split-view columns stable.** Both columns (sidebar and detail) have a fixed minimum width *and* height via `.frame(minWidth:…, minHeight:…)`, and the window's minimum stays above their sum. If a column's minimum follows its content (text wrapping, a field growing, controls wrapping), AppKit re-lays out mid-pass and aborts with an update-constraints exception. Content inside must wrap or truncate to fit instead of overflowing. The right-hand panel (Changes, Terminal, subagents) gets its width from the detail column's own size through a GeometryReader. Never use SwiftUI's `.inspector`: it adds a third split-view column, and opening it crashed Eden this way.
- **Keep toolbars constant.** Don't add or remove toolbar items as state changes, and don't change their labels, icons, or tooltips with state that toggles often (the sidebar, the panel): any change to toolbar content makes AppKit redraw every item. Say both states in one label ("Show or hide the panel") and leave Show/Hide wording to the menu bar. The sidebar button is a title-bar accessory (`SidebarButton`), not a toolbar item, so it stays beside the window buttons as the sidebar opens and closes.
- **Never resize a scroll view under the toolbar.** In macOS 26 the glass toolbar tracks the scroll view beneath it; when that scroll view's width or safe-area insets change (a panel opening beside it), every toolbar button redraws, a visible one-frame flash. The right-hand panel therefore slides over the session, and scrolling content keeps clear of it with `.contentMargins(.trailing, panelInset, for: .scrollContent)`; non-scrolling bits (the composer) use padding. The flash probe in the scratch harness measured this: resizing flashed on every toggle, margins never did. Two more rules from the same probe: the margin changes in one step, never animated (the transcript's `LazyVStack` re-estimated off-screen rows on every frame of an animated margin and jumped under the toolbar; a plain `VStack` fixed that but dropped to 20fps on a long session), and the panel is always mounted and slides by offset, so a second click mid-slide turns it around from where it is.
- **Float popups, don't insert them.** Menus that appear over content (like the slash menu) are overlays hung from a zero-height anchor view, so they can't change a column's size or re-center a page. A custom `alignmentGuide` on an overlay was ignored on macOS 27; the anchor works.
- **Let the window show through.** Settings > Appearance > Window can blur the desktop in behind sessions and the panel (`WindowBackdrop`), so views there don't paint `windowBackgroundColor` behind themselves. One that has to hide something underneath (the browser's blank page) uses `WindowBackdrop(covers: true)`.
- **Read live state in event handlers.** `onSubmit` and `onKeyPress` closures can outlive the render that made them. Compute what they act on inside the handler, from the model or a binding, not from a value captured in `body`.
- **Read agent output with readability handlers.** Agent processes stay alive between turns. `FileHandle.bytes` on their pipes held short replies until the process exited, which left sessions stuck on "Thinking". `AgentProcess` reads with `readabilityHandler` and delivers lines on the main queue in order.
- **Say projects and sessions.** A project is the folder the code lives in; sessions sit under it and can be pinned or archived. (The code still calls them `Repo` and `AgentThread`.)
- **Don't assume git.** Any folder can be a project. Check `Git.isRepository` before anything that needs git (worktrees, branches, diffs, commits) and fall back to working in the folder.
- Match the surrounding code's style and comment density.

## Build and check

```sh
swift build --package-path App                    # compile; must finish with no errors
swift test --package-path App                     # and the packages' tests, if you touched them
swift script/bundle.swift                         # package build/Eden.app as "Eden Dev"
open -n build/Eden.app                            # run it next to the Eden you're using
```

Code with no UI or app state (processes, protocols, git, parsing) belongs in a package, with tests. See `docs/TESTING.md`.

Eden Dev keeps its own settings and threads, so trying a build never touches the user's real ones. Don't pass `--install`; that replaces the user's /Applications/Eden.app.

Test the agent engine without the UI:

```sh
App/.build/debug/Eden --smoke <repo> <model id> "prompt" ["follow-up"]
```

Use a cheap model for smoke tests (`claude-haiku-4-5`).
