import SwiftUI

/// How the two answers of a comparison were made, side by side. Only the rows that measure the
/// models themselves say which did better: speed, and the time to the answer after reading the
/// chat (thinking, and on the Mac a little network). Loading, reading the chat and the Mac's
/// connection depend on what was already in memory or the network; the first token and the answer
/// time include them or depend on the answer's length. Those are shown but not ranked.
struct CompareMetricsView: View {
    let a: ReplyMetrics?
    let b: ReplyMetrics?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                grid
            }
            Text("Only speed and the time to answer after reading are ranked. The rest depends on what was already loaded, the network or the answer's length.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Layouts

    private var grid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                    .accessibilityHidden(true)
                columnHeader("A", a)
                columnHeader("B", b)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    cell(row, .a)
                    cell(row, .b)
                }
                .font(.subheadline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
            }
        }
    }

    /// At accessibility sizes three columns don't fit: each row's label above its two values.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("A").foregroundStyle(.secondary)
                        cell(row, .a)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("B").foregroundStyle(.secondary)
                        cell(row, .b)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.spoken)
            }
        }
    }

    private func columnHeader(_ letter: String, _ m: ReplyMetrics?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(letter).font(.subheadline.weight(.semibold))
            if let m {
                Label(m.modelTitle, systemImage: (Mode(rawValue: m.modeRaw) ?? .fast).symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(m.map { "\(letter), \($0.modelTitle)" } ?? letter)
        .accessibilityAddTraits(.isHeader)
    }

    private func cell(_ row: Row, _ side: Side) -> some View {
        let value = side == .a ? row.a : row.b
        let better = row.better == side
        return VStack(alignment: .leading, spacing: 3) {
            if row.isNotes {
                if value.lines.isEmpty {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    ForEach(value.lines, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                // The better value in semibold with a checkmark, in the primary colour: the amber
                // as text is about 2.3:1 on white.
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value.text ?? "—")
                        .monospacedDigit()
                        .fontWeight(better ? .semibold : .regular)
                        .foregroundStyle(value.text == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    if better {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                }
                ForEach(value.lines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                if let fraction = value.bar {
                    Capsule()
                        .fill(better ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.5)))
                        .frame(width: max(3, 72 * fraction), height: 3)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    enum Side { case a, b }

    struct Value {
        var text: String?
        /// For VoiceOver, built from the numbers ("21.1 tokens per second"); `text` if nil.
        var spoken: String?
        var lines: [String] = []
        /// Speed as a fraction of the faster one's, for its thin bar.
        var bar: Double?
    }

    struct Row: Identifiable {
        let label: String
        var a: Value
        var b: Value
        /// Set only on the rows where a model can be said to have done better.
        var better: Side?
        /// "A is faster": said by VoiceOver after both values.
        var verdict: (Side) -> String = { _ in "" }
        var isNotes = false
        var id: String { label }

        var spoken: String {
            func say(_ v: Value) -> String {
                if isNotes { return v.lines.isEmpty ? "none" : v.lines.joined(separator: ", ") }
                return ([v.spoken ?? v.text ?? "not measured"] + v.lines).joined(separator: ", ")
            }
            var text = "\(label): A \(say(a)), B \(say(b))"
            if let better { text += "; \(verdict(better))" }
            return text
        }
    }

    var rows: [Row] {
        var rows: [Row] = []
        rows.append(Row(label: "First token", a: Self.time(a?.firstTokenSeconds), b: Self.time(b?.firstTokenSeconds)))
        rows.append(Row(label: "First answer word", a: Self.time(a?.firstAnswerSeconds), b: Self.time(b?.firstAnswerSeconds)))
        // The model's own part of that wait: from the end of reading the chat to the answer, which
        // is mostly thinking. Loading is already left out; reading and the Mac's connection are too.
        rows.append(ranked("Time to answer after reading", Self.afterReading(a), Self.afterReading(b), lowerIsBetter: true,
                           minimumGap: 0.5, value: Self.time) { "\($0) started answering sooner after reading" })

        var speed = ranked("Speed", a?.tokensPerSecond, b?.tokensPerSecond, lowerIsBetter: false, value: { x in
            Value(text: x.map { String(format: "%.1f tok/s", $0) }, spoken: x.map { String(format: "%.1f tokens per second", $0) })
        }) { "\($0) is faster" }
        if let x = a?.tokensPerSecond, let y = b?.tokensPerSecond, max(x, y) > 0 {
            speed.a.bar = x / max(x, y)
            speed.b.bar = y / max(x, y)
        }
        rows.append(speed)

        rows.append(Row(label: "Generated tokens", a: Self.count(a?.generatedTokens), b: Self.count(b?.generatedTokens)))
        // Not ranked: it's as much the answer's length as the model (speed covers the model).
        rows.append(Row(label: "Answer time", a: Self.time(a?.generateSeconds), b: Self.time(b?.generateSeconds)))
        rows.append(Row(label: "Read the chat", a: reading(a), b: reading(b)))
        rows.append(Row(label: "Load", a: Self.time(a?.loadSeconds), b: Self.time(b?.loadSeconds)))
        rows.append(Row(label: "Total", a: Self.time(a?.totalSeconds), b: Self.time(b?.totalSeconds)))

        if a?.modeRaw == Mode.mac.rawValue || b?.modeRaw == Mode.mac.rawValue {
            rows.append(Row(label: "Found the Mac", a: Self.time(a?.findSeconds), b: Self.time(b?.findSeconds)))
            rows.append(Row(label: "Connected", a: Self.time(a?.connectSeconds), b: Self.time(b?.connectSeconds)))
            rows.append(Row(label: "Route", a: Value(text: a?.route), b: Value(text: b?.route)))
        }

        let notesA = Self.warnings(a), notesB = Self.warnings(b)
        if !notesA.isEmpty || !notesB.isEmpty {
            rows.append(Row(label: "Notes", a: Value(lines: notesA), b: Value(lines: notesB), isNotes: true))
        }
        return rows
    }

    /// A row that says which did better, when both were measured and they differ by more than a
    /// few percent and `minimumGap` (closer than that is noise).
    private func ranked(_ label: String, _ x: Double?, _ y: Double?, lowerIsBetter: Bool, minimumGap: Double = 0,
                        value: (Double?) -> Value, verdict: @escaping (String) -> String) -> Row {
        var row = Row(label: label, a: value(x), b: value(y))
        if let x, let y, max(x, y) > 0, abs(x - y) / max(x, y) > 0.05, abs(x - y) > minimumGap {
            row.better = (x < y) == lowerIsBetter ? .a : .b
        }
        row.verdict = { verdict($0 == .a ? "A" : "B") }
        return row
    }

    /// From the end of reading the chat to the first word of the answer: `firstAnswerSeconds`
    /// (already without loading) less reading and, on the Mac, finding it and connecting.
    static func afterReading(_ m: ReplyMetrics?) -> Double? {
        guard let m, let first = m.firstAnswerSeconds else { return nil }
        return max(0, first - (m.promptSeconds ?? 0) - (m.findSeconds ?? 0) - (m.connectSeconds ?? 0))
    }

    private func reading(_ m: ReplyMetrics?) -> Value {
        guard let m else { return Value() }
        let parts = [tokens(m.promptTokens), Self.duration(m.promptSeconds)].compactMap { $0 }
        let spoken = [m.promptTokens.map(Self.spokenTokens), Self.spokenDuration(m.promptSeconds)].compactMap { $0 }
        var lines: [String] = []
        if m.restored == true {
            lines.append("restored")
        } else if let reused = m.reusedTokens, reused > 0 {
            lines.append("\(reused.formatted()) reused")
        }
        return Value(text: parts.isEmpty ? nil : parts.joined(separator: " · "),
                     spoken: spoken.isEmpty ? nil : spoken.joined(separator: ", "), lines: lines)
    }

    static func warnings(_ m: ReplyMetrics?) -> [String] {
        guard let m else { return [] }
        var notes: [String] = []
        if let model = m.macModel, MacLink.alwaysThinks(model) { notes.append("always thinks") }
        if m.trimmed == true { notes.append("saw less of the chat") }
        if m.cutOff != nil { notes.append("cut off") }
        if m.stopped == true { notes.append("stopped") }
        return notes
    }

    private func tokens(_ n: Int?) -> String? { n.map { "\($0.formatted()) tok" } }

    static func spokenTokens(_ n: Int) -> String { n == 1 ? "1 token" : "\(n.formatted()) tokens" }

    /// A count of tokens, shown and spoken.
    static func count(_ n: Int?) -> Value {
        Value(text: n.map { "\($0.formatted()) tok" }, spoken: n.map(spokenTokens))
    }

    /// A time, shown ("0.4 s") and spoken ("0.4 seconds").
    static func time(_ value: Double?) -> Value {
        Value(text: duration(value), spoken: spokenDuration(value))
    }

    /// "0.4 seconds", "12 seconds", "1 minute 5 seconds", for VoiceOver.
    static func spokenDuration(_ value: Double?) -> String? {
        guard let value, value >= 0 else { return nil }
        if value < 10 { return String(format: "%.1f seconds", value) }
        let total = Int(value.rounded())
        return Duration.seconds(total).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// "0.4 s", "12 s", "1 min 5 s", like the reply's status line.
    static func duration(_ value: Double?) -> String? {
        guard let value, value >= 0 else { return nil }
        if value < 10 { return String(format: "%.1f s", value) }
        return PhaseClock.format(Int(value.rounded()))
    }
}
