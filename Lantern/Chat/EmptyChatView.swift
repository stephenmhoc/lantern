import SwiftUI

/// Shown in an empty chat: where the answers come from, and a few ways to start. It's the
/// transcript's background view, so it disappears with the first message.
struct EmptyChat: View {
    let conversation: Conversation
    /// Puts a starter's opening words in the message box for the user to finish. Without it the
    /// starters aren't shown, since tapping them would do nothing.
    var onStarter: ((String) -> Void)?
    @Environment(MacLink.self) private var mac

    var body: some View {
        // Fits what it can: the keyboard or a short window (iPad split view) leaves little height.
        ViewThatFits(in: .vertical) {
            content(starters: true, header: true)
            content(starters: true, header: false)
            content(starters: false, header: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        // The message box covers the bottom of this view: centre in what's left above it.
        .padding(.bottom, 96)
    }

    private func content(starters: Bool, header: Bool) -> some View {
        VStack(spacing: 24) {
            if header {
                VStack(spacing: 10) {
                    Image(systemName: conversation.mode == .mac ? "cloud.fill" : "flame.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 64, height: 64)
                        .background(.tint.opacity(0.12), in: .circle)
                        .accessibilityHidden(true)
                    Text("Ask anything").font(.title2.bold())
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if starters, let onStarter {
                // A Grid, not a LazyVGrid, so both cards in a row are as tall as the taller one.
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    ForEach(0..<Starter.all.count / 2, id: \.self) { row in
                        GridRow {
                            ForEach(Starter.all[row * 2..<row * 2 + 2]) { starter in
                                StarterButton(starter: starter) { onStarter(starter.prompt) }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)  // rows as tall as their content, no taller
            }
        }
        .frame(maxWidth: 460)
    }

    private var message: String {
        guard conversation.mode == .mac else { return "Answers come from this device, with or without internet." }
        if mac.route == .unreachable { return "Lantern can't reach your Mac right now." }
        return "Your Mac answers, over your home network or tailnet."
    }
}

/// A way to start a chat: a short title, and the opening words it puts in the message box.
struct Starter: Identifiable {
    let title: String
    let symbol: String
    /// Ends where the user carries on typing (or pastes, for a summary).
    let prompt: String
    var id: String { title }

    /// Everyday tasks a small model does well, worded neutrally.
    static let all = [
        Starter(title: "Write a message", symbol: "pencil.line", prompt: "Help me write a short, friendly message to "),
        Starter(title: "Explain something", symbol: "lightbulb", prompt: "Explain in simple terms how "),
        Starter(title: "Make a plan", symbol: "checklist", prompt: "Make a simple step-by-step plan for "),
        Starter(title: "Summarise a text", symbol: "text.alignleft", prompt: "Summarise this in a few bullet points:\n\n"),
    ]
}

private struct StarterButton: View {
    let starter: Starter
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: starter.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(height: 22)  // symbols differ in height; keep the titles on one line
                    .accessibilityHidden(true)
                Text(starter.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityHint("Starts the message for you to finish")
    }
}
