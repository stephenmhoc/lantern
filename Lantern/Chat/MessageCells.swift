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

/// The answer's text view, on TextKit 1 with `BlockLayoutManager` so code blocks and tables get
/// one even background each.
private final class AnswerTextView: UITextView {
    private let storage = NSTextStorage()  // the text view doesn't keep its own storage alive

    init() {
        let layout = BlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError() }
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
        bubble.backgroundColor = .tintColor.withAlphaComponent(0.15)
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
        dateLabel.textColor = .tertiaryLabel
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
    var isSpeaking = false
    /// Buttons under an error: Retry, Open Readiness, Check the Mac.
    var errorActions: [UIAction] = []
}

final class AssistantCell: UICollectionViewCell, UITextViewDelegate {
    private let glow = GlowView()
    private let status = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let thoughtTail = UILabel()
    private let thinkingButton = UIButton(configuration: .plain())
    private let thinkingText = makeTextView(style: .callout, color: .secondaryLabel)
    private let answer = styled(AnswerTextView(), style: .body, color: .label)
    private let errorLabel = UILabel()
    private let errorRow = UIStackView()
    private let footnote = UILabel()
    private let previousButton = HitButton(configuration: .plain())
    private let nextButton = HitButton(configuration: .plain())
    private let versionLabel = UILabel()
    private let stopSpeakingButton = HitButton(configuration: .plain())
    private let moreButton = HitButton(configuration: .plain())
    private lazy var statusRow = UIStackView(arrangedSubviews: [glow, status])
    private lazy var versionRow = UIStackView(arrangedSubviews: [previousButton, versionLabel, nextButton])
    private lazy var footerRow = UIStackView(arrangedSubviews: [versionRow, footnote, stopSpeakingButton, moreButton])

    var onToggleThinking: (() -> Void)?
    /// -1 for the previous answer to this question, +1 for the next.
    var onSwitchVersion: ((Int) -> Void)?
    var onStopSpeaking: (() -> Void)?
    /// The message's actions, built when a menu opens so they're never stale.
    var menuItems: (() -> [UIMenuElement])?

    private var text = ""
    private var renderedKey: String?
    private var copiedBlock: Int?
    private var copiedReset: Task<Void, Never>?

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
        thoughtTail.textColor = .tertiaryLabel
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
        thinkingButton.addAction(UIAction { [weak self] _ in self?.onToggleThinking?() }, for: .primaryActionTriggered)

        answer.delegate = self

        footnote.font = .preferredFont(forTextStyle: .caption2)
        footnote.textColor = .tertiaryLabel
        footnote.adjustsFontForContentSizeCategory = true
        footnote.numberOfLines = 0

        for (button, symbol, label) in [(moreButton, "ellipsis.circle", "More"),
                                        (stopSpeakingButton, "stop.circle", "Stop reading"),
                                        (previousButton, "chevron.left", "Previous answer"),
                                        (nextButton, "chevron.right", "Next answer")] {
            button.configuration?.image = UIImage(systemName: symbol)
            button.configuration?.contentInsets = .zero
            button.configuration?.preferredSymbolConfigurationForImage = .init(textStyle: .footnote)
            button.isPointerInteractionEnabled = true
            button.accessibilityLabel = label
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menuItems?() ?? [])
        }])
        stopSpeakingButton.configuration?.baseForegroundColor = GlowView.amber
        stopSpeakingButton.addAction(UIAction { [weak self] _ in self?.onStopSpeaking?() }, for: .primaryActionTriggered)
        previousButton.addAction(UIAction { [weak self] _ in self?.onSwitchVersion?(-1) }, for: .primaryActionTriggered)
        nextButton.addAction(UIAction { [weak self] _ in self?.onSwitchVersion?(1) }, for: .primaryActionTriggered)
        versionLabel.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        versionLabel.textColor = .secondaryLabel
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionRow.spacing = 2
        footerRow.spacing = 10
        footerRow.alignment = .center

        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true
        errorRow.spacing = 8
        errorRow.alignment = .leading

        let stack = UIStackView(arrangedSubviews: [
            statusRow, progress, thoughtTail, thinkingButton, thinkingText, answer, errorLabel, errorRow, footerRow,
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.setCustomSpacing(4, after: statusRow)
        stack.setCustomSpacing(2, after: thinkingButton)
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
            self.versionLabel.font = .monospacedDigitSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: self.traitCollection).pointSize,
                weight: .regular)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderedKey = nil
        copiedBlock = nil
        copiedReset?.cancel()
    }

    func configure(_ content: AssistantContent) {
        let message = content.message
        let live = content.live
        let thinking = live?.thinking ?? message.thinking
        text = live?.text ?? message.content

        // While it's being written: the glow, what it's doing and for how long, and progress.
        let statusText = content.status?.text ?? (message.finished ? nil : "Interrupted: Lantern closed before this finished.")
        statusRow.isHidden = statusText == nil
        status.text = statusText
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
        thinkingText.isHidden = thinking.isEmpty || !content.thinkingExpanded
        if !thinkingText.isHidden, thinkingText.text != thinking { thinkingText.text = thinking }
        thoughtTail.isHidden = !(thinkingNow && !thinking.isEmpty && !content.thinkingExpanded)
        if !thoughtTail.isHidden { thoughtTail.text = Self.tail(of: thinking) }

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
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            errorRow.addArrangedSubview(button)
        }
        errorRow.addArrangedSubview(UIView())  // keeps the buttons at their natural width
        errorRow.isHidden = errorRow.arrangedSubviews.count == 1

        var notes: [String] = []
        if let seconds = message.thoughtSeconds, !thinking.isEmpty { notes.append("Thought \(PhaseClock.format(Int(seconds.rounded())))") }
        if let f = message.footnote { notes.append(f) }
        footnote.text = notes.joined(separator: " · ")

        let (versions, current) = message.allVersions
        versionRow.isHidden = versions.count < 2 || live != nil
        versionLabel.text = "\(current + 1)/\(versions.count)"
        previousButton.isEnabled = current > 0
        nextButton.isEnabled = current < versions.count - 1
        versionLabel.accessibilityLabel = "Answer \(current + 1) of \(versions.count)"

        stopSpeakingButton.isHidden = !content.isSpeaking
        moreButton.isHidden = live != nil
        footerRow.isHidden = live != nil
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
        let key = "\(traitCollection.preferredContentSizeCategory.rawValue)|\(copiedBlock ?? -1)|\(text)"
        guard key != renderedKey else { return }
        renderedKey = key
        answer.attributedText = Markdown.render(text, traits: traitCollection, copied: copiedBlock)
    }

    // MARK: - Code blocks' Copy links, and the answer's own actions in its text menu

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, url.scheme == Markdown.copyScheme else { return defaultAction }
        let code = textView.textStorage.attribute(.lanternCode, at: textItem.range.location, effectiveRange: nil) as? String
        let index = Int(url.host() ?? "")
        return UIAction { [weak self] _ in
            guard let self, let code else { return }
            UIPasteboard.general.string = code
            UIAccessibility.post(notification: .announcement, argument: "Code copied")
            copiedBlock = index
            renderAnswer()
            copiedReset?.cancel()
            copiedReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, let self else { return }
                copiedBlock = nil
                renderAnswer()
            }
        }
    }

    func textView(
        _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        if case .link(let url) = textItem.content, url.scheme == Markdown.copyScheme { return nil }
        return UITextItem.MenuConfiguration(menu: defaultMenu)
    }

    /// Long-press or right-click on the answer's text selects it; its menu gets the answer's actions too.
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let extra = menuItems?() ?? []
        guard !extra.isEmpty else { return nil }
        return UIMenu(children: suggestedActions + [UIMenu(title: "Answer", options: .displayInline, children: extra)])
    }
}

/// A button whose touch and pointer target is at least 44 points square, however small it looks.
final class HitButton: UIButton {
    var minimumHitSize: CGFloat = 44

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (minimumHitSize - bounds.width) / 2)
        let dy = max(0, (minimumHitSize - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}
