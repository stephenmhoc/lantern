import Foundation

/// What the reply under way is doing, for its cell: a status line with elapsed time, a determinate
/// bar when there's progress to show, and how bright the glow is.
struct ReplyStatus: Equatable {
    var text: String
    var progress: Double?
    var intensity: Double
    var isSlow: Bool
    /// The same for VoiceOver, in words: "Thinking, 12 seconds" rather than "Thinking · 12 s".
    var accessibilityText: String
}

/// Times the thinking, seen from the chat screen's ticks; each phase's own start comes from
/// `LiveReply.phaseStarted`, so a chat reopened part-way through a reply counts from the right time.
struct PhaseClock {
    private(set) var replyID: UUID?
    private(set) var thinkingStarted: Date?
    private(set) var thinkingEnded: Date?

    /// Waiting longer than this with nothing coming in counts as slow. Stopgap until there's a
    /// per-model typical time to first token.
    static let slowAfter: TimeInterval = 20

    /// Notes the live reply's phase now; call on every tick.
    mutating func observe(_ live: LiveReply, now: Date = .now) {
        if replyID != live.id {
            self = PhaseClock()
            replyID = live.id
        }
        if live.phase == .thinking, thinkingStarted == nil { thinkingStarted = live.phaseStarted }
        if live.phase != .thinking, thinkingStarted != nil, thinkingEnded == nil { thinkingEnded = now }
    }

    /// How long the model thought, once it has stopped thinking.
    func thoughtSeconds(now: Date = .now) -> Double? {
        guard let thinkingStarted else { return nil }
        return (thinkingEnded ?? now).timeIntervalSince(thinkingStarted)
    }

    func status(for live: LiveReply, modelName: String?, now: Date = .now) -> ReplyStatus {
        let seconds = max(0, Int(now.timeIntervalSince(live.phaseStarted)))
        // Thinking streams too: only a reply with nothing at all to show yet is slow.
        let slow = live.text.isEmpty && live.thinking.isEmpty && now.timeIntervalSince(live.started) > Self.slowAfter
        let what: String
        var progress: Double?
        let intensity: Double
        var hint: String?
        switch live.phase {
        case .loading(let p):
            what = "Loading \(modelName ?? "the model")"
            progress = p
            intensity = 0.2
        case .waiting:
            what = live.mode == .mac ? "Asking the Mac" : "Reading your question"
            intensity = 0.3
            // Splash keeps Inkling loaded: a long wait is a long chat being read.
            if slow, live.mode == .mac { hint = "The Mac is reading the chat" }
        case .reading(let p):
            what = "Reading the chat"
            progress = p
            intensity = 0.35
        case .thinking:
            what = "Thinking"
            intensity = 0.55
        case .searching(let query):
            what = "Searching the web for “\(query)”"
            intensity = 0.45
        case .answering:
            what = "Writing"
            intensity = 1
        }
        // The bar shows progress; the number says it for anyone who can't judge the bar.
        let percent = progress.map { "\(Int(($0 * 100).rounded()))%" }
        let text = ([what, percent, Self.format(seconds)].compactMap { $0 } + [hint].compactMap { $0 })
            .joined(separator: " · ")
        let spokenPercent = progress.map { "\(Int(($0 * 100).rounded())) percent" }
        let spoken = ([what, spokenPercent, Self.spoken(seconds)].compactMap { $0 } + [hint].compactMap { $0 })
            .joined(separator: ", ")
        return ReplyStatus(text: text, progress: progress, intensity: intensity,
                           isSlow: slow && live.phase != .answering, accessibilityText: spoken)
    }

    static func format(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }

    /// "12 seconds", "1 minute, 5 seconds": "s" alone is read as the letter.
    static func spoken(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds < 60 ? [.second] : [.minute, .second]
        return formatter.string(from: TimeInterval(seconds)) ?? format(seconds)
    }
}

/// The line under an answer: the model that wrote it, and that it was stopped, cut off or had
/// earlier messages left out. Footnotes stored by earlier versions also carry speeds, timings
/// and the route, which are left out when shown.
enum ReplyFootnote {
    static func shown(_ footnote: String) -> String {
        footnote.components(separatedBy: " · ")
            .filter { !$0.contains("tok/s") && !$0.contains("first token") && !$0.hasPrefix("via ") && !$0.hasSuffix(" s") }
            .joined(separator: " · ")
    }
}
