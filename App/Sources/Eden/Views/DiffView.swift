import AgentKit
import SwiftUI

/// The Changes panel: a session's or a project's diff, file by file, with a
/// commit bar. It refreshes each time it opens, so it always shows the
/// folder as it is now.
struct DiffView<Source: ChangeSource>: View {
    let thread: Source
    @AppStorage(Preferences.diffColors) private var colors = DiffColors.redGreen
    @State private var message = ""
    @State private var status: String?

    var body: some View {
        let files = thread.diffFiles
        VStack(spacing: 0) {
            header(files)
            Divider()
            if thread.changesFolder == nil {
                ContentUnavailableView(
                    "No Changes Yet",
                    systemImage: "plus.forwardslash.minus",
                    description: Text("This session gets its own worktree with the first message; its changes show up here.")
                )
                .frame(maxHeight: .infinity)
            } else if !thread.tracksChanges {
                ContentUnavailableView(
                    "Not a Git Repository",
                    systemImage: "folder",
                    description: Text("Eden shows changes by comparing with git. Run git init in the Terminal to start tracking this folder.")
                )
                .frame(maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView(
                    "No Changes",
                    systemImage: "checkmark.seal",
                    description: Text("Nothing has changed in this folder since the last commit.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(files) { file in
                            FileSection(file: file, colors: colors)
                        }
                    }
                    .textSelection(.enabled)
                }
                Divider()
                commitBar
            }
        }
        // The header stays at the top even when the content is a short empty state.
        .frame(maxHeight: .infinity, alignment: .top)
        // Opening Changes shows the folder as it is now, not as of the last turn.
        .task { await thread.refreshDiff() }
    }

    private func header(_ files: [DiffFile]) -> some View {
        HStack(spacing: 8) {
            Text("Changes").font(.headline)
            if !files.isEmpty {
                Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                    .foregroundStyle(.secondary)
                ChangeCounts(added: thread.diffStats.added, removed: thread.diffStats.removed, colors: colors)
            }
            Spacer()
            Button { Task { await thread.refreshDiff() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(thread.changesFolder == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Commit message", text: $message)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Commit", action: commit)
                    .buttonStyle(.borderedProminent)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || thread.isRunning)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12)
    }

    private func commit() {
        let text = message.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !thread.isRunning else { return }
        Task {
            do {
                status = try await thread.commit(message: text)
                message = ""
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

/// "+12 −3" in the diff colors chosen in Settings.
struct ChangeCounts: View {
    let added: Int
    let removed: Int
    let colors: DiffColors

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(colors.added)
            Text("−\(removed)").foregroundStyle(colors.removed)
        }
        .monospacedDigit()
    }
}

// MARK: Files

/// One file's section: a header that sticks to the top while you scroll its
/// lines, and the lines themselves, which the header can fold away.
private struct FileSection: View {
    let file: DiffFile
    let colors: DiffColors
    @State private var collapsed = false

    var body: some View {
        Section {
            if !collapsed {
                if file.isBinary {
                    Text("Binary file")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                ForEach(file.hunks) { hunk in
                    HunkHeader(text: hunk.header)
                    ForEach(hunk.lines) { line in
                        DiffLineRow(line: line, colors: colors)
                    }
                }
                if file.hiddenLines > 0 {
                    Text("\(file.hiddenLines.formatted()) more lines not shown")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            }
        } header: {
            Button { withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: 10)
                    Image(systemName: file.symbol)
                        .foregroundStyle(file.symbolColor(colors))
                    // File name first, its folder after, like Xcode's jump bar.
                    Text(file.name).fontWeight(.medium).lineLimit(1)
                    if !file.folder.isEmpty {
                        Text(file.folder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    ChangeCounts(added: file.added, removed: file.removed, colors: colors)
                        .font(.caption)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
                .background(.bar)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.separator).frame(height: 1)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct HunkHeader: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.07))
    }
}

/// Old and new line numbers in the gutter, then the line, tinted by kind.
private struct DiffLineRow: View {
    let line: DiffLine
    let colors: DiffColors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .note ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
        .padding(.trailing, 10)
        .background(tint.map { $0.opacity(0.12) } ?? .clear)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: ""
        }
    }

    private var tint: Color? {
        switch line.kind {
        case .added: colors.added
        case .removed: colors.removed
        default: nil
        }
    }
}

// MARK: Parsing

/// Files, added lines, and removed lines in a unified diff, counted without
/// building every line: the transcript's Changes card redraws often.
struct DiffStats {
    var files = 0
    var added = 0
    var removed = 0

    init(_ diff: String) {
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("diff --git") { files += 1 }
            else if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
    }
}


/// One file in a unified diff (`git diff`), parsed into hunks with line numbers.
struct DiffFile: Identifiable {
    enum Change { case modified, added, deleted, renamed }

    /// Position in the diff plus path: a path can appear twice (a delete and
    /// an untracked add of the same file, or a type change).
    let id: String
    var path: String
    var change = Change.modified
    var isBinary = false
    var hunks: [DiffHunk] = []
    /// Counted while parsing, over the whole file, including lines past the limit.
    var added = 0
    var removed = 0
    /// Lines kept for display, and lines past `lineLimit` left out.
    var shownLines = 0
    var hiddenLines = 0
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }

    /// A file longer than this shows its start and a count of the rest: a
    /// generated file or a whole new repository shouldn't stall the panel.
    static let lineLimit = 2000

    var symbol: String {
        switch change {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        case .modified: "doc.text"
        }
    }

    func symbolColor(_ colors: DiffColors) -> Color {
        switch change {
        case .added: colors.added
        case .deleted: colors.removed
        default: .secondary
        }
    }

    static func parse(_ diff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var oldLine = 0, newLine = 0, counter = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                // "diff --git a/path b/path": the new path is after " b/". Git
                // quotes paths with unusual characters: "b/my file".
                var path = line
                if let quoted = line.range(of: " \"b/", options: .backwards) {
                    path = String(line[quoted.upperBound...].dropLast())
                } else if let plain = line.range(of: " b/", options: .backwards) {
                    path = String(line[plain.upperBound...])
                }
                files.append(DiffFile(id: "\(files.count)|\(path)", path: path))
                continue
            }
            guard !files.isEmpty else { continue }
            if line.hasPrefix("@@") {
                if files[files.count - 1].shownLines >= DiffFile.lineLimit { continue }
                let (old, new) = hunkStarts(line)
                oldLine = old
                newLine = new
                counter += 1
                files[files.count - 1].hunks.append(DiffHunk(id: "\(files[files.count - 1].path)|\(counter)|\(line)", header: line, lines: []))
                continue
            }
            if files[files.count - 1].hunks.isEmpty {
                // File metadata before the first hunk.
                if line.hasPrefix("new file mode") { files[files.count - 1].change = .added }
                else if line.hasPrefix("deleted file mode") { files[files.count - 1].change = .deleted }
                else if line.hasPrefix("rename from") { files[files.count - 1].change = .renamed }
                else if line.hasPrefix("Binary files") { files[files.count - 1].isBinary = true }
                continue
            }
            counter += 1
            // IDs carry the file, position, and text: when the diff refreshes,
            // a row whose content changed is a new row, never a stale one.
            let id = "\(files[files.count - 1].path)|\(counter)|\(line)"
            var parsed: DiffLine
            if line.hasPrefix("+") {
                parsed = DiffLine(id: id, kind: .added, newNumber: newLine, text: String(line.dropFirst()))
                newLine += 1
            } else if line.hasPrefix("-") {
                parsed = DiffLine(id: id, kind: .removed, oldNumber: oldLine, text: String(line.dropFirst()))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                parsed = DiffLine(id: id, kind: .note, text: String(line.dropFirst(2)))
            } else if line.isEmpty, raw.endIndex == diff.endIndex {
                continue
            } else {
                parsed = DiffLine(id: id, kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(line.dropFirst()))
                oldLine += 1
                newLine += 1
            }
            let last = files.count - 1
            if parsed.kind == .added { files[last].added += 1 } else if parsed.kind == .removed { files[last].removed += 1 }
            guard files[last].shownLines < DiffFile.lineLimit, !files[last].hunks.isEmpty else {
                files[last].hiddenLines += 1
                continue
            }
            files[last].shownLines += 1
            files[last].hunks[files[last].hunks.count - 1].lines.append(parsed)
        }
        return files
    }

    /// "@@ -208,9 +208,16 @@" gives (208, 208).
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        func start(after marker: Character) -> Int {
            guard let index = header.firstIndex(of: marker) else { return 1 }
            let digits = header[header.index(after: index)...].prefix { $0.isNumber }
            return Int(digits) ?? 1
        }
        return (start(after: "-"), start(after: "+"))
    }
}

struct DiffHunk: Identifiable {
    let id: String
    let header: String
    var lines: [DiffLine]
}

struct DiffLine: Identifiable {
    enum Kind { case context, added, removed, note }

    let id: String
    let kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    let text: String
}
