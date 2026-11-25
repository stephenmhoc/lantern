import UIKit
import UniformTypeIdentifiers

/// The bar under the chat: status strip, attached files, a full-width text view that grows to six
/// lines, and under it the controls: mode menu and attach menu on the left, dictation and Send/Stop
/// on the right. While the keyboard is down and there's nothing to send or edit it collapses to one
/// row: the model's symbol, the field, dictation, and Stop while this chat is answering.
/// On iOS 26 and later it's a floating Liquid Glass panel at the readable width; before that, a
/// full-width blurred bar.
final class ComposerView: UIView, UITextViewDelegate {
    let textView = ComposerTextView()
    let modeButton = HitButton(configuration: .gray())
    /// The collapsed row's model button: the symbol alone, opening the same picker (`syncModeIcon`).
    let modeIconButton = HitButton(configuration: .plain())
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
    private var fieldRow: UIStackView!
    private var controls: UIStackView!
    private var stackTop: NSLayoutConstraint!
    private var stackBottom: NSLayoutConstraint!
    private var insets: (top: CGFloat, bottom: CGFloat) = (8, 8)
    /// The one-row layout, while the keyboard is down and there's nothing to send.
    private(set) var isCollapsed = false
    /// The keyboard's current animation, so collapsing and expanding move with it.
    private var keyboardAnimation: (duration: TimeInterval, curve: UIView.AnimationCurve, at: Date)?
    private var modeTitle = ""
    private let usesGlass: Bool
    private lazy var tap = UIImpactFeedbackGenerator(style: .light, view: self)
    /// The chat's text column; the field's text and the controls line up with its edges.
    let columnGuide = UILayoutGuide()
    private var columnLeading: NSLayoutConstraint!
    private var columnTrailing: NSLayoutConstraint!
    /// Set by the chat from its own layout, so the field lines up with the transcript.
    var columnInsets: (leading: CGFloat, trailing: CGFloat) = (16, 16) {
        didSet {
            columnLeading.constant = columnInsets.leading
            columnTrailing.constant = -columnInsets.trailing
        }
    }
    /// How far the glass panel reaches past the column on each side.
    private static let glassPadding: CGFloat = 12

    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    /// Every edit, for drafts and pre-warming.
    var onTextChange: ((String) -> Void)?
    var onCancelEdit: (() -> Void)?
    var onMic: (() -> Void)?
    /// After a chip's remove button.
    var onAttachmentsChange: (() -> Void)?
    var isRunning = false { didSet { updateButton(); updateCollapsed() } }
    /// Files to send with the next message, shown as chips above the field.
    var attachments: [Attachment] = [] {
        didSet {
            renderChips()
            updateButton()
            updateCollapsed()
            announceAdded(since: oldValue)
        }
    }
    var isListening = false { didSet { updateMic() } }
    var canSend = true { didSet { updateButton() } }
    /// Shows "Editing message" above the field while a sent message is being edited.
    var isEditingMessage = false {
        didSet {
            editBanner.isHidden = !isEditingMessage
            updateCollapsed()
        }
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
        // On glass, no side inset: the text starts on the column edge, in line with the transcript.
        // Before iOS 26 the field is its own grey bubble and keeps its padding.
        let side: CGFloat = usesGlass ? 0 : 10
        textView.textContainerInset = UIEdgeInsets(top: 9, left: side, bottom: 9, right: side)
        if usesGlass { textView.textContainer.lineFragmentPadding = 0 }
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
            // A light tap to confirm the button did something; the keyboard's Return needs none.
            tap.impactOccurred(intensity: isRunning ? 0.8 : 0.5)
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
        micButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Before the microphone starts: haptics are muted while recording.
            tap.impactOccurred(intensity: 0.6)
            onMic?()
        }, for: .primaryActionTriggered)
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

        modeIconButton.isPointerInteractionEnabled = true
        modeIconButton.isHidden = true
        modeIconButton.configuration?.contentInsets = .zero
        modeIconButton.configuration?.baseForegroundColor = .secondaryLabel
        modeIconButton.configuration?.preferredSymbolConfigurationForImage = .init(textStyle: .body)
        modeIconButton.setContentHuggingPriority(.required, for: .horizontal)
        modeIconButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Expanded, the field gets the whole width and the controls sit in a row beneath it;
        // collapsed, the field shares one row with the model's symbol, dictation and Stop.
        fieldRow = UIStackView(arrangedSubviews: [modeIconButton, textView])
        fieldRow.spacing = 8
        fieldRow.alignment = .center
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls = UIStackView(arrangedSubviews: [modeButton, attachButton, spacer, micButton, sendButton])
        controls.spacing = 8
        controls.alignment = .center
        controls.setCustomSpacing(2, after: micButton)
        // At accessibility text sizes the mode button is a bare symbol and the others are small
        // for their text: touch and hold shows each one large, with its name.
        controls.addInteraction(UILargeContentViewerInteraction())
        fieldRow.addInteraction(UILargeContentViewerInteraction())
        for button in [modeButton, modeIconButton, attachButton, micButton, sendButton] {
            button.showsLargeContentViewer = true
            button.scalesLargeContentImage = true
        }
        attachButton.largeContentTitle = "Attach"
        let stack = UIStackView(arrangedSubviews: [statusView, editBanner, chipScroll, fieldRow, controls])
        stack.setCustomSpacing(2, after: fieldRow)
        stack.setCustomSpacing(0, after: statusView)
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addLayoutGuide(columnGuide)
        columnLeading = columnGuide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        columnTrailing = columnGuide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        NSLayoutConstraint.activate([columnLeading, columnTrailing])
        let pad = Self.glassPadding

        if #available(iOS 26, *) {
            // A floating glass panel just wider than the text column; the chat scrolls under it.
            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.layer.cornerRadius = 26
            glass.layer.cornerCurve = .continuous
            glass.clipsToBounds = true
            glass.contentView.addSubview(stack)
            addSubview(glass)
            glass.translatesAutoresizingMaskIntoConstraints = false
            insets = (10, 8)
            stackTop = stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: insets.top)
            stackBottom = stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -insets.bottom)
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                glass.leadingAnchor.constraint(equalTo: columnGuide.leadingAnchor, constant: -pad),
                glass.trailingAnchor.constraint(equalTo: columnGuide.trailingAnchor, constant: pad),
                stackTop, stackBottom,
                stack.leadingAnchor.constraint(equalTo: columnGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: columnGuide.trailingAnchor),
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
            ])
            stackTop = stack.topAnchor.constraint(equalTo: topAnchor, constant: insets.top)
            stackBottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
            NSLayoutConstraint.activate([
                stackTop, stackBottom,
                stack.leadingAnchor.constraint(equalTo: columnGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: columnGuide.trailingAnchor),
            ])
        }

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            heightConstraint,
            modeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            modeIconButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            modeIconButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: usesGlass ? 0 : 15),
            // The visible width, not the trailing anchor: a text view's anchors are its content's
            // edges, so in the collapsed row a long placeholder ran on under the mic.
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: textView.frameLayoutGuide.widthAnchor, constant: usesGlass ? 0 : -25),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 9),
        ])
        placeholder.numberOfLines = 1
        updateButton()
        updateForTextSize()
        updateCollapsed(animated: false)
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillMove(_:)), name: name, object: nil)
        }
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
        modeIconButton.configuration?.image = UIImage(systemName: symbol)
        modeIconButton.largeContentTitle = title
        modeIconButton.largeContentImage = UIImage(systemName: symbol)
        modeButton.largeContentTitle = title
        modeButton.largeContentImage = UIImage(systemName: symbol)
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
    func textViewDidBeginEditing(_ textView: UITextView) { updateCollapsed() }
    func textViewDidEndEditing(_ textView: UITextView) { updateCollapsed() }

    private func textDidChange(notify: Bool) {
        placeholder.isHidden = !textView.text.isEmpty
        updateHeight()
        updateButton()
        updateCollapsed()
        if notify { onTextChange?(textView.text) }
    }

    /// Copies the mode button's menu, state and VoiceOver text onto the collapsed row's symbol
    /// button. The chat calls it after setting up `modeButton`.
    func syncModeIcon() {
        modeIconButton.isEnabled = modeButton.isEnabled
        modeIconButton.accessibilityLabel = modeButton.accessibilityLabel
        modeIconButton.accessibilityValue = modeButton.accessibilityValue
    }

    @objc private func keyboardWillMove(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)
            .flatMap { UIView.AnimationCurve(rawValue: $0.intValue) } ?? .easeInOut
        keyboardAnimation = (duration, curve, Date())
        updateCollapsed()
    }

    /// Collapsed while the field isn't focused and holds nothing: no text, no files, no edit.
    private var wantsCollapsed: Bool {
        !textView.isFirstResponder && textView.text.isEmpty && attachments.isEmpty && !isEditingMessage
    }

    /// Switches between the one-row and the full layout, moving with the keyboard when it's the
    /// keyboard that caused it (its notification and the field's focus change arrive together).
    private func updateCollapsed(animated: Bool = true) {
        let collapse = wantsCollapsed
        // Collapsed there's never anything to send, so its button is only ever Stop.
        let sendHidden = collapse && !isRunning
        if sendButton.isHidden != sendHidden, collapse == isCollapsed {
            sendButton.isHidden = sendHidden
        }
        guard collapse != isCollapsed || !animated else { return }
        isCollapsed = collapse
        let apply = { [self] in
            modeIconButton.isHidden = !collapse
            controls.isHidden = collapse
            // Dictation and Send/Stop move to whichever row is showing.
            let row: UIStackView = collapse ? fieldRow : controls
            row.addArrangedSubview(micButton)
            row.addArrangedSubview(sendButton)
            row.setCustomSpacing(2, after: micButton)
            sendButton.isHidden = sendHidden
            stackTop.constant = collapse ? 3 : insets.top
            stackBottom.constant = -(collapse ? 3 : insets.bottom)
        }
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            apply()
            return
        }
        let keyboard = keyboardAnimation.flatMap { Date().timeIntervalSince($0.at) < 0.3 ? $0 : nil }
        let animator = UIViewPropertyAnimator(duration: keyboard?.duration ?? 0.25, curve: keyboard?.curve ?? .easeInOut) {
            apply()
            self.superview?.layoutIfNeeded()
        }
        animator.startAnimation()
    }

    private func updateHeight() {
        let line = textView.font?.lineHeight ?? 20
        let minHeight = max(38, ceil(line) + 18)
        // Six lines, but at the largest text sizes six lines would cover most of an iPhone over
        // the keyboard: no more than a third of the window there, and always at least two lines.
        var maxHeight = line * 6 + 18
        if let window, isAccessibilitySize {
            maxHeight = max(line * 2 + 18, min(maxHeight, window.bounds.height / 3))
        }
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
        sendButton.accessibilityUserInputLabels = isRunning ? ["Stop", "Stop answer"] : ["Send"]
        sendButton.largeContentTitle = sendButton.accessibilityLabel
        sendButton.largeContentImage = UIImage(systemName: name)
        sendButton.isEnabled = isRunning || (canSend && (hasText || !attachments.isEmpty))
    }

    private func updateMic() {
        micButton.configuration?.image = UIImage(systemName: isListening ? "mic.fill" : "mic")
        micButton.configuration?.baseForegroundColor = isListening ? .systemRed : nil
        micButton.accessibilityLabel = isListening ? "Stop dictation" : "Dictate"
        micButton.accessibilityUserInputLabels = isListening ? ["Stop dictation", "Stop listening"] : ["Dictate", "Microphone"]
        micButton.accessibilityValue = isListening ? "Listening" : nil
        micButton.largeContentTitle = micButton.accessibilityLabel
        micButton.largeContentImage = micButton.configuration?.image
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
                self?.remove(attachment)
            })
        }
        chipScroll.isHidden = attachments.isEmpty
        chipScroll.accessibilityContainerType = .semanticGroup
        chipScroll.accessibilityLabel = attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments"
        if let last = chipStack.arrangedSubviews.last {
            layoutIfNeeded()
            chipScroll.scrollRectToVisible(last.frame, animated: false)
        }
    }

    private func remove(_ attachment: Attachment) {
        guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
        tap.impactOccurred(intensity: 0.5)
        attachments.remove(at: index)
        onAttachmentsChange?()
        // The chip VoiceOver was on is gone: go on to the next one, or back to the field.
        let chips = chipStack.arrangedSubviews.compactMap { $0 as? AttachmentChip }
        let next: UIView = chips.isEmpty ? textView : chips[min(index, chips.count - 1)].info
        UIAccessibility.post(notification: .layoutChanged, argument: next)
        UIAccessibility.post(notification: .announcement, argument: "Removed \(attachment.name)")
    }

    /// Files and photos come in from menus, drops and paste with nothing else to show they've
    /// arrived than a chip VoiceOver isn't on: say so.
    private func announceAdded(since old: [Attachment]) {
        let before = Set(old.map(\.id))
        let added = attachments.filter { !before.contains($0.id) }
        guard !added.isEmpty, UIAccessibility.isVoiceOverRunning else { return }
        let names = added.count == 1 ? added[0].name : "\(added.count) files"
        UIAccessibility.post(notification: .announcement, argument: "Attached \(names)")
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
