import Foundation
import LlamaKit

/// What Lantern says to the bridge on the serving Mac (`Bridge/`, `lantern-bridge`; see its README):
/// the OpenAI API (`/v1/models`, streamed `/v1/chat/completions`) passed to Splash, which serves
/// Inkling, plus the bridge's own `/lantern/v1/…` (pairing, its info).
nonisolated enum BridgeAPI {
    // MARK: Models

    struct ModelList: Decodable { let data: [Model] }

    struct Model: Decodable, Sendable {
        struct Info: Decodable, Sendable {
            let backend_name: String?
            let vision: Bool?
            let tools: Bool?
            let thinking: Bool?
            let context_length: Int?
        }
        let id: String
        let lantern: Info?

        /// "vision", "tools", "thinking", as the bridge lists them.
        var capabilities: Set<String> {
            var set: Set<String> = []
            if lantern?.vision == true { set.insert("vision") }
            if lantern?.tools == true { set.insert("tools") }
            if lantern?.thinking == true { set.insert("thinking") }
            return set
        }
    }

    struct Info: Decodable, Sendable {
        struct Splash: Decodable, Sendable { let state: String?; let message: String?; let version: String? }
        let name: String
        let version: String
        let splash: Splash?
    }

    /// Both ways of pairing answer with this (`proof` only for a typed code).
    struct Paired: Decodable {
        struct Tailnet: Decodable {
            /// "ok", "not_configured" or "failed".
            let status: String
            let message: String?
            let auth_key: String?
            let address: String?
        }
        let token: String
        let name: String?
        let proof: String?
        let addresses: [String]?
        let tailnet: Tailnet?
    }

    /// An error as the OpenAI API (and the bridge) word them.
    struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String? }
        let detail: Detail?
        let text: String?
        enum CodingKeys: String, CodingKey { case error }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            detail = try? c.decode(Detail.self, forKey: .error)
            text = try? c.decode(String.self, forKey: .error)
        }
        var message: String? { detail?.message ?? text }
    }

    // MARK: A chat completion

    struct Request: Encodable {
        let model: String
        let messages: [Message]
        var stream = true
        var stream_options = ["include_usage": true]
        /// "high" or "none" (which the bridge makes Splash's "minimal"); left out for a model that doesn't think.
        var reasoning_effort: String?
        var tools: [Tool]?
        var max_tokens: Int?
    }

    struct Message: Encodable {
        let role: String
        var content: Content?
        var tool_calls: [Call]?
        var tool_call_id: String?
    }

    /// Text, or text and images as parts (`image_url` with a data URL).
    enum Content: Encodable {
        case text(String)
        case parts([Part])

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .parts(let p): try c.encode(p)
            }
        }
    }

    struct Part: Encodable {
        struct ImageURL: Encodable { let url: String }
        let type: String
        var text: String?
        var image_url: ImageURL?
    }

    struct Call: Encodable {
        struct Function: Encodable { let name: String; let arguments: String }
        let id: String
        var type = "function"
        let function: Function
    }

    struct Tool: Encodable {
        struct Function: Encodable {
            struct Parameters: Encodable {
                struct Property: Encodable { let type: String; var `enum`: [String]? = nil; let description: String }
                var type = "object"
                let properties: [String: Property]
                let required: [String]
            }
            let name: String
            let description: String
            let parameters: Parameters
        }
        var type = "function"
        let function: Function

        static let webSearch = Tool(function: .init(
            name: WebSearch.toolName, description: WebSearch.toolDescription,
            parameters: .init(
                properties: [
                    "query": .init(type: "string", description: WebSearch.queryDescription),
                    "topic": .init(type: "string", enum: WebSearch.topics, description: WebSearch.topicDescription),
                ],
                required: ["query"])))
    }

    // MARK: Its stream

    /// One `data:` line of the stream.
    struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct CallDelta: Decodable {
                    struct Function: Decodable { let name: String?; let arguments: String? }
                    let index: Int?
                    let id: String?
                    let function: Function?
                }
                let content: String?
                /// Splash's thinking (`reasoning` is the same under another server's name).
                let reasoning_content: String?
                let reasoning: String?
                let tool_calls: [CallDelta]?
            }
            let delta: Delta?
            let finish_reason: String?
        }
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        let choices: [Choice]?
        let usage: Usage?
        let error: ErrorBody.Detail?
    }

    /// A tool call as it arrives in pieces: its id and name first, its arguments a bit at a time.
    struct PendingCall {
        var id = ""
        var name = ""
        var arguments = ""

        /// The search it asks for, or nil if it isn't a usable `web_search` call.
        var search: WebSearch? {
            guard name == WebSearch.toolName,
                  let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
                  let query = (object["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty
            else { return nil }
            let topic = (object["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return WebSearch(query: query, topic: topic?.isEmpty == false ? topic : nil)
        }
    }

    // MARK: History

    /// The chat as the API's messages: a reply that searched first has each search as a call and
    /// its result, then its answer. Rendered from the stored fields alone, so it's the same each time.
    static func messages(_ history: [ChatMessage]) -> [Message] {
        var calls = 0
        return history.flatMap { m -> [Message] in
            guard m.role == .assistant, let searches = m.searches, !searches.isEmpty else { return [message(m)] }
            let ids = searches.map { _ in calls += 1; return "call_\(calls)" }
            return searchMessages(searches, ids: ids, said: "") + [Message(role: "assistant", content: .text(m.content))]
        }
    }

    static func message(_ m: ChatMessage) -> Message {
        let images = m.images ?? []
        guard !images.isEmpty else { return Message(role: m.role.rawValue, content: .text(m.content)) }
        let parts = [Part(type: "text", text: m.content)]
            + images.map { Part(type: "image_url", image_url: .init(url: "data:image/jpeg;base64,\($0.base64EncodedString())")) }
        return Message(role: m.role.rawValue, content: .parts(parts))
    }

    /// The model's turn that called (anything it said, then its calls), then each result.
    static func searchMessages(_ searches: [WebSearch], ids: [String], said: String) -> [Message] {
        guard !searches.isEmpty else { return [] }
        let calls = zip(searches, ids).map { search, id in
            var arguments = ["query": search.query]
            arguments["topic"] = search.topic
            let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return Call(id: id, function: .init(name: WebSearch.toolName, arguments: json))
        }
        return [Message(role: "assistant", content: said.isEmpty ? nil : .text(said), tool_calls: calls)]
            + zip(searches, ids).map { Message(role: "tool", content: .text($0.modelText), tool_call_id: $1) }
    }
}
