import UIKit
typealias PlatformImage = UIImage
import PDFKit
import UniformTypeIdentifiers

/// Turns files into `Attachment`s: text files and PDFs into their text, images into a downscaled
/// JPEG. What's extracted is stored on the message and is exactly what the model sees each time.
nonisolated enum AttachmentReader {
    /// What the composer accepts from the file picker, drops and paste.
    static let types: [UTType] = [.pdf, .text, .image]
    /// Longest side of an image as stored and shown to the model; the projector scales it again.
    static let imageSide: CGFloat = 1024
    /// Text beyond this is cut off: no context Lantern has would hold more.
    static let maxCharacters = 400_000

    enum Failure: LocalizedError {
        case unreadable(String), empty(String), unsupported(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read “\(name)”."
            case .empty(let name): "“\(name)” has no text Lantern can read. A scanned PDF needs text recognition first."
            case .unsupported(let name): "Lantern can attach text files, PDFs and images, not “\(name)”."
            }
        }
    }

    /// Reads a file the user picked or dropped. Slow for a long PDF: call it off the main actor.
    nonisolated static func read(_ url: URL) throws -> Attachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            guard let image = PlatformImage(contentsOfFile: url.path), let attachment = attachment(image, name: name) else {
                throw Failure.unreadable(name)
            }
            return attachment
        }
        let text: String
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable(name) }
            text = document.string ?? ""
        } else if type.conforms(to: .text) {
            guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } else {
            throw Failure.unsupported(name)
        }
        return try attachment(text: text, name: name)
    }

    /// Text that came without a file (pasted from a PDF, say), or a file's text.
    nonisolated static func attachment(text: String, name: String) throws -> Attachment {
        // One newline style, no trailing space per line, so the same file always reads the same.
        var clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        clean = clean.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/[ \t]+$/, with: "") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw Failure.empty(name) }
        if clean.count > maxCharacters { clean = String(clean.prefix(maxCharacters)) }
        return Attachment(name: name, text: clean)
    }

    /// An image as the model will see it: at most `imageSide` on its longest side, as JPEG.
    nonisolated static func attachment(_ image: PlatformImage, name: String) -> Attachment? {
        let size = image.size
        let scale = min(1, imageSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()  // transparent PNGs get a white background, not black
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }
        return Attachment(name: name, image: data)
    }

    /// About how many tokens an attachment adds to the turn (four characters a token, roughly
    /// right for English across both tokenizers), for warning before it's sent.
    static func estimatedTokens(_ attachment: Attachment) -> Int {
        attachment.isImage ? 280 : attachment.text.utf8.count / 4 + 12
    }
}
