import UIKit

/// Renders a model's Markdown (headings, lists, code, emphasis, links) for a UITextView. Foundation
/// parses it; this turns the parsed block and inline intents into fonts and paragraph styles. Cheap
/// enough to redo on every streaming tick: a long answer parses in a millisecond or two.
enum Markdown {
    static func render(_ text: String, color: UIColor = .label) -> NSAttributedString {
        let body = UIFont.preferredFont(forTextStyle: .body)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: body, .foregroundColor: color])
        }

        let out = NSMutableAttributedString()
        var previousBlock: PresentationIntent?
        for run in parsed.runs {
            let block = run.presentationIntent
            var piece = String(parsed[run.range].characters)
            var font = body
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8

            var listDepth = 0
            var listItem: (ordinal: Int, ordered: Bool)?
            for component in block?.components ?? [] {
                switch component.kind {
                case .header(let level):
                    font = .preferredFont(forTextStyle: level == 1 ? .title2 : level == 2 ? .title3 : .headline)
                    font = font.withTraits(.traitBold)
                case .codeBlock:
                    font = .monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
                    attributes[.backgroundColor] = UIColor.secondarySystemFill
                    if piece.hasSuffix("\n") { piece.removeLast() }
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
                default:
                    break
                }
            }

            // A new block starts on a new line; list items get their bullet or number.
            if block != previousBlock {
                if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
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
                previousBlock = block
            } else if listItem != nil {
                paragraph.headIndent = CGFloat(listDepth) * 22
                paragraph.firstLineHeadIndent = paragraph.headIndent - 22
            }

            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { font = font.withTraits(.traitBold) }
                if inline.contains(.emphasized) { font = font.withTraits(.traitItalic) }
                if inline.contains(.code) {
                    font = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                    attributes[.backgroundColor] = UIColor.secondarySystemFill
                }
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = font
            attributes[.paragraphStyle] = paragraph
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
}
