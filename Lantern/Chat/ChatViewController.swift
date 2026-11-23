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

    // Hooks for the app around the chat. Each does nothing until set.
    /// Opens Readiness, to download a model. The error "Open Readiness" button and the mode menu's
    /// "Get Models" item only appear once this is set.
    var onOpenReadiness: (() -> Void)?
    /// Opens Settings, where the Mac's address is. "Check the Mac" opens it if the Mac still can't be reached.
    var onOpenSettings: (() -> Void)?
    /// Called when typing starts in a chat whose model isn't loaded (or whose Mac route isn't known),
    /// to get it ready before Send. Must return at once (e.g. start `Engine.prepare` in a Task).
    var onBeginTyping: (() -> Void)?

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
    private var clock = PhaseClock()
    private var announcedSlow: UUID?

    /// The sent message being edited in the composer (Edit & Resend), and the draft it replaced.
    private var editingID: UUID?
    private var draftBeforeEdit = ""
    private var draftSave: Task<Void, Never>?
    private var wasTyping = false

    init(conversation: Conversation, engine: Engine) {
        self.conversation = conversation
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Messages keep to the readable width: about 700 points, centered, on iPad; the standard
        // margins on iPhone. Cells add no side margins of their own.
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .readableContent
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        let user = UICollectionView.CellRegistration<UserCell, UUID> { [unowned self] cell, _, id in
            if let m = message(id) { cell.configure(m, editing: editingID == id) }
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
        composer.onTextChange = { [unowned self] text in textChanged(text) }
        composer.onCancelEdit = { [unowned self] in cancelEditing() }
        composer.text = conversation.draft
        wasTyping = !conversation.draft.isEmpty
        view.addSubview(composer)

        let starters = host(EmptyChat(conversation: conversation))
        collectionView.backgroundView = starters.view

        jumpButton.configuration?.image = UIImage(systemName: "chevron.down")
        jumpButton.configuration?.cornerStyle = .capsule
        jumpButton.accessibilityLabel = "Jump to latest"
        jumpButton.isPointerInteractionEnabled = true
        jumpButton.isHidden = true
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpButton.addAction(UIAction { [unowned self] _ in
            isPinned = true
            scrollToBottom(animated: true)
        }, for: .primaryActionTriggered)
        view.addSubview(jumpButton)

        // The transcript runs under the composer (glass or blur); `viewDidLayoutSubviews` insets it.
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            jumpButton.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),
            jumpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            jumpButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        Speaker.shared.onChange = { [weak self] in self?.reconfigureVisibleAnswers() }
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToBottom(animated: false)
        // Ready to type on iPad and Mac; on iPhone the keyboard would cover a chat you came to read.
        if traitCollection.userInterfaceIdiom != .phone { composer.textView.becomeFirstResponder() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveDraft()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let overlap = max(0, view.bounds.maxY - composer.frame.minY - view.safeAreaInsets.bottom)
        guard collectionView.contentInset.bottom != overlap else { return }
        collectionView.contentInset.bottom = overlap
        collectionView.verticalScrollIndicatorInsets.bottom = overlap
        if isPinned { scrollToBottom(animated: false) }
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
        if let ended = renderedLive, live?.id != ended { replyEnded(ended) }

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

        if let id = editingID, conversation.index(of: id) == nil { cancelEditing() }
        collectionView.backgroundView?.isHidden = !ids.isEmpty
        let runningHere = live != nil
        composer.isRunning = runningHere
        composer.canSend = !engine.isBusy
        composer.isEditingMessage = editingID != nil
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

    /// A reply in this chat finished, stopped or failed: keep how long it thought, and tell VoiceOver.
    private func replyEnded(_ id: UUID) {
        guard let i = conversation.index(of: id) else { return }
        if clock.replyID == id, let seconds = clock.thoughtSeconds(),
           !conversation.messages[i].thinking.isEmpty, conversation.messages[i].thoughtSeconds == nil {
            // Not during SwiftUI's update of this view: the write itself causes another update.
            DispatchQueue.main.async { [conversation] in
                guard conversation.modelContext != nil, !conversation.isDeleted,
                      let i = conversation.index(of: id) else { return }
                conversation.messages[i].thoughtSeconds = seconds
                try? conversation.modelContext?.save()
            }
        }
        let m = conversation.messages[i]
        let spoken = m.error.map { "Reply failed. \($0)" }
            ?? (m.content.isEmpty ? nil : "Answer ready. \(Markdown.firstSentence(m.content))")
        if let spoken { announce(spoken) }
    }

    /// Streams the live reply into its cell a few times a second.
    @objc private func tick() {
        guard let live else { return }
        clock.observe(live)
        if announcedSlow != live.id,
           clock.status(for: live, modelName: nil).isSlow {
            announcedSlow = live.id
            announce("Taking a while.")
        }
        guard let path = dataSource.indexPath(for: live.id),
              let cell = collectionView.cellForItem(at: path) as? AssistantCell else { return }
        configure(cell, id: live.id)
        if isPinned {
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
        }
    }

    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }

    private func configure(_ cell: AssistantCell, id: UUID) {
        guard let m = message(id) else { return }
        let live = live?.id == id ? live : nil
        var content = AssistantContent(message: m, live: live)
        if let live {
            clock.observe(live)
            content.status = clock.status(for: live, modelName: modelName(for: live.mode))
        }
        content.thinkingExpanded = expanded.contains(id)
        content.isSpeaking = Speaker.shared.speaking == id
        content.errorActions = errorActions(for: m)
        cell.configure(content)
        cell.menuItems = { [unowned self] in answerMenuItems(id) }
        cell.onToggleThinking = { [unowned self] in
            if expanded.remove(id) == nil { expanded.insert(id) }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([id])
            dataSource.apply(snapshot, animatingDifferences: true)
        }
        cell.onSwitchVersion = { [unowned self] delta in switchVersion(id, by: delta) }
        cell.onStopSpeaking = { Speaker.shared.stop() }
    }

    private func modelName(for mode: Mode) -> String? {
        mode == .mac ? engine.mac.modelName : engine.model(for: mode)?.name
    }

    private func reconfigureVisibleAnswers() {
        var snapshot = dataSource.snapshot()
        let ids = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
        snapshot.reconfigureItems(ids.filter { message($0)?.isUser == false })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isBusy else { return }
        // Edit & Resend: the conversation goes back to just before the edited message.
        if let id = editingID, let i = conversation.index(of: id) {
            Speaker.shared.stop()
            conversation.messages.removeSubrange(i...)
        }
        editingID = nil
        composer.text = ""
        wasTyping = false
        saveDraft()
        isPinned = true
        engine.send(text, in: conversation)
        refresh()
    }

    /// Retry keeps the answer it replaces: the new one gets the old ones as its other versions.
    private func retry(_ mode: Mode) {
        guard let old = conversation.messages.last, !old.isUser, !engine.isBusy else { return }
        if Speaker.shared.speaking == old.id { Speaker.shared.stop() }
        let kept = old.allVersions.list.filter { !$0.content.isEmpty }
        isPinned = true
        engine.retry(in: conversation, mode: mode)
        if let i = conversation.messages.indices.last, conversation.messages[i].id != old.id, !kept.isEmpty {
            conversation.messages[i].versions = kept
            try? conversation.modelContext?.save()
        }
        refresh()
    }

    private func switchVersion(_ id: UUID, by delta: Int) {
        guard live?.id != id, let i = conversation.index(of: id) else { return }
        let current = conversation.messages[i].allVersions.current
        conversation.messages[i].showVersion(current + delta)
        try? conversation.modelContext?.save()
        let (list, now) = conversation.messages[i].allVersions
        announce("Answer \(now + 1) of \(list.count)")
        refresh()
    }

    private func beginEditing(_ id: UUID) {
        guard let m = message(id), m.isUser, !engine.isBusy else { return }
        if editingID == nil { draftBeforeEdit = composer.text }
        editingID = id
        composer.text = m.content
        composer.textView.becomeFirstResponder()
        refreshEditingCells()
    }

    private func cancelEditing() {
        guard editingID != nil else { return }
        editingID = nil
        composer.text = draftBeforeEdit
        refreshEditingCells()
    }

    private func refreshEditingCells() {
        composer.isEditingMessage = editingID != nil
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { message($0)?.isUser == true })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func setMode(_ mode: Mode) {
        guard live == nil else { return }
        conversation.mode = mode
        refresh()
    }

    private func isAvailable(_ mode: Mode) -> Bool {
        guard mode.isOnDevice else { return true }  // the Mac may come back; it's badged, not disabled
        return engine.model(for: mode).map { engine.store.states[$0.id] == .ready } ?? false
    }

    private func updateModeButton() {
        let mode = conversation.mode
        composer.setMode(title: mode.title, symbol: mode.symbol)
        composer.modeButton.accessibilityLabel = "Mode"
        composer.modeButton.accessibilityValue = "\(mode.title), thinking \(conversation.thinking.rawValue)"
        composer.modeButton.isEnabled = live == nil

        let modes = Mode.allCases.map { m in
            let unreachable = m == .mac && engine.mac.route == .unreachable
            let action = UIAction(
                title: m.title, subtitle: availability(m),
                image: UIImage(systemName: unreachable ? "exclamationmark.triangle" : m.symbol),
                attributes: isAvailable(m) ? [] : .disabled, state: m == mode ? .on : .off
            ) { [unowned self] _ in setMode(m) }
            return action
        }
        var sections: [UIMenuElement] = [UIMenu(options: .displayInline, children: modes)]
        if let open = onOpenReadiness, Mode.allCases.contains(where: { !isAvailable($0) }) {
            sections.append(UIAction(title: "Get Models…", image: UIImage(systemName: "arrow.down.circle")) { _ in open() })
        }
        let thinking = Thinking.allCases.map { t in
            UIAction(title: t.rawValue.capitalized, state: t == conversation.thinking ? .on : .off) { [unowned self] _ in
                conversation.thinking = t
                refresh()
            }
        }
        sections.append(UIMenu(
            title: "Thinking", subtitle: mode == .smart ? "Smart always thinks a little" : conversation.thinking.rawValue.capitalized,
            image: UIImage(systemName: "lightbulb"), children: thinking))
        composer.modeButton.menu = UIMenu(children: sections)
    }

    private func availability(_ mode: Mode) -> String {
        if mode == .mac { return engine.mac.route == .unknown ? "Ollama on your Mac" : engine.mac.route.label }
        guard let model = engine.model(for: mode) else { return "" }
        return engine.store.states[model.id] == .ready ? model.name : "Not on this device"
    }

    // MARK: - Drafts and warming up

    private func textChanged(_ text: String) {
        let typing = !text.isEmpty
        if typing, !wasTyping, needsWarmUp { onBeginTyping?() }
        wasTyping = typing
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { self?.saveDraft() }
        }
    }

    /// Whether Send would have to wait for a model to load or the Mac to be found.
    private var needsWarmUp: Bool {
        guard !engine.isBusy else { return false }
        let mode = conversation.mode
        if mode == .mac { return engine.mac.route.host == nil }
        return engine.loadedModel == nil || engine.loadedModel != engine.model(for: mode)
    }

    private func saveDraft() {
        draftSave?.cancel()
        // Text being edited from a sent message isn't a draft; the draft from before the edit is.
        let text = editingID == nil ? composer.text : draftBeforeEdit
        guard conversation.modelContext != nil, !conversation.isDeleted, conversation.draft != text else { return }
        conversation.draft = text
        try? conversation.modelContext?.save()
    }

    // MARK: - Menus

    private func isLast(_ id: UUID) -> Bool { conversation.messages.last?.id == id }

    /// Copy, Share, Read Aloud, Retry and Retry with another mode. For the context menu, the More
    /// button and the answer's text menu.
    private func answerMenuItems(_ id: UUID) -> [UIMenuElement] {
        guard let m = message(id), !m.isUser, live?.id != id else { return [] }
        var items: [UIMenuElement] = []
        if !m.content.isEmpty {
            var basics: [UIMenuElement] = [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = m.content
                },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [unowned self] _ in
                    share(m.content, from: id)
                },
            ]
            if Speaker.shared.speaking == id {
                basics.append(UIAction(title: "Stop Reading", image: UIImage(systemName: "stop.circle")) { _ in
                    Speaker.shared.stop()
                })
            } else {
                basics.append(UIAction(title: "Read Aloud", image: UIImage(systemName: "speaker.wave.2")) { _ in
                    Speaker.shared.speak(m.content, id: id)
                })
            }
            items.append(UIMenu(options: .displayInline, children: basics))
        }
        if isLast(id), !engine.isBusy {
            let current = conversation.mode
            let others = Mode.allCases.filter { $0 != current }.map { mode in
                UIAction(title: mode.title, subtitle: availability(mode), image: UIImage(systemName: mode.symbol),
                         attributes: isAvailable(mode) ? [] : .disabled) { [unowned self] _ in retry(mode) }
            }
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise"),
                         attributes: isAvailable(current) ? [] : .disabled) { [unowned self] _ in retry(current) },
                UIMenu(title: "Retry with…", image: UIImage(systemName: "arrow.triangle.branch"), children: others),
            ]))
        }
        return items
    }

    /// Copy, and Edit & Resend.
    private func userMenuItems(_ id: UUID) -> [UIMenuElement] {
        guard let m = message(id), m.isUser else { return [] }
        return [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = m.content },
            UIAction(title: "Edit & Resend", image: UIImage(systemName: "pencil"),
                     attributes: engine.isBusy ? .disabled : []) { [unowned self] _ in beginEditing(id) },
        ]
    }

    private func share(_ text: String, from id: UUID) {
        let share = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        let source: UIView = dataSource.indexPath(for: id).flatMap { collectionView.cellForItem(at: $0) } ?? composer
        share.popoverPresentationController?.sourceItem = source
        present(share, animated: true)
    }

    /// Retry, plus a way to fix the cause: Readiness for a missing model, a fresh look for the Mac.
    private func errorActions(for m: StoredMessage) -> [UIAction] {
        guard let error = m.error, !m.isUser else { return [] }
        var actions: [UIAction] = []
        if isLast(m.id) {
            actions.append(UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise"),
                                    attributes: engine.isBusy ? .disabled : []) { [unowned self] _ in
                retry(conversation.mode)
            })
        }
        switch ReplyErrorKind(error: error, mode: conversation.mode) {
        case .notDownloaded:
            if let open = onOpenReadiness {
                actions.append(UIAction(title: "Open Readiness", image: UIImage(systemName: "arrow.down.circle")) { _ in open() })
            }
        case .mac:
            actions.append(UIAction(title: "Check the Mac", image: UIImage(systemName: "desktopcomputer")) {
                [unowned self] _ in checkMac()
            })
        case .other:
            break
        }
        return actions
    }

    /// Looks for the Mac again; if it still can't be reached, opens Settings to check its address.
    private func checkMac() {
        Task {
            let route = await engine.mac.resolve()
            if route.host == nil {
                announce("Still can't reach the Mac.")
                onOpenSettings?()
            } else {
                announce("The Mac answers over the \(route.label.lowercased()). Try again.")
            }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let id = dataSource.itemIdentifier(for: indexPaths[0]), let m = message(id) else { return nil }
        let items = m.isUser ? userMenuItems(id) : answerMenuItems(id)
        guard !items.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSUUID, previewProvider: nil) { _ in UIMenu(children: items) }
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? UserCell else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: cell.previewView.bounds, cornerRadius: 18)
        return UITargetedPreview(view: cell.previewView, parameters: parameters)
    }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        self.collectionView(collectionView, contextMenuConfiguration: configuration, highlightPreviewForItemAt: indexPath)
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

    /// While an input method is composing (Japanese, Chinese, Korean), Return belongs to it: it
    /// commits the composition. Only take Return over when nothing is being composed.
    private var isComposing: Bool { composer.textView.markedTextRange != nil }

    override var keyCommands: [UIKeyCommand]? {
        let modes = Mode.allCases.enumerated().map { i, m in
            UIKeyCommand(title: m.title, action: #selector(modeKey(_:)), input: "\(i + 1)", modifierFlags: .command,
                         propertyList: m.rawValue)
        }
        var commands = [
            UIKeyCommand(title: "Send", action: #selector(sendKey), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: "Stop", action: #selector(stopKey), input: UIKeyCommand.inputEscape),
            UIKeyCommand(title: "Stop", action: #selector(stopKey), input: ".", modifierFlags: .command),
        ] + modes
        if !isComposing {
            let returnKey = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendKey))
            returnKey.wantsPriorityOverSystemBehavior = true  // hardware Return sends; the on-screen one adds a line
            let newline = UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(newlineKey))
            newline.wantsPriorityOverSystemBehavior = true
            commands.insert(contentsOf: [returnKey, newline], at: 0)
        }
        return commands
    }

    @objc private func sendKey() {
        // If Return still reaches us mid-composition, do what the input method would: commit it.
        if isComposing {
            composer.textView.unmarkText()
            return
        }
        if composer.isRunning == false { send(composer.text) }
    }

    @objc private func newlineKey() {
        if isComposing { composer.textView.unmarkText() } else { composer.textView.insertText("\n") }
    }

    @objc private func stopKey() {
        if live != nil {
            engine.stop()
        } else if editingID != nil {
            cancelEditing()
        }
    }

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

/// Shown in an empty chat. What it says depends on where the answers come from.
private struct EmptyChat: View {
    let conversation: Conversation
    @Environment(MacLink.self) private var mac

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: conversation.mode == .mac ? "desktopcomputer" : "flame")
                .font(.largeTitle).foregroundStyle(.tint)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }

    private var message: String {
        guard conversation.mode == .mac else { return "Ask anything. It runs on this device." }
        if mac.route == .unreachable { return "Ask anything. Lantern can't reach your Mac right now." }
        return "Ask anything. Your Mac answers, over your home network or tailnet."
    }
}
