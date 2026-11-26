import AppKit
import LlamaKit
import SwiftUI

/// The user's question: a bubble on the right in the warm amber tint, files above the text, and the
/// date note the model was given, small above it.
struct UserMessage: View {
    let message: StoredMessage
    let editing: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let note = message.dateNote {
                Text(note.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.attachments ?? []) { AttachmentChipView(attachment: $0) }
                if !message.content.isEmpty {
                    Text(message.content)
                        .font(.system(size: PlatformFont.lanternBodySize))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.userBubble, in: .rect(cornerRadius: 16))
            .opacity(editing ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
    }
}

/// One answer: status while it's written, thinking behind a disclosure, searches with their
/// sources, the Markdown answer, an error with its fixes, then the footer (versions, footnote, menu).
struct AnswerMessage<ErrorActions: View, Menu: View>: View {
    let message: StoredMessage
    let live: LiveReply?
    let liveText: String?
    let liveThinking: String?
    let liveSearches: [WebSearch]?
    let status: ReplyStatus?
    let expanded: Bool
    let showDetails: Bool
    let isSpeaking: Bool
    let toggleThinking: () -> Void
    let switchVersion: (Int) -> Void
    /// Retry, offered under the last answer only.
    let retry: (() -> Void)?
    @ViewBuilder let errorActions: () -> ErrorActions
    @ViewBuilder let menu: () -> Menu

    @State private var hovering = false

    private var text: String {
        #if DEBUG
        if let sample = MarkdownSample.override { return sample }
        #endif
        return liveText ?? message.content
    }
    private var thinking: String { liveThinking ?? message.thinking }
    private var searches: [WebSearch] { liveSearches ?? message.searches ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = status?.text ?? (message.finished ? nil : "Interrupted: Lantern closed before this finished.") {
                HStack(spacing: 6) {
                    if status != nil { ProgressView().controlSize(.mini) }
                    Text(s).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                if let p = status?.progress { ProgressView(value: p).frame(maxWidth: 240) }
            }
            if !thinking.isEmpty { thinkingView }
            if !searches.isEmpty { SearchesButton(searches: searches) }
            if !text.isEmpty {
                AnswerText(markdown: text)
                    .contextMenu { menu() }
            }
            if let error = message.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    if live == nil {
                        HStack { errorActions() }.controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.25)))
            }
            if live == nil { footer }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }

    private var thinkingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggleThinking) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(live != nil && text.isEmpty ? "Thinking" : "Thought process")
                }
                .font(.callout)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .animation(.easeOut(duration: 0.15), value: expanded)
            .accessibilityValue(expanded ? "Shown" : "Hidden")
            if expanded {
                Text(thinking)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 2) }
            } else if live != nil, text.isEmpty {
                Text(Self.tail(of: thinking)).font(.callout).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    /// Under a finished answer: its versions, then Copy, Retry and More, then the footnote. The
    /// buttons show while the pointer is over the answer (and always under the last one).
    @ViewBuilder
    private var footer: some View {
        let (versions, current) = message.allVersions
        let note = footnote
        HStack(spacing: 2) {
            if versions.count > 1 {
                Button { switchVersion(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(current == 0)
                    .help("Previous answer")
                Text("\(current + 1)/\(versions.count)")
                    .monospacedDigit()
                    .accessibilityLabel("Answer \(current + 1) of \(versions.count)")
                Button { switchVersion(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(current >= versions.count - 1)
                    .help("Next answer")
                Divider().frame(height: 12).padding(.horizontal, 4)
            }
            Group {
                if !text.isEmpty {
                    Button { copy() } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                        .help("Copy")
                }
                if let retry {
                    Button(action: retry) { Image(systemName: "arrow.clockwise") }
                        .help("Retry")
                }
                if isSpeaking {
                    Button { Speaker.shared.stop() } label: { Image(systemName: "stop.circle") }
                        .help("Stop Reading")
                }
                SwiftUI.Menu { menu() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            .opacity(hovering || retry != nil || isSpeaking ? 1 : 0)
            if !note.isEmpty {
                Text(note)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 6)
                    .help(note)
            }
        }
        .buttonStyle(FooterButtonStyle())
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @State private var copied = false

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private var footnote: String {
        var notes: [String] = []
        if showDetails, let seconds = message.thoughtSeconds, !thinking.isEmpty { notes.append("Thought \(PhaseClock.format(Int(seconds.rounded())))") }
        if let f = message.footnote { notes.append(showDetails ? f : ReplyDetails.essentials(of: f)) }
        return notes.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func tail(of thinking: String) -> String {
        let flat = thinking.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        guard flat.count > 140 else { return flat }
        var cut = String(flat.suffix(140))
        if let space = cut.firstIndex(of: " ") { cut = String(cut[cut.index(after: space)...]) }
        return "…" + cut
    }
}

/// "Searched for “…”", with the pages found in its menu.
private struct SearchesButton: View {
    let searches: [WebSearch]

    var body: some View {
        let failed = searches.allSatisfy { $0.error != nil }
        let title = failed ? "Couldn't search the web"
            : searches.count == 1 ? "Searched for “\(searches[0].query)”"
            : "Searched the web \(searches.count) times"
        Menu {
            ForEach(Array(searches.enumerated()), id: \.offset) { _, search in
                Section("“\(search.query)”") {
                    if let error = search.error {
                        Text(error)
                    } else if search.results.isEmpty {
                        Text("No results")
                    } else {
                        ForEach(Array(search.results.enumerated()), id: \.offset) { _, result in
                            if let url = URL(string: result.url) {
                                let site = url.host()?.replacingOccurrences(of: "www.", with: "") ?? result.url
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Text(result.title)
                                    Text(result.published.map { "\(site) · \($0)" } ?? site)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(title, systemImage: failed ? "exclamationmark.magnifyingglass" : "magnifyingglass")
                .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
    }
}

/// A file on a message or in the message box: its icon or thumbnail, its name, and in the box a
/// remove button.
struct AttachmentChipView: View {
    let attachment: Attachment
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let data = attachment.image, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 28, height: 28).clipShape(.rect(cornerRadius: 5))
            } else {
                Image(systemName: attachment.symbol).foregroundStyle(.secondary)
            }
            Text(attachment.name).lineLimit(1).truncationMode(.middle).font(.callout)
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
        .frame(maxWidth: 280, alignment: .leading)
    }
}

extension Color {
    /// The question's bubble, as on the iPhone: a warm tint of the amber.
    static let userBubble = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let rgb: UInt32 = dark ? (high ? 0x4D3821 : 0x3B2A17) : (high ? 0xF9DDBA : 0xFDEFDF)
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    })
}

// MARK: - The answer's text

/// The answer as `Markdown.render` draws it on the iPhone, in an AppKit text view on TextKit 1 with
/// `BlockLayoutManager` (code blocks and tables on one background each): selectable, links live,
/// only re-rendered when the text changes (a few times a second while streaming).
struct AnswerText: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> AnswerNSTextView { AnswerNSTextView() }

    func updateNSView(_ view: AnswerNSTextView, context: Context) {
        view.show(markdown)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnswerNSTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 600
        return CGSize(width: width, height: nsView.height(for: width))
    }
}

final class AnswerNSTextView: NSTextView {
    private var shown: String?
    private var appearanceName: NSAppearance.Name?
    /// One per code block, at the end of its first line, as on the iPhone.
    private var copyButtons: [NSButton] = []
    private var copiedReset: Task<Void, Never>?

    init() {
        let storage = NSTextStorage()
        let layout = BlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isAutomaticLinkDetectionEnabled = true
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }
    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }

    func show(_ markdown: String) {
        let name = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        guard markdown != shown || name != appearanceName else { return }
        shown = markdown
        appearanceName = name
        textStorage?.setAttributedString(Markdown.render(markdown))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        placeCopyButtons()
    }

    /// Each code block's code and the range of its first line.
    private var codeBlocks: [(code: String, range: NSRange)] {
        guard let storage = textStorage else { return [] }
        var blocks: [(String, NSRange)] = []
        storage.enumerateAttribute(.lanternCode, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let code = value as? String { blocks.append((code, range)) }
        }
        return blocks
    }

    private func placeCopyButtons() {
        guard let layout = layoutManager, let container = textContainer else { return }
        let blocks = codeBlocks
        while copyButtons.count < blocks.count { copyButtons.append(makeCopyButton(copyButtons.count)) }
        layout.ensureLayout(for: container)
        for (i, button) in copyButtons.enumerated() {
            button.isHidden = i >= blocks.count
            guard i < blocks.count else { continue }
            let glyph = layout.glyphIndexForCharacter(at: blocks[i].range.location)
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let size = button.fittingSize
            button.frame = CGRect(x: bounds.width - Markdown.blockInset - size.width + 6,
                                  y: line.midY - size.height / 2, width: size.width, height: size.height).integral
            button.setAccessibilityLabel(blocks.count == 1 ? "Copy code" : "Copy code block \(i + 1)")
        }
    }

    private func makeCopyButton(_ index: Int) -> NSButton {
        let button = NSButton(title: "Copy", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                              target: self, action: #selector(copyCode(_:)))
        button.tag = index
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Copy the code"
        addSubview(button)
        return button
    }

    @objc private func copyCode(_ sender: NSButton) {
        let blocks = codeBlocks
        guard blocks.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blocks[sender.tag].code, forType: .string)
        sender.title = "Copied"
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        sender.contentTintColor = .controlAccentColor
        needsLayout = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let sender else { return }
            sender.title = "Copy"
            sender.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            sender.contentTintColor = .secondaryLabelColor
            self?.needsLayout = true
        }
    }

    func height(for width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        if container.size.width != width {
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let shown { self.shown = nil; show(shown) }
    }
}

/// The small icon buttons under an answer: borderless, a hover highlight, tight together.
private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButton(configuration: configuration)
    }

    private struct FooterButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 24, minHeight: 22)
                .padding(.horizontal, 2)
                .background(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5))
                .opacity(configuration.isPressed ? 0.6 : enabled ? 1 : 0.4)
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}
