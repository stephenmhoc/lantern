import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A chat as a Markdown file, for ShareLink.
nonisolated struct ChatExport: Transferable {
    let title: String
    let markdown: String

    @MainActor init(_ c: Conversation) {
        title = c.title
        var lines = ["# \(c.title)", "", "_\(c.created.formatted(date: .long, time: .shortened)) · Lantern_", ""]
        for m in c.messages {
            if m.isUser {
                lines += ["**You**", "", m.content, ""]
            } else {
                lines += ["**Lantern**" + (m.footnote.map { " _(\($0))_" } ?? ""), ""]
                if !m.content.isEmpty { lines += [m.content, ""] }
                if let error = m.error { lines += ["> \(error)", ""] }
                // The pages a search found, as links under the answer that used them.
                let sources = (m.searches ?? []).flatMap(\.results)
                if !sources.isEmpty {
                    lines += ["Sources:"] + sources.map { "- [\($0.title)](\($0.url))" } + [""]
                }
            }
        }
        markdown = lines.joined(separator: "\n")
    }

    var filename: String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        return "\(safe.isEmpty ? "Chat" : safe).md"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .markdownText) { Data($0.markdown.utf8) }
            .suggestedFileName { $0.filename }
        ProxyRepresentation(exporting: \.markdown)
    }
}

extension UTType {
    nonisolated static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}
