import UIKit

/// The bar under the chat: status strip, mode menu, a text view that grows to six lines, Send/Stop.
/// On iOS 26 and later it's a floating Liquid Glass panel at the readable width; before that, a
/// full-width blurred bar.
final class ComposerView: UIView, UITextViewDelegate {
    let textView = ComposerTextView()
    let modeButton = HitButton(configuration: .gray())
    let sendButton = HitButton(configuration: .plain())
    private let placeholder = UILabel()
    private let editBanner = UIStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var modeTitle = ""
    private let usesGlass: Bool

    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    /// Every edit, for drafts and pre-warming.
    var onTextChange: ((String) -> Void)?
    var onCancelEdit: (() -> Void)?
    var isRunning = false { didSet { updateButton() } }
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

        let row = UIStackView(arrangedSubviews: [modeButton, textView, sendButton])
        row.spacing = 8
        row.alignment = .bottom
        let stack = UIStackView(arrangedSubviews: [statusView, editBanner, row])
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
                stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
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
            modeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
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
    /// the message field keeps its room.
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
        sendButton.isEnabled = isRunning || (canSend && hasText)
    }
}

/// The message field. Tells the composer when its width changes, which only it knows for sure:
/// the composer's own layout runs before the stack view inside it has resized the field.
final class ComposerTextView: UITextView {
    var onWidthChange: (() -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onWidthChange?()
        }
    }
}
