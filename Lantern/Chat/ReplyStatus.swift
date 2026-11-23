import Foundation

/// What the reply under way is doing, for its cell: a status line with elapsed time, a determinate
/// bar when there's progress to show, and how bright the glow is.
struct ReplyStatus: Equatable {
    var text: String
    var progress: Double?
    var intensity: Double
    var isSlow: Bool
}

/// Times each phase of the live reply and the thinking, seen from the chat screen's ticks.
///
/// Stopgap: `LiveReply` will carry its own phase start time and time to first token. When it does,
/// read those here instead and drop the bookkeeping; the cell only sees `ReplyStatus`.
struct PhaseClock {
    private(set) var replyID: UUID?
    private var phaseKind: Int?
    private var phaseStarted = Date()
    private(set) var thinkingStarted: Date?
    private(set) var thinkingEnded: Date?

    /// Waiting longer than this with no text counts as slow. Stopgap until there's a per-model
    /// typical time to first token.
    static let slowAfter: TimeInterval = 20

    private static func kind(_ phase: LiveReply.Phase) -> Int {
        switch phase {
        case .loading: 0
        case .waiting: 1
        case .reading: 2
        case .thinking: 3
        case .answering: 4
        }
    }

    /// Notes the live reply's phase now; call on every tick.
    mutating func observe(_ live: LiveReply, now: Date = .now) {
        if replyID != live.id {
            self = PhaseClock()
            replyID = live.id
            // Seeing a reply for the first time part-way (the chat was reopened): count from its start.
            phaseStarted = live.started
        }
        let kind = Self.kind(live.phase)
        if kind != phaseKind {
            if phaseKind != nil { phaseStarted = now }
            phaseKind = kind
        }
        if live.phase == .thinking, thinkingStarted == nil { thinkingStarted = phaseStarted }
        if live.phase != .thinking, thinkingStarted != nil, thinkingEnded == nil { thinkingEnded = now }
    }

    /// How long the model thought, once it has stopped thinking.
    func thoughtSeconds(now: Date = .now) -> Double? {
        guard let thinkingStarted else { return nil }
        return (thinkingEnded ?? now).timeIntervalSince(thinkingStarted)
    }

    func status(for live: LiveReply, modelName: String?, now: Date = .now) -> ReplyStatus {
        let seconds = Int(now.timeIntervalSince(phaseStarted))
        let elapsed = Self.format(seconds)
        let slow = live.text.isEmpty && now.timeIntervalSince(live.started) > Self.slowAfter
        switch live.phase {
        case .loading(let p):
            return ReplyStatus(text: "Loading \(modelName ?? "the model") · \(elapsed)", progress: p, intensity: 0.2,
                               isSlow: slow)
        case .waiting:
            let what = live.mode == .mac ? "Asking the Mac" : "Reading your question"
            return ReplyStatus(text: "\(what) · \(elapsed)", progress: nil, intensity: 0.3, isSlow: slow)
        case .reading(let p):
            return ReplyStatus(text: "Reading the chat · \(elapsed)", progress: p, intensity: 0.35, isSlow: slow)
        case .thinking:
            return ReplyStatus(text: "Thinking · \(elapsed)", progress: nil, intensity: 0.55, isSlow: slow)
        case .answering:
            return ReplyStatus(text: "Writing · \(elapsed)", progress: nil, intensity: 1, isSlow: false)
        }
    }

    static func format(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}
