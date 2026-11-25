import CoreTransferable
import LlamaKit
import SwiftUI
import UniformTypeIdentifiers

/// The chat's details, beside it on iPad (a sheet on iPhone): what answers, how much of the
/// context it has used, how fast the last reply was, and the system prompt.
struct ChatInspector: View {
    let conversation: Conversation
    /// Hides it; used for the Done button when it's a sheet.
    let close: () -> Void
    @Environment(Engine.self) private var engine
    @Environment(MacLink.self) private var mac
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // Memory, battery and heat change while it's open.
        let content = TimelineView(.periodic(from: .now, by: 2)) { _ in form }
        if sizeClass == .compact {
            // On iPhone the inspector is a sheet with nothing above the form, so the first section
            // started at the sheet's very edge. A header of its own gives it room and a way out.
            // Not a NavigationStack with a toolbar: an inspector's toolbar items and title go to the
            // chat's navigation bar, not the sheet's.
            VStack(spacing: 0) {
                ZStack {
                    Text("Info").font(.headline)
                    HStack {
                        Spacer()
                        Button("Done", action: close).fontWeight(.semibold)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 8)
                content
            }
            .background(Color(.systemGroupedBackground))
            .presentationDragIndicator(.visible)
        } else {
            content
        }
    }

    private var form: some View {
        Form {
            Section("Model") {
                LabeledContent("Model", value: modelName)
                LabeledContent("Runs on", value: conversation.mode.isOnDevice ? "This device" : "Your Mac")
                if conversation.mode == .mac {
                    LabeledContent("Connected by", value: mac.route.label)
                }
                if conversation.mode != .apple {  // Apple Intelligence's model doesn't think
                    LabeledContent("Thinking", value: conversation.thinking.rawValue.capitalized)
                }
            }

            Section {
                if let usage = engine.contextUsage(for: conversation) {
                    LabeledContent("Context used", value: "\(usage.used.formatted()) of \(usage.limit.formatted()) tokens")
                    ProgressView(value: Double(usage.used), total: Double(max(usage.limit, 1)))
                } else {
                    LabeledContent("Context used", value: "≈ \(contextTokens.formatted()) tokens")
                }
            } footer: {
                if engine.contextUsage(for: conversation) == nil {
                    Text("An estimate until the chat's next reply: about four characters to a token.")
                }
            }

            Section("Last reply") {
                let last = lastReply
                LabeledContent("Speed", value: last.speed ?? "—")
                LabeledContent("First token", value: last.firstToken ?? "—")
                if let load = last.load { LabeledContent("Loading the model", value: load) }
            }

            Section("This device") {
                if conversation.mode.usesLlama, let free = MemoryStats.availableBytes {
                    LabeledContent("Memory free", value: MemoryStats.gb(free))
                }
                LabeledContent("Battery", value: Power.isCharging ? "\(Power.batteryText), charging" : Power.batteryText)
                if Power.isHot {
                    LabeledContent("Temperature") { Text("Hot").foregroundStyle(.orange) }
                }
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
            let name = conversation.resolvedMacModel
            return name.isEmpty ? "Ollama's first model" : "\(MacLink.displayName(name)) (\(name))"
        case .apple:
            let status = engine.apple.status
            return status.isAvailable ? Mode.apple.title : "\(Mode.apple.title) (\(status.short.lowercased()))"
        case .fast, .smart, .qwen:
            guard let model = engine.model(for: conversation.mode) else { return "None" }
            return engine.store.states[model.id] == .ready ? model.name : "\(model.name) (not on this device)"
        }
    }

    private var contextTokens: Int {
        let chars = conversation.systemPrompt.count + conversation.messages.reduce(0) { $0 + $1.content.count }
        return chars / 4
    }

    /// From the last reply's metrics (the version shown), or for a reply from before them, read
    /// from its footnote, e.g. "Gemma 4 E2B · 14.2 tok/s · 0.8 s to first token". The metrics'
    /// first token leaves out loading the model, shown on its own line when it took a moment.
    private var lastReply: (speed: String?, firstToken: String?, load: String?) {
        let reply = conversation.messages.last { !$0.isUser && ($0.metrics != nil || $0.footnote != nil) }
        if let m = reply?.metrics {
            return (m.tokensPerSecond.map { String(format: "%.1f tok/s", $0) },
                    m.firstTokenSeconds.map { String(format: "%.1f s", $0) },
                    m.loadSeconds.flatMap { $0 >= 0.1 ? String(format: "%.1f s", $0) : nil })
        }
        guard let footnote = reply?.footnote else { return (nil, nil, nil) }
        let parts = footnote.components(separatedBy: " · ")
        let speed = parts.first { $0.contains("tok/s") }
        let first = parts.first { $0.localizedCaseInsensitiveContains("first token") || $0.contains("TTFT") }
            .flatMap { part in part.firstMatch(of: /[0-9]+(\.[0-9]+)?\s*s/).map { String($0.output.0) } }
        return (speed, first, nil)
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
                // The pages a search found, as links under the answer that used them.
                let sources = (m.searches ?? []).flatMap(\.results)
                if !sources.isEmpty {
                    lines += ["Sources:"] + sources.map { "- [\($0.title)](\($0.url))" } + [""]
                }
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
