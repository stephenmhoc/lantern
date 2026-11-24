import PDFKit
import UIKit
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
            guard let image = UIImage(contentsOfFile: url.path), let attachment = attachment(image, name: name) else {
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
    nonisolated static func attachment(_ image: UIImage, name: String) -> Attachment? {
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

/// A file attached to a message: its icon or thumbnail and name, and in the composer a remove button.
/// Grows with Dynamic Type; a long name is cut in the middle so its extension stays visible.
final class AttachmentChip: UIView {
    /// Decoding a 1024 px JPEG for a thumbnail takes a few milliseconds, and the composer and the
    /// transcript build chips again whenever their attachments change: decode each image once.
    private static let thumbnails: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    private let icon = UIImageView()
    /// What VoiceOver lands on: the icon and name.
    let info = UIStackView()
    private let name = UILabel()
    private let isImage: Bool
    private var iconSide: NSLayoutConstraint!
    private var nameWidth: NSLayoutConstraint!

    init(_ attachment: Attachment, onRemove: (() -> Void)? = nil) {
        isImage = attachment.isImage
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous

        icon.contentMode = .scaleAspectFill
        icon.clipsToBounds = true
        icon.layer.cornerRadius = 5
        icon.layer.cornerCurve = .continuous
        icon.tintColor = .secondaryLabel
        if let image = Self.thumbnail(for: attachment) {
            icon.image = image
        } else {
            icon.image = UIImage(systemName: attachment.symbol)
            icon.contentMode = .scaleAspectFit
        }
        name.text = attachment.name
        name.font = .preferredFont(forTextStyle: .footnote)
        name.adjustsFontForContentSizeCategory = true
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The icon and name are one element ("Image: photo.jpg"), the remove button another.
        [icon, name].forEach(info.addArrangedSubview)
        info.spacing = 6
        info.alignment = .center
        info.isAccessibilityElement = true
        info.accessibilityLabel = "\(attachment.isImage ? "Image" : "File"): \(attachment.name)"
        let stack = UIStackView(arrangedSubviews: [info])
        stack.spacing = 0
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        iconSide = icon.widthAnchor.constraint(equalToConstant: 22)
        nameWidth = name.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        let constraints = [
            iconSide!, nameWidth!,
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: isImage ? 5 : 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: onRemove == nil ? -9 : 0),
        ]
        if let onRemove {
            let remove = HitButton(configuration: .plain())
            remove.configuration?.image = UIImage(systemName: "xmark.circle.fill")
            remove.configuration?.baseForegroundColor = .secondaryLabel
            remove.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 7)
            remove.configuration?.preferredSymbolConfigurationForImage = .init(textStyle: .subheadline)
            remove.isPointerInteractionEnabled = true
            remove.accessibilityLabel = "Remove \(attachment.name)"
            remove.accessibilityUserInputLabels = ["Remove \(attachment.name)", "Remove"]
            remove.setContentHuggingPriority(.required, for: .horizontal)
            remove.setContentCompressionResistancePriority(.required, for: .horizontal)
            remove.addAction(UIAction { _ in onRemove() }, for: .primaryActionTriggered)
            stack.addArrangedSubview(remove)
            // Also on the chip itself, so a VoiceOver user on the name can remove it without moving on.
            info.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Remove") { _ in
                onRemove()
                return true
            }]
        }
        NSLayoutConstraint.activate(constraints)
        isAccessibilityElement = onRemove == nil
        accessibilityLabel = info.accessibilityLabel
        updateForTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.updateForTextSize()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A photo's thumbnail is bigger than a file's symbol, so it can be recognised; both grow with
    /// the text, and so does the room for the name, up to about half an iPhone's width.
    private func updateForTextSize() {
        let metrics = UIFontMetrics(forTextStyle: .footnote)
        iconSide.constant = min(isImage ? 48 : 34, metrics.scaledValue(for: isImage ? 30 : 20, compatibleWith: traitCollection))
        nameWidth.constant = min(260, metrics.scaledValue(for: 180, compatibleWith: traitCollection))
    }

    /// Big enough for the largest icon at the screen's scale.
    private static func thumbnail(for attachment: Attachment) -> UIImage? {
        guard let data = attachment.image else { return nil }
        let key = attachment.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        let pixels = 48 * 3.0
        let aspect = image.size.width / max(image.size.height, 1)
        // Fill a square: the shorter side reaches the target.
        let size = aspect > 1 ? CGSize(width: pixels * aspect, height: pixels) : CGSize(width: pixels, height: pixels / aspect)
        let thumbnail = image.preparingThumbnail(of: size) ?? image
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
    }
}
