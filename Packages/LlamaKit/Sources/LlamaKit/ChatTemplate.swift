import Foundation
import llama

/// Whether a reasoning model thinks before answering. Gemma 4 and Qwen 3.5 only have thinking on or
/// off, so `low` and `high` both mean on; the cases stay because chats store them.
public enum Thinking: String, Sendable, CaseIterable, Codable {
    case off, low, high

    var isOn: Bool { self != .off }
}

/// Turns messages into a prompt, and the model's raw tokens back into thinking and answer text.
/// llama.cpp's C helper has no Jinja engine, so the models Lantern ships are written out here from
/// the Jinja in their GGUFs (`lantern-smoke <file> --template` prints it).
struct ChatTemplate {
    enum Format: String { case gemma4, qwen35 }

    let format: Format

    /// Nil for any model whose template isn't one of these.
    init?(model: OpaquePointer) {
        guard let raw = llama_model_chat_template(model, nil).map({ String(cString: $0) }) else { return nil }
        if raw.contains("<|turn>") {
            format = .gemma4
        } else if raw.contains("<|im_start|>"), raw.contains("<think>") {
            format = .qwen35
        } else {
            return nil
        }
    }

    /// The end-of-generation token that closes a model turn the way the template does. A reply that
    /// ends on any other (e.g. Gemma's `<eos>`) can't be continued token-for-token.
    var turnEnd: String {
        switch format {
        case .gemma4: "<turn|>"
        case .qwen35: "<|im_end|>"
        }
    }

    func render(_ messages: [ChatMessage], thinking: Thinking) -> String {
        switch format {
        case .gemma4: gemma4(messages, thinking: thinking)
        case .qwen35: qwen35(messages, thinking: thinking)
        }
    }

    /// Whether a cache built with `old` can be extended for a request with `new`, token-for-token
    /// what a full render would give. Gemma's template drops earlier thinking from past turns, so a
    /// cache holding it no longer matches once thinking is on; Gemma can rewind, so it re-renders.
    /// Qwen's template drops it too, but Qwen can't rewind: re-rendering would mean reading the
    /// whole chat again, so its cache keeps each reply as it was streamed (thinking included) and
    /// only turns are appended. A full render happens only without a cache or saved state, or when
    /// the kept thinking has filled the context.
    func canContinue(from old: Thinking, to new: Thinking) -> Bool {
        switch format {
        case .gemma4: !old.isOn && !new.isOn
        case .qwen35: true  // thinking only changes the generation prompt, which comes after
        }
    }

    /// The text that follows a reply the model closed with `turnEnd` (not yet in the cache), through
    /// the next generation prompt. The turns are rendered as a full render would: user turns, and on
    /// a model that can't rewind, earlier replies (a stopped answer) as history.
    func renderContinuation(_ turns: [ChatMessage], thinking: Thinking) -> String {
        switch format {
        case .gemma4:
            turnEnd + "\n" + turns.map(gemmaTurn).joined() + "<|turn>model\n"
        case .qwen35:
            turnEnd + "\n" + turns.map(qwenTurn).joined() + qwenGenerationPrompt(thinking)
        }
    }

    /// The start of a full render up to the end of a leading system message: the part every chat
    /// with the same system prompt shares. Nil if there's no system message.
    func renderSystemPrefix(_ messages: [ChatMessage], thinking: Thinking) -> String? {
        guard let system = messages.first, system.role == .system else { return nil }
        switch format {
        case .gemma4: return "<bos><|turn>system\n" + (thinking.isOn ? "<|think|>\n" : "") + trim(system.content) + "<turn|>\n"
        case .qwen35: return qwenTurn(system)
        }
    }

    /// Replaced by an image's tokens when a prompt with images is tokenized (`mtmd_default_marker`).
    static let mediaMarker = "<__media__>"

    /// A turn's text with a media marker per image in front, as llama-server places them. A turn
    /// without images is just its content, so text-only prompts are unchanged.
    private func content(_ m: ChatMessage) -> String {
        (m.images ?? []).map { _ in Self.mediaMarker + "\n" }.joined() + m.content
    }

    private func gemmaTurn(_ m: ChatMessage) -> String {
        "<|turn>\(m.role == .assistant ? "model" : m.role.rawValue)\n\(trim(content(m)))<turn|>\n"
    }

    // Gemma 4: a leading system message is its own turn; the template trims all content.
    private func gemma4(_ messages: [ChatMessage], thinking: Thinking) -> String {
        var out = "<bos>"
        var rest = messages[...]
        let system = messages.first?.role == .system ? messages.first?.content : nil
        if system != nil { rest = rest.dropFirst() }
        if thinking.isOn || system != nil {
            out += "<|turn>system\n"
            if thinking.isOn { out += "<|think|>\n" }
            out += trim(system ?? "") + "<turn|>\n"
        }
        return out + rest.map(gemmaTurn).joined() + "<|turn>model\n"
    }

    /// Qwen 3.5 (ChatML), without tools: every content trimmed; a past reply is just its answer
    /// (the template drops the thinking of replies before the last question, and Lantern's
    /// messages always end with one). No BOS.
    private func qwenTurn(_ m: ChatMessage) -> String {
        "<|im_start|>\(m.role.rawValue)\n\(trim(m.content))<|im_end|>\n"
    }

    /// Qwen 3.5 thinks only when asked (`enable_thinking`); otherwise the prompt closes an empty
    /// think block for it.
    private func qwenGenerationPrompt(_ thinking: Thinking) -> String {
        "<|im_start|>assistant\n" + (thinking.isOn ? "<think>\n" : "<think>\n\n</think>\n\n")
    }

    private func qwen35(_ messages: [ChatMessage], thinking: Thinking) -> String {
        messages.map(qwenTurn).joined() + qwenGenerationPrompt(thinking)
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    func makeParser(thinking: Thinking) -> OutputParser {
        // Qwen's prompt opens the think block itself, so its output starts inside it.
        OutputParser(format: format, thinking: format == .qwen35 && thinking.isOn)
    }
}

/// Sorts the model's output into thinking and answer. Marker tokens arrive as whole pieces, so each
/// can be matched exactly.
struct OutputParser {
    enum Piece { case thinking(String), text(String) }

    private let format: ChatTemplate.Format
    private var inThinking: Bool
    /// What a marker is followed by that isn't part of either channel (Gemma's "thought\n" after
    /// `<|channel>`, Qwen's blank line after `</think>`); this is what's left to skip.
    private var skip = Substring()

    init(format: ChatTemplate.Format, thinking: Bool = false) {
        self.format = format
        inThinking = thinking
    }

    /// `marker` is a control or user-defined token. Control tokens and `<|…|>`-style markers are
    /// never shown; any other user-defined token is ordinary text in some vocabularies (Gemma's
    /// `<table>`), so it is.
    mutating func consume(_ piece: String, marker: Bool, control: Bool) -> Piece? {
        if marker {
            switch (format, piece) {
            case (.gemma4, "<|channel>"):
                inThinking = true
                skip = "thought\n"
                return nil
            case (.qwen35, "<think>"):
                inThinking = true
                skip = "\n"
                return nil
            case (.gemma4, "<channel|>"):
                inThinking = false
                skip = ""
                return nil
            case (.qwen35, "</think>"):
                inThinking = false
                skip = "\n\n"
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

    /// The hand-written template's full render of `messages` and its system prefix, for checking
    /// against the model's Jinja (`lantern-smoke <file> --render`). Nil if the format is unknown.
    public static func renderedPrompt(
        path: String, _ messages: [ChatMessage], thinking: Thinking
    ) -> (prompt: String, systemPrefix: String?)? {
        var mp = llama_model_default_params()
        mp.vocab_only = true
        guard let m = llama_model_load_from_file(path, mp) else { return nil }
        defer { llama_model_free(m) }
        guard let template = ChatTemplate(model: m) else { return nil }
        return (template.render(messages, thinking: thinking), template.renderSystemPrefix(messages, thinking: thinking))
    }
}
