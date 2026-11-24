import UIKit

extension NSAttributedString.Key {
    /// Marks a code block or table, so `BlockLayoutManager` can draw one even background behind it.
    nonisolated static let lanternBlock = NSAttributedString.Key("LanternBlock")
    /// On a code block's first line (its language): the code its Copy button copies.
    nonisolated static let lanternCode = NSAttributedString.Key("LanternCode")
    /// A block quote, drawn with a bar down its leading edge.
    nonisolated static let lanternQuote = NSAttributedString.Key("LanternQuote")
    /// A thematic break (`---`), drawn as a hairline across the text.
    nonisolated static let lanternRule = NSAttributedString.Key("LanternRule")
    /// A table's header row, drawn with a hairline under it.
    nonisolated static let lanternTableHeader = NSAttributedString.Key("LanternTableHeader")
}

/// Renders a model's Markdown (headings, lists, code, tables, quotes, emphasis, links) for a
/// UITextView. Foundation parses it; this turns the parsed block and inline intents into fonts and
/// paragraph styles. Cheap enough to redo on every streaming tick: a long answer parses in a
/// millisecond or two. An unclosed code fence mid-stream parses as a code block running to the end,
/// so a half-written block already looks like one.
enum Markdown {
    /// How far code blocks' and tables' text sits inside their background.
    nonisolated static let blockInset: CGFloat = 12
    /// How far each level of a list is indented.
    private static let listIndent: CGFloat = 24
    private static let paragraphGap: CGFloat = 10

    static func render(_ text: String, color: UIColor = .label, traits: UITraitCollection = .current) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: color])
        }

        // Each ordered list's marker column fits its widest number, so "10." doesn't push its text
        // onto the next line. Components run from the innermost out: an item's list follows it.
        let digits = UIFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
        var columns: [Int: CGFloat] = [:]
        for run in parsed.runs {
            guard let components = run.presentationIntent?.components else { continue }
            for (k, component) in components.enumerated() where k + 1 < components.count {
                guard case .listItem(let ordinal) = component.kind, case .orderedList = components[k + 1].kind else { continue }
                let width = ceil(("\(ordinal)." as NSString).size(withAttributes: [.font: digits]).width) + 10
                columns[components[k + 1].identity] = max(columns[components[k + 1].identity] ?? listIndent, width)
            }
        }

        let out = NSMutableAttributedString()
        var previousBlock: PresentationIntent?
        var previousQuote: Int?
        var previousGroup = Group.none
        // The paragraph that carries its list item's marker: a second paragraph (or a code block)
        // in the same item is indented under it without a marker of its own.
        var markedItem: Int?
        var markedBlock: PresentationIntent?
        var table: TableBuilder?
        var codeBlocks = 0

        for run in parsed.runs {
            let block = run.presentationIntent
            let piece = String(parsed[run.range].characters)
            var font = body
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = paragraphGap

            // Components run from the innermost out.
            var listDepth = 0
            var listIndentation: CGFloat = 0
            var innermostColumn: CGFloat?
            var listItem: (identity: Int, ordinal: Int, ordered: Bool)?
            var codeHint: String??
            var heading: Int?
            var quote: Int?
            var rule: Int?
            var cell: TableBuilder.Cell?
            for component in block?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    heading = level
                case .codeBlock(let hint):
                    codeHint = .some(hint)
                case .blockQuote:
                    quote = component.identity  // the outermost, so nested quotes share one bar
                case .thematicBreak:
                    rule = component.identity
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (component.identity, ordinal, false) }
                case .orderedList:
                    listDepth += 1
                    let column = columns[component.identity] ?? listIndent
                    listIndentation += column
                    if innermostColumn == nil { innermostColumn = column }
                    if listDepth == 1, let item = listItem { listItem = (item.identity, item.ordinal, true) }
                case .unorderedList:
                    listDepth += 1
                    listIndentation += listIndent
                    if innermostColumn == nil { innermostColumn = listIndent }
                case .table(let columns):
                    cell = cell ?? TableBuilder.Cell(table: component.identity, row: 0, column: 0, header: false)
                    cell?.table = component.identity
                    cell?.alignments = columns.map(\.alignment)
                case .tableHeaderRow:
                    cell = cell ?? TableBuilder.Cell(table: 0, row: 0, column: 0, header: true)
                    cell?.row = component.identity
                    cell?.header = true
                case .tableRow:
                    cell = cell ?? TableBuilder.Cell(table: 0, row: 0, column: 0, header: false)
                    cell?.row = component.identity
                case .tableCell(let column):
                    cell = cell ?? TableBuilder.Cell(table: 0, row: 0, column: 0, header: false)
                    cell?.column = column
                default:
                    break
                }
            }
            let group: Group = codeHint != nil || cell != nil ? .none : listItem != nil ? .list : quote != nil ? .quote : .none

            // A table ends when a run outside it (or in another table) arrives.
            if let t = table, cell?.table != t.identity {
                t.finish(in: out, inset: blockInset)
                table = nil
            }

            let startsBlock = block != previousBlock
            let atStart = out.length == 0
            // A new block starts on a new line (a new cell, on a tab).
            if startsBlock {
                if let cell, let t = table, t.lastRow == cell.row {
                    out.append(NSAttributedString(string: "\t"))
                } else if !atStart {
                    // Inside one quote the line break carries the quote too, so its bar is unbroken.
                    let sameQuote = quote != nil && quote == previousQuote
                    out.append(NSAttributedString(string: "\n", attributes: sameQuote ? [.lanternQuote: quote!] : [:]))
                }
                if let cell, table == nil {
                    table = TableBuilder(identity: cell.table, start: out.length, alignments: cell.alignments)
                }
            }

            // Lists and quotes are set tighter inside; leaving one gets the usual gap back.
            if startsBlock, !atStart, previousGroup != .none, group != previousGroup {
                paragraph.paragraphSpacingBefore = 6
            }

            if let level = heading {
                let style: UIFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : .headline
                font = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).withTraits(.traitBold)
                paragraph.paragraphSpacingBefore = atStart && startsBlock ? 0 : level <= 2 ? 14 : 8
                paragraph.paragraphSpacing = level <= 2 ? 6 : 4
            }
            if let quote {
                attributes[.foregroundColor] = UIColor.secondaryLabel
                attributes[.lanternQuote] = quote
                paragraph.firstLineHeadIndent = 16
                paragraph.headIndent = 16
                paragraph.paragraphSpacing = 6
            }
            if let item = listItem, codeHint == nil, cell == nil {
                let indent = listIndentation
                let column = innermostColumn ?? listIndent
                paragraph.headIndent = indent
                paragraph.firstLineHeadIndent = indent
                paragraph.paragraphSpacing = 4
                if startsBlock, markedItem != item.identity {
                    markedItem = item.identity
                    markedBlock = block
                    // The marker ends at a right tab, so "9." and "10." line up on their dots.
                    let markerStyle = markerParagraph(paragraph, indent: indent, column: column)
                    let marker: String
                    var markerFont = body
                    if item.ordered {
                        marker = "\t\(item.ordinal).\t"
                        markerFont = digits
                    } else {
                        marker = "\t" + ["•", "◦", "▪︎"][min(listDepth, 3) - 1] + "\t"
                    }
                    out.append(NSAttributedString(string: marker, attributes: [
                        .font: markerFont, .foregroundColor: item.ordered ? color : UIColor.secondaryLabel,
                        .paragraphStyle: markerStyle,
                    ]))
                }
                if block == markedBlock {
                    paragraph.setParagraphStyle(markerParagraph(paragraph, indent: indent, column: column))
                }
            }

            if let hint = codeHint {
                if startsBlock {
                    appendCodeHeader(to: out, hint: hint, code: piece, index: codeBlocks, traits: traits)
                }
                appendCode(to: out, piece, index: codeBlocks, color: color, traits: traits)
                codeBlocks += 1
                previousBlock = block
                previousQuote = nil
                previousGroup = .none
                continue
            }

            if let rule {
                // The parser gives a break as "⸻"; it stays in the text (for copying) but invisible,
                // and BlockLayoutManager draws a hairline through its line instead.
                attributes[.foregroundColor] = UIColor.clear
                attributes[.lanternRule] = rule
                font = .systemFont(ofSize: 8)
                paragraph.paragraphSpacingBefore = 4
                paragraph.paragraphSpacing = 14
            }

            if let cell {
                font = .preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
                if cell.header { font = font.withTraits(.traitBold) }
            }
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = font.withTraits(.traitBold) }
                if inline.contains(.emphasized) { font = font.withTraits(.traitItalic) }
                if inline.contains(.code) {
                    font = codeFont(size: font.pointSize * 0.9 / traitsScale(traits), traits: traits)
                    // A table already sits on the same fill; a second one inside it only looks muddy.
                    if cell == nil { attributes[.backgroundColor] = UIColor.tertiarySystemFill }
                }
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            attributes[.paragraphStyle] = paragraph
            let start = out.length
            out.append(NSAttributedString(string: piece, attributes: attributes))
            if let cell { table?.add(cell, range: NSRange(location: start, length: out.length - start)) }
            previousBlock = block
            previousQuote = quote
            previousGroup = group
        }
        table?.finish(in: out, inset: blockInset)
        padBlocksAtEdges(out)
        return out
    }

    private enum Group { case none, list, quote }

    /// A list item's first line: hangs out to the marker, which ends at a right tab before the text.
    private static func markerParagraph(_ base: NSParagraphStyle, indent: CGFloat, column: CGFloat) -> NSMutableParagraphStyle {
        let p = base.mutableCopy() as! NSMutableParagraphStyle
        p.firstLineHeadIndent = indent - column
        p.headIndent = indent
        p.tabStops = [NSTextTab(textAlignment: .right, location: indent - 8), NSTextTab(textAlignment: .left, location: indent)]
        return p
    }

    /// A text view clips to its text, and a block's background reaches a little past it: give a
    /// block at the very start or end a hairline paragraph to draw into.
    private static func padBlocksAtEdges(_ out: NSMutableAttributedString) {
        guard out.length > 0 else { return }
        let hairline: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 1)]
        if out.attribute(.lanternBlock, at: out.length - 1, effectiveRange: nil) != nil {
            out.append(NSAttributedString(string: "\n\u{200B}", attributes: hairline))
        }
        if out.attribute(.lanternBlock, at: 0, effectiveRange: nil) != nil {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = 0
            var attributes = hairline
            attributes[.paragraphStyle] = p
            out.insert(NSAttributedString(string: "\u{200B}\n", attributes: attributes), at: 0)
        }
    }

    /// The answer as plain text, for speech and VoiceOver announcements.
    static func plainText(_ text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return text }
        return String(parsed.characters)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "```", with: "")
    }

    /// The first sentence of an answer, for announcing that it's done.
    static func firstSentence(_ text: String, limit: Int = 200) -> String {
        let plain = plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        var first = plain
        plain.enumerateSubstrings(in: plain.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                first = s
                stop = true
            }
        }
        first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.count > limit ? String(first.prefix(limit)) + "…" : first
    }

    // MARK: - Code

    /// Monospaced at `size` points for the default text size, scaled with Dynamic Type.
    private static func codeFont(size: CGFloat, traits: UITraitCollection) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: size, weight: .regular), compatibleWith: traits)
    }

    /// How much Dynamic Type scales body text, to turn a scaled size back into a default one.
    private static func traitsScale(_ traits: UITraitCollection) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traits) / 17
    }

    private static func blockParagraph(before: CGFloat = 0, after: CGFloat = 0) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = blockInset
        p.headIndent = blockInset
        p.tailIndent = -blockInset
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        return p
    }

    /// The block's first line: its language, if given. `AnswerTextView` puts a Copy button at the
    /// line's trailing end, which is why the line is there even without a language.
    private static func appendCodeHeader(
        to out: NSMutableAttributedString, hint: String?, code: String, index: Int, traits: UITraitCollection
    ) {
        let small = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        var trimmed = code
        if trimmed.hasSuffix("\n") { trimmed.removeLast() }
        let label = hint.flatMap { $0.isEmpty ? nil : $0 } ?? "\u{200B}"
        out.append(NSAttributedString(string: label + "\n", attributes: [
            .font: small, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: blockParagraph(before: 10, after: 6),
            .lanternBlock: "code-\(index)", .lanternCode: trimmed,
        ]))
    }

    private static func appendCode(
        to out: NSMutableAttributedString, _ code: String, index: Int, color: UIColor, traits: UITraitCollection
    ) {
        var code = code
        if code.hasSuffix("\n") { code.removeLast() }
        let font = codeFont(size: 14, traits: traits)
        let column = ("0" as NSString).size(withAttributes: [.font: font]).width
        let lines = code.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let last = i == lines.count - 1
            // A line too long for the width wraps two columns deeper than its own indentation, so
            // it reads as one line rather than as the next.
            let leading = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let paragraph = blockParagraph(after: last ? 20 : 0)
            paragraph.headIndent = blockInset + CGFloat(leading + 2) * column
            paragraph.lineSpacing = 2
            out.append(NSAttributedString(string: last ? line : line + "\n", attributes: [
                .font: font, .foregroundColor: color, .lanternBlock: "code-\(index)", .paragraphStyle: paragraph,
            ]))
        }
    }

    // MARK: - Tables

    /// Collects a table's cells as they're appended, then lines its columns up with tab stops.
    private final class TableBuilder {
        struct Cell {
            var table: Int, row: Int, column: Int, header: Bool
            var alignments: [PresentationIntent.TableColumn.Alignment] = []
        }

        let identity: Int
        let start: Int
        let alignments: [PresentationIntent.TableColumn.Alignment]
        private var cells: [(column: Int, range: NSRange)] = []
        private(set) var lastRow: Int?
        private var lastKey: (row: Int, column: Int)?

        init(identity: Int, start: Int, alignments: [PresentationIntent.TableColumn.Alignment]) {
            self.identity = identity
            self.start = start
            self.alignments = alignments
        }

        func add(_ cell: Cell, range: NSRange) {
            if let k = lastKey, k.row == cell.row, k.column == cell.column, let last = cells.last {
                cells[cells.count - 1].range = NSUnionRange(last.range, range)
            } else {
                cells.append((cell.column, range))
            }
            lastKey = (cell.row, cell.column)
            lastRow = cell.row
        }

        func finish(in out: NSMutableAttributedString, inset: CGFloat) {
            let range = NSRange(location: start, length: out.length - start)
            guard range.length > 0 else { return }
            let count = (cells.map(\.column).max() ?? 0) + 1
            var widths = [CGFloat](repeating: 0, count: count)
            for c in cells {
                widths[c.column] = max(widths[c.column], ceil(out.attributedSubstring(from: c.range).size().width))
            }
            let gap: CGFloat = 20
            var x = inset
            var stops: [NSTextTab] = []
            for column in 0..<count {
                if column > 0 {
                    let alignment = column < alignments.count ? alignments[column] : .left
                    switch alignment {
                    case .center: stops.append(NSTextTab(textAlignment: .center, location: x + widths[column] / 2))
                    case .right: stops.append(NSTextTab(textAlignment: .right, location: x + widths[column]))
                    default: stops.append(NSTextTab(textAlignment: .left, location: x))
                    }
                }
                x += widths[column] + gap
            }
            let text = out.string as NSString
            var rows: [NSRange] = []
            text.enumerateSubstrings(in: range, options: [.byParagraphs, .substringNotRequired]) { _, r, enclosing, _ in
                rows.append(enclosing)
            }
            for (i, row) in rows.enumerated() {
                let p = NSMutableParagraphStyle()
                p.tabStops = stops
                p.defaultTabInterval = gap
                p.firstLineHeadIndent = inset
                p.headIndent = inset
                p.paragraphSpacingBefore = i == 0 ? 10 : 0
                p.paragraphSpacing = i == rows.count - 1 ? 20 : i == 0 ? 10 : 6
                out.addAttribute(.paragraphStyle, value: p, range: row)
            }
            if rows.count > 1, let header = rows.first {
                out.addAttribute(.lanternTableHeader, value: identity, range: header)
            }
            out.addAttribute(.lanternBlock, value: "table-\(identity)", range: range)
        }
    }
}

/// Draws what sits behind the answer's text: one even, rounded background behind each code block
/// and table (the full width of the text, instead of a ragged highlight behind each line's
/// characters), a hairline under a table's header row, a bar beside each block quote and a hairline
/// for each thematic break.
nonisolated final class BlockLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let width = container.size.width
        let hairline: CGFloat = 0.5

        eachRun(of: .lanternBlock, in: characters, storage: storage) { used in
            let rect = CGRect(x: 0, y: used.minY - 8, width: width, height: used.height + 16)
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), cornerRadius: 10).fill()
        }
        eachRun(of: .lanternTableHeader, in: characters, storage: storage) { used in
            let inset = Markdown.blockInset
            UIColor.separator.setFill()
            UIBezierPath(rect: CGRect(x: origin.x + inset, y: origin.y + used.maxY + 4.5, width: width - 2 * inset, height: hairline)).fill()
        }
        eachRun(of: .lanternQuote, in: characters, storage: storage) { used in
            UIColor.tertiaryLabel.setFill()
            let bar = CGRect(x: origin.x + 2, y: origin.y + used.minY + 1, width: 3, height: used.height - 2)
            UIBezierPath(roundedRect: bar, cornerRadius: 1.5).fill()
        }
        eachRun(of: .lanternRule, in: characters, storage: storage) { used in
            UIColor.separator.setFill()
            UIBezierPath(rect: CGRect(x: origin.x, y: origin.y + used.midY.rounded(), width: width, height: hairline)).fill()
        }
    }

    /// Calls `draw` once with the used rect of each whole run of `key` that `characters` touches,
    /// even when only part of it is being drawn.
    private func eachRun(
        of key: NSAttributedString.Key, in characters: NSRange, storage: NSTextStorage, draw: (CGRect) -> Void
    ) {
        let everything = NSRange(location: 0, length: storage.length)
        var drawn = Set<Int>()
        storage.enumerateAttribute(key, in: characters) { value, range, _ in
            guard value != nil else { return }
            var full = NSRange()
            _ = storage.attribute(key, at: range.location, longestEffectiveRange: &full, in: everything)
            guard drawn.insert(full.location).inserted else { return }
            var rect = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil)) {
                _, used, _, _, _ in rect = rect.union(used)
            }
            if !rect.isNull { draw(rect) }
        }
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
}
