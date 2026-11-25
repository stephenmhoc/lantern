import GameController
import LlamaKit
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// Shows another chat in this window ("Continue in New Chat").
    var onOpenChat: ((Conversation) -> Void)?
    /// Called when typing starts in a chat whose model isn't loaded (or whose Mac route isn't known),
    /// to get it ready before Send. Must return at once (e.g. start `Engine.prepare` in a Task).
    var onBeginTyping: (() -> Void)?
    /// Opens `CompareView` for a reply (its id, and whether to start on B).
    var onShowComparison: ((UUID, Bool) -> Void)?

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
    private var attachmentsBeforeEdit: [Attachment] = []
    private let dictation = Dictation()
    /// What was in the field when dictation started; what's heard goes after it.
    private var dictationPrefix = ""
    private var draftSave: Task<Void, Never>?
    private var wasTyping = false

    init(conversation: Conversation, engine: Engine) {
        self.conversation = conversation
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The widest the transcript's text gets.
    static let maxTextWidth: CGFloat = 688

    /// The text column's distance from each side of a view this wide: the standard margin, where
    /// the header's buttons start, or centered at `maxTextWidth` when there's room. The transcript
    /// and the composer's field and controls share it.
    func columnInsets(width: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let margin = systemMinimumLayoutMargins
        let safe = view.safeAreaInsets
        let leading = safe.left + margin.leading, trailing = safe.right + margin.trailing
        let extra = max(0, (width - leading - trailing - Self.maxTextWidth) / 2)
        return ((leading + extra).rounded(), (trailing + extra).rounded())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Messages keep to `columnInsets`. Cells add no side margins of their own.
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(80))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsetsReference = .none
            let side = self?.columnInsets(width: environment.container.contentSize.width) ?? (leading: 16, trailing: 16)
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: side.leading, bottom: 12, trailing: side.trailing)
            return section
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
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
        composer.onMic = { [unowned self] in toggleDictation() }
        composer.textView.onPasteFiles = { [unowned self] providers in attach(providers) }
        composer.text = conversation.draft
        wasTyping = !conversation.draft.isEmpty
        view.addSubview(composer)

        // A starter fills the message box for the user to finish; it never replaces a draft.
        let starters = host(EmptyChat(conversation: conversation) { [unowned self] text in
            if composer.text.isEmpty { composer.text = text }
            // Next turn: the same tap also reaches `tappedTranscript`, which would put the keyboard away.
            DispatchQueue.main.async { self.composer.textView.becomeFirstResponder() }
        })
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
            jumpButton.trailingAnchor.constraint(equalTo: composer.columnGuide.trailingAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -12),
            jumpButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            jumpButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        Speaker.shared.onChange = { [weak self] in self?.reconfigureVisibleAnswers() }
        // Settings' "Speed and tokens" switch: redraw the answers' footnotes when it changes.
        showsMetrics = ReplyDetails.shown
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.showsMetrics != ReplyDetails.shown else { return }
                self.showsMetrics = ReplyDetails.shown
                self.reconfigureVisibleAnswers()
            }
        }
        // A tap on the transcript (or the new chat's page) away from the message box puts the keyboard away.
        let tapAway = UITapGestureRecognizer(target: self, action: #selector(tappedTranscript))
        tapAway.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tapAway)
        // Files dropped anywhere on the chat are attached (text dropped on the field is typed).
        view.addInteraction(UIDropInteraction(delegate: self))
        setUpDictation()
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToBottom(animated: false)
        takeJump()
        observeJump()
        // Ready to type on iPad and Mac; on iPhone the keyboard would cover a chat you came to read.
        // A new chat is the page the app opens on, with its prompt ideas: there the on-screen
        // keyboard stays down, so only with a hardware keyboard. Not behind a sheet (Settings,
        // Readiness), whose keyboard-covered content would be hidden.
        let keyboardOK = !conversation.messages.isEmpty || GCKeyboard.coalesced != nil
        if traitCollection.userInterfaceIdiom != .phone, keyboardOK,
           view.window?.rootViewController?.presentedViewController == nil {
            composer.textView.becomeFirstResponder()
        }
        engine.prepare(mode: conversation.mode, for: conversation)  // load the model before the first message
        #if DEBUG
        // -ui compare (or compare:b, with :metrics to scroll to the table): the seeded comparison, once the chat has settled.
        // -ui compare:chat: the seeded comparison's chat, without opening the sheet.
        if let ui = DebugLaunch.ui, ui.hasPrefix("compare"), ui != "compare:chat",
           let reply = conversation.messages.last, reply.comparison != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.showComparison(reply.id, startOnB: ui.hasPrefix("compare:b"))
            }
        }
        // -ui composer:focus|composer:text|modelmenu|modelmenu:collapsed: the message box expanded
        // (focused, or holding a draft without the keyboard) or the model menu open.
        if let ui = DebugLaunch.ui, ui.hasPrefix("composer") || ui.hasPrefix("modelmenu") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                switch ui {
                case "composer:focus": composer.textView.becomeFirstResponder()
                case "composer:text": composer.text = "What should I plant next to tomatoes?"
                case "modelmenu":
                    composer.text = " "
                    try? await Task.sleep(for: .milliseconds(500))
                    DebugLaunch.presentMenu(of: composer.modeButton)
                case "modelmenu:collapsed": DebugLaunch.presentMenu(of: composer.modeIconButton)
                default: break
                }
            }
        }
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dictation.stop()
        saveDraft()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let side = columnInsets(width: view.bounds.width)
        if composer.columnInsets != side {
            composer.columnInsets = side
            collectionView.collectionViewLayout.invalidateLayout()
        }
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
        composer.placeholderText = dictation.isRunning ? "Listening…"
            : engine.isBusy && !runningHere ? "Another chat is answering…" : "Ask \(conversation.modelTitle)"
        updateModeButton()
        updateAttachMenu()

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
        cell.onCompare = { [unowned self] in showComparison(id) }
    }

    private func modelName(for mode: Mode) -> String? {
        mode == .mac ? conversation.modelTitle : mode == .apple ? mode.title : engine.model(for: mode)?.name
    }

    private var showsMetrics = true

    @objc private func tappedTranscript() {
        if composer.textView.isFirstResponder { composer.textView.resignFirstResponder() }
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
        let attachments = composer.attachments
        guard !text.isEmpty || !attachments.isEmpty, !engine.isBusy else { return }
        dictation.stop()
        // Edit & Resend: the conversation goes back to just before the edited message.
        if let id = editingID, let i = conversation.index(of: id) {
            Speaker.shared.stop()
            conversation.messages.removeSubrange(i...)
        }
        editingID = nil
        composer.text = ""
        composer.attachments = []
        attachmentsBeforeEdit = []
        wasTyping = false
        saveDraft()
        isPinned = true
        engine.send(text, attachments: attachments, in: conversation)
        refresh()
    }

    /// Retry keeps the answer it replaces: the new one gets the old ones as its other versions
    /// (`Engine.retry` does that).
    private func retry(_ mode: Mode, macModel: String? = nil) {
        guard let old = conversation.messages.last, !old.isUser, !engine.isBusy else { return }
        if Speaker.shared.speaking == old.id { Speaker.shared.stop() }
        isPinned = true
        engine.retry(in: conversation, mode: mode, macModel: macModel)
        refresh()
    }

    /// Answers the last question again with `other`, keeping both answers as a pair to compare.
    private func compare(with other: ModelChoice) {
        guard let old = conversation.messages.last, !old.isUser, !engine.isBusy else { return }
        if Speaker.shared.speaking == old.id { Speaker.shared.stop() }
        isPinned = true
        engine.compare(in: conversation, with: other)
        refresh()
    }

    /// The two answers side by side, with how each was made. Presented by `ChatScreen` in
    /// SwiftUI, so the sheet goes away with this chat when another one is selected or opened.
    func showComparison(_ id: UUID, startOnB: Bool = false) {
        onShowComparison?(id, startOnB)
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
        if editingID == nil {
            draftBeforeEdit = composer.text
            attachmentsBeforeEdit = composer.attachments
        }
        editingID = id
        composer.text = m.content
        composer.attachments = m.attachments ?? []
        composer.textView.becomeFirstResponder()
        refreshEditingCells()
    }

    private func cancelEditing() {
        guard editingID != nil else { return }
        editingID = nil
        composer.text = draftBeforeEdit
        composer.attachments = attachmentsBeforeEdit
        attachmentsBeforeEdit = []
        refreshEditingCells()
    }

    private func refreshEditingCells() {
        composer.isEditingMessage = editingID != nil
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { message($0)?.isUser == true })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// `macModel`: for `.mac`, which of the Mac's models. Picking one also makes it the one new
    /// Mac chats start with.
    private func setMode(_ mode: Mode, macModel: String? = nil) {
        guard live == nil else { return }
        conversation.mode = mode
        if let macModel {
            conversation.macModel = macModel
            UserDefaults.standard.set(macModel, forKey: MacLink.modelKey)
        }
        refresh()
    }

    private func isAvailable(_ mode: Mode) -> Bool {
        guard mode.isOnDevice else { return true }  // the Mac may come back; it's badged, not disabled
        if mode == .apple { return engine.apple.status.isAvailable }
        return engine.model(for: mode).map { engine.store.states[$0.id] == .ready } ?? false
    }

    /// One entry per model: the Gemmas, Qwen and Apple Intelligence on this device, then each of
    /// Ollama's models on the Mac.
    private var choices: (device: [ModelChoice], mac: [ModelChoice]) {
        let device = Mode.allCases.filter(\.isOnDevice).map { ModelChoice(mode: $0, macModel: nil) }
        var names = engine.mac.models
        // The chat's own model even if the Mac hasn't been checked yet (or no longer lists it).
        let current = conversation.resolvedMacModel
        if !current.isEmpty, !names.contains(current) { names.insert(current, at: 0) }
        let mac = names.isEmpty ? [ModelChoice(mode: .mac, macModel: nil)] : names.map { ModelChoice(mode: .mac, macModel: $0) }
        return (device, mac)
    }

    private func isCurrent(_ choice: ModelChoice) -> Bool {
        guard choice.mode == conversation.mode else { return false }
        return choice.mode != .mac || choice.macModel == nil || choice.macModel == conversation.resolvedMacModel
    }

    private func updateModeButton() {
        let mode = conversation.mode
        let title = conversation.modelTitle
        composer.setMode(title: title, symbol: mode.symbol)
        composer.modeButton.accessibilityLabel = "Model"
        composer.modeButton.accessibilityValue = mode == .apple ? "\(title), on this device"
            : "\(title), \(mode.isOnDevice ? "on this device" : "on your \(engine.mac.computerName)"), thinking \(conversation.thinking.rawValue)"
        composer.modeButton.isEnabled = live == nil

        let unreachable = engine.mac.route == .unreachable
        let (device, mac) = choices
        let deviceItems = device.map { c in
            UIAction(title: c.title, subtitle: availability(c.mode), image: UIImage(systemName: c.mode.symbol),
                     attributes: isAvailable(c.mode) ? [] : .disabled, state: isCurrent(c) ? .on : .off) { [unowned self] _ in
                setMode(c.mode)
            }
        }
        let macItems = mac.map { c in
            UIAction(title: c.title, image: UIImage(systemName: unreachable ? "exclamationmark.triangle" : c.mode.symbol),
                     state: isCurrent(c) ? .on : .off) { [unowned self] _ in
                setMode(.mac, macModel: c.macModel)
            }
        }
        var sections: [UIMenuElement] = [
            UIMenu(title: "On this device", options: .displayInline, children: deviceItems),
            UIMenu(title: availability(.mac), options: .displayInline, children: macItems),
        ]
        // Only for what can be downloaded: Apple Intelligence's model comes with the system.
        if let open = onOpenReadiness, Mode.allCases.contains(where: { $0.usesLlama && !isAvailable($0) }) {
            sections.append(UIAction(title: "Get Models…", image: UIImage(systemName: "arrow.down.circle")) { _ in open() })
        }
        let thinking = Thinking.allCases.map { t in
            UIAction(title: t.rawValue.capitalized, state: t == conversation.thinking ? .on : .off) { [unowned self] _ in
                conversation.thinking = t
                refresh()
            }
        }
        // Apple Intelligence's model doesn't think before answering: no choice to offer.
        if mode != .apple {
            sections.append(UIMenu(
                title: "Thinking", subtitle: conversation.thinking.rawValue.capitalized,
                image: UIImage(systemName: "lightbulb"), children: thinking))
        }
        composer.modeButton.menu = UIMenu(children: sections)
        composer.syncModeIcon()
    }

    private func availability(_ mode: Mode) -> String {
        if mode == .mac {
            let name = engine.mac.computerName
            return switch engine.mac.route {
            case .unknown, .checking: "On Your \(name)"
            case .unreachable: "On Your \(name) · Not reachable"
            default: "On Your \(name) · \(engine.mac.route.label)"
            }
        }
        if mode == .apple {
            let status = engine.apple.status
            return status.isAvailable ? "Built into this device" : status.short
        }
        guard let model = engine.model(for: mode) else { return "" }
        return engine.store.states[model.id] == .ready ? "On this device" : "Not on this device"
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
        if mode == .apple { return false }  // `prepare` already warmed it when the chat opened
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
        if m.comparison != nil {
            items.append(UIAction(title: "Compare Answers", image: UIImage(systemName: "rectangle.split.2x1")) {
                [unowned self] _ in showComparison(id)
            })
        }
        if isLast(id), !engine.isBusy {
            let current = conversation.mode
            let (device, mac) = choices
            let others = (device + mac).filter { !isCurrent($0) }.map { c in
                UIAction(title: c.title, subtitle: c.mode.isOnDevice ? availability(c.mode) : "On Your \(engine.mac.computerName)",
                         image: UIImage(systemName: c.mode.symbol),
                         attributes: isAvailable(c.mode) ? [] : .disabled) { [unowned self] _ in retry(c.mode, macModel: c.macModel) }
            }
            // A second answer from another model, kept beside this one (see CompareView).
            let own = answeredBy(m)
            let rivals = (device + mac).filter { !isSame($0, own) }.map { c in
                UIAction(title: c.title, subtitle: c.mode.isOnDevice ? availability(c.mode) : "On Your \(engine.mac.computerName)",
                         image: UIImage(systemName: c.mode.symbol),
                         attributes: isAvailable(c.mode) ? [] : .disabled) { [unowned self] _ in compare(with: c) }
            }
            var retries: [UIMenuElement] = [
                UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise"),
                         attributes: isAvailable(current) ? [] : .disabled) { [unowned self] _ in retry(current) },
                UIMenu(title: "Retry With", image: UIImage(systemName: "arrow.triangle.branch"), children: others),
            ]
            if m.finished, m.error == nil, !m.content.isEmpty, !rivals.isEmpty {
                retries.append(UIMenu(title: "Compare With", image: UIImage(systemName: "rectangle.split.2x1"), children: rivals))
            }
            items.append(UIMenu(options: .displayInline, children: retries))
        }
        return items
    }

    /// The model that wrote an answer: from its metrics, else its footnote, else the chat's.
    private func answeredBy(_ m: StoredMessage) -> ModelChoice {
        conversation.model(of: m.metrics, footnote: m.footnote, macModels: engine.mac.models)
    }

    /// Whether two choices name the same model. A Mac choice without a model means the chat's.
    private func isSame(_ a: ModelChoice, _ b: ModelChoice) -> Bool {
        guard a.mode == b.mode else { return false }
        guard a.mode == .mac else { return true }
        let resolve = { (c: ModelChoice) in c.macModel ?? self.conversation.resolvedMacModel }
        return resolve(a) == resolve(b)
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
        guard m.error != nil, !m.isUser else { return [] }
        var actions: [UIAction] = []
        if isLast(m.id) {
            actions.append(UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise"),
                                    attributes: engine.isBusy ? .disabled : []) { [unowned self] _ in
                retry(conversation.mode)
            })
        }
        // Replies saved before errors had a kind fall back to the mode.
        let kind = m.errorKind ?? (conversation.mode == .mac ? .macUnreachable : .other)
        switch kind {
        case .notDownloaded:
            if let open = onOpenReadiness {
                actions.append(UIAction(title: "Open Models", image: UIImage(systemName: "arrow.down.circle")) { _ in open() })
            }
        case .macUnreachable, .macNoModel, .macFailed:
            actions.append(UIAction(title: "Check the Mac", image: UIImage(systemName: "desktopcomputer")) {
                [unowned self] _ in checkMac()
            })
        case .contextFull where isLast(m.id):
            actions.append(UIAction(title: "Drop Oldest Messages and Continue", image: UIImage(systemName: "scissors"),
                                    attributes: engine.isBusy ? .disabled : []) { [unowned self] _ in
                engine.continueTrimmed(in: conversation)
            })
            if let open = onOpenChat {
                actions.append(UIAction(title: "Continue in New Chat", image: UIImage(systemName: "square.and.pencil")) {
                    [unowned self] _ in open(engine.continueInNewChat(from: conversation))
                })
            }
        default:
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

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        focusJumpTarget()
    }

    // MARK: - Jumping to a search result

    /// Scrolls to the message a sidebar search result was tapped for (`ChatJump`), if it's for this
    /// chat. The shown version is left alone: switching it would change the history sent next.
    private func takeJump() {
        guard view.window != nil,
              let target = ChatJump.shared.claim(for: conversation.persistentModelID),
              let path = dataSource.indexPath(for: target.message) else { return }
        isPinned = false  // or the next layout snaps back to the bottom
        collectionView.layoutIfNeeded()
        jumpFocus = target.message
        let before = collectionView.contentOffset
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: true)
        jumpButton.isHidden = false
        // Already in place: no scrolling animation will end to move VoiceOver there.
        if collectionView.contentOffset == before, collectionView.cellForItem(at: path) != nil,
           !collectionView.isDragging { DispatchQueue.main.async { [weak self] in self?.focusJumpTarget() } }
        // The match is in another answer to that question, which isn't switched to (that would
        // change the history sent next): tell VoiceOver where it is. Nothing pops up on screen.
        if let version = target.version, let m = message(target.message) {
            let (list, current) = m.allVersions
            if version != current, list.indices.contains(version) {
                UIAccessibility.post(notification: .announcement, argument: "Match is in answer \(version + 1) of \(list.count)")
            }
        }
    }

    /// The message a search jump scrolled to, until VoiceOver has been moved to it.
    private var jumpFocus: UUID?

    /// Moves VoiceOver to the jumped-to message, once its cell is on screen (after the scroll, so
    /// it works for a message that was far off).
    private func focusJumpTarget() {
        guard let id = jumpFocus, let path = dataSource.indexPath(for: id),
              let cell = collectionView.cellForItem(at: path) else { return }
        jumpFocus = nil
        UIAccessibility.post(notification: .layoutChanged, argument: cell)
    }

    /// On iPad the tapped chat may already be on screen: take a target set while it's showing.
    private func observeJump() {
        guard !observingJump else { return }
        observingJump = true
        withObservationTracking { _ = ChatJump.shared.pending } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observingJump = false
                guard self.view.window != nil else { return }  // viewDidAppear starts it again
                self.takeJump()
                self.observeJump()
            }
        }
    }
    private var observingJump = false

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

// MARK: - Attachments

extension ChatViewController: UIDocumentPickerDelegate, PHPickerViewControllerDelegate, UIDropInteractionDelegate {
    /// Choose File, Choose Photo; Photo is off in a mode that can't see images, with the reason.
    fileprivate func updateAttachMenu() {
        let mode = conversation.mode
        let seesImages = engine.canSeeImages(mode)
        var photoNote: String?
        let projector = engine.model(for: mode)?.projector
        if !seesImages { photoNote = projector == nil ? "\(mode.title) can't see images" : "Needs Image reading for \(mode.title)" }
        var items: [UIMenuElement] = [
            UIAction(title: "Choose File…", subtitle: "Text or PDF", image: UIImage(systemName: "doc")) { [unowned self] _ in
                chooseFile()
            },
            UIAction(title: "Choose Photo…", subtitle: photoNote, image: UIImage(systemName: "photo"),
                     attributes: seesImages ? [] : .disabled) { [unowned self] _ in choosePhoto() },
        ]
        if mode.isOnDevice, !seesImages, projector != nil, let open = onOpenReadiness {
            items.append(UIAction(title: "Get Image Reading…", image: UIImage(systemName: "arrow.down.circle")) { _ in open() })
        }
        composer.attachButton.menu = UIMenu(children: items)
        composer.attachButton.isEnabled = live == nil
    }

    private func chooseFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: AttachmentReader.types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func choosePhoto() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 4
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task {
            var read: [Attachment] = []
            for url in urls {
                do {
                    read.append(try await Task.detached { try AttachmentReader.read(url) }.value)
                } catch {
                    showProblem(error.localizedDescription)
                }
            }
            add(read)
        }
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        attach(results.map(\.itemProvider))
    }

    /// Pasted or dropped items: files, images, or text that came as a file.
    fileprivate func attach(_ providers: [NSItemProvider]) {
        Task {
            var read: [Attachment] = []
            for (n, provider) in providers.enumerated() {
                do {
                    read.append(try await Self.load(provider, fallbackName: "Pasted \(n + 1)"))
                } catch {
                    showProblem(error.localizedDescription)
                }
            }
            add(read)
        }
    }

    private nonisolated static func load(_ provider: NSItemProvider, fallbackName: String) async throws -> Attachment {
        guard let type = AttachmentReader.types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            throw AttachmentReader.Failure.unsupported(provider.suggestedName ?? fallbackName)
        }
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { done in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    return done.resume(throwing: error ?? AttachmentReader.Failure.unreadable(name ?? fallbackName))
                }
                do {
                    var attachment = try AttachmentReader.read(url)
                    // Temporary files have made-up names; the provider knows the real one.
                    if let name, !name.isEmpty {
                        let ext = url.pathExtension
                        attachment.name = name.hasSuffix(".\(ext)") || ext.isEmpty ? name : "\(name).\(ext)"
                    }
                    done.resume(returning: attachment)
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    /// Adds files to the composer, first saying so if one is too big for the model to make good
    /// use of (over half its context), or is an image the mode can't see.
    private func add(_ new: [Attachment]) {
        guard !new.isEmpty else { return }
        let mode = conversation.mode
        let seen = engine.canSeeImages(mode) ? new : new.filter { !$0.isImage }
        if seen.count < new.count {
            showProblem(engine.model(for: mode)?.projector == nil
                        ? "\(mode.title) can't see photos. Gemma 4 E2B and E4B can, with Image reading."
                        : "\(mode.title) needs Image reading, in Settings > Models, to see photos.")
        }
        guard !seen.isEmpty else { return }
        let limit = engine.contextLimit(for: mode)
        let big = seen.filter { AttachmentReader.estimatedTokens($0) > limit / 2 }
        guard let first = big.first else { return append(seen) }
        let tokens = AttachmentReader.estimatedTokens(first)
        let alert = UIAlertController(
            title: big.count == 1 ? "“\(first.name)” is long" : "Some files are long",
            message: """
                About \(tokens.formatted()) tokens: more than half of what \(conversation.modelTitle) can hold \
                (\(limit.formatted())). The answer may be cut short, and the chat will fill up quickly.
                """,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Attach Anyway", style: .default) { [unowned self] _ in append(seen) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func append(_ attachments: [Attachment]) {
        composer.attachments += attachments
        // Not behind a sheet (Settings, Readiness), whose keyboard-covered content would be hidden.
        if traitCollection.userInterfaceIdiom != .phone, view.window?.rootViewController?.presentedViewController == nil {
            composer.textView.becomeFirstResponder()
        }
    }

    fileprivate func showProblem(_ message: String, settings: Bool = false) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        if settings, let url = URL(string: UIApplication.openSettingsURLString) {
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in UIApplication.shared.open(url) })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        if presentedViewController == nil { present(alert, animated: true) }
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        live == nil && session.hasItemsConforming(toTypeIdentifiers: AttachmentReader.types.map(\.identifier))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        attach(session.items.map(\.itemProvider))
    }
}

// MARK: - Dictation

extension ChatViewController {
    fileprivate func setUpDictation() {
        dictation.onTranscript = { [unowned self] heard in
            composer.text = dictationPrefix + heard
            textChanged(composer.text)
        }
        dictation.onEnd = { [unowned self] error in
            composer.isListening = false
            refresh()
            if let error { showProblem(error.localizedDescription) }
        }
        Task { [weak self] in
            let available = await Dictation.isAvailable()
            self?.composer.micButton.isHidden = !available
        }
    }

    /// Tap to listen, tap again to stop. What's heard goes after what's already typed.
    fileprivate func toggleDictation() {
        if dictation.isRunning {
            dictation.stop()
            composer.isListening = false
            refresh()
            return
        }
        Speaker.shared.stop()
        let typed = composer.text
        dictationPrefix = typed.isEmpty || typed.hasSuffix(" ") || typed.hasSuffix("\n") ? typed : typed + " "
        composer.isListening = true
        Task {
            do {
                try await dictation.start()
                refresh()
            } catch {
                composer.isListening = false
                let failure = error as? Dictation.Failure
                showProblem(error.localizedDescription, settings: failure?.opensSettings == true)
            }
        }
    }
}

/// The chat screen as SwiftUI sees it. `revision` changes whenever something the UIKit side shows
/// (other than streaming text) changes, which is what makes SwiftUI call `refresh()`. Around the
/// UIKit controller: the editable title and its menu (Rename, Export), the inspector,
/// a banner when another chat or a model test holds the engine, and the menu bar's view of the chat.
struct ChatScreen: View {
    @Bindable var conversation: Conversation
    @Environment(Engine.self) private var engine
    @AppStorage(DefaultMode.key) private var lastMode = ""
    @SceneStorage("inspector") private var showInspector = false
    @Environment(\.showReadiness) private var showReadiness
    @Environment(\.showSettings) private var showSettings
    @Environment(\.openChat) private var openChat
    @State private var comparing: ComparisonRequest?
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The reply `CompareView` shows, and which side it starts on.
    struct ComparisonRequest: Identifiable {
        let reply: UUID
        let startOnB: Bool
        var id: UUID { reply }
    }

    var body: some View {
        ChatControllerView(conversation: conversation, engine: engine, revision: revision, showReadiness: showReadiness,
                           showSettings: showSettings, openChat: openChat,
                           showComparison: { comparing = ComparisonRequest(reply: $0, startOnB: $1) })
            .ignoresSafeArea(.keyboard)  // the UIKit side follows the keyboard itself
            .safeAreaInset(edge: .top, spacing: 0) { BusyBanner(conversation: conversation) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                RenameButton()
                ShareLink(item: ChatExport(conversation), preview: SharePreview(conversation.title)) {
                    Label("Export Chat", systemImage: "square.and.arrow.up")
                }
                .disabled(conversation.messages.isEmpty)
                // iPhone: here rather than in the bar, which keeps to the side panel and New chat.
                if sizeClass == .compact {
                    Button("Chat Info", systemImage: "info.circle") { showInspector = true }
                }
            }
            .toolbar {
                if sizeClass != .compact {
                    ToolbarItem(placement: .primaryAction) {
                        Button(showInspector ? "Hide Info" : "Show Info", systemImage: "info.circle") {
                            withAnimation { showInspector.toggle() }
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                    }
                }
            }
            // Here rather than presented from UIKit: the screen is rebuilt per chat (`.id`), so the
            // sheet can't outlive it and act on the chat it came from.
            .sheet(item: $comparing) { request in
                CompareView(conversation: conversation, replyID: request.reply, startOnB: request.startOnB)
                    .presentationDetents([.large])
            }
            .inspector(isPresented: $showInspector) {
                ChatInspector(conversation: conversation) { withAnimation { showInspector = false } }
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            #if DEBUG
            // After the push settles: on iPhone a sheet asked for mid-push never shows.
            .task { if DebugLaunch.ui == "inspector" { try? await Task.sleep(for: .seconds(1)); showInspector = true } }
            #endif
            .focusedSceneValue(\.chat, ChatFocus(
                conversation: conversation, mode: conversation.mode,
                canChangeMode: engine.running != conversation.persistentModelID))
            // The mode a new chat starts in follows the one last chosen or sent with.
            .onChange(of: conversation.mode) { _, mode in lastMode = mode.rawValue }
            .onChange(of: conversation.messages.count) { old, new in
                if new > old { lastMode = conversation.mode.rawValue }
            }
    }

    /// Renaming to nothing keeps the old title.
    private var title: Binding<String> {
        Binding(
            get: { conversation.title },
            set: { new in
                let t = new.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { conversation.title = t }
            })
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

/// When another chat (maybe in another window) is answering, or Readiness is testing a model, this
/// chat can't send. Says so above the transcript, with a way to stop it.
private struct BusyBanner: View {
    let conversation: Conversation
    @Environment(Engine.self) private var engine
    @Environment(\.modelContext) private var context

    var body: some View {
        if let text {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text).lineLimit(2)
                Spacer(minLength: 8)
                if engine.running != nil {
                    Button("Stop") { engine.stop() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            .font(.footnote)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }

    private var text: String? {
        if let model = engine.testing { return "Testing \(model.name). Chats can send when it's done." }
        if engine.testingApple { return "Testing \(Mode.apple.title). Chats can send when it's done." }
        guard let running = engine.running, running != conversation.persistentModelID else { return nil }
        if let other: Conversation = context.registeredModel(for: running) {
            return "“\(other.title)” is answering. This chat can send when it's done."
        }
        return "Another chat is answering. This chat can send when it's done."
    }
}

private struct ChatControllerView: UIViewControllerRepresentable {
    let conversation: Conversation
    let engine: Engine
    let revision: Int
    let showReadiness: OpenSheetAction
    let showSettings: OpenSheetAction
    let openChat: OpenChatAction
    let showComparison: (UUID, Bool) -> Void

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController(conversation: conversation, engine: engine)
        controller.onOpenReadiness = { showReadiness() }
        controller.onOpenSettings = { showSettings() }
        controller.onOpenChat = { openChat($0) }
        controller.onShowComparison = { showComparison($0, $1) }
        controller.onBeginTyping = { [conversation, engine] in engine.prepare(mode: conversation.mode, for: conversation) }
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.refresh()
    }
}
