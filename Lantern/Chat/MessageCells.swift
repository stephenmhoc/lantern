import UIKit

/// A non-scrolling, selectable text view: partial selection, Copy, Look Up, and tappable phone
/// numbers and addresses.
private func makeTextView(style: UIFont.TextStyle = .body, color: UIColor = .label) -> UITextView {
    let view = UITextView()
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

final class UserCell: UICollectionViewCell {
    private let bubble = UIView()
    private let textView = makeTextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.backgroundColor = .tintColor.withAlphaComponent(0.15)
        bubble.layer.cornerRadius = 18
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)
        bubble.addSubview(textView)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            bubble.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.layoutMarginsGuide.leadingAnchor, constant: 48),
            textView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 10),
            textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ message: StoredMessage) {
        textView.text = message.content
    }
}

final class AssistantCell: UICollectionViewCell {
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let thinkingButton = UIButton(configuration: .plain())
    private let thinkingText = makeTextView(style: .callout, color: .secondaryLabel)
    private let answer = makeTextView()
    private let footnote = UILabel()
    private let errorLabel = UILabel()
    private let moreButton = UIButton(configuration: .plain())
    private lazy var statusRow = UIStackView(arrangedSubviews: [spinner, status])
    private lazy var footerRow = UIStackView(arrangedSubviews: [footnote, moreButton])

    var onToggleThinking: (() -> Void)?
    private var renderedText: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        status.font = .preferredFont(forTextStyle: .callout)
        status.textColor = .secondaryLabel
        status.adjustsFontForContentSizeCategory = true
        statusRow.spacing = 8

        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = .secondaryLabel
        config.preferredSymbolConfigurationForImage = .init(textStyle: .caption1)
        thinkingButton.configuration = config
        thinkingButton.contentHorizontalAlignment = .leading
        thinkingButton.addAction(UIAction { [weak self] _ in self?.onToggleThinking?() }, for: .primaryActionTriggered)

        footnote.font = .preferredFont(forTextStyle: .caption2)
        footnote.textColor = .tertiaryLabel
        footnote.adjustsFontForContentSizeCategory = true
        footnote.numberOfLines = 0
        moreButton.configuration?.image = UIImage(systemName: "ellipsis.circle")
        moreButton.configuration?.contentInsets = .zero
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = "More"
        moreButton.setContentHuggingPriority(.required, for: .horizontal)
        footerRow.spacing = 8
        footerRow.alignment = .center

        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = true

        let stack = UIStackView(arrangedSubviews: [statusRow, thinkingButton, thinkingText, answer, errorLabel, footerRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderedText = nil
    }

    /// `live` is set while this reply is being written; `menu` is nil until it's done.
    func configure(_ message: StoredMessage, live: LiveReply?, thinkingExpanded: Bool, menu: UIMenu?) {
        let thinking = live?.thinking ?? message.thinking
        let text = live?.text ?? message.content
        let statusText = live?.status ?? (message.finished ? nil : "Interrupted: Lantern closed before this finished.")

        statusRow.isHidden = statusText == nil
        status.text = statusText
        if live != nil, statusText != nil { spinner.startAnimating() } else { spinner.stopAnimating() }

        thinkingButton.isHidden = thinking.isEmpty
        let thinkingNow = live != nil && text.isEmpty
        thinkingButton.configuration?.title = thinkingNow ? "Thinking" : "Thought process"
        thinkingButton.configuration?.image = UIImage(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
        thinkingButton.accessibilityValue = thinkingExpanded ? "Shown" : "Hidden"
        thinkingText.isHidden = thinking.isEmpty || !thinkingExpanded
        if !thinkingText.isHidden, thinkingText.text != thinking { thinkingText.text = thinking }

        answer.isHidden = text.isEmpty
        if text != renderedText {
            answer.attributedText = Markdown.render(text)
            renderedText = text
        }

        errorLabel.isHidden = message.error == nil
        errorLabel.text = message.error
        footnote.text = message.footnote
        moreButton.menu = menu
        footerRow.isHidden = live != nil || (message.footnote == nil && menu == nil)
    }
}
