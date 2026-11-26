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
/// commands. The empty-chat view is a SwiftUI view hosted inside it.
final class ChatViewController: UIViewController, UICollectionViewDelegate {
    let conversation: Conversation
    private let engine: Engine

    // Hooks for the app around the chat. Each does nothing until set.
    /// Opens the page that downloads this device's model.
    var onGetModel: (() -> Void)?
    /// Opens Settings: the Mac's pairing, the web search key.
    var onOpenSettings: (() -> Void)?
    /// Shows another chat in this window ("Continue in New Chat").
    var onOpenChat: ((Conversation) -> Void)?
    /// Called when typing starts in a chat whose model isn't loaded (or whose Mac route isn't known),
    /// to get it ready before Send. Must return at once (e.g. start `Engine.prepare` in a Task).
    var onBeginTyping: (() -> Void)?
    /// Opens `CompareView` for a reply.
    var onShowComparison: ((UUID) -> Void)?

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

        composer = ComposerView()
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.onSend = { [unowned self] in send(composer.text) }
        composer.onStop = { [unowned self] in engine.stop() }
        composer.onTextChange = { [unowned self] text in textChanged(text) }
        composer.onCancelEdit = { [unowned self] in cancelEditing() }
        composer.textView.onPasteFiles = { [unowned self] providers in attach(providers) }
        for button in [composer.modeButton, composer.modeIconButton] {
            button.addAction(UIAction { [unowned self, unowned button] _ in showModelPicker(from: button) }, for: .primaryActionTriggered)
        }
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

        // A tap on the transcript (or the new chat's page) away from the message box puts the keyboard away.
        let tapAway = UITapGestureRecognizer(target: self, action: #selector(tappedTranscript))
        tapAway.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tapAway)
        // Files dropped anywhere on the chat are attached (text dropped on the field is typed).
        view.addInteraction(UIDropInteraction(delegate: self))
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scrollToBottom(animated: false)
        takeJump()
        observeJump()
        // Ready to type on iPad and Mac; on iPhone the keyboard would cover a chat you came to read.
        // A new chat is the page the app opens on, with its prompt ideas: there the on-screen
        // keyboard stays down, so only with a hardware keyboard. Not behind a sheet (Settings),
        // whose keyboard-covered content would be hidden.
        let keyboardOK = !conversation.messages.isEmpty || GCKeyboard.coalesced != nil
        if traitCollection.userInterfaceIdiom != .phone, keyboardOK,
           view.window?.rootViewController?.presentedViewController == nil {
            composer.textView.becomeFirstResponder()
        }
        engine.prepare(conversation)  // load the model before the first message
        #if DEBUG
        // -ui picker | compare | comparepicker: that sheet, once the chat has settled.
        if let ui = DebugLaunch.ui, ["picker", "compare", "comparepicker"].contains(ui) {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let reply = conversation.messages.last else { return }
                switch ui {
                case "picker": showModelPicker(from: composer.modeIconButton)
                case "compare" where reply.comparison != nil: showComparison(reply.id)
                case "comparepicker" where !reply.isUser: showComparePicker(for: reply.id)
                default: break
                }
            }
        }
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
        composer.placeholderText = engine.isBusy && !runningHere ? "Another chat is answering…"
            : MacLink.isConfigured ? "Ask \(conversation.modelTitle)" : "Message"  // who answers, once there's a choice
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
            content.status = clock.status(for: live, modelName: conversation.modelTitle)
        }
        content.thinkingExpanded = expanded.contains(id)
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
        cell.onCompare = { [unowned self] in showComparison(id) }
    }

    @objc private func tappedTranscript() {
        if composer.textView.isFirstResponder { composer.textView.resignFirstResponder() }
    }

    // MARK: - Actions

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = composer.attachments
        guard !text.isEmpty || !attachments.isEmpty, !engine.isBusy else { return }
        // Edit & Resend: the conversation goes back to just before the edited message.
        if let id = editingID, let i = conversation.index(of: id) { conversation.messages.removeSubrange(i...) }
        editingID = nil
        composer.text = ""
        composer.attachments = []
        attachmentsBeforeEdit = []
        wasTyping = false
        saveDraft()
        isPinned = true
        ChatDefaults.remember(conversation)
        engine.send(text, attachments: attachments, in: conversation)
        refresh()
    }

    /// Retry keeps the answer it replaces: the new one gets the old ones as its other versions
    /// (`Engine.retry` does that).
    private func retry() {
        guard let old = conversation.messages.last, !old.isUser, !engine.isBusy else { return }
        isPinned = true
        engine.retry(in: conversation)
        refresh()
    }

    /// Answers the last question again with `other`, keeping both answers as a pair to compare.
    private func compare(with other: ModelChoice, thinking: Thinking) {
        guard let old = conversation.messages.last, !old.isUser, !engine.isBusy else { return }
        isPinned = true
        engine.compare(in: conversation, with: other, thinking: thinking)
        refresh()
    }

    /// The two answers side by side, with how each was made. Presented by `ChatScreen` in
    /// SwiftUI, so the sheet goes away with this chat when another one is selected or opened.
    func showComparison(_ id: UUID) { onShowComparison?(id) }

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

    private func setMode(_ mode: Mode) {
        guard live == nil else { return }
        conversation.mode = mode
        ChatDefaults.remember(conversation)
        engine.prepare(conversation)
        refresh()
    }

    private func updateModeButton() {
        let mode = conversation.answeringMode
        let title = conversation.modelTitle
        composer.setMode(title: title, symbol: mode.symbol)
        composer.modeButton.accessibilityLabel = "Model"
        var value = "\(title), on \(mode == .mac ? (Device.isMac ? engine.mac.computerName : "your Mac") : "this \(Device.name)")"
        if conversation.thinking != .off { value += ", thinks first" }
        if conversation.webSearch, WebSearcher.hasKey { value += ", searches the web" }
        composer.modeButton.accessibilityValue = value
        composer.modeButton.isEnabled = live == nil
        composer.syncModeIcon()
    }

    // MARK: - Model picker

    /// The two models, as the picker's rows (on a Mac, only the Mac's). `current`: which one is
    /// checked, if any.
    private func modelRows(current: Mode?) -> [ModelPicker.Row] {
        if Device.isMac { return [macRow(current: current)] }
        let store = engine.store
        let deviceNote: String = if store.isReady {
            "On this \(Device.name)"
        } else if case .downloading(let p) = store.state {
            "Downloading · \(Int(p * 100))%"
        } else {
            "Not downloaded yet"
        }
        let device = ModelPicker.Row(choice: .device, title: store.model.name, symbol: Mode.device.symbol, note: deviceNote,
                                     enabled: true, current: current == .device)
        return [device, macRow(current: current)]
    }

    /// The Mac's model. An unpaired Mac is never the selected model: its row leads to where it's
    /// paired (on a Mac that serves, it's on its way).
    private func macRow(current: Mode?) -> ModelPicker.Row {
        let choice = ModelChoice(mode: .mac, macModel: nil)
        guard MacLink.isConfigured else {
            #if targetEnvironment(macCatalyst)
            if MacRole.current == .serve {
                return ModelPicker.Row(choice: choice, title: "Inkling", symbol: "desktopcomputer",
                                       note: "Starting on this Mac", enabled: false, current: false)
            }
            #endif
            return ModelPicker.Row(choice: choice, title: Device.isMac ? "Inkling" : "Mac", symbol: "desktopcomputer",
                                   note: "Pair in Settings", enabled: true, current: false, opens: true)
        }
        let model = conversation.resolvedMacModel
        let reachable = engine.mac.route != .unreachable
        let place = MacLink.lanHost.hasPrefix("127.0.0.1") ? "On this Mac" : "On \(engine.mac.computerName)"
        return ModelPicker.Row(
            choice: choice, title: model.isEmpty ? "Mac" : MacLink.displayName(model),
            symbol: "desktopcomputer", note: place + (reachable ? "" : " · Not reachable"),
            enabled: true, current: current == .mac)
    }

    /// The model button's picker (`ModelPicker`). On iPhone the keyboard goes down while it's up,
    /// or it would sit over the sheet, and comes back after.
    private func showModelPicker(from source: UIView) {
        guard live == nil, presentedViewController == nil else { return }
        let compact = traitCollection.horizontalSizeClass == .compact
        let refocus = compact && composer.textView.isFirstResponder
        if refocus { composer.textView.resignFirstResponder() }

        weak var host: UIViewController?
        let close: (@escaping () -> Void) -> Void = { then in
            guard let host else { return then() }
            host.dismiss(animated: true, completion: then)
        }
        let thinking = Binding(
            get: { [unowned self] in conversation.thinking != .off },
            set: { [unowned self] on in
                conversation.thinking = on ? .high : .off
                ChatDefaults.remember(conversation)
                refresh()
            })
        let search = Binding(
            get: { [unowned self] in conversation.webSearch },
            set: { [unowned self] on in
                conversation.webSearch = on
                ChatDefaults.remember(conversation)
                engine.prepare(conversation)  // the system turn changed: read it while the question is typed
                refresh()
            })
        let openSettings = { [unowned self] in close { self.onOpenSettings?() } }
        let picker = ModelPicker(
            rows: { [unowned self] _ in modelRows(current: conversation.answeringMode) },
            thinking: thinking,
            search: search,
            setUpSearch: openSettings,
            select: { [unowned self] choice in
                // An unpaired Mac can't answer: its row leads to where it's paired.
                if choice.mode == .mac, !MacLink.isConfigured { return openSettings() }
                setMode(choice.mode)
                close {}
            },
            close: { close {} })
        let controller = PickerHost(rootView: AnyView(picker.environment(engine).environment(engine.store).environment(engine.mac)))
        controller.onClose = { [weak self] in if refocus { self?.composer.textView.becomeFirstResponder() } }
        host = controller
        presentPicker(controller, from: source)
    }

    /// A sheet on iPhone (half height, pulls up to full), a popover from `source` on iPad. Opaque:
    /// as glass over a dark transcript the grouped list turned a muddy grey.
    private func presentPicker(_ controller: UIViewController, from source: UIView, rect: CGRect? = nil) {
        controller.view.backgroundColor = .systemGroupedBackground
        controller.modalPresentationStyle = .popover
        // The Mac lists one model, so less height.
        controller.preferredContentSize = CGSize(width: 360, height: Device.isMac ? 400 : 520)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = rect ?? source.bounds
            popover.permittedArrowDirections = [.down, .up]
            let sheet = popover.adaptiveSheetPresentationController
            // Tall enough for both models and both switches without scrolling at the default text size.
            sheet.detents = [.custom { context in min(540, context.maximumDetentValue) }, .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(controller, animated: true)
    }

    /// Compare With: the picker for the second answer to `id`, the last reply. Its own model is
    /// offered only with the thinking switched the other way.
    private func showComparePicker(for id: UUID) {
        guard let m = message(id), presentedViewController == nil else { return }
        let ownTitle = m.metrics?.modelTitle ?? conversation.modelTitle
        let thought = m.metrics?.thinking ?? (conversation.thinking != .off)
        weak var host: UIViewController?
        let picker = ComparePicker(
            answerThought: thought,
            rows: { [unowned self] thinking in
                modelRows(current: nil).map { row in
                    var row = row
                    let available = row.choice.mode == .mac ? MacLink.isConfigured : engine.store.isReady
                    if available, row.title == ownTitle {
                        row.enabled = thinking != thought
                        row.note = row.enabled ? "This answer's model, thinking \(thinking ? "on" : "off")"
                            : "This answer's model: switch thinking to compare"
                    } else {
                        row.enabled = available
                    }
                    return row
                }
            },
            select: { [unowned self] choice, thinking in
                host?.dismiss(animated: true)
                compare(with: choice, thinking: thinking ? .high : .off)
            },
            close: { host?.dismiss(animated: true) })
        let controller = PickerHost(rootView: AnyView(picker.environment(engine).environment(engine.store).environment(engine.mac)))
        host = controller
        // From the answer's bubble on iPad.
        let cell = dataSource.indexPath(for: id).flatMap { collectionView.cellForItem(at: $0) }
        presentPicker(controller, from: cell ?? composer.modeButton)
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

    /// Whether there's anything to get ready before Send. `Engine.prepare` is cheap when there isn't.
    private var needsWarmUp: Bool { !engine.isBusy }

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

    /// Copy, Share, Retry and Compare With. For the context menu and the More button.
    private func answerMenuItems(_ id: UUID) -> [UIMenuElement] {
        guard let m = message(id), !m.isUser, live?.id != id else { return [] }
        var items: [UIMenuElement] = []
        if !m.content.isEmpty {
            items.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = m.content
                },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [unowned self] _ in
                    share(m.content, from: id)
                },
            ]))
        }
        if m.comparison != nil {
            items.append(UIAction(title: "Compare Answers", image: UIImage(systemName: "rectangle.split.2x1")) {
                [unowned self] _ in showComparison(id)
            })
        }
        if isLast(id), !engine.isBusy {
            var retries: [UIMenuElement] = [
                UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise")) { [unowned self] _ in retry() },
            ]
            // A second answer, from the other model or the same one with thinking the other way,
            // kept beside this one (see CompareView). In a sheet: a menu has no room for the switch.
            if m.finished, m.error == nil, !m.content.isEmpty {
                retries.append(UIAction(title: "Compare With…", image: UIImage(systemName: "rectangle.split.2x1")) {
                    [unowned self] _ in showComparePicker(for: id)
                })
            }
            items.append(UIMenu(options: .displayInline, children: retries))
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

    /// Retry, plus a way to fix the cause: the download for a missing model, a fresh look for the Mac.
    private func errorActions(for m: StoredMessage) -> [UIAction] {
        guard m.error != nil, !m.isUser else { return [] }
        var actions: [UIAction] = []
        if isLast(m.id) {
            actions.append(UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise"),
                                    attributes: engine.isBusy ? .disabled : []) { [unowned self] _ in
                retry()
            })
        }
        // Replies saved before errors had a kind fall back to the mode.
        let kind = m.errorKind ?? (conversation.answeringMode == .mac ? .macUnreachable : .other)
        switch kind {
        case .notDownloaded:
            if let open = onGetModel {
                actions.append(UIAction(title: "Download \(engine.store.best.name)", image: UIImage(systemName: "arrow.down.circle")) { _ in open() })
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
        var commands = [
            UIKeyCommand(title: "Send", action: #selector(sendKey), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: "Stop", action: #selector(stopKey), input: UIKeyCommand.inputEscape),
            UIKeyCommand(title: "Stop", action: #selector(stopKey), input: ".", modifierFlags: .command),
        ]
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
}

// MARK: - Attachments

extension ChatViewController: UIDocumentPickerDelegate, PHPickerViewControllerDelegate, UIDropInteractionDelegate {
    /// Choose File, Choose Photo. Photo is off until the model's image support has downloaded.
    fileprivate func updateAttachMenu() {
        let seesImages = engine.canSeeImages(conversation.answeringMode)
        composer.attachButton.menu = UIMenu(children: [
            UIAction(title: "Choose File…", subtitle: "Text or PDF", image: UIImage(systemName: "doc")) { [unowned self] _ in
                chooseFile()
            },
            UIAction(title: "Choose Photo…", subtitle: seesImages ? nil : Self.noImages, image: UIImage(systemName: "photo"),
                     attributes: seesImages ? [] : .disabled) { [unowned self] _ in choosePhoto() },
        ])
        composer.attachButton.isEnabled = live == nil
    }

    private static let noImages = "Image support is still downloading"

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
        let mode = conversation.answeringMode
        let seen = engine.canSeeImages(mode) ? new : new.filter { !$0.isImage }
        if seen.count < new.count { showProblem("\(Self.noImages). Photos can be attached once it's here.") }
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
        // Not behind a sheet (Settings), whose keyboard-covered content would be hidden.
        if traitCollection.userInterfaceIdiom != .phone, view.window?.rootViewController?.presentedViewController == nil {
            composer.textView.becomeFirstResponder()
        }
    }

    fileprivate func showProblem(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
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

/// The chat screen as SwiftUI sees it. `revision` changes whenever something the UIKit side shows
/// (other than streaming text) changes, which is what makes SwiftUI call `refresh()`. Around the
/// UIKit controller: the editable title, and a banner when this chat can't answer yet (another
/// chat is answering, or this device's model isn't here).
struct ChatScreen: View {
    @Bindable var conversation: Conversation
    @Environment(Engine.self) private var engine
    @Environment(\.showModel) private var showModel
    @Environment(\.showSettings) private var showSettings
    @Environment(\.openChat) private var openChat
    @State private var comparing: ComparisonRequest?

    /// The reply `CompareView` shows.
    struct ComparisonRequest: Identifiable {
        let reply: UUID
        var id: UUID { reply }
    }

    var body: some View {
        ChatControllerView(conversation: conversation, engine: engine, revision: revision, showModel: showModel,
                           showSettings: showSettings, openChat: openChat,
                           showComparison: { comparing = ComparisonRequest(reply: $0) })
            .ignoresSafeArea(.keyboard)  // the UIKit side follows the keyboard itself
            .safeAreaInset(edge: .top, spacing: 0) { ChatBanner(conversation: conversation) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { RenameButton() }
            // Here rather than presented from UIKit: the screen is rebuilt per chat (`.id`), so the
            // sheet can't outlive it and act on the chat it came from.
            .sheet(item: $comparing) { request in
                CompareView(conversation: conversation, replyID: request.reply)
                    .presentationDetents([.large])
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
        h.combine(conversation.webSearch)
        h.combine(conversation.macModel)
        h.combine(engine.running)
        h.combine(engine.live?.id)
        h.combine(engine.isBusy)
        h.combine(engine.store.isReady)
        h.combine(engine.store.model)
        h.combine(MacLink.isConfigured)
        h.combine(engine.store.hasProjector)
        h.combine(engine.mac.route)
        return h.finalize()
    }
}

/// Above the transcript, when this chat can't answer yet: another chat is answering (with a way to
/// stop it), or this device's model isn't downloaded (with its progress, or a way to get it).
private struct ChatBanner: View {
    let conversation: Conversation
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.showModel) private var showModel
    @Environment(\.showMacSettings) private var showMacSettings
    @Environment(\.showSettings) private var showSettings

    var body: some View {
        if let busy {
            row {
                ProgressView().controlSize(.small)
                Text(busy).lineLimit(2)
                Spacer(minLength: 8)
                Button("Stop") { engine.stop() }.buttonStyle(.bordered).controlSize(.small)
            }
        } else if let mac = macProblem {
            Button { mac.action?() } label: {
                row {
                    if mac.action == nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "desktopcomputer").foregroundStyle(.tint)
                    }
                    Text(mac.text)
                    Spacer(minLength: 8)
                    if mac.action != nil {
                        Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(mac.action == nil)
        } else if conversation.answeringMode.isOnDevice, !store.isReady {
            Button { showModel() } label: {
                row {
                    if case .downloading(let p) = store.state {
                        ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                        Text("Downloading \(store.best.name) · \(Int(p * 100))%").monospacedDigit()
                    } else {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
                        Text("Download \(store.best.name) to chat on this \(Device.name)")
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
    }

    /// Why the Mac can't answer yet, and the way on: Splash starting or failed there (the bridge's
    /// 503), and on a Mac, no Mac to reach yet (pairing, or Login Items for a Mac that serves).
    private var macProblem: (text: String, action: (() -> Void)?)? {
        if conversation.answeringMode == .mac, MacLink.isConfigured, let why = engine.mac.notServing {
            #if targetEnvironment(macCatalyst)
            let here = MacRole.current == .serve
            #else
            let here = false
            #endif
            if MacError.isStarting(why) { return (here ? "Starting Inkling on this Mac…" : "The Mac is starting Inkling…", nil) }
            return ("Inkling isn't running\(here ? "" : " on the Mac"): \(why)",
                    here ? { showSettings() } : { Task { await engine.mac.resolve() } })
        }
        #if targetEnvironment(macCatalyst)
        _ = engine.mac.route  // observed: it changes once this Mac's own bridge is connected
        guard !MacLink.isConfigured else { return nil }
        switch MacRole.current {
        case .client:
            return ("Pair with a Mac to chat with Inkling", { showMacSettings() })
        case .serve:
            switch MacServer.shared.state {
            case .needsApproval:
                return ("Turn Lantern on in Login Items to serve Inkling", { MacServer.shared.openLoginItems() })
            case .failed(let message):
                return (message, { showSettings() })
            default:
                return ("Starting Inkling on this Mac…", nil)
            }
        case nil:
            return nil
        }
        #else
        return nil
        #endif
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .font(.footnote)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(.bar)
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
    }

    private var busy: String? {
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
    let showModel: OpenSheetAction
    let showSettings: OpenSheetAction
    let openChat: OpenChatAction
    let showComparison: (UUID) -> Void

    func makeUIViewController(context: Context) -> ChatViewController {
        let controller = ChatViewController(conversation: conversation, engine: engine)
        controller.onGetModel = { showModel() }
        controller.onOpenSettings = { showSettings() }
        controller.onOpenChat = { openChat($0) }
        controller.onShowComparison = { showComparison($0) }
        controller.onBeginTyping = { [conversation, engine] in engine.prepare(conversation) }
        return controller
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {
        controller.refresh()
    }
}

/// The model picker's controller: says when it's gone, whichever way it went (Done, a pick, or a
/// swipe down).
private final class PickerHost: UIHostingController<AnyView> {
    var onClose: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose?()
        onClose = nil
    }
}
