import LlamaKit
import UIKit

/// A non-scrolling, selectable text view: partial selection, Copy, Look Up, and tappable phone
/// numbers and addresses.
private func makeTextView(style: UIFont.TextStyle = .body, color: UIColor = .label) -> UITextView {
    styled(UITextView(), style: style, color: color)
}

private func styled<T: UITextView>(_ view: T, style: UIFont.TextStyle, color: UIColor) -> T {
    view.isEditable = false
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.font = .preferredFont(forTextStyle: style)
    view.textColor = color
    view.adjustsFontForContentSizeCategory = true
    view.dataDetectorTypes = [.phoneNumber, .address, .link]
    return view
}

/// A selectable, non-scrolling text view that draws Markdown like an answer in the transcript
/// (code blocks with their Copy buttons, tables), for showing answers elsewhere (CompareView).
func makeAnswerTextView() -> UITextView {
    styled(AnswerTextView(), style: .body, color: .label)
}

/// The answer's text view, on TextKit 1 with `BlockLayoutManager` so code blocks and tables get
/// one even background each. Each code block gets a real Copy button at the end of its first line,
/// placed after layout, so it stays put while the reply streams.
private final class AnswerTextView: UITextView {
    private let storage = NSTextStorage()  // the text view doesn't keep its own storage alive
    private var copyButtons: [HitButton] = []
    private var copied: Int?
    private var copiedReset: Task<Void, Never>?

    init() {
        let layout = BlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.copyButtons.forEach { $0.setNeedsUpdateConfiguration() }
            self.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var attributedText: NSAttributedString! {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeCopyButtons()
    }

    /// For a reused cell: no button still says "Copied".
    func resetCopied() {
        copiedReset?.cancel()
        copied = nil
        for button in copyButtons { style(button, copied: false) }
    }

    /// The character ranges of the code blocks' first lines, in order.
    private var codeHeaders: [NSRange] {
        var headers: [NSRange] = []
        textStorage.enumerateAttribute(.lanternCode, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            if value != nil { headers.append(range) }
        }
        return headers
    }

    private func placeCopyButtons() {
        let headers = codeHeaders
        while copyButtons.count < headers.count { copyButtons.append(makeCopyButton(index: copyButtons.count)) }
        for (i, button) in copyButtons.enumerated() {
            button.isHidden = i >= headers.count
            guard i < headers.count else { continue }
            let glyph = layoutManager.glyphIndexForCharacter(at: headers[i].location)
            let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let size = button.intrinsicContentSize
            button.frame = CGRect(
                x: bounds.width - Markdown.blockInset - size.width,
                y: textContainerInset.top + line.midY - size.height / 2,
                width: size.width, height: size.height
            ).integral
        }
        // The text view is one accessibility element, so VoiceOver can't reach the buttons inside it.
        let actions = headers.indices.map { i in
            UIAccessibilityCustomAction(name: headers.count == 1 ? "Copy code" : "Copy code block \(i + 1)") { [weak self] _ in
                self?.copyCode(i)
                return true
            }
        }
        if accessibilityCustomActions?.count != actions.count { accessibilityCustomActions = actions }
    }

    private func makeCopyButton(index: Int) -> HitButton {
        let button = HitButton(configuration: .plain())
        button.isPointerInteractionEnabled = true
        button.showsHover()
        style(button, copied: false)
        button.addAction(UIAction { [weak self] _ in self?.copyCode(index) }, for: .primaryActionTriggered)
        addSubview(button)
        return button
    }

    private func style(_ button: UIButton, copied: Bool) {
        var config = UIButton.Configuration.plain()
        config.title = copied ? "Copied" : "Copy"
        config.image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc")
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        config.baseForegroundColor = copied ? .tintColor : .secondaryLabel
        config.preferredSymbolConfigurationForImage = .init(textStyle: .caption1, scale: .small)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .caption1).bold()
            return attributes
        }
        button.configuration = config
        button.accessibilityLabel = copied ? "Copied" : "Copy code"
    }

    private func copyCode(_ index: Int) {
        let headers = codeHeaders
        guard headers.indices.contains(index),
              let code = textStorage.attribute(.lanternCode, at: headers[index].location, effectiveRange: nil) as? String
        else { return }
        UIPasteboard.general.string = code
        UIAccessibility.post(notification: .announcement, argument: "Code copied")
        if let old = copied, copyButtons.indices.contains(old) { style(copyButtons[old], copied: false) }
        copied = index
        style(copyButtons[index], copied: true)
        setNeedsLayout()  // "Copied" is wider than "Copy"
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            resetCopied()
            setNeedsLayout()
        }
    }
}

final class UserCell: UICollectionViewCell {
    private let bubble = UIView()
    private let textView = makeTextView()
    private let files = UIStackView()
    private let dateLabel = UILabel()
    private var renderedFiles: [Attachment]?
    private var belowDate: NSLayoutConstraint!
    private var atTop: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.directionalLayoutMargins.leading = 0
        contentView.directionalLayoutMargins.trailing = 0  // the section's readable-width insets are the margins
        bubble.backgroundColor = .userBubble
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        // The bubble takes the touches, so long-press and right-click open the message's menu.
        textView.isUserInteractionEnabled = false
        files.axis = .vertical
        files.alignment = .leading
        files.spacing = 4
        // The date note the model was given, shown small above the bubble.
        dateLabel.font = .preferredFont(forTextStyle: .caption2)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .secondaryLabel  // tertiary is under 3:1 in dark mode
        dateLabel.textAlignment = .right
        let content = UIStackView(arrangedSubviews: [files, textView])
        content.axis = .vertical
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dateLabel)
        contentView.addSubview(bubble)
        bubble.addSubview(content)
        atTop = bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4)
        belowDate = bubble.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 3)
        NSLayoutConstraint.activate([
            atTop,
            dateLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.layoutMarginsGuide.leadingAnchor),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubble.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.layoutMarginsGuide.leadingAnchor, constant: 48),
            content.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            content.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            content.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The bubble, for the context menu's preview.
    var previewView: UIView { bubble }

    func configure(_ message: StoredMessage, editing: Bool) {
        textView.text = message.content
        textView.isHidden = message.content.isEmpty
        if renderedFiles != message.attachments {
            renderedFiles = message.attachments
            files.arrangedSubviews.forEach { $0.removeFromSuperview() }
            (message.attachments ?? []).forEach { files.addArrangedSubview(AttachmentChip($0)) }
        }
        files.isHidden = !message.hasAttachments
        dateLabel.text = message.dateNote?.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        dateLabel.isHidden = message.dateNote == nil
        atTop.isActive = dateLabel.isHidden
        belowDate.isActive = !dateLabel.isHidden
        bubble.alpha = editing ? 0.5 : 1
        let names = (message.attachments ?? []).map(\.name).joined(separator: ", ")
        accessibilityLabel = "You: \(message.content)" + (names.isEmpty ? "" : ". Attached: \(names)")
        accessibilityValue = editing ? "Editing" : nil
    }
}

/// What an answer's cell shows.
struct AssistantContent {
    var message: StoredMessage
    /// Set while this reply is being written.
    var live: LiveReply?
    var status: ReplyStatus?
    var thinkingExpanded = false
    /// Buttons under an error: Retry, Download, Check the Mac.
    var errorActions: [UIAction] = []
}

final class AssistantCell: UICollectionViewCell, UITextViewDelegate {
    private let glow = GlowView()
    private let status = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let thoughtTail = UILabel()
    private let thinkingButton = UIButton(configuration: .plain())
    private let thinkingText = makeTextView(style: .callout, color: .secondaryLabel)
    /// The thought process, set off from the answer by a bar down its leading edge.
    private let thinkingBox = UIView()
    /// "Searched for “…”": its menu lists each search's sources, which open in the browser.
    private let searchButton = UIButton(configuration: .plain())
    private var renderedSearches: [WebSearch]?
    private let answer = styled(AnswerTextView(), style: .body, color: .label)
    private let errorLabel = UILabel()
    private let errorRow = UIStackView()
    private let footnote = UILabel()
    private let previousButton = HitButton(configuration: .plain())
    private let nextButton = HitButton(configuration: .plain())
    private let versionLabel = UILabel()
    private let moreButton = HitButton(configuration: .plain())
    /// Opens the comparison, on an answer that has one.
    private let compareButton = HitButton(configuration: .plain())
    private lazy var statusRow = UIStackView(arrangedSubviews: [glow, status])
    private lazy var versionRow = HitStackView(arrangedSubviews: [previousButton, versionLabel, nextButton])
    private lazy var footerButtons = HitStackView(arrangedSubviews: [compareButton, moreButton])
    /// Keeps the buttons at the trailing edge while the footnote is on its own line below.
    private let footerSpacer = UIView()
    /// One row, or at accessibility text sizes a column (pager, then footnote, then buttons), so the
    /// footnote never gets squeezed down to a sliver beside 44 pt buttons.
    private lazy var footerRow = UIStackView(arrangedSubviews: [versionRow, footnote, footerSpacer, footerButtons])
    private lazy var body = UIStackView(arrangedSubviews: [
        statusRow, progress, thoughtTail, thinkingButton, thinkingBox, searchButton, answer, errorLabel, errorRow, footerRow,
    ])
    /// The footnote moves under the row when beside the pager and buttons it would take more than two lines.
    private var footnoteBelow = false

    var onToggleThinking: (() -> Void)?
    /// -1 for the previous answer to this question, +1 for the next.
    var onSwitchVersion: ((Int) -> Void)?
    var onCompare: (() -> Void)?
    /// The message's actions, built when a menu opens so they're never stale.
    var menuItems: (() -> [UIMenuElement])?

    private var text = ""
    private var renderedKey: String?

    /// The answer, for the context menu's preview.
    var previewView: UIView { answer.isHidden ? contentView : answer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.directionalLayoutMargins.leading = 0
        contentView.directionalLayoutMargins.trailing = 0  // the section's readable-width insets are the margins

        status.font = .preferredFont(forTextStyle: .callout)
        status.textColor = .secondaryLabel
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        statusRow.spacing = 8
        statusRow.alignment = .center
        glow.setContentHuggingPriority(.required, for: .horizontal)
        progress.trackTintColor = .tertiarySystemFill
        progress.progressTintColor = GlowView.amber
        progress.isAccessibilityElement = false  // the status line says the percentage

        thoughtTail.font = .preferredFont(forTextStyle: .footnote)
        thoughtTail.adjustsFontForContentSizeCategory = true
        thoughtTail.textColor = .secondaryLabel  // tertiary is too faint for text read while it streams
        thoughtTail.numberOfLines = 2
        thoughtTail.accessibilityLabel = "Latest thought"

        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0)
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = .secondaryLabel
        config.preferredSymbolConfigurationForImage = .init(textStyle: .caption1)
        thinkingButton.configuration = config
        thinkingButton.contentHorizontalAlignment = .leading
        thinkingButton.isPointerInteractionEnabled = true
        thinkingButton.showsHover()
        thinkingButton.addAction(UIAction { [weak self] _ in self?.onToggleThinking?() }, for: .primaryActionTriggered)

        var search = config
        search.imagePlacement = .leading
        search.imagePadding = 6
        search.image = UIImage(systemName: "magnifyingglass")
        search.titleLineBreakMode = .byTruncatingTail
        searchButton.configuration = search
        searchButton.contentHorizontalAlignment = .leading
        searchButton.isPointerInteractionEnabled = true
        searchButton.showsHover()
        searchButton.showsMenuAsPrimaryAction = true
        searchButton.isHidden = true

        let thinkingBar = UIView()
        thinkingBar.backgroundColor = .tertiaryLabel  // .separator all but vanishes in dark mode
        thinkingBar.layer.cornerRadius = 1
        thinkingBar.translatesAutoresizingMaskIntoConstraints = false
        thinkingText.translatesAutoresizingMaskIntoConstraints = false
        thinkingBox.addSubview(thinkingBar)
        thinkingBox.addSubview(thinkingText)
        NSLayoutConstraint.activate([
            thinkingBar.leadingAnchor.constraint(equalTo: thinkingBox.leadingAnchor, constant: 2),
            thinkingBar.widthAnchor.constraint(equalToConstant: 2),
            thinkingBar.topAnchor.constraint(equalTo: thinkingBox.topAnchor, constant: 2),
            thinkingBar.bottomAnchor.constraint(equalTo: thinkingBox.bottomAnchor, constant: -2),
            thinkingText.leadingAnchor.constraint(equalTo: thinkingBar.trailingAnchor, constant: 12),
            thinkingText.trailingAnchor.constraint(equalTo: thinkingBox.trailingAnchor),
            thinkingText.topAnchor.constraint(equalTo: thinkingBox.topAnchor),
            thinkingText.bottomAnchor.constraint(equalTo: thinkingBox.bottomAnchor),
        ])

        answer.delegate = self

        footnote.font = .preferredFont(forTextStyle: .caption2)
        footnote.textColor = .secondaryLabel  // tertiary is under 3:1 in dark mode
        footnote.adjustsFontForContentSizeCategory = true
        footnote.numberOfLines = 0

        for (button, symbol, label) in [(moreButton, "ellipsis.circle", "More"),
                                        (previousButton, "chevron.left", "Previous answer"),
                                        (nextButton, "chevron.right", "Next answer")] {
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.contentInsets = .zero
            button.configuration?.preferredSymbolConfigurationForImage = .init(textStyle: .footnote)
            button.isPointerInteractionEnabled = true
            button.accessibilityLabel = label
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumTarget).isActive = true
            button.showsHover()
        }
        // Narrow frames so the pager and ⋯ sit compactly, each with a 44 × 44 pt touch area that
        // reaches into the space beside it but never into a neighbour's: ‹ covers 0–44 (over the
        // start of "1/2"), › starts after the label and reaches into the gap before the footnote,
        // ⋯ reaches back into the 12 pt gap before it.
        for button in [previousButton, nextButton] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        previousButton.hitOutsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 20)
        nextButton.hitOutsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 16)
        moreButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        moreButton.hitOutsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menuItems?() ?? [])
        }])
        var compare = UIButton.Configuration.plain()
        compare.title = "Compare"
        compare.image = UIImage(systemName: "rectangle.split.2x1")
        compare.imagePadding = 4
        compare.contentInsets = .zero
        compare.baseForegroundColor = .secondaryLabel
        compare.preferredSymbolConfigurationForImage = .init(textStyle: .caption1, scale: .small)
        compare.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .caption1)
            return attributes
        }
        compareButton.configuration = compare
        compareButton.isPointerInteractionEnabled = true
        if Device.isMac { compareButton.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6) }
        compareButton.showsHover()
        compareButton.accessibilityLabel = "Compare answers"
        compareButton.setContentHuggingPriority(.required, for: .horizontal)
        compareButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        compareButton.addAction(UIAction { [weak self] _ in self?.onCompare?() }, for: .primaryActionTriggered)
        compareButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            compareButton.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumTarget),
            compareButton.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumTarget),
        ])
        previousButton.addAction(UIAction { [weak self] _ in self?.onSwitchVersion?(-1) }, for: .primaryActionTriggered)
        nextButton.addAction(UIAction { [weak self] _ in self?.onSwitchVersion?(1) }, for: .primaryActionTriggered)
        versionLabel.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        versionLabel.textColor = .secondaryLabel
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)  // or the footnote squeezes "1/2" out
        versionRow.spacing = 4
        versionRow.alignment = .center
        footerButtons.spacing = 12
        footerButtons.alignment = .center
        footerSpacer.isHidden = true
        for row in [versionRow, footerButtons] {
            row.setContentHuggingPriority(.required, for: .horizontal)
            row.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        layoutFooter()

        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true
        errorRow.spacing = 8
        errorRow.alignment = .leading

        let stack = body
        stack.setCustomSpacing(-6, after: footerRow)  // a footnote moved below sits close under the 44 pt row
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.setCustomSpacing(4, after: statusRow)
        stack.setCustomSpacing(2, after: thinkingButton)
        stack.setCustomSpacing(14, after: thinkingBox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            glow.widthAnchor.constraint(equalToConstant: 22),
            glow.heightAnchor.constraint(equalToConstant: 22),
        ])
        glow.stop()

        // Dynamic Type: render the Markdown again at the new sizes.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.renderAnswer()
            self.layoutFooter()
            self.versionLabel.font = .monospacedDigitSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: self.traitCollection).pointSize,
                weight: .regular)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A row beside the footnote normally; a column at accessibility text sizes.
    private func layoutFooter() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        footerRow.axis = large ? .vertical : .horizontal
        footerRow.alignment = large ? .leading : .center
        footerRow.spacing = large ? 4 : 10
        placeFootnote(width: body.bounds.width)
    }

    /// Beside the pager and buttons if it fits there in two lines, else on its own line under them.
    private func placeFootnote(width: CGFloat) {
        guard footerRow.axis == .horizontal, width > 0, let text = footnote.text, !text.isEmpty else {
            if footerRow.axis == .vertical || footnote.text?.isEmpty != false { moveFootnote(below: false) }
            return
        }
        var room = width
        for row in [versionRow, footerButtons] where !row.isHidden {
            room -= row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + footerRow.spacing
        }
        let font = footnote.font ?? .preferredFont(forTextStyle: .caption2)
        let height = room <= 40 ? .infinity : (text as NSString).boundingRect(
            with: CGSize(width: room, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin],
            attributes: [.font: font], context: nil).height
        moveFootnote(below: (height / font.lineHeight).rounded() > 2)
    }

    private func moveFootnote(below: Bool) {
        guard below != footnoteBelow else { return }
        footnoteBelow = below
        footnote.removeFromSuperview()
        if below, let i = body.arrangedSubviews.firstIndex(of: footerRow) {
            body.insertArrangedSubview(footnote, at: i + 1)
        } else {
            footerRow.insertArrangedSubview(footnote, at: 1)
        }
        footerSpacer.isHidden = !footnoteBelow
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontal: UILayoutPriority,
        verticalFittingPriority vertical: UILayoutPriority
    ) -> CGSize {
        placeFootnote(width: targetSize.width - contentView.layoutMargins.left - contentView.layoutMargins.right)
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontal,
                                             verticalFittingPriority: vertical)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderedKey = nil
        renderedSearches = nil
        answer.resetCopied()
    }

    func configure(_ content: AssistantContent) {
        let message = content.message
        let live = content.live
        let thinking = live?.thinking ?? message.thinking
        text = live?.text ?? message.content
        #if DEBUG
        #endif

        // While it's being written: the glow, what it's doing and for how long, and progress.
        let statusText = content.status?.text ?? (message.finished ? nil : "Interrupted: Lantern closed before this finished.")
        statusRow.isHidden = statusText == nil
        status.text = statusText
        status.accessibilityLabel = content.status?.accessibilityText
        if let s = content.status {
            glow.start()
            glow.intensity = s.intensity
        } else {
            glow.stop()
        }
        if let p = content.status?.progress {
            progress.isHidden = false
            progress.setProgress(Float(p), animated: true)
        } else {
            progress.isHidden = true
        }

        thinkingButton.isHidden = thinking.isEmpty
        let thinkingNow = live != nil && text.isEmpty
        thinkingButton.configuration?.title = thinkingNow ? "Thinking" : "Thought process"
        thinkingButton.configuration?.image = UIImage(systemName: content.thinkingExpanded ? "chevron.down" : "chevron.right")
        thinkingButton.accessibilityValue = content.thinkingExpanded ? "Shown" : "Hidden"
        thinkingBox.isHidden = thinking.isEmpty || !content.thinkingExpanded
        if !thinkingBox.isHidden, thinkingText.text != thinking { thinkingText.text = thinking }
        thoughtTail.isHidden = !(thinkingNow && !thinking.isEmpty && !content.thinkingExpanded)
        if !thoughtTail.isHidden { thoughtTail.text = Self.tail(of: thinking) }

        showSearches(live?.searches ?? message.searches ?? [])

        answer.isHidden = text.isEmpty
        let before = renderedKey
        renderAnswer()
        if live != nil, renderedKey != before { glow.flicker() }
        if live != nil {
            answer.accessibilityTraits.insert(.updatesFrequently)
        } else {
            answer.accessibilityTraits.remove(.updatesFrequently)
        }

        errorLabel.isHidden = message.error == nil
        errorLabel.text = message.error
        errorRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for action in live == nil ? content.errorActions : [] {
            var config = UIButton.Configuration.bordered()
            config.buttonSize = .small
            config.cornerStyle = .capsule
            config.imagePadding = 4
            let button = UIButton(configuration: config, primaryAction: action)
            button.isPointerInteractionEnabled = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumTarget).isActive = true
            errorRow.addArrangedSubview(button)
        }
        errorRow.addArrangedSubview(UIView())  // keeps the buttons at their natural width
        errorRow.isHidden = errorRow.arrangedSubviews.count == 1

        var notes: [String] = []
        if let f = message.footnote { notes.append(ReplyFootnote.shown(f)) }
        notes.removeAll(where: \.isEmpty)
        footnote.text = notes.joined(separator: " · ")

        let (versions, current) = message.allVersions
        versionRow.isHidden = versions.count < 2 || live != nil
        versionLabel.text = "\(current + 1)/\(versions.count)"
        previousButton.isEnabled = current > 0
        nextButton.isEnabled = current < versions.count - 1
        versionLabel.accessibilityLabel = "Answer \(current + 1) of \(versions.count)"
        previousButton.accessibilityValue = "\(current + 1) of \(versions.count)"
        nextButton.accessibilityValue = previousButton.accessibilityValue

        compareButton.isHidden = message.comparison == nil || live != nil
        moreButton.isHidden = live != nil
        footerRow.isHidden = live != nil
        footnote.isHidden = live != nil  // also when it's below the row
        placeFootnote(width: body.bounds.width)
    }

    /// One line for the searches the model ran, with their sources in its menu: a section per
    /// search, a row per page (its site underneath), or why the search failed.
    private func showSearches(_ searches: [WebSearch]) {
        searchButton.isHidden = searches.isEmpty
        guard searches != renderedSearches else { return }
        renderedSearches = searches
        guard !searches.isEmpty else { return }
        let failed = searches.allSatisfy { $0.error != nil }
        let title = failed ? "Couldn't search the web"
            : searches.count == 1 ? "Searched for “\(searches[0].query)”"
            : "Searched the web \(searches.count) times"
        searchButton.configuration?.title = title
        searchButton.configuration?.image = UIImage(systemName: failed ? "exclamationmark.magnifyingglass" : "magnifyingglass")
        let sources = searches.reduce(0) { $0 + $1.results.count }
        searchButton.accessibilityLabel = title
        searchButton.accessibilityValue = failed ? nil : "\(sources) sources"
        searchButton.accessibilityHint = "Shows the sources"
        searchButton.menu = UIMenu(children: searches.map { search in
            let rows: [UIMenuElement] = if let error = search.error {
                [UIAction(title: error, attributes: .disabled) { _ in }]
            } else if search.results.isEmpty {
                [UIAction(title: "No results", attributes: .disabled) { _ in }]
            } else {
                search.results.compactMap { result in
                    guard let url = URL(string: result.url) else { return nil }
                    let site = url.host()?.replacingOccurrences(of: "www.", with: "") ?? result.url
                    return UIAction(title: result.title, subtitle: result.published.map { "\(site) · \($0)" } ?? site, image: UIImage(systemName: "safari")) { _ in
                        UIApplication.shared.open(url)
                    }
                }
            }
            return UIMenu(title: "“\(search.query)”", options: .displayInline, children: rows)
        })
    }

    /// The last line or two of the thought stream, for under the status while it thinks.
    private static func tail(of thinking: String) -> String {
        let flat = thinking.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        guard flat.count > 140 else { return flat }
        var cut = String(flat.suffix(140))
        if let space = cut.firstIndex(of: " ") { cut = String(cut[cut.index(after: space)...]) }
        return "…" + cut
    }

    private func renderAnswer() {
        let key = "\(traitCollection.preferredContentSizeCategory.rawValue)|\(text)"
        guard key != renderedKey else { return }
        renderedKey = key
        answer.attributedText = Markdown.render(text, traits: traitCollection)
    }

    // MARK: - The answer's own actions in its text menu

    /// Long-press or right-click on the answer's text selects it; its menu gets the answer's actions too.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let extra = menuItems?() ?? []
        guard !extra.isEmpty else { return nil }
        return UIMenu(children: suggestedActions + [UIMenu(title: "Answer", options: .displayInline, children: extra)])
    }
}

/// The smallest a control's target gets: 44 pt for a finger, 28 for the Mac's pointer.
let minimumTarget: CGFloat = Device.isMac ? 28 : 44

extension UIView {
    /// The Mac: a faint rounded fill while the pointer is over the control, as a Mac's borderless
    /// buttons have. Nothing elsewhere, where the pointer effect does it.
    func showsHover(radius: CGFloat = 6) {
        #if targetEnvironment(macCatalyst)
        addGestureRecognizer(UIHoverGestureRecognizer(target: HoverFill.shared, action: #selector(HoverFill.hover(_:))))
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private final class HoverFill: NSObject {
    static let shared = HoverFill()

    @objc func hover(_ recognizer: UIHoverGestureRecognizer) {
        let inside = recognizer.state == .began || recognizer.state == .changed
        recognizer.view?.backgroundColor = inside ? .quaternarySystemFill : .clear
    }
}
#endif

/// A button whose touch and pointer target is at least 44 points square (28 on the Mac), however
/// small it looks.
final class HitButton: UIButton {
    var minimumHitSize: CGFloat = minimumTarget
    /// How far the touch area reaches past each edge, instead of growing evenly to `minimumHitSize`.
    var hitOutsets: UIEdgeInsets?

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let o = hitOutsets {
            return bounds.inset(by: UIEdgeInsets(top: -o.top, left: -o.left, bottom: -o.bottom, right: -o.right)).contains(point)
        }
        let dx = max(0, (minimumHitSize - bounds.width) / 2)
        let dy = max(0, (minimumHitSize - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

/// A stack whose buttons' touch areas may reach past its own edges.
final class HitStackView: UIStackView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || arrangedSubviews.contains {
            !$0.isHidden && $0.isUserInteractionEnabled && $0.point(inside: convert(point, to: $0), with: event)
        }
    }
}

extension UIColor {
    /// The question's bubble: a warm tint of the amber, fixed rather than the tint colour at 15%,
    /// which was a muddy brown on black in dark mode and went grey while a sheet dimmed the tint.
    static let userBubble = UIColor { traits in
        let high = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark
            ? UIColor(rgb: high ? 0x4D3821 : 0x3B2A17)
            : UIColor(rgb: high ? 0xF9DDBA : 0xFDEFDF)
    }

    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

