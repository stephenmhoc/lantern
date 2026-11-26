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
        case .gemma4: return "<bos>" + gemmaSystem(system, thinking: thinking)
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
        if m.role == .system { return gemmaSystem(m, thinking: .off) }
        // A reply that searched: each call and its result, then the answer, all in one model turn.
        let searches = m.role == .assistant ? (m.searches ?? []).map { gemmaCall($0) + gemmaResponse($0) }.joined() : ""
        return "<|turn>\(m.role == .assistant ? "model" : m.role.rawValue)\n\(searches)\(trim(content(m)))<turn|>\n"
    }

    /// The system turn: thinking switch, the prompt, then any tool declarations.
    private func gemmaSystem(_ system: ChatMessage, thinking: Thinking) -> String {
        "<|turn>system\n" + (thinking.isOn ? "<|think|>\n" : "") + trim(system.content)
            + (system.declaresWebSearch ? gemmaWebSearchDeclaration : "") + "<turn|>\n"
    }

    // Gemma 4: a leading system message is its own turn; the template trims all content.
    private func gemma4(_ messages: [ChatMessage], thinking: Thinking) -> String {
        var out = "<bos>"
        var rest = messages[...]
        if let system = messages.first, system.role == .system {
            rest = rest.dropFirst()
            out += gemmaSystem(system, thinking: thinking)
        } else if thinking.isOn {
            out += "<|turn>system\n<|think|>\n<turn|>\n"
        }
        return out + rest.map(gemmaTurn).joined() + "<|turn>model\n"
    }

    /// Gemma's own quote token: strings in declarations, calls and results are wrapped in it.
    private static let q = "<|\"|>"

    /// `web_search` as the template's `format_function_declaration` writes it.
    private var gemmaWebSearchDeclaration: String {
        let q = Self.q
        return "<|tool>declaration:\(WebSearch.toolName){description:\(q)\(WebSearch.toolDescription)\(q)"
            + ",parameters:{properties:{query:{description:\(q)\(WebSearch.queryDescription)\(q),type:\(q)STRING\(q)}"
            + ",topic:{description:\(q)\(WebSearch.topicDescription)\(q),enum:["
            + WebSearch.topics.map { "\(q)\($0)\(q)" }.joined(separator: ",") + "],type:\(q)STRING\(q)}}"
            + ",required:[\(q)query\(q)],type:\(q)OBJECT\(q)}}<tool|>"
    }

    /// Arguments in the order the declaration lists them, as the template writes a call.
    private func gemmaCall(_ search: WebSearch) -> String {
        let topic = search.topic.map { ",topic:\(Self.q)\($0)\(Self.q)" } ?? ""
        return "<|tool_call>call:\(WebSearch.toolName){query:\(Self.q)\(search.query)\(Self.q)\(topic)}<tool_call|>"
    }

    private func gemmaResponse(_ search: WebSearch) -> String {
        "<|tool_response>response:\(WebSearch.toolName){value:\(Self.q)\(Self.unquoted(search.modelText))\(Self.q)}<tool_response|>"
    }

    /// Search results are web text: anything in them that reads as the template's own markup is
    /// taken out, so a page can't close the result early or open a turn.
    private static func unquoted(_ text: String) -> String {
        var out = text
        for marker in ["<|\"|>", "<|tool_response>", "<tool_response|>", "<|turn>", "<turn|>", "<|im_start|>", "<|im_end|>",
                       "<tool_response>", "</tool_response>", "<tool_call>", "</tool_call>", "<|tool_call>", "<tool_call|>"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out
    }

    /// Qwen 3.5 (ChatML): every content trimmed; a past reply is just its answer (the template
    /// drops the thinking of replies before the last question, and Lantern's messages always end
    /// with one), after any searches it ran, each its own call and result turns. No BOS.
    private func qwenTurn(_ m: ChatMessage) -> String {
        if m.role == .system, m.declaresWebSearch {
            let prompt = trim(m.content)
            return "<|im_start|>system\n" + qwenWebSearchDeclaration + (prompt.isEmpty ? "" : "\n\n" + prompt) + "<|im_end|>\n"
        }
        let searches = m.role == .assistant ? (m.searches ?? []).map {
            "<|im_start|>assistant\n" + qwenCall($0) + "<|im_end|>\n" + qwenResponseTurn($0)
        }.joined() : ""
        return searches + "<|im_start|>\(m.role.rawValue)\n\(trim(m.content))<|im_end|>\n"
    }

    /// The tools block Qwen's template opens the system turn with, `web_search` as `tojson` writes it.
    private var qwenWebSearchDeclaration: String {
        func json(_ s: String) -> String {
            String(decoding: try! JSONEncoder().encode(s), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        }
        let tool = "{\"type\": \"function\", \"function\": {\"name\": \(json(WebSearch.toolName)), \"description\": \(json(WebSearch.toolDescription)), "
            + "\"parameters\": {\"type\": \"object\", \"properties\": {\"query\": {\"type\": \"string\", \"description\": \(json(WebSearch.queryDescription))}, "
            + "\"topic\": {\"type\": \"string\", \"enum\": [" + WebSearch.topics.map(json).joined(separator: ", ")
            + "], \"description\": \(json(WebSearch.topicDescription))}}, "
            + "\"required\": [\"query\"]}}}"
        return "# Tools\n\nYou have access to the following functions:\n\n<tools>\n" + tool + "\n</tools>"
            + "\n\nIf you choose to call a function ONLY reply in the following format with NO suffix:\n\n<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n</parameter>\n<parameter=example_parameter_2>\nThis is the value for the second parameter\nthat can span\nmultiple lines\n</parameter>\n</function>\n</tool_call>\n\n<IMPORTANT>\nReminder:\n- Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags\n- Required parameters MUST be specified\n- You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after\n- If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls\n</IMPORTANT>"
    }

    private func qwenCall(_ search: WebSearch) -> String {
        let topic = search.topic.map { "<parameter=topic>\n\($0)\n</parameter>\n" } ?? ""
        return "<tool_call>\n<function=\(WebSearch.toolName)>\n<parameter=query>\n\(search.query)\n</parameter>\n"
            + topic + "</function>\n</tool_call>"
    }

    /// A search's result, as the user turn the template wraps tool results in.
    private func qwenResponseTurn(_ search: WebSearch) -> String {
        "<|im_start|>user\n<tool_response>\n\(trim(Self.unquoted(search.modelText)))\n</tool_response><|im_end|>\n"
    }

    /// Qwen 3.5 thinks only when asked (`enable_thinking`); otherwise the prompt closes an empty
    /// think block for it.
    private func qwenGenerationPrompt(_ thinking: Thinking) -> String {
        "<|im_start|>assistant\n" + (thinking.isOn ? "<think>\n" : "<think>\n\n</think>\n\n")
    }

    private func qwen35(_ messages: [ChatMessage], thinking: Thinking) -> String {
        messages.map(qwenTurn).joined() + qwenGenerationPrompt(thinking)
    }

    // MARK: - Tool calls while generating

    /// The tokens that open and close a tool call in the model's output.
    var toolCallStart: String { format == .gemma4 ? "<|tool_call>" : "<tool_call>" }
    var toolCallEnd: String { format == .gemma4 ? "<tool_call|>" : "</tool_call>" }

    /// The search query in a call's text (what came between `toolCallStart` and `toolCallEnd`), or
    /// nil if it isn't a `web_search` call with one.
    func searchQuery(inCall text: String) -> String? {
        let query: Substring?
        switch format {
        case .gemma4:
            // call:web_search{query:<|"|>…<|"|>}
            guard text.contains("call:\(WebSearch.toolName)") else { return nil }
            query = text.firstMatch(of: /query:<\|"\|>(?<q>[\s\S]*?)<\|"\|>/)?.output.q
                ?? text.firstMatch(of: /query:"(?<q>[^"]*)"/)?.output.q
        case .qwen35:
            // <function=web_search> <parameter=query> … </parameter>
            guard text.contains("<function=\(WebSearch.toolName)>") else { return nil }
            query = text.firstMatch(of: /<parameter=query>(?<q>[\s\S]*?)<\/parameter>/)?.output.q
        }
        let trimmed = query.map { trim(String($0)) } ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The topic a `web_search` call asked for, as written ("news", "general"), or nil if none.
    func searchTopic(inCall text: String) -> String? {
        let topic: Substring? = switch format {
        case .gemma4:
            text.firstMatch(of: /topic:<\|"\|>(?<t>[\s\S]*?)<\|"\|>/)?.output.t
                ?? text.firstMatch(of: /topic:"(?<t>[^"]*)"/)?.output.t
        case .qwen35:
            text.firstMatch(of: /<parameter=topic>(?<t>[\s\S]*?)<\/parameter>/)?.output.t
        }
        let trimmed = topic.map { trim(String($0)) } ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What follows a finished call (the model's output ends with `toolCallEnd`): the result, then
    /// whatever lets the model carry on with its reply. Gemma continues the same turn (into a
    /// fresh thought when thinking); Qwen closes its turn, gets the result as a user turn and
    /// starts a new reply, as its template renders tool results.
    func renderToolResult(_ search: WebSearch, thinking: Thinking) -> String {
        switch format {
        case .gemma4: gemmaResponse(search) + (thinking.isOn ? "<|channel>thought\n" : "")
        case .qwen35: "<|im_end|>\n" + qwenResponseTurn(search) + qwenGenerationPrompt(thinking)
        }
    }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    func makeParser(thinking: Thinking) -> OutputParser {
        // Qwen's prompt opens the think block itself, so its output starts inside it.
        OutputParser(format: format, thinking: format == .qwen35 && thinking.isOn)
    }

    /// The parser for the model's output after a tool result (`renderToolResult`), which opens a
    /// thought for it when thinking.
    func makeParserAfterToolResult(thinking: Thinking) -> OutputParser {
        OutputParser(format: format, thinking: thinking.isOn)
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
