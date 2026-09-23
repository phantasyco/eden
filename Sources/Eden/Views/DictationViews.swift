import SwiftUI

/// The microphone beside Send: starts dictating into the message.
struct DictationButton: View {
    @Environment(AppModel.self) private var app
    let dictation: Dictation
    @Binding var text: String
    var diameter: CGFloat = 28

    var body: some View {
        Button {
            Task { await dictation.start(after: text, write: { text = $0 }, fail: { app.lastError = $0 }) }
        } label: {
            Label("Dictate", systemImage: "mic")
        }
        .buttonStyle(CircleButtonStyle(diameter: diameter))
        .help("Dictate")
    }
}

/// While you dictate, the composer's controls give way to Cancel, the live
/// waveform, and Stop; after Stop, "Transcribing" while the final text
/// lands. Send stays where it is and sends what you've said so far.
struct DictationBar: View {
    let dictation: Dictation
    var diameter: CGFloat = 28

    var body: some View {
        HStack(spacing: 8) {
            Button { dictation.cancel() } label: {
                Label("Cancel Dictation", systemImage: "xmark")
            }
            .buttonStyle(CircleButtonStyle(diameter: diameter))
            .help("Cancel Dictation")
            .keyboardShortcut(.cancelAction)

            if dictation.phase == .transcribing {
                Text("Transcribing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                ProgressView()
                    .controlSize(.small)
                    .frame(width: diameter, height: diameter)
                    .background(Color.primary.opacity(0.08), in: Circle())
            } else {
                DictationWaveform(levels: dictation.levels)
                    .frame(maxWidth: .infinity)
                    .frame(height: diameter)
                Button { dictation.stop() } label: {
                    Label("Stop Dictation", systemImage: "stop.fill")
                }
                .buttonStyle(CircleButtonStyle(diameter: diameter))
                .help("Stop Dictation")
            }
        }
    }
}

/// Your voice as it comes in, newest on the right: a bar for each moment,
/// a dot for silence, like Voice Memos.
struct DictationWaveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 5
            let bar: CGFloat = 2.5
            let count = min(levels.count, Int(size.width / step))
            for index in 0..<count {
                let level = CGFloat(levels[levels.count - 1 - index])
                let x = size.width - CGFloat(index + 1) * step + (step - bar) / 2
                let height = max(bar, level * size.height)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: bar, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .style(.secondary))
            }
        }
        .accessibilityLabel("Listening")
    }
}
