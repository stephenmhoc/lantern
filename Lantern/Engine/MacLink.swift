import Foundation
import LlamaKit
import Observation

/// Ollama on the Mac. The home network comes first (it works without the internet); the tailnet is
/// the way in from elsewhere, through Lantern's own tailnet node when signed in, or the Tailscale
/// app's VPN otherwise.
@Observable
final class MacLink {
    enum Route: Hashable {
        case unknown, checking, unreachable
        case lan(String)
        case tailnet(String)

        var label: String {
            switch self {
            case .unknown: "Not checked"
            case .checking: "Checking…"
            case .lan: "Home network"
            case .tailnet: "Tailnet"
            case .unreachable: "Can't reach the Mac"
            }
        }

        var host: String? {
            switch self {
            case .lan(let h), .tailnet(let h): h
            default: nil
            }
        }
    }

    // Settings, edited with @AppStorage in SettingsView.
    static let lanKey = "mac.lan", tailnetKey = "mac.tailnet", modelKey = "mac.model"
    /// The context Ollama is asked for (`options.num_ctx`); its own default is much smaller and
    /// silently drops the start of a long chat.
    static let contextKey = "mac.numCtx"
    static let defaultLAN = "mac-studio.local", defaultContext = 16384

    let tailnet = Tailnet()
    private(set) var route: Route = .unknown
    private(set) var models: [String] = []

    private var defaults: UserDefaults { .standard }
    var modelName: String { defaults.string(forKey: Self.modelKey) ?? "" }
    var contextLength: Int {
        let n = defaults.integer(forKey: Self.contextKey)
        return n > 0 ? n : Self.defaultContext
    }
    /// Models Ollama refused `think` for; they're asked without it from then on.
    @ObservationIgnored private var cannotThink: Set<String> = []

    /// Uses the home network if it answers; only then waits on the tailnet.
    @discardableResult
    func resolve() async -> Route {
        route = .checking
        let lan = Self.normalized(defaults.string(forKey: Self.lanKey) ?? Self.defaultLAN)
        let tail = Self.normalized(defaults.string(forKey: Self.tailnetKey) ?? "")
        async let tailTags = Self.tags(tail, session: tailnet.session ?? .shared)
        if let lan, let l = await Self.tags(lan) {
            route = .lan(lan)
            models = l
        } else if let tail, let t = await tailTags {
            route = .tailnet(tail)
            models = t
        } else {
            route = .unreachable
            models = []
        }
        if !models.isEmpty, !models.contains(modelName) {
            let pick = models.first { $0.localizedCaseInsensitiveContains("inkling") } ?? models[0]
            defaults.set(pick, forKey: Self.modelKey)
        }
        return route
    }

    static func normalized(_ host: String) -> String? {
        var h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return nil }
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if !h.contains(":") { h += ":11434" }
        return h
    }

    /// The model names Ollama has, or nil if the host doesn't answer.
    static func tags(_ host: String?, session: URLSession = .shared) async -> [String]? {
        guard let host, let url = URL(string: "http://\(host)/api/tags") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONDecoder().decode(TagList.self, from: data) else { return nil }
        return list.models.map(\.name)
    }

    /// Stops when the reading task is cancelled. A route that has gone stale (left home, Wi-Fi
    /// dropped) gets one fresh check and retry before giving up.
    func stream(_ messages: [ChatMessage], thinking: Thinking) async throws -> AsyncThrowingStream<Generation, Error> {
        if route.host == nil { await resolve() }
        let (bytes, _) = try await open(messages, thinking: thinking, retry: true)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: Data(line.utf8)) else { continue }
                        if let error = chunk.error { throw MacError.ollama(error) }
                        if let t = chunk.message?.thinking, !t.isEmpty { continuation.yield(.thinking(t)) }
                        if let t = chunk.message?.content, !t.isEmpty { continuation.yield(.text(t)) }
                        if chunk.done == true {
                            var stats = GenerationStats()
                            stats.promptTokens = chunk.prompt_eval_count ?? 0
                            stats.promptSeconds = Double(chunk.prompt_eval_duration ?? 0) / 1e9
                            stats.generatedTokens = chunk.eval_count ?? 0
                            stats.generateSeconds = Double(chunk.eval_duration ?? 0) / 1e9
                            continuation.yield(.done(stats))
                        }
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish()  // Stop, not a failure
                } catch {
                    if error is URLError { route = .unknown }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func open(
        _ messages: [ChatMessage], thinking: Thinking, retry: Bool
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        guard let host = route.host, let url = URL(string: "http://\(host)/api/chat") else { throw MacError.unreachable }
        guard !modelName.isEmpty else { throw MacError.noModel }
        var request = URLRequest(url: url, timeoutInterval: 120)  // between bytes, not overall
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let model = modelName
        // Sent even when off, or a thinking model thinks anyway; left out for models that reject it.
        let think: Bool? = cannotThink.contains(model) ? nil : thinking != .off
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: true,
            think: think,
            options: .init(num_ctx: contextLength)
        ))
        do {
            let session: URLSession = if case .tailnet = route { tailnet.session ?? .shared } else { .shared }
            let (bytes, response) = try await session.bytes(for: request)
            guard let code = (response as? HTTPURLResponse)?.statusCode, code == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // Ollama explains itself in a small JSON body.
                var body = Data()
                for try await byte in bytes.prefix(4096) { body.append(byte) }
                let message = (try? JSONDecoder().decode(ChatChunk.self, from: body))?.error
                if code == 400, think != nil, message?.localizedCaseInsensitiveContains("think") == true {
                    cannotThink.insert(model)  // not a thinking model: ask again without it, once
                    return try await open(messages, thinking: thinking, retry: retry)
                }
                throw MacError.http(code, model: model, message: message)
            }
            return (bytes, response)
        } catch let error as URLError where error.code != .cancelled && retry {
            await resolve()
            return try await open(messages, thinking: thinking, retry: false)
        }
    }

    private struct TagList: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Options: Encodable { let num_ctx: Int }
        let model: String
        let messages: [Message]
        let stream: Bool
        let think: Bool?  // left out when nil
        let options: Options
    }

    private struct ChatChunk: Decodable {
        struct Message: Decodable { let content: String?; let thinking: String? }
        let message: Message?
        let done: Bool?
        let error: String?
        let prompt_eval_count: Int?
        let prompt_eval_duration: Int64?
        let eval_count: Int?
        let eval_duration: Int64?
    }
}

nonisolated enum MacError: LocalizedError {
    case unreachable, noModel, http(Int, model: String, message: String?), ollama(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: "Can't reach Ollama on the Mac over the home network or the tailnet."
        case .noModel: "Ollama on the Mac has no models."
        case .http(404, let model, _):
            "The Mac doesn't have the model \(model) any more. Pick another in Settings, or pull it in Ollama."
        case .http(400, _, let message): "Ollama couldn't use this request: \(message ?? "bad request")."
        case .http(401, _, _), .http(403, _, _): "Ollama on the Mac refused the connection. Check that it allows this device."
        case .http(429, _, _), .http(503, _, _): "Ollama on the Mac is busy. Try again in a moment."
        case .http(let code, let model, let message) where code >= 500:
            "Ollama on the Mac failed to run \(model)\(message.map { ": \($0)" } ?? " (HTTP \(code))"). It may be out of memory."
        case .http(let code, _, let message): "Ollama answered with HTTP \(code)\(message.map { ": \($0)" } ?? "")."
        case .ollama(let message): "Ollama: \(message)"
        }
    }

    var kind: ReplyErrorKind {
        switch self {
        case .unreachable: .macUnreachable
        case .noModel, .http(404, _, _): .macNoModel
        case .http, .ollama: .macFailed
        }
    }
}
