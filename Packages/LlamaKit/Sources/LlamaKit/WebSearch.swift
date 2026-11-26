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
        /// When the page was published, as "Nov 25, 2026": news searches have it, others usually
        /// don't. Nil for searches from before it was kept.
        public var published: String?
        public init(title: String, url: String, content: String, published: String? = nil) {
            self.title = title
            self.url = url
            self.content = content
            self.published = published
        }
    }

    public var query: String
    /// The topic the model asked for, exactly as it wrote it ("news" or "general"), or nil when
    /// it gave none. Kept as written so the call renders back as it was streamed.
    public var topic: String?
    public var results: [Result]
    /// Why there are no results: no internet, not signed in… Nil when the search ran.
    public var error: String?

    public init(query: String, topic: String? = nil, results: [Result] = [], error: String? = nil) {
        self.query = query
        self.topic = topic
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
    /// Without it, a search for "today's sports news" found topic pages and archived copies years
    /// old: the web's general index doesn't favour what's new. The news index does, with dates.
    public static let topicDescription = """
        news for current events, sports, scores, weather, markets and anything else from the last \
        few days, so the results are recent and dated; general (the default) for everything else.
        """
    public static let topics = ["general", "news"]
    /// Whether this search asked for the news index.
    public var wantsNews: Bool { topic?.lowercased() == "news" }
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
            "[\(i + 1)] \(r.title)\n\(r.url)\n" + (r.published.map { "Published \($0)\n" } ?? "") + r.content
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same search cut down to fit a small context: the first `results` results, each
    /// excerpt to `excerpt` characters. On device, five long excerpts would fill the chat.
    public func trimmed(results limit: Int, excerpt: Int) -> WebSearch {
        var copy = self
        copy.results = results.prefix(limit).map {
            Result(title: $0.title, url: $0.url, content: Self.excerpt($0.content, limit: excerpt), published: $0.published)
        }
        return copy
    }

    /// A page's date as Tavily gives it ("Wed, 25 Nov 2026 21:56:57 GMT") as a day: "Nov 25, 2026".
    public static func day(fromHTTPDate text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "GMT")
        parse.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = parse.date(from: text) else { return nil }
        let show = DateFormatter()
        show.locale = Locale(identifier: "en_US_POSIX")
        show.timeZone = TimeZone(identifier: "GMT")
        show.dateFormat = "MMM d, yyyy"
        return show.string(from: date)
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
