import UIKit

/// The bar under the chat: status strip, mode menu, a text view that grows to six lines, Send/Stop.
final class ComposerView: UIView, UITextViewDelegate {
    let textView = UITextView()
    let modeButton = UIButton(configuration: .gray())
    let sendButton = UIButton(configuration: .plain())
    private let placeholder = UILabel()
    private var heightConstraint: NSLayoutConstraint!

    var onSend: (() -> Void)?
    var onStop: (() -> Void)?
    var isRunning = false { didSet { updateButton() } }
    var canSend = true { didSet { updateButton() } }

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            textViewDidChange(textView)
        }
    }

    var placeholderText: String {
        get { placeholder.text ?? "" }
        set { placeholder.text = newValue }
    }

    init(statusView: UIView) {
        super.init(frame: .zero)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 18
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = "Message"

        placeholder.font = textView.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)

        modeButton.showsMenuAsPrimaryAction = true
        modeButton.configuration?.cornerStyle = .capsule
        modeButton.configuration?.imagePadding = 4
        modeButton.configuration?.preferredSymbolConfigurationForImage = .init(textStyle: .footnote)
        modeButton.setContentHuggingPriority(.required, for: .horizontal)
        modeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        sendButton.configuration?.preferredSymbolConfigurationForImage = .init(pointSize: 30)
        sendButton.configuration?.contentInsets = .zero
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if isRunning { onStop?() } else { onSend?() }
        }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [modeButton, textView, sendButton])
        row.spacing = 8
        row.alignment = .bottom
        let stack = UIStackView(arrangedSubviews: [statusView, row])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        heightConstraint = textView.heightAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 100),  // under the home indicator too
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            heightConstraint,
            modeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 15),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 9),
        ])
        updateButton()
        // Dynamic Type changes the line height, and so the six-line limit.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.textViewDidChange(self.textView)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        let maxHeight = (textView.font?.lineHeight ?? 20) * 6 + 18
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        heightConstraint.constant = min(max(38, fitting), maxHeight)
        textView.isScrollEnabled = fitting > maxHeight
        updateButton()
    }

    private var hasText: Bool { !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func updateButton() {
        let name = isRunning ? "stop.circle.fill" : "arrow.up.circle.fill"
        sendButton.configuration?.image = UIImage(systemName: name)
        sendButton.accessibilityLabel = isRunning ? "Stop" : "Send"
        sendButton.isEnabled = isRunning || (canSend && hasText)
    }
}
