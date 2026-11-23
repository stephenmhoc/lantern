import AppIntents

/// The mode for a chat started from outside the app. `.usual` picks it the way the New chat
/// button does (`DefaultMode`). Compiled into the widget extension too, for the control.
nonisolated enum ChatModeChoice: String, AppEnum {
    // Not `mac`/"Mac": Siri rejects App Intent options named after Apple trademarks (ITMS-90626).
    case usual, fast, smart, computer

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mode")
    static let caseDisplayRepresentations: [ChatModeChoice: DisplayRepresentation] = [
        .usual: DisplayRepresentation(title: "Usual", subtitle: "The mode you used last, if it's ready"),
        .fast: DisplayRepresentation(title: "Fast", subtitle: "Gemma on this device", image: .init(systemName: "hare")),
        .smart: DisplayRepresentation(title: "Smart", subtitle: "Inkling on this device", image: .init(systemName: "brain")),
        .computer: DisplayRepresentation(title: "Computer", subtitle: "Ollama on your computer", image: .init(systemName: "desktopcomputer")),
    ]

    /// The `Mode` raw value for a `LanternLink`; nil for the usual mode.
    var linkMode: String? {
        switch self {
        case .usual: nil
        case .computer: "mac"
        default: rawValue
        }
    }
}

/// "New Chat": opens Lantern on a new chat. An `OpenIntent` so the Control Center control can use
/// it; it lives in both targets because a control's intent that opens the app is performed by the app.
struct NewChatIntent: OpenIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Opens Lantern on a new chat.")

    @Parameter(title: "Mode", default: .usual)
    var target: ChatModeChoice

    init() {}
    init(mode: ChatModeChoice) { target = mode }

    static var parameterSummary: some ParameterSummary {
        Summary("New \(\.$target) chat")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LANTERN_WIDGETS
        SystemRouter.shared.submit(.new(mode: target.linkMode))
        #endif
        return .result()
    }
}
