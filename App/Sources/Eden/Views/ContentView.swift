import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Preferences.theme) private var theme = Theme.eden
    @AppStorage(Preferences.colorScheme) private var colorScheme = ColorSchemeChoice.system

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView()
                // Eden's own sidebar button (SidebarButton, beside the window
                // buttons) replaces the system's, which crossfades between two
                // spots and leaves a ghost. It has to be removed from the
                // sidebar column's view to take.
                .toolbar(removing: .sidebarToggle)
                // Constant minimum height, like the detail column (see AGENTS.md).
                .frame(minHeight: 320, maxHeight: .infinity)
                // The sidebar's edge runs the window's full height, through the
                // title bar, like Safari's. It's part of the sidebar, so it
                // slides with it when the sidebar opens or closes.
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            DetailArea()
        }
        .tint(theme.color)
        .background(SidebarButton.Installer(model: model))
        .sheet(isPresented: $model.showWelcome, onDismiss: model.finishWelcome) {
            WelcomeView()
                .tint(theme.color)
        }
        .sheet(item: $model.mcpSheetAgent) { agent in
            MCPServerSheet(agent: agent)
                .tint(theme.color)
        }
        .sheet(isPresented: $model.showRemoteProjectSheet) {
            RemoteProjectSheet()
                .tint(theme.color)
        }
        .sheet(isPresented: $model.showCloneSheet) {
            CloneSheet()
                .tint(theme.color)
        }
        // On NSApp, so Settings, menus, and sheets follow along.
        .onAppear { NSApp.appearance = colorScheme.appearance }
        .onChange(of: colorScheme) { NSApp.appearance = colorScheme.appearance }
        .task { model.handleLaunchArguments() }
        .alert("Eden", isPresented: errorShown) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }
}

/// The detail column: a session or the new-session screen, with the
/// right-hand panel (Changes, Terminal, subagents) beside it when it's open.
/// The panel is a plain side panel sized from the column's own width, not a
/// SwiftUI inspector: the inspector adds a third split-view column, and
/// opening it sent the window into an update-constraints loop and a crash.
/// Sizing from the space we have keeps the column's limits fixed (AGENTS.md).
private struct DetailArea: View {
    @Environment(AppModel.self) private var model
    /// The panel's width from dragging its edge; 0 until you do.
    @AppStorage(Preferences.panelWidth) private var storedWidth = 0.0

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let shown = model.showPanel
            let expanded = shown && model.panelExpanded
            // The panel's width whether it's showing or not, so it slides out at its size.
            let panel = expanded ? total : panelWidth(for: total)
            // The panel slides over the session's right side rather than
            // squeezing it. The session keeps its full width and moves its
            // content out of the way with margins (`panelInset`): a scroll view
            // that changed width or insets under the glass toolbar made every
            // toolbar button redraw, a visible flash, as the panel opened or
            // closed (measured frame by frame in the flash probe).
            ZStack(alignment: .trailing) {
                // Expanded, the session stays underneath (so a half-typed
                // message survives) but out of sight and out of reach. Its
                // margin changes in one step, not animated: the transcript's
                // lazy stack re-measured its rows on every frame of an animated
                // margin and jumped under the toolbar as the panel settled.
                content
                    .environment(\.panelInset, shown && !expanded ? panel : 0)
                    .frame(width: total)
                    // Nothing inside animates with the panel, even when it's
                    // opened with an animation from elsewhere.
                    .transaction(value: shown) { $0.animation = nil }
                    .transaction(value: expanded) { $0.animation = nil }
                    .opacity(expanded ? 0 : 1)
                    .animation(Self.slide, value: expanded)
                    .allowsHitTesting(!expanded)
                // Always here, and it slides by offset: an offset animation
                // turns around from wherever it is when you click again
                // mid-slide, where inserting and removing the panel snapped.
                SidePanel()
                    .frame(width: max(0, panel))
                    .overlay(alignment: .leading) {
                        if shown && !expanded {
                            PanelResizeHandle(width: $storedWidth, range: 280...max(280, total - 300))
                                .offset(x: -5)
                        }
                    }
                    .offset(x: shown ? 0 : panel + 1)
                    .animation(Self.slide, value: shown)
                    .animation(Self.slide, value: expanded)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
            // The panel's edge runs the window's full height, through the title
            // bar, like the sidebar's. It's always here and only slides: adding
            // and removing a view under the glass toolbar made every toolbar
            // button flash as the panel finished opening or closing. Closed, it
            // sits just past the window's edge.
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    .offset(x: total - (shown ? panel : 0))
                    .opacity(expanded ? 0 : 1)
                    .animation(Self.slide, value: shown)
                    .animation(Self.slide, value: expanded)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        // Under the session and the panel alike, up through the toolbar; the
        // sidebar keeps its own material.
        .background { WindowBackdrop().ignoresSafeArea() }
        .toolbar {
            // Back and Forward at the leading edge, like Finder and Safari.
            // Always there, disabled when there's nowhere to go: toolbars
            // don't add or remove items (see AGENTS.md). The sidebar button
            // isn't here: it stays beside the window buttons (SidebarButton).
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back (⌘[)")
                .disabled(!model.canGoBack)
                Button { model.goForward() } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .help("Forward (⌘])")
                .disabled(!model.canGoForward)
            }
            // Its own item, apart from the arrows' shared glass: a different
            // kind of action. There whether or not the sidebar is showing.
            ToolbarItem(placement: .navigation) {
                Button { model.newChat() } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("New Session (⌘N)")
            }
            // Always the last items, like the inspector button in Xcode and Pages:
            // Expand, then the panel itself.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if model.showPanel {
                        model.panelExpanded.toggle()
                    } else {
                        model.openPanel(.home)
                        model.panelExpanded = true
                    }
                } label: {
                    Label("Expand Panel", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Expand or restore the panel (⇧⌘E)")
                // Opens on the launcher: Changes, Files, Terminal, Browser.
                Button {
                    if model.showPanel { model.showPanel = false } else { model.openPanel(.home) }
                } label: {
                    Label("Panel", systemImage: "sidebar.trailing")
                }
                .help("Show or hide Changes, Files, Terminal, and Browser (⌥⌘B)")
            }
        }
    }

    /// How the panel slides: a spring, so a second click mid-slide turns it
    /// around from where it is, keeping its speed, instead of starting over.
    static let slide = Animation.snappy(duration: 0.25)

    /// The width you dragged it to, or about 40% of the column until you do;
    /// at least 280 points, and always leaving the session at least 300.
    private func panelWidth(for total: CGFloat) -> CGFloat {
        let preferred = storedWidth > 0 ? storedWidth : min(520, total * 0.4)
        return min(max(280, preferred), max(0, total - 300))
    }

    @ViewBuilder private var content: some View {
        if let thread = model.selectedThread {
            ThreadView(thread: thread)
                .id(thread.id)
        } else {
            NewChatView()
        }
    }
}

/// The panel's left edge: drag to resize, with the left-right cursor.
/// Double-clicking it goes back to the automatic width.
private struct PanelResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Color.clear
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = start ?? min(max(width > 0 ? width : range.lowerBound, range.lowerBound), range.upperBound)
                        start = base
                        // Dragging left widens the panel.
                        width = min(max(base - value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in start = nil }
            )
            .onTapGesture(count: 2) { width = 0 }
            .help("Drag to resize. Double-click for the automatic width.")
    }
}

extension EnvironmentValues {
    /// How much of the session's right side the panel covers. Scrolling
    /// content keeps clear of it with `.contentMargins`, not by shrinking.
    @Entry var panelInset: CGFloat = 0
}

/// The sidebar button, beside the window buttons whether the sidebar is open
/// or closed, like Mail's and Notes'. It's a title-bar accessory, not a
/// toolbar item: a toolbar item in the detail column rides the sidebar's
/// edge as it opens and closes, and the system's own button crossfades
/// between two spots and leaves a ghost. The toolbar lays out after it.
struct SidebarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.toggleSidebar() } label: {
            Label("Sidebar", systemImage: "sidebar.left")
                .labelStyle(.iconOnly)
                .font(.system(size: 15))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("Show or hide the sidebar (⌘B)")
        .padding(.leading, 6)
        .padding(.trailing, 2)
        .frame(maxHeight: .infinity)
    }

    /// Adds the button to the window's title bar once the window exists.
    struct Installer: NSViewRepresentable {
        let model: AppModel

        func makeNSView(context: Context) -> NSView { Hook(model: model) }
        func updateNSView(_ view: NSView, context: Context) {}

        final class Hook: NSView {
            private static let identifier = NSUserInterfaceItemIdentifier("eden.sidebar-button")
            let model: AppModel

            init(model: AppModel) {
                self.model = model
                super.init(frame: .zero)
            }

            required init?(coder: NSCoder) { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                guard let window, !window.titlebarAccessoryViewControllers.contains(where: { $0.identifier == Self.identifier }) else { return }
                let host = NSHostingView(rootView: SidebarButton().environment(model))
                host.frame.size = NSSize(width: host.fittingSize.width, height: 52)
                let accessory = NSTitlebarAccessoryViewController()
                accessory.identifier = Self.identifier
                accessory.layoutAttribute = .leading
                accessory.view = host
                window.addTitlebarAccessoryViewController(accessory)
            }
        }
    }
}
