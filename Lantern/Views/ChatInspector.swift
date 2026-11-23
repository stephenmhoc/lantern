import CoreTransferable
import LlamaKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat's details, beside it on iPad (a sheet on iPhone): what answers, how much of the
/// context it has used, how fast the last reply was, and the system prompt.
struct ChatInspector: View {
    let conversation: Conversation
    @Environment(Engine.self) private var engine
    @Environment(MacLink.self) private var mac

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("Mode", value: conversation.mode.title)
                LabeledContent("Model", value: modelName)
                LabeledContent("Thinking", value: conversation.mode == .smart && conversation.thinking == .off
                               ? "A little (Smart always thinks)" : conversation.thinking.rawValue.capitalized)
            }

            Section {
                LabeledContent("Context used", value: "≈ \(contextTokens.formatted()) tokens")
            } footer: {
                // HOOK(engine): replace the estimate with the engine's real count (and the model's
                // context size) once it exposes context usage.
                Text("An estimate: about four characters to a token.")
            }

            Section("Last reply") {
                LabeledContent("Speed", value: lastReply.speed ?? "—")
                LabeledContent("First token", value: lastReply.firstToken ?? "—")
            }

            Section("System prompt") {
                Text(Engine.systemPrompt())
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        // No navigationTitle: the inspector shares the chat's navigation bar, and would rename it.
    }

    private var modelName: String {
        switch conversation.mode {
        case .mac:
            return mac.modelName.isEmpty ? "Ollama's first model" : mac.modelName
        case .fast, .smart:
            guard let model = engine.model(for: conversation.mode) else { return "None" }
            return engine.store.states[model.id] == .ready ? model.name : "\(model.name) (not on this device)"
        }
    }

    private var contextTokens: Int {
        let chars = Engine.systemPrompt().count + conversation.messages.reduce(0) { $0 + $1.content.count }
        return chars / 4
    }

    /// Read from the last reply's footnote, e.g. "Gemma 4 E2B · 14.2 tok/s · 0.8 s to first token".
    /// HOOK(engine): the footnote has no time to first token yet; any part containing "first token"
    /// or "TTFT" with a number of seconds is picked up here.
    private var lastReply: (speed: String?, firstToken: String?) {
        guard let footnote = conversation.messages.last(where: { !$0.isUser && $0.footnote != nil })?.footnote else {
            return (nil, nil)
        }
        let parts = footnote.components(separatedBy: " · ")
        let speed = parts.first { $0.contains("tok/s") }
        let first = parts.first { $0.localizedCaseInsensitiveContains("first token") || $0.contains("TTFT") }
            .flatMap { part in part.firstMatch(of: /[0-9]+(\.[0-9]+)?\s*s/).map { String($0.output.0) } }
        return (speed, first)
    }
}

extension UTType {
    nonisolated static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// A chat as a Markdown file, for ShareLink.
nonisolated struct ChatExport: Transferable {
    let title: String
    let markdown: String

    @MainActor init(_ c: Conversation) {
        title = c.title
        var lines = ["# \(c.title)", "", "_\(c.created.formatted(date: .long, time: .shortened)) · Lantern_", ""]
        for m in c.messages {
            if m.isUser {
                lines += ["**You**", "", m.content, ""]
            } else {
                lines += ["**Lantern**" + (m.footnote.map { " _(\($0))_" } ?? ""), ""]
                if !m.content.isEmpty { lines += [m.content, ""] }
                if let error = m.error { lines += ["> \(error)", ""] }
            }
        }
        markdown = lines.joined(separator: "\n")
    }

    private var filename: String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return "\(safe.isEmpty ? "Chat" : safe).md"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .markdownText) { Data($0.markdown.utf8) }
            .suggestedFileName { $0.filename }
        ProxyRepresentation(exporting: \.markdown)
    }
}
