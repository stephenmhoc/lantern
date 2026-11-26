import Foundation
import LlamaKit
import Security

/// Runs the web searches models ask for, with Tavily, straight from this device: any model can
/// use it, wherever the device is, as long as it has the internet. The key is the user's own
/// Tavily API key, kept in the Keychain (Settings). Whether a chat searches is the chat's own
/// switch (`Conversation.webSearch`).
nonisolated enum WebSearcher {
    /// Whether searching can happen at all: there's a key.
    static var hasKey: Bool { apiKey != nil }

    /// Never throws: a failure comes back as the search's `error`, which the model is told, so it
    /// answers from what it knows.
    /// `topic` is what the model asked for: "news" searches Tavily's news index, which favours
    /// recent pages and dates them; anything else the whole web. It's kept on the result as given.
    static func search(
        _ query: String, topic: String? = nil, results limit: Int = WebSearch.resultLimit, excerpt: Int = WebSearch.excerptLimit
    ) async -> WebSearch {
        let asked = WebSearch(query: query, topic: topic)
        func failed(_ reason: String) -> WebSearch { WebSearch(query: query, topic: topic, error: reason) }
        guard let key = apiKey else { return failed("There's no Tavily API key in Settings.") }
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(Request(query: query, max_results: limit, topic: asked.wantsNews ? "news" : "general"))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return failed(failure(code: code, body: data)) }
            let found = try JSONDecoder().decode(Response.self, from: data)
            let results = (found.results ?? []).prefix(limit).map {
                WebSearch.Result(
                    title: $0.title ?? $0.url, url: $0.url, content: WebSearch.excerpt($0.content ?? "", limit: excerpt),
                    published: WebSearch.day(fromHTTPDate: $0.published_date))
            }
            return WebSearch(query: query, topic: topic, results: Array(results))
        } catch let error as URLError {
            let reason = switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: "This device has no internet connection."
            case .timedOut: "The search took too long."
            case .cancelled: "The search was stopped."
            default: "The search service couldn't be reached."
            }
            return failed(reason)
        } catch {
            return failed("The search came back in a form Lantern can't read.")
        }
    }

    static func failure(code: Int, body: Data) -> String {
        switch code {
        case 401, 403: return "Tavily didn't accept the API key in Settings."
        case 429: return "Too many searches at once. Try again in a moment."
        case 432, 433: return "The Tavily account has used up its searches for now."
        default:
            // Tavily explains itself as {"detail": {"error": "…"}}.
            let detail = (try? JSONDecoder().decode(Failure.self, from: body))?.detail?.error
            return "The search failed\(detail.map { ": \($0)" } ?? " (HTTP \(code))")."
        }
    }

    private struct Request: Encodable {
        let query: String
        let max_results: Int
        let topic: String
        var search_depth = "basic"
    }

    private struct Response: Decodable {
        struct Item: Decodable { let title: String?; let url: String; let content: String?; let published_date: String? }
        let results: [Item]?
    }

    private struct Failure: Decodable {
        struct Detail: Decodable { let error: String? }
        let detail: Detail?
    }

    // MARK: - The key

    private static let account = "tavily"
    private static let service = "com.merimerimeri.Lantern.webSearch"

    /// The Tavily API key from the Keychain. A Debug build falls back to `TAVILY_API_KEY` in its
    /// environment (`SIMCTL_CHILD_TAVILY_API_KEY` for the simulator), so tests need no key on disk.
    static var apiKey: String? {
        if let stored = storedKey { return stored }
        #if DEBUG
        if let key = ProcessInfo.processInfo.environment["TAVILY_API_KEY"], !key.isEmpty { return key }
        #endif
        return nil
    }

    /// The key saved in Settings, if any (not the Debug fallback).
    static var storedKey: String? {
        Keychain.read(service: service, account: account).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves the key, or removes it when it's empty. It stays on this device: not synced.
    static func setKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(service: service, account: account)
        } else {
            Keychain.write(trimmed, service: service, account: account)
        }
    }
}
