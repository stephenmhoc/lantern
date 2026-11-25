import Foundation

/// One web search a model ran while answering: what it asked for and what came back, or why it
/// failed. Stored with the reply and sent back with the history, so what the model is shown
/// (`modelText`) comes from these fields alone and reads the same every time.
public struct WebSearch: Sendable, Hashable, Codable {
    public struct Result: Sendable, Hashable, Codable {
        public var title: String
        public var url: String
        /// An excerpt of the page, trimmed to `excerptLimit` characters.
        public var content: String
        public init(title: String, url: String, content: String) {
            self.title = title
            self.url = url
            self.content = content
        }
    }

    public var query: String
    public var results: [Result]
    /// Why there are no results: no internet, not signed in… Nil when the search ran.
    public var error: String?

    public init(query: String, results: [Result] = [], error: String? = nil) {
        self.query = query
        self.results = results
        self.error = error
    }

    /// The tool's name, as the model calls it.
    public static let toolName = "web_search"
    /// What the model is told the tool does. A model calls it on its own judgement.
    public static let toolDescription = """
        Search the web for current or specific information you don't know: news, prices, \
        schedules, recent releases, facts about a particular person, place or product. \
        Returns the top results with an excerpt of each page.
        """
    public static let queryDescription = "What to search for, as you'd type it into a search engine."
    /// Results kept per search, and characters kept of each page: five excerpts fit easily in the
    /// context with the rest of the chat.
    public static let resultLimit = 5
    public static let excerptLimit = 1500

    /// The tool's result as the model reads it: numbered results with their addresses (so it can
    /// cite them), or the failure, worded so it still answers.
    public var modelText: String {
        if let error {
            return "The search failed: \(error) Answer from what you already know, and say that you couldn't search."
        }
        if results.isEmpty { return "No results." }
        return results.enumerated().map { i, r in
            "[\(i + 1)] \(r.title)\n\(r.url)\n\(r.content)"
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same search cut down to fit a small context: the first `results` results, each
    /// excerpt to `excerpt` characters. On device, five long excerpts would fill the chat.
    public func trimmed(results limit: Int, excerpt: Int) -> WebSearch {
        var copy = self
        copy.results = results.prefix(limit).map {
            Result(title: $0.title, url: $0.url, content: Self.excerpt($0.content, limit: excerpt))
        }
        return copy
    }

    /// `text` cut at a word boundary to `limit` characters, with an ellipsis when cut.
    public static func excerpt(_ text: String, limit: Int = excerptLimit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.prefix(limit)
        let end = cut.lastIndex(where: \.isWhitespace) ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
