import Foundation

/// A `lantern://` deep link. Compiled into the app and the widget extension, so the widgets, the
/// intents and Spotlight all reach the app the same way:
/// - `lantern://new` or `lantern://new?mode=fast`: a new chat, in that mode or the usual one.
/// - `lantern://ask?text=…&mode=smart`: a new chat that sends `text` straight away.
/// - `lantern://chat/<id>`: opens a chat. The id is `Conversation.stateID`.
///
/// Modes are `Mode` raw values (`fast` is Gemma 4 E2B, `smart` Gemma 4 E4B, `mac` the Mac);
/// anything else means the usual mode.
nonisolated enum LanternLink: Equatable, Sendable {
    case new(mode: String?)
    case ask(text: String, mode: String?)
    case chat(id: String)

    static let scheme = "lantern"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch components.host?.lowercased() {
        case "new":
            self = .new(mode: value("mode"))
        case "ask":
            guard let text = value("text") else { self = .new(mode: value("mode")); return }
            self = .ask(text: text, mode: value("mode"))
        case "chat":
            let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !id.isEmpty else { return nil }
            self = .chat(id: id)
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .new(let mode):
            components.host = "new"
            if let mode { components.queryItems = [URLQueryItem(name: "mode", value: mode)] }
        case .ask(let text, let mode):
            components.host = "ask"
            components.queryItems = [URLQueryItem(name: "text", value: text)]
                + (mode.map { [URLQueryItem(name: "mode", value: $0)] } ?? [])
        case .chat(let id):
            components.host = "chat"
            components.path = "/" + id
        }
        return components.url!
    }
}
