import UIKit

extension NSAttributedString.Key {
    /// Marks a code block or table, so `BlockLayoutManager` can draw one even background behind it.
    nonisolated static let lanternBlock = NSAttributedString.Key("LanternBlock")
    /// The code a code block's Copy link copies.
    nonisolated static let lanternCode = NSAttributedString.Key("LanternCode")
}

/// Renders a model's Markdown (headings, lists, code, tables, emphasis, links) for a UITextView.
/// Foundation parses it; this turns the parsed block and inline intents into fonts and paragraph
/// styles. Cheap enough to redo on every streaming tick: a long answer parses in a millisecond or two.
enum Markdown {
    /// Code blocks start with a "Copy" link to `lantern-copy://<index>`; `AssistantCell` handles it.
    static let copyScheme = "lantern-copy"

    private static let blockInset: CGFloat = 12

    /// `copied` is the code block whose link should read "Copied" for a moment.
    static func render(
        _ text: String, color: UIColor = .label, traits: UITraitCollection = .current, copied: Int? = nil
    ) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: color])
        }

        let out = NSMutableAttributedString()
        var previousBlock: PresentationIntent?
        var table: TableBuilder?
        var codeBlocks = 0

        for run in parsed.runs {
            let block = run.presentationIntent
            let piece = String(parsed[run.range].characters)
            var font = body
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8

            var listDepth = 0
            var listItem: (ordinal: Int, ordered: Bool)?
            var codeHint: String??
            var cell: TableBuilder.Cell?
            for component in block?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    font = .preferredFont(forTextStyle: level == 1 ? .title2 : level == 2 ? .title3 : .headline,
                                          compatibleWith: traits)
                    font = font.withTraits(.traitBold)
                case .codeBlock(let hint):
                    codeHint = .some(hint)
                case .blockQuote:
                    attributes[.foregroundColor] = UIColor.secondaryLabel
                    paragraph.firstLineHeadIndent = 12
                    paragraph.headIndent = 12
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (ordinal, false) }
                case .orderedList:
                    listDepth += 1
                    if listDepth == 1, let item = listItem { listItem = (item.ordinal, true) }
                case .unorderedList:
                    listDepth += 1
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

            // A table ends when a run outside it (or in another table) arrives.
            if let t = table, cell?.table != t.identity {
                t.finish(in: out, inset: blockInset)
                table = nil
            }

            // A new block starts on a new line (a new cell, on a tab); list items get their marker.
            if block != previousBlock {
                if let cell, let t = table, t.lastRow == cell.row {
                    out.append(NSAttributedString(string: "\t"))
                } else if out.length > 0 {
                    out.append(NSAttributedString(string: "\n"))
                }
                if let cell, table == nil {
                    table = TableBuilder(identity: cell.table, start: out.length, alignments: cell.alignments)
                }
                if let item = listItem {
                    let marker = item.ordered ? "\(item.ordinal).\t" : "•\t"
                    let indent = CGFloat(listDepth) * 22
                    paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    paragraph.firstLineHeadIndent = indent - 22
                    paragraph.headIndent = indent
                    out.append(NSAttributedString(string: marker, attributes: [
                        .font: body, .foregroundColor: color, .paragraphStyle: paragraph,
                    ]))
                }
                if let hint = codeHint {
                    appendCodeHeader(to: out, hint: hint, code: piece, index: codeBlocks, copied: copied == codeBlocks,
                                     traits: traits)
                }
                previousBlock = block
            } else if listItem != nil {
                paragraph.headIndent = CGFloat(listDepth) * 22
                paragraph.firstLineHeadIndent = paragraph.headIndent - 22
            }

            if codeHint != nil {
                appendCode(to: out, piece, index: codeBlocks, color: color, traits: traits)
                codeBlocks += 1
                continue
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
                    attributes[.backgroundColor] = UIColor.secondarySystemFill
                }
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            attributes[.paragraphStyle] = paragraph
            let start = out.length
            out.append(NSAttributedString(string: piece, attributes: attributes))
            if let cell { table?.add(cell, range: NSRange(location: start, length: out.length - start)) }
        }
        table?.finish(in: out, inset: blockInset)
        padBlocksAtEdges(out)
        return out
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

    /// The block's first line: the language, if given, and a Copy link.
    private static func appendCodeHeader(
        to out: NSMutableAttributedString, hint: String?, code: String, index: Int, copied: Bool, traits: UITraitCollection
    ) {
        let small = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let paragraph = blockParagraph(before: 14, after: 4)
        let block = "code-\(index)"
        if let hint, !hint.isEmpty {
            out.append(NSAttributedString(string: hint + "   ", attributes: [
                .font: small, .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraph, .lanternBlock: block,
            ]))
        }
        var trimmed = code
        if trimmed.hasSuffix("\n") { trimmed.removeLast() }
        out.append(NSAttributedString(string: copied ? "Copied" : "Copy", attributes: [
            .font: small.withTraits(.traitBold), .paragraphStyle: paragraph, .lanternBlock: block,
            .link: URL(string: "\(copyScheme)://\(index)")!, .lanternCode: trimmed,
        ]))
        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph, .lanternBlock: block]))
    }

    private static func appendCode(
        to out: NSMutableAttributedString, _ code: String, index: Int, color: UIColor, traits: UITraitCollection
    ) {
        var code = code
        if code.hasSuffix("\n") { code.removeLast() }
        let font = codeFont(size: 15, traits: traits)
        let lines = code.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let last = i == lines.count - 1
            out.append(NSAttributedString(string: last ? line : line + "\n", attributes: [
                .font: font, .foregroundColor: color, .lanternBlock: "code-\(index)",
                .paragraphStyle: blockParagraph(after: last ? 18 : 0),
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
                p.paragraphSpacingBefore = i == 0 ? 14 : 0
                p.paragraphSpacing = i == rows.count - 1 ? 18 : i == 0 ? 8 : 5
                out.addAttribute(.paragraphStyle, value: p, range: row)
            }
            out.addAttribute(.lanternBlock, value: "table-\(identity)", range: range)
        }
    }
}

/// Draws one even, rounded background behind each code block and table, the full width of the
/// text, instead of a ragged highlight behind each line's characters.
nonisolated final class BlockLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let everything = NSRange(location: 0, length: storage.length)
        var drawn = Set<Int>()
        storage.enumerateAttribute(.lanternBlock, in: characters) { value, range, _ in
            guard value != nil else { return }
            var full = NSRange()
            _ = storage.attribute(.lanternBlock, at: range.location, longestEffectiveRange: &full, in: everything)
            guard drawn.insert(full.location).inserted else { return }
            var rect = CGRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: full, actualCharacterRange: nil)) {
                _, used, _, _, _ in rect = rect.union(used)
            }
            guard !rect.isNull else { return }
            rect.origin.x = 0
            rect.size.width = container.size.width
            rect = rect.insetBy(dx: 0, dy: -8).offsetBy(dx: origin.x, dy: origin.y)
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 10).fill()
        }
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
}
