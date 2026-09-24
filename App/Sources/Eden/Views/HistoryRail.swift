import SwiftUI

/// A message you sent, as a place in the session to go back to.
struct Checkpoint: Identifiable {
    let id: String
    let text: String
    let date: Date

    static func all(in items: [TranscriptItem]) -> [Checkpoint] {
        items.compactMap { item in
            guard case .user(let text) = item.kind else { return nil }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return Checkpoint(id: item.id, text: line.trimmingCharacters(in: .whitespaces), date: item.date)
        }
    }
}

/// Which checkpoints have scrolled up past the reading line. The transcript
/// reports it and only the rail reads it, so scrolling redraws the rail, not
/// the transcript.
@Observable
final class CheckpointTracker {
    var passed: [String: Bool] = [:]
}

/// The session's history down the leading edge of the transcript: a tick for
/// each message you sent, like the index down the side of Contacts. Hover a
/// tick to see the message, click it to scroll there. The tick for the part
/// you're reading is darker, and Scroll to Bottom brings you back.
struct HistoryRail: View {
    let checkpoints: [Checkpoint]
    let tracker: CheckpointTracker
    /// At the end of the transcript. The latest message may be too far up
    /// for the tracker to have seen it, but it's the one you're reading.
    let atBottom: Bool
    let jump: (Checkpoint) -> Void

    static let width: CGFloat = 30

    var body: some View {
        let current = currentID
        GeometryReader { geometry in
            // Ticks move closer together to fit a long session in the space there is.
            let pitch = min(12, max(4, geometry.size.height * 0.6 / CGFloat(max(1, checkpoints.count))))
            VStack(spacing: 0) {
                ForEach(checkpoints) { checkpoint in
                    CheckpointTick(checkpoint: checkpoint, isCurrent: checkpoint.id == current, height: pitch, jump: jump)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session history")
    }

    private var currentID: String? {
        checkpoints.last { tracker.passed[$0.id] == true }?.id ?? (atBottom ? checkpoints.last : checkpoints.first)?.id
    }
}

private struct CheckpointTick: View {
    let checkpoint: Checkpoint
    let isCurrent: Bool
    let height: CGFloat
    let jump: (Checkpoint) -> Void
    @State private var hovered = false

    var body: some View {
        Button { jump(checkpoint) } label: {
            Capsule()
                .fill(isCurrent ? AnyShapeStyle(.primary) : hovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: isCurrent || hovered ? 16 : 10, height: 3)
                .padding(.leading, 8)
                .frame(width: HistoryRail.width, height: height, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        // Floats beside the tick, over the transcript, without moving anything.
        .overlay(alignment: .leading) {
            if hovered {
                CheckpointLabel(checkpoint: checkpoint)
                    .offset(x: HistoryRail.width + 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(hovered ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: isCurrent)
        .accessibilityLabel(checkpoint.text)
        .accessibilityHint("Scrolls to this message")
    }
}

/// The message and when you sent it, on glass like a popover.
private struct CheckpointLabel: View {
    let checkpoint: Checkpoint

    var body: some View {
        HStack(spacing: 8) {
            Text(checkpoint.text)
                .lineLimit(1)
            Text(checkpoint.date.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 340, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .fixedSize()
    }
}
