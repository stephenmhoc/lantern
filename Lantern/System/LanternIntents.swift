import AppIntents

// The models run in the app, so every intent opens it and hands over to `SystemRouter`.
// `NewChatIntent` is in NewChatIntent.swift, shared with the widget extension.

/// "Ask Lantern": a new chat that sends the question straight away. Also what a Share Sheet
/// shortcut runs (Shortcut Input → Ask Lantern).
struct AskLanternIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Lantern"
    static let description = IntentDescription("Starts a new chat in Lantern and sends your question.")
    static let openAppWhenRun = true

    @Parameter(title: "Question", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "What do you want to ask?")
    var text: String

    @Parameter(title: "Mode", default: .usual)
    var mode: ChatModeChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Lantern \(\.$text)") { \.$mode }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SystemRouter.shared.submit(.ask(text: text, mode: mode.linkMode))
        return .result()
    }
}

/// "Open Chat": shows a chat. Also run when a chat is picked from Spotlight.
struct OpenChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let description = IntentDescription("Opens a Lantern chat.")

    @Parameter(title: "Chat")
    var target: ChatEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        SystemRouter.shared.submit(.chat(id: target.id))
        return .result()
    }
}

struct LanternShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskLanternIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
                "Ask \(.applicationName) in \(\.$mode) mode",
            ],
            shortTitle: "Ask Lantern",
            systemImageName: "flame"
        )
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "New \(.applicationName) chat",
                "Start a chat in \(.applicationName)",
                "New \(\.$target) chat in \(.applicationName)",
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open a \(.applicationName) chat",
            ],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left.and.bubble.right"
        )
    }
}
