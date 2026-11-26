import AppKit
import UniformTypeIdentifiers

/// Export as Markdown: the chat as `ChatExport` writes it (the same file the iPhone shares), saved
/// where the user picks.
enum MarkdownExport {
    static func save(_ conversation: Conversation) {
        let export = ChatExport(conversation)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdownText]
        panel.nameFieldStringValue = export.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(export.markdown.utf8).write(to: url, options: .atomic)
    }
}
