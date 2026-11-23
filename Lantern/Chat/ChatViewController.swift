import LlamaKit
import SwiftData
import SwiftUI
import UIKit

/// The chat: a UIKit transcript and message box, hosted in SwiftUI's split view. UIKit because this
/// is where the work is: streaming text into a cell without reloading it, selectable answers with
/// tappable phone numbers, keeping to the bottom only while you're there, and hardware-keyboard
/// commands. The status strip and the empty-chat view are SwiftUI views hosted inside it.
final class ChatViewController: UIViewController, UICollectionViewDelegate {
    let conversation: Conversation
    private let engine: Engine

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, UUID>!
    private var composer: ComposerView!
    private let jumpButton = UIButton(configuration: .gray())

    /// What each cell last showed, to reconfigure only the ones that changed.
    private var rendered: [UUID: StoredMessage] = [:]
    private var renderedLive: UUID?
    private var expanded: Set<UUID> = []
    private var isPinned = true
    private var ticker: CADisplayLink?

    init(conversation: Conversation, engine: Engine) {
        self.conversation = conversation
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        let user = UICollectionView.CellRegistration<UserCell, UUID> { [unowned self] cell, _, id in
            if let m = message(id) { cell.configure(m) }
        }
        let assistant = UICollectionView.CellRegistration<AssistantCell, UUID> { [unowned self] cell, _, id in
            configure(cell, id: id)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [unowned self] view, indexPath, id in
            message(id)?.isUser == true
                ? view.dequeueConfiguredReusableCell(using: user, for: indexPath, item: id)
                : view.dequeueConfiguredReusableCell(using: assistant, for: indexPath, item: id)
        }

        let status = host(StatusStrip(conversation: conversation))
        composer = ComposerView(statusView: status.view)
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.onSend = { [unowned self] in send(composer.text) }
        composer.onStop = { [unowned self] in engine.stop() }
        view.addSubview(composer)

        let starters = host(EmptyChat())
        collectionView.backgroundView = starters.view

        jumpButton.configuration?.image = UIImage(systemName: "chevron.down")
        jumpButton.configuration?.cornerStyle = .capsule
        jumpButton.accessibilityLabel = "Jump to latest"
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.addAction(UIAction { [unowned self] _ in
            isPinned = true
            scrollToBottom(animated: true)
        }, for: .primaryActionTriggered)
        view.addSubview(jumpButton)

        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: composer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            jumpButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),
        ])
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToBottom(animated: false)
    }

    private func host<V: View>(_ view: V) -> UIHostingController<some View> {
        let controller = UIHostingController(rootView: view.environment(engine).environment(engine.mac))
        controller.sizingOptions = .intrinsicContentSize
        controller.view.backgroundColor = .clear
        addChild(controller)
        controller.didMove(toParent: self)
        return controller
    }

    // MARK: - State

    private func message(_ id: UUID) -> StoredMessage? {
        conversation.index(of: id).map { conversation.messages[$0] }
    }

    /// The reply being written, if it belongs to this chat.
    private var live: LiveReply? {
        guard let live = engine.live, engine.running == conversation.persistentModelID else { return nil }
        return live
    }

    /// Called by SwiftUI whenever the chat or the engine's state changes (never per token).
    func refresh() {
        guard isViewLoaded, conversation.modelContext != nil else { return }
        let ids = conversation.messages.map(\.id)
        var snapshot = NSDiffableDataSourceSnapshot<Int, UUID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        var changed = conversation.messages.filter { m in rendered[m.id].map { $0 != m } ?? false }.map(\.id)
        if renderedLive != live?.id { changed += [renderedLive, live?.id].compactMap { $0 }.filter(ids.contains) }
        snapshot.reconfigureItems(Array(Set(changed)))
        dataSource.apply(snapshot, animatingDifferences: !rendered.isEmpty)
        rendered = Dictionary(conversation.messages.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        renderedLive = live?.id

        collectionView.backgroundView?.isHidden = !ids.isEmpty
        let runningHere = live != nil
        composer.isRunning = runningHere
        composer.canSend = !engine.isBusy
        composer.placeholderText = engine.isBusy && !runningHere ? "Another chat is answering…" : "Ask \(conversation.mode.title)"
        updateModeButton()

        if runningHere, ticker == nil {
            ticker = CADisplayLink(target: self, selector: #selector(tick))
            ticker?.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
            ticker?.add(to: .main, forMode: .common)
        } else if !runningHere {
            ticker?.invalidate()
            ticker = nil
        }
        if isPinned { scrollToBottom(animated: !rendered.isEmpty) }
    }

    /// Streams the live reply into its cell a few times a second.
    @objc private func tick() {
        guard let live, let path = dataSource.indexPath(for: live.id),
              let cell = collectionView.cellForItem(at: path) as? AssistantCell else { return }
        configure(cell, id: live.id)
        if isPinned {
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
        }
    }

    private func configure(_ cell: AssistantCell, id: UUID) {
        guard let m = message(id) else { return }
        let live = live?.id == id ? live : nil
        cell.configure(m, live: live, thinkingExpanded: expanded.contains(id), menu: live == nil ? menu(for: m) : nil)
        cell.onToggleThinking = { [unowned self] in
            if expanded.remove(id) == nil { expanded.insert(id) }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([id])
            dataSource.apply(snapshot, animatingDifferences: true)
        }
    }

    // MARK: - Actions

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isBusy else { return }
        composer.text = ""
        isPinned = true
        engine.send(text, in: conversation)
        refresh()
    }

    private func setMode(_ mode: Mode) {
        guard live == nil else { return }
        conversation.mode = mode
        refresh()
    }

    private func updateModeButton() {
        let mode = conversation.mode
        composer.modeButton.configuration?.title = mode.title
        composer.modeButton.configuration?.image = UIImage(systemName: mode.symbol)
        composer.modeButton.accessibilityLabel = "Mode"
        composer.modeButton.accessibilityValue = "\(mode.title), thinking \(conversation.thinking.rawValue)"
        composer.modeButton.isEnabled = live == nil

        let modes = Mode.allCases.map { m in
            UIAction(title: m.title, subtitle: availability(m), image: UIImage(systemName: m.symbol),
                     state: m == mode ? .on : .off) { [unowned self] _ in setMode(m) }
        }
        let thinking = Thinking.allCases.map { t in
            UIAction(title: t.rawValue.capitalized, state: t == conversation.thinking ? .on : .off) { [unowned self] _ in
                conversation.thinking = t
                refresh()
            }
        }
        let thinkingMenu = UIMenu(
            title: "Thinking", subtitle: mode == .smart ? "Smart always thinks a little" : conversation.thinking.rawValue.capitalized,
            image: UIImage(systemName: "lightbulb"), children: thinking)
        composer.modeButton.menu = UIMenu(children: [UIMenu(options: .displayInline, children: modes), thinkingMenu])
    }

    private func availability(_ mode: Mode) -> String {
        if mode == .mac { return engine.mac.route == .unknown ? "Ollama on your Mac" : engine.mac.route.label }
        guard let model = engine.model(for: mode) else { return "" }
        return engine.store.states[model.id] == .ready ? model.name : "Not on this device"
    }

    private func menu(for message: StoredMessage) -> UIMenu? {
        guard !message.isUser else { return nil }
        var items: [UIMenuElement] = []
        if !message.content.isEmpty {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = message.content
            })
            items.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [unowned self] action in
                let share = UIActivityViewController(activityItems: [message.content], applicationActivities: nil)
                share.popoverPresentationController?.sourceItem = action.sender as? UIView ?? composer
                present(share, animated: true)
            })
        }
        if conversation.messages.last?.id == message.id, !engine.isBusy {
            let retries = Mode.allCases.map { m in
                UIAction(title: m == conversation.mode ? "Retry" : "Retry with \(m.title)", image: UIImage(systemName: m.symbol)) {
                    [unowned self] _ in
                    isPinned = true
                    engine.retry(in: conversation, mode: m)
                    refresh()
                }
            }
            items.append(UIMenu(options: .displayInline, children: retries))
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    // MARK: - Scrolling

    private var distanceFromBottom: CGFloat {
        collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
            - collectionView.contentOffset.y - collectionView.bounds.height
    }

    /// Only the user's own scrolling decides whether to follow new text.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isTracking || scrollView.isDecelerating { isPinned = distanceFromBottom < 44 }
        jumpButton.isHidden = isPinned || distanceFromBottom < 44
    }

    private func scrollToBottom(animated: Bool) {
        let inset = collectionView.adjustedContentInset
        let y = max(-inset.top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    // MARK: - Keyboard

    override var keyCommands: [UIKeyCommand]? {
        let returnKey = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendKey))
        returnKey.wantsPriorityOverSystemBehavior = true  // hardware Return sends; the on-screen one adds a line
        let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(newlineKey))
        newline.wantsPriorityOverSystemBehavior = true
        let modes = Mode.allCases.enumerated().map { i, m in
            UIKeyCommand(title: m.title, action: #selector(modeKey(_:)), input: "\(i + 1)", modifierFlags: .command,
                         propertyList: m.rawValue)
        }
        return [
            returnKey, newline,
            UIKeyCommand(title: "Send", action: #selector(sendKey), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: "Stop", action: #selector(stopKey), input: UIKeyCommand.inputEscape),
            UIKeyCommand(title: "Stop", action: #selector(stopKey), input: ".", modifierFlags: .command),
        ] + modes
    }

    @objc private func sendKey() { if composer.isRunning == false { send(composer.text) } }
    @objc private func newlineKey() { composer.textView.insertText("\n") }
    @objc private func stopKey() { if live != nil { engine.stop() } }
    @objc private func modeKey(_ command: UIKeyCommand) {
        if let raw = command.propertyList as? String, let mode = Mode(rawValue: raw) { setMode(mode) }
    }
}

/// The chat screen as SwiftUI sees it. `revision` changes whenever something the UIKit side shows
/// (other than streaming text) changes, which is what makes SwiftUI call `refresh()`.
struct ChatScreen: View {
    let conversation: Conversation
    @Environment(Engine.self) private var engine

    var body: some View {
        ChatControllerView(conversation: conversation, engine: engine, revision: revision)
            .ignoresSafeArea(.keyboard)  // the UIKit side follows the keyboard itself
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var revision: Int {
        var h = Hasher()
        h.combine(conversation.messages)
        h.combine(conversation.mode)
        h.combine(conversation.thinking)
        h.combine(engine.running)
        h.combine(engine.live?.id)
        h.combine(engine.isBusy)
        h.combine(engine.store.downloaded)
        h.combine(engine.mac.route)
        return h.finalize()
    }
}

private struct ChatControllerView: UIViewControllerRepresentable {
    let conversation: Conversation
    let engine: Engine
    let revision: Int

    func makeUIViewController(context: Context) -> ChatViewController {
        ChatViewController(conversation: conversation, engine: engine)
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.refresh()
    }
}

/// Shown in an empty chat.
private struct EmptyChat: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame").font(.largeTitle).foregroundStyle(.tint)
            Text("Ask anything. It runs on this device.").foregroundStyle(.secondary)
        }
        .padding()
    }
}
