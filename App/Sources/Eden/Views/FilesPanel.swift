import AgentKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where you are in a folder's Files tab: the open file, the expanded
/// folders, what you searched, and whether Markdown shows as source.
struct FilesState {
    var open: String?
    var expanded: Set<String> = []
    var query = ""
    var showSource = false
}

/// The project's files as git sees them (tracked plus untracked, minus
/// ignored), or every file in a folder without git, and one file's
/// contents, on this Mac or over SSH.
enum ProjectFiles {
    enum Content {
        case text(String, truncated: Bool)
        case image(NSImage)
        case binary
        case failed(String)
    }

    /// Enough for any source file; past this the viewer says it stopped.
    static let byteLimit = 512 * 1024

    /// Enough for a big project; a folder like ~/ would otherwise list forever.
    static let fileLimit = 20_000

    static func list(in folder: URL, on machine: Machine) -> [String] {
        let files: [String]
        if Git.isRepository(folder, on: machine, refresh: machine.isLocal) {
            let out = try? Git.raw(["ls-files", "--cached", "--others", "--exclude-standard", "-z"], in: folder, on: machine)
            files = (out?.stdout ?? "").split(separator: "\0").map(String.init)
        } else if machine.isLocal {
            files = walk(folder)
        } else {
            // Hidden folders and dependencies stay out, as they would with a .gitignore.
            let command = machine.command("sh", ["-c", "find . -type f -not -path '*/.*' -not -path '*/node_modules/*' | head -n \(fileLimit)"], in: folder.path)
            let out = try? Shell.run(command.executable, command.arguments, cwd: nil)
            files = (out?.stdout ?? "").split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
        }
        return Set(files).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A folder without git, walked on this Mac, skipping hidden files and
    /// the dependency folders a .gitignore would.
    private static func walk(_ folder: URL) -> [String] {
        let skipped: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "__pycache__", "target", "dist"]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let base = folder.standardizedFileURL.path + "/"
        var files: [String] = []
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            files.append(path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent)
            if files.count >= fileLimit { break }
        }
        return files
    }

    static func read(_ path: String, in folder: URL, on machine: Machine) -> Content {
        let data: Data
        if machine.isLocal {
            let url = folder.appendingPathComponent(path)
            if ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "pdf", "icns"].contains(url.pathExtension.lowercased()),
               let image = NSImage(contentsOf: url) {
                return .image(image)
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .failed("Couldn't open \(path).") }
            defer { try? handle.close() }
            data = (try? handle.read(upToCount: byteLimit + 1)) ?? Data()
        } else {
            let command = machine.command("head", ["-c", String(byteLimit + 1), "--", path], in: folder.path)
            guard let out = try? Shell.run(command.executable, command.arguments, cwd: nil), out.status == 0 else {
                return .failed("Couldn't read \(path) on \(machine.name).")
            }
            data = Data(out.stdout.utf8)
        }
        if data.prefix(8000).contains(0) { return .binary }
        let truncated = data.count > byteLimit
        return .text(String(decoding: data.prefix(byteLimit), as: UTF8.self), truncated: truncated)
    }
}

/// The Files tab: a viewer on the left and the project's tree on the right,
/// with a search above the tree. Markdown opens rendered; the toolbar
/// switches to its source.
struct FilesPanel: View {
    @Environment(AppModel.self) private var model
    let repo: Repo
    /// The folder, as the panel names it: a path, or ssh://host/path.
    let place: URL
    @State private var files: [String] = []
    @State private var loading = true
    @State private var content: ProjectFiles.Content?

    private var folder: URL { URL(fileURLWithPath: place.path(percentEncoded: false)) }
    private var key: String { place.absoluteString }

    private var state: Binding<FilesState> {
        Binding(
            get: { model.filesState[key] ?? FilesState() },
            set: { model.filesState[key] = $0 }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let treeWidth = min(300, max(200, geometry.size.width * 0.34))
            HStack(spacing: 0) {
                viewer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                FileTree(files: files, loading: loading, state: state, reload: load)
                    .frame(width: treeWidth)
            }
        }
        .task { await load() }
        .task(id: state.wrappedValue.open) { await read() }
        // New and changed files show up when the agent's diff moves.
        .onChange(of: model.selectedThread?.diffStats.files) { Task { await load() } }
    }

    // MARK: Viewer

    @ViewBuilder private var viewer: some View {
        VStack(spacing: 0) {
            ViewerBar(repo: repo, folder: folder, path: state.wrappedValue.open, isMarkdown: isMarkdown,
                      showSource: state.showSource, content: content)
            Divider()
            if let path = state.wrappedValue.open {
                switch content {
                case nil:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .text(let text, let truncated):
                    let note = truncated ? "Showing the first \(ProjectFiles.byteLimit / 1024) KB of \((path as NSString).lastPathComponent)." : nil
                    if isMarkdown, !state.wrappedValue.showSource {
                        // Rendered Markdown wraps to the panel, so it scrolls one way.
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                MarkdownText(text)
                                    .frame(maxWidth: 760, alignment: .leading)
                                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // Code keeps its lines, so it scrolls sideways too.
                        ScrollView([.vertical, .horizontal]) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(text)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: true)
                                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .image(let image):
                    ScrollView([.vertical, .horizontal]) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: image.size.width, maxHeight: image.size.height)
                            .padding(16)
                    }
                case .binary:
                    ContentUnavailableView("Binary File", systemImage: "doc.zipper",
                                           description: Text("Open it in another app to see it."))
                case .failed(let message):
                    ContentUnavailableView("Can't Show This File", systemImage: "exclamationmark.triangle", description: Text(message))
                }
            } else {
                ContentUnavailableView("Open a File", systemImage: "doc",
                                       description: Text("Pick a file from the list, or search for one."))
            }
        }
    }

    private var isMarkdown: Bool {
        guard let path = state.wrappedValue.open else { return false }
        return ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
    }

    private func load() async {
        let folder = folder, machine = repo.machine
        let list = await Task.detached { ProjectFiles.list(in: folder, on: machine) }.value
        files = list
        loading = false
    }

    private func read() async {
        content = nil
        guard let path = state.wrappedValue.open else { return }
        let folder = folder, machine = repo.machine
        content = await Task.detached { ProjectFiles.read(path, in: folder, on: machine) }.value
    }
}

/// The viewer's top bar: where the file is, then source or rendered, copy,
/// and Open with the apps that can open it.
private struct ViewerBar: View {
    let repo: Repo
    let folder: URL
    let path: String?
    let isMarkdown: Bool
    @Binding var showSource: Bool
    let content: ProjectFiles.Content?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            breadcrumb
            Spacer(minLength: 8)
            if isMarkdown {
                Button { showSource.toggle() } label: {
                    Label(showSource ? "Show Rendered" : "Show Source",
                          systemImage: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(showSource ? "Show Rendered" : "Show Source")
            }
            if case .text(let text, _) = content {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy Contents", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Copy Contents")
            }
            if repo.machine.isLocal {
                let target = path.map { folder.appendingPathComponent($0) } ?? folder
                Menu {
                    Button("Open with Default App", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(target) }
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                    Divider()
                    ForEach(OpenApps.installed, id: \.bundleID) { app in
                        Button(app.name) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                NSWorkspace.shared.open([target], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
                            }
                        }
                    }
                } label: {
                    Text("Open")
                } primaryAction: {
                    NSWorkspace.shared.open(target)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Open with the default app. Click the arrow for others.")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    /// "eden › Sources › Eden › Models.swift", or the project's name.
    private var breadcrumb: some View {
        let parts = [repo.name] + (path?.split(separator: "/").map(String.init) ?? [])
        return HStack(spacing: 4) {
            Image(systemName: path == nil ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.compact.right").font(.caption).foregroundStyle(.tertiary)
                }
                Text(part)
                    .foregroundStyle(index == parts.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .truncationMode(.head)
    }
}

/// Apps a file or folder can open in, the installed ones only.
enum OpenApps {
    static let known: [(name: String, bundleID: String)] = [
        ("Xcode", "com.apple.dt.Xcode"),
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("TextEdit", "com.apple.TextEdit"),
    ]

    static var installed: [(name: String, bundleID: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

/// The project's tree: folders you can expand, or a flat list of matches
/// while you search.
private struct FileTree: View {
    let files: [String]
    let loading: Bool
    @Binding var state: FilesState
    let reload: () async -> Void
    @FocusState private var searchFocused: Bool

    /// Each folder's children: subfolders first, then files, by name.
    private var children: [String: [Node]] {
        var folders: [String: Set<String>] = [:]
        var leaves: [String: [String]] = [:]
        for path in files {
            let parts = path.split(separator: "/").map(String.init)
            var parent = ""
            for (index, part) in parts.enumerated() {
                let current = parent.isEmpty ? part : parent + "/" + part
                if index == parts.count - 1 {
                    leaves[parent, default: []].append(current)
                } else {
                    folders[parent, default: []].insert(current)
                }
                parent = current
            }
        }
        var result: [String: [Node]] = [:]
        for key in Set(folders.keys).union(leaves.keys) {
            let dirs = (folders[key] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { Node(path: $0, isFolder: true) }
            let items = (leaves[key] ?? []).map { Node(path: $0, isFolder: false) }
            result[key] = dirs + items
        }
        return result
    }

    private var matches: [String] {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        let hits = files.filter { $0.localizedCaseInsensitiveContains(query) }
        // Names that match beat paths that only match in a folder.
        return hits.sorted { lhs, rhs in
            let l = (lhs as NSString).lastPathComponent.localizedCaseInsensitiveContains(query)
            let r = (rhs as NSString).lastPathComponent.localizedCaseInsensitiveContains(query)
            return l != r ? l : lhs.count < rhs.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchField(prompt: "Search Files", text: $state.query, focused: $searchFocused)
                Button { Task { await reload() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(8)
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView("No Files", systemImage: "folder")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                            let tree = children
                            ForEach(rows(in: "", tree: tree, depth: 0), id: \.node.path) { row in
                                FileRow(node: row.node, depth: row.depth, isOpen: state.open == row.node.path,
                                        isExpanded: state.expanded.contains(row.node.path)) { select(row.node) }
                            }
                        } else {
                            ForEach(matches.prefix(300), id: \.self) { path in
                                FileRow(node: Node(path: path, isFolder: false), depth: 0, isOpen: state.open == path,
                                        isExpanded: false, showsFolder: true) { state.open = path }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// The visible rows: a folder's children, and its expanded folders' children under them.
    private func rows(in folder: String, tree: [String: [Node]], depth: Int) -> [(node: Node, depth: Int)] {
        var result: [(node: Node, depth: Int)] = []
        for node in tree[folder] ?? [] {
            result.append((node, depth))
            if node.isFolder, state.expanded.contains(node.path) {
                result += rows(in: node.path, tree: tree, depth: depth + 1)
            }
        }
        return result
    }

    private func select(_ node: Node) {
        if node.isFolder {
            if state.expanded.contains(node.path) { state.expanded.remove(node.path) } else { state.expanded.insert(node.path) }
        } else {
            state.open = node.path
        }
    }
}

private struct Node: Hashable {
    let path: String
    let isFolder: Bool
    var name: String { (path as NSString).lastPathComponent }
}

private struct FileRow: View {
    let node: Node
    let depth: Int
    let isOpen: Bool
    let isExpanded: Bool
    var showsFolder = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                    .opacity(node.isFolder ? 1 : 0)
                icon
                    .frame(width: 16, height: 16)
                Text(node.name)
                    .lineLimit(1)
                if showsFolder {
                    Text((node.path as NSString).deletingLastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14 + 4)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isOpen ? 0.1 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(node.path)
    }

    /// Finder's icon for the file's type; a folder symbol for folders.
    @ViewBuilder private var icon: some View {
        if node.isFolder {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .foregroundStyle(.secondary)
        } else {
            let ext = (node.path as NSString).pathExtension
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: ext) ?? .data))
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
