import SwiftUI

/// Shown in an empty chat, the page Lantern opens on: a few prompt ideas, four at a time from
/// `Starter.all` ("More ideas" for the next four). It's the transcript's background view, so it
/// disappears with the first message.
struct EmptyChat: View {
    let conversation: Conversation
    /// Puts a starter's opening words in the message box for the user to finish. Without it the
    /// starters aren't shown, since tapping them would do nothing.
    var onStarter: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    /// Which four ideas show: a different set each new chat, the next set on "More ideas".
    @State private var page = Int.random(in: 0..<Starter.pages)

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
                    Image(systemName: conversation.answeringMode == .mac ? "desktopcomputer" : "flame.fill")
                        .font(.system(size: Self.badge * 0.47, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: Self.badge, height: Self.badge)
                        .background(.tint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: .circle)
                        .accessibilityHidden(true)
                    Text("Ask anything").font(.title2.bold())
                }
            }
            if starters, let onStarter {
                let shown = Starter.page(page)
                VStack(spacing: 10) {
                    HStack {
                        Text("Try asking").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            withAnimation(.snappy) { page = (page + 1) % Starter.pages }
                        } label: {
                            Label("More ideas", systemImage: "arrow.clockwise").font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .hoverEffect(.highlight)
                    }
                    // A Grid, not a LazyVGrid, so both cards in a row are as tall as the taller one.
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(0..<shown.count / Self.columns, id: \.self) { row in
                            GridRow {
                                ForEach(shown[row * Self.columns..<(row + 1) * Self.columns]) { starter in
                                    StarterButton(starter: starter) { onStarter(starter.prompt) }
                                }
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)  // rows as tall as their content, no taller
                    .id(page)
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: Self.width)
    }

    private static let badge: CGFloat = 64
    private static let width: CGFloat = 460
    private static let columns = 2
}

/// A way to start a chat: a short title, and the opening words it puts in the message box.
struct Starter: Identifiable {
    let title: String
    let symbol: String
    /// Ends where the user carries on typing (or pastes, for a summary).
    let prompt: String
    var id: String { title }

    /// Everyday tasks a small model does well, worded neutrally. A multiple of four: one page each.
    static let all = [
        Starter(title: "Write a message", symbol: "pencil.line", prompt: "Help me write a short, friendly message to "),
        Starter(title: "Explain something simply", symbol: "lightbulb", prompt: "Explain in simple terms how "),
        Starter(title: "Make a step-by-step plan", symbol: "checklist", prompt: "Make a simple step-by-step plan for "),
        Starter(title: "Summarise a text", symbol: "text.alignleft", prompt: "Summarise this in a few bullet points:\n\n"),

        Starter(title: "Cook with what I have", symbol: "fork.knife", prompt: "What can I cook with "),
        Starter(title: "Brainstorm ideas", symbol: "sparkles", prompt: "Give me ten ideas for "),
        Starter(title: "Polish my writing", symbol: "text.badge.checkmark", prompt: "Fix the grammar and make this clearer, keeping my tone:\n\n"),
        Starter(title: "Weigh up a choice", symbol: "scale.3d", prompt: "List the pros and cons of "),

        Starter(title: "Quiz me on a topic", symbol: "questionmark.bubble", prompt: "Quiz me with five questions, one at a time, about "),
        Starter(title: "Work out a sum", symbol: "function", prompt: "Work this out step by step: "),
        Starter(title: "Make a packing list", symbol: "suitcase", prompt: "Make a packing list for "),
        Starter(title: "Translate a text", symbol: "character.bubble", prompt: "Translate this into English:\n\n"),

        Starter(title: "Draft an email", symbol: "envelope", prompt: "Write a short, polite email asking "),
        Starter(title: "Tell a bedtime story", symbol: "book", prompt: "Write a short bedtime story about "),
        Starter(title: "Practise an interview", symbol: "person.2", prompt: "Interview me, one question at a time, for a job as "),
        Starter(title: "Explain some code", symbol: "chevron.left.forwardslash.chevron.right", prompt: "Explain what this code does:\n\n"),
    ]

    static var pages: Int { all.count / 4 }
    static func page(_ i: Int) -> [Starter] { Array(all[(i % pages) * 4..<(i % pages) * 4 + 4]) }
}

private struct StarterButton: View {
    let starter: Starter
    let action: () -> Void
    @State private var hovering = false

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
            .padding(Self.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(hovering ? Self.hoverFill : Self.cardFill, in: .rect(cornerRadius: Self.radius))
            .contentShape(.rect(cornerRadius: Self.radius))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)  // iPad's pointer; the Mac's is the fill
        .onHover { over in if Device.isMac { hovering = over } }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(starter.prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "…")
        .accessibilityHint("Starts the message for you to finish")
    }

    private static let cardFill = Color(.secondarySystemBackground)
    private static let hoverFill = Color(.tertiarySystemFill)
    private static let padding: CGFloat = Device.isMac ? 12 : 14
    private static let radius: CGFloat = Device.isMac ? 12 : 16
}
