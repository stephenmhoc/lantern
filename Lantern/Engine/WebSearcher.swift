import Foundation
import LlamaKit
import Security

/// Runs the web searches models ask for, with Tavily, straight from this device: any model can
/// use it, wherever the device is, as long as it has the internet. The key is the user's own
/// Tavily API key, kept in the Keychain (Settings > Search the Web).
nonisolated enum WebSearcher {
    /// Whether searching can happen at all: switched on in Settings, with a key.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: Engine.webSearchKey) && apiKey != nil }

    /// Never throws: a failure comes back as the search's `error`, which the model is told, so it
    /// answers from what it knows.
    static func search(
        _ query: String, results limit: Int = WebSearch.resultLimit, excerpt: Int = WebSearch.excerptLimit
    ) async -> WebSearch {
        guard let key = apiKey else { return WebSearch(query: query, error: "There's no Tavily API key in Settings.") }
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(Request(query: query, max_results: limit))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return WebSearch(query: query, error: failure(code: code, body: data)) }
            let found = try JSONDecoder().decode(Response.self, from: data)
            let results = (found.results ?? []).prefix(limit).map {
                WebSearch.Result(title: $0.title ?? $0.url, url: $0.url, content: WebSearch.excerpt($0.content ?? "", limit: excerpt))
            }
            return WebSearch(query: query, results: Array(results))
        } catch let error as URLError {
            let reason = switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: "This device has no internet connection."
            case .timedOut: "The search took too long."
            case .cancelled: "The search was stopped."
            default: "The search service couldn't be reached."
            }
            return WebSearch(query: query, error: reason)
        } catch {
            return WebSearch(query: query, error: "The search came back in a form Lantern can't read.")
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
        var search_depth = "basic"
    }

    private struct Response: Decodable {
        struct Item: Decodable { let title: String?; let url: String; let content: String? }
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
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Saves the key, or removes it when it's empty. It stays on this device: not synced.
    static func setKey(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = baseQuery
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
