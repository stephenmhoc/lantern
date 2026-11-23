import UIKit
import UniformTypeIdentifiers

/// The bar under the chat: status strip, attached files, a full-width text view that grows to six
/// lines, and under it the controls: mode menu and attach menu on the left, dictation and Send/Stop
/// on the right.
/// On iOS 26 and later it's a floating Liquid Glass panel at the readable width; before that, a
/// full-width blurred bar.
final class ComposerView: UIView, UITextViewDelegate {
    let textView = ComposerTextView()
    let modeButton = HitButton(configuration: .gray())
    let sendButton = HitButton(configuration: .plain())
    /// Files and photos; its menu is set by the chat, which knows what the mode can read.
    let attachButton = HitButton(configuration: .plain())
    /// Hidden until the chat knows on-device dictation works for the language.
    let micButton = HitButton(configuration: .plain())
    private let placeholder = UILabel()
    private let editBanner = UIStackView()
    private let chipScroll = UIScrollView()
    private let chipStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var modeTitle = ""
    private let usesGlass: Bool

    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    /// Every edit, for drafts and pre-warming.
    var onTextChange: ((String) -> Void)?
    var onCancelEdit: (() -> Void)?
    var onMic: (() -> Void)?
    /// After a chip's remove button.
    var onAttachmentsChange: (() -> Void)?
    var isRunning = false { didSet { updateButton() } }
    /// Files to send with the next message, shown as chips above the field.
    var attachments: [Attachment] = [] {
        didSet {
            renderChips()
            updateButton()
        }
    }
    var isListening = false { didSet { updateMic() } }
    var canSend = true { didSet { updateButton() } }
    /// Shows "Editing message" above the field while a sent message is being edited.
    var isEditingMessage = false {
        didSet { editBanner.isHidden = !isEditingMessage }
    }

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            textDidChange(notify: false)
        }
    }

    var placeholderText: String {
        get { placeholder.text ?? "" }
        set { placeholder.text = newValue }
    }

    init(statusView: UIView) {
        if #available(iOS 26, *) { usesGlass = true } else { usesGlass = false }
        super.init(frame: .zero)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = usesGlass ? .clear : .secondarySystemBackground
        textView.layer.cornerRadius = 18
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        textView.isScrollEnabled = false
        textView.delegate = self
        // The field's height depends on its width: follow rotation, Stage Manager and the sidebar.
        textView.onWidthChange = { [weak self] in self?.updateHeight() }
        textView.accessibilityLabel = "Message"

        placeholder.font = textView.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)

        modeButton.showsMenuAsPrimaryAction = true
        modeButton.isPointerInteractionEnabled = true
        modeButton.configuration?.cornerStyle = .capsule
        modeButton.configuration?.imagePadding = 4
        modeButton.setContentHuggingPriority(.required, for: .horizontal)
        modeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        sendButton.configuration?.contentInsets = .zero
        sendButton.isPointerInteractionEnabled = true
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if isRunning { onStop?() } else { onSend?() }
        }, for: .primaryActionTriggered)

        let editLabel = UILabel()
        editLabel.text = "Editing message. Sending replaces it and everything after."
        editLabel.font = .preferredFont(forTextStyle: .footnote)
        editLabel.adjustsFontForContentSizeCategory = true
        editLabel.textColor = .secondaryLabel
        editLabel.numberOfLines = 0
        let cancelEdit = HitButton(configuration: .plain())
        cancelEdit.configuration?.title = "Cancel"
        cancelEdit.configuration?.buttonSize = .small
        cancelEdit.isPointerInteractionEnabled = true
        cancelEdit.setContentHuggingPriority(.required, for: .horizontal)
        cancelEdit.setContentCompressionResistancePriority(.required, for: .horizontal)
        cancelEdit.addAction(UIAction { [weak self] _ in self?.onCancelEdit?() }, for: .primaryActionTriggered)
        let editIcon = UIImageView(image: UIImage(systemName: "pencil"))
        editIcon.tintColor = .secondaryLabel
        editIcon.setContentHuggingPriority(.required, for: .horizontal)
        [editIcon, editLabel, cancelEdit].forEach(editBanner.addArrangedSubview)
        editBanner.spacing = 6
        editBanner.alignment = .center
        editBanner.isHidden = true

        attachButton.configuration?.image = UIImage(systemName: "paperclip")
        attachButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 2, bottom: 8, trailing: 2)
        attachButton.configuration?.preferredSymbolConfigurationForImage = .init(textStyle: .body)
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.isPointerInteractionEnabled = true
        attachButton.accessibilityLabel = "Attach"
        attachButton.setContentHuggingPriority(.required, for: .horizontal)
        attachButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        micButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 2, bottom: 8, trailing: 2)
        micButton.configuration?.preferredSymbolConfigurationForImage = .init(textStyle: .body)
        micButton.isPointerInteractionEnabled = true
        micButton.isHidden = true
        micButton.setContentHuggingPriority(.required, for: .horizontal)
        micButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        micButton.addAction(UIAction { [weak self] _ in self?.onMic?() }, for: .primaryActionTriggered)
        updateMic()

        chipStack.spacing = 6
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipScroll.showsHorizontalScrollIndicator = false
        chipScroll.addSubview(chipStack)
        chipScroll.isHidden = true
        NSLayoutConstraint.activate([
            chipStack.topAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: chipScroll.contentLayoutGuide.trailingAnchor),
            chipStack.heightAnchor.constraint(equalTo: chipScroll.frameLayoutGuide.heightAnchor),
        ])

        // The field gets the whole width; the controls sit in a row beneath it.
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = UIStackView(arrangedSubviews: [modeButton, attachButton, spacer, micButton, sendButton])
        controls.spacing = 8
        controls.alignment = .center
        controls.setCustomSpacing(2, after: micButton)
        let stack = UIStackView(arrangedSubviews: [statusView, editBanner, chipScroll, textView, controls])
        stack.setCustomSpacing(2, after: textView)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        if #available(iOS 26, *) {
            // A floating glass panel at the readable width; the chat scrolls under it.
            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.layer.cornerRadius = 26
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
            glass.contentView.addSubview(stack)
            addSubview(glass)
            glass.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                glass.leadingAnchor.constraint(equalTo: readableContentGuide.leadingAnchor, constant: -8),
                glass.trailingAnchor.constraint(equalTo: readableContentGuide.trailingAnchor, constant: 8),
                stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -6),
                stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -10),
            ])
        } else {
            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            blur.translatesAutoresizingMaskIntoConstraints = false
            addSubview(blur)
            addSubview(stack)
            NSLayoutConstraint.activate([
                blur.topAnchor.constraint(equalTo: topAnchor),
                blur.leadingAnchor.constraint(equalTo: leadingAnchor),
                blur.trailingAnchor.constraint(equalTo: trailingAnchor),
                blur.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 100),  // under the home indicator too
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                stack.leadingAnchor.constraint(equalTo: readableContentGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: readableContentGuide.trailingAnchor),
            ])
        }

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            heightConstraint,
            modeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 15),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -10),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 9),
        ])
        placeholder.numberOfLines = 1
        updateButton()
        updateForTextSize()
        // Dynamic Type changes the line height, and so the six-line limit, the send glyph and
        // whether the mode button has room for its title.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.updateForTextSize()
            self.updateHeight()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The mode button's title and symbol. At accessibility text sizes it shows only the symbol, so
    /// the controls row keeps its room.
    func setMode(title: String, symbol: String) {
        modeTitle = title
        modeButton.configuration?.image = UIImage(systemName: symbol)
        updateModeTitle()
    }

    private var isAccessibilitySize: Bool { traitCollection.preferredContentSizeCategory.isAccessibilityCategory }

    private func updateModeTitle() {
        modeButton.configuration?.title = isAccessibilitySize ? nil : modeTitle
        // Alone, the symbol can be bigger than beside a title, but not so big it outgrows the button.
        modeButton.configuration?.preferredSymbolConfigurationForImage = isAccessibilitySize
            ? .init(pointSize: 24) : .init(textStyle: .footnote)
    }

    private func updateForTextSize() {
        updateModeTitle()
        // The send glyph grows with the text, up to a point.
        let size = min(56, UIFontMetrics(forTextStyle: .body).scaledValue(for: 30, compatibleWith: traitCollection))
        sendButton.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: size)
    }

    func textViewDidChange(_ textView: UITextView) { textDidChange(notify: true) }

    private func textDidChange(notify: Bool) {
        placeholder.isHidden = !textView.text.isEmpty
        updateHeight()
        updateButton()
        if notify { onTextChange?(textView.text) }
    }

    private func updateHeight() {
        let line = textView.font?.lineHeight ?? 20
        let minHeight = max(38, ceil(line) + 18)
        let maxHeight = line * 6 + 18
        guard textView.bounds.width > 0 else {
            heightConstraint.constant = minHeight
            return
        }
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        heightConstraint.constant = min(max(minHeight, fitting), maxHeight)
        textView.isScrollEnabled = fitting > maxHeight
    }

    private var hasText: Bool { !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func updateButton() {
        let name = isRunning ? "stop.circle.fill" : "arrow.up.circle.fill"
        sendButton.configuration?.image = UIImage(systemName: name)
        sendButton.accessibilityLabel = isRunning ? "Stop" : "Send"
        sendButton.isEnabled = isRunning || (canSend && (hasText || !attachments.isEmpty))
    }

    private func updateMic() {
        micButton.configuration?.image = UIImage(systemName: isListening ? "mic.fill" : "mic")
        micButton.configuration?.baseForegroundColor = isListening ? .systemRed : nil
        micButton.accessibilityLabel = isListening ? "Stop dictation" : "Dictate"
        if isListening {
            micButton.imageView?.addSymbolEffect(.pulse, options: .repeating)
        } else {
            micButton.imageView?.removeAllSymbolEffects()
        }
    }

    private func renderChips() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            chipStack.addArrangedSubview(AttachmentChip(attachment) { [weak self] in
                guard let self else { return }
                attachments.removeAll { $0.id == attachment.id }
                onAttachmentsChange?()
            })
        }
        chipScroll.isHidden = attachments.isEmpty
        if let last = chipStack.arrangedSubviews.last {
            layoutIfNeeded()
            chipScroll.scrollRectToVisible(last.frame, animated: false)
        }
    }
}

/// The message field. Tells the composer when its width changes, which only it knows for sure:
/// the composer's own layout runs before the stack view inside it has resized the field.
final class ComposerTextView: UITextView {
    var onWidthChange: (() -> Void)?
    /// Paste with an image or a PDF (and no text) on the pasteboard attaches it instead.
    var onPasteFiles: (([NSItemProvider]) -> Void)?
    private var lastWidth: CGFloat = 0

    private var pasteboardHasFiles: Bool {
        let board = UIPasteboard.general
        return !board.hasStrings && (board.hasImages || board.contains(pasteboardTypes: [UTType.pdf.identifier]))
    }

    override func paste(_ sender: Any?) {
        if let onPasteFiles, pasteboardHasFiles {
            onPasteFiles(UIPasteboard.general.itemProviders)
        } else {
            super.paste(sender)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), onPasteFiles != nil, pasteboardHasFiles { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}
