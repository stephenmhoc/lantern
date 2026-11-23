import Foundation
import llama

/// How hard a reasoning model should think before answering. Inkling maps this to its
/// "Thinking effort level"; Gemma only has thinking on or off.
public enum Thinking: String, Sendable, CaseIterable, Codable {
    case off, low, high

    var inklingEffort: String {
        switch self {
        case .off: "0"
        case .low: "0.2"
        case .high: "0.9"
        }
    }
}

/// Turns messages into a prompt, and the model's raw tokens back into thinking and answer text.
/// llama.cpp's C helper has no Jinja engine, so the two models Lantern ships are written out here
/// from the Jinja in their GGUFs (`lantern-smoke <file> --template` prints it).
struct ChatTemplate {
    enum Format: String { case inkling, gemma4 }

    let format: Format

    /// Nil for any model whose template isn't one of these.
    init?(model: OpaquePointer) {
        guard let raw = llama_model_chat_template(model, nil).map({ String(cString: $0) }) else { return nil }
        if raw.contains("<|message_user|>") {
            format = .inkling
        } else if raw.contains("<|turn>") {
            format = .gemma4
        } else {
            return nil
        }
    }

    /// The end-of-generation token that closes a model turn the way the template does. A reply that
    /// ends on any other (e.g. Gemma's `<eos>`) can't be continued token-for-token.
    var turnEnd: String {
        switch format {
        case .inkling: "<|content_model_end_sampling|>"
        case .gemma4: "<turn|>"
        }
    }

    func render(_ messages: [ChatMessage], thinking: Thinking) -> String {
        switch format {
        case .inkling: inkling(messages, thinking: thinking)
        case .gemma4: gemma4(messages, thinking: thinking)
        }
    }

    /// Whether a cache built with `old` can be extended for a request with `new`, token-for-token
    /// what a full render would give. Gemma's template drops earlier thinking from past turns, so a
    /// cache holding it no longer matches once thinking is on.
    func canContinue(from old: Thinking, to new: Thinking) -> Bool {
        switch format {
        case .inkling: old == new  // the effort level is part of the prompt
        case .gemma4: old == .off && new == .off
        }
    }

    /// The text that follows a reply the model closed with `turnEnd` (not yet in the cache), through
    /// the next generation prompt.
    func renderContinuation(_ newUserTurns: [ChatMessage]) -> String {
        switch format {
        case .inkling:
            turnEnd + newUserTurns.map { "<|message_user|><|content_text|>\($0.content)<|end_message|>" }.joined()
        case .gemma4:
            turnEnd + "\n" + newUserTurns.map { "<|turn>user\n\(trim($0.content))<turn|>\n" }.joined() + "<|turn>model\n"
        }
    }

    // Inkling 2: no assistant header at the end; the model opens its own message.
    private func inkling(_ messages: [ChatMessage], thinking: Thinking) -> String {
        let effort = "<|message_system|><|content_text|>Thinking effort level: \(thinking.inklingEffort)<|end_message|>"
        var out = ""
        var effortEmitted = false
        for m in messages {
            if !effortEmitted && m.role != .system {
                out += effort
                effortEmitted = true
            }
            switch m.role {
            case .system: out += "<|message_system|><|content_text|>\(m.content)<|end_message|>"
            case .user: out += "<|message_user|><|content_text|>\(m.content)<|end_message|>"
            case .assistant: out += "<|message_model|><|content_text|>\(m.content)<|end_message|>\(turnEnd)"
            }
        }
        return effortEmitted ? out : out + effort
    }

    // Gemma 4: a leading system message is its own turn; the template trims all content.
    private func gemma4(_ messages: [ChatMessage], thinking: Thinking) -> String {
        var out = "<bos>"
        var rest = messages[...]
        let system = messages.first?.role == .system ? messages.first?.content : nil
        if system != nil { rest = rest.dropFirst() }
        if thinking != .off || system != nil {
            out += "<|turn>system\n"
            if thinking != .off { out += "<|think|>\n" }
            out += trim(system ?? "") + "<turn|>\n"
        }
        for m in rest {
            out += "<|turn>\(m.role == .assistant ? "model" : m.role.rawValue)\n\(trim(m.content))<turn|>\n"
        }
        return out + "<|turn>model\n"
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    func makeParser() -> OutputParser { OutputParser(format: format) }
}

/// Sorts the model's output into thinking and answer. Marker tokens arrive as whole pieces, so each
/// can be matched exactly.
struct OutputParser {
    enum Piece { case thinking(String), text(String) }

    private let format: ChatTemplate.Format
    private var inThinking = false
    /// Gemma writes "<|channel>thought\n" before its thinking; this is what's left to skip.
    private var skip = Substring()

    init(format: ChatTemplate.Format) { self.format = format }

    /// `marker` is a control or user-defined token. Control tokens and `<|…|>`-style markers are
    /// never shown; any other user-defined token is ordinary text in some vocabularies (Gemma's
    /// `<table>`), so it is.
    mutating func consume(_ piece: String, marker: Bool, control: Bool) -> Piece? {
        if marker {
            switch (format, piece) {
            case (.inkling, "<|content_thinking|>"), (.gemma4, "<|channel>"):
                inThinking = true
                if format == .gemma4 { skip = "thought\n" }
                return nil
            case (.inkling, "<|content_text|>"), (.gemma4, "<channel|>"):
                inThinking = false
                skip = ""
                return nil
            default:
                if control || piece.hasPrefix("<|") || piece.hasSuffix("|>") { return nil }
            }
        }
        var text = Substring(piece)
        while let c = skip.first, let t = text.first, c == t {
            skip.removeFirst()
            text.removeFirst()
        }
        if !text.isEmpty { skip = "" }
        if text.isEmpty { return nil }
        return inThinking ? .thinking(String(text)) : .text(String(text))
    }
}

extension LlamaModel {
    /// The raw Jinja template from the GGUF, for checking the hand-written formats against.
    public static func rawTemplate(path: String) -> String? {
        var mp = llama_model_default_params()
        mp.vocab_only = true
        guard let m = llama_model_load_from_file(path, mp) else { return nil }
        defer { llama_model_free(m) }
        return llama_model_chat_template(m, nil).map { String(cString: $0) }
    }
}
