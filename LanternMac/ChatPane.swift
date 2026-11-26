import LlamaKit
import SwiftUI
import UniformTypeIdentifiers

/// One chat: its messages, the reply being written, and the message box. The live reply is read
/// a few times a second (`TimelineView` at 15 Hz while this chat answers), never per token; the
/// store is written when a turn starts and ends, as on the iPhone.
struct ChatPane: View {
    @Bindable var conversation: Conversation
    let openChat: (Conversation) -> Void

    @Environment(Engine.self) private var engine
    @Environment(\.openSettings) private var openSettings
    @AppStorage(DefaultMode.key) private var lastMode = ""
    @AppStorage(ReplyDetails.key) private var showDetails = true

    @State private var draft = ""
    @State private var attachments: [Attachment] = []
    @State private var attachProblem: String?
    @State private var editingID: UUID?
    @State private var draftBeforeEdit = ""
    @State private var expanded: Set<UUID> = []
    /// Following the bottom: true until the user scrolls up, again when they're back down.
    @State private var following = true
    @State private var clock = ClockBox()
    @State private var importing = false
    @State private var dropTargeted = false
    @FocusState private var composerFocused: Bool

    /// The reply being written, if it belongs to this chat.
    private var live: LiveReply? {
        guard let live = engine.live, engine.running == conversation.persistentModelID else { return nil }
        return live
    }

    var body: some View {
        Group {
            if conversation.messages.isEmpty {
                EmptyChat(conversation: conversation) { prompt in
                    draft = prompt
                    composerFocused = true
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            } else {
                transcript
            }
        }
        .background(.background)
        .modifier(ChatTitle(conversation: conversation))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: ChatExport(conversation), preview: SharePreview(conversation.title)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(conversation.messages.isEmpty)
                .help("Share this chat as Markdown")
            }
        }
        .onAppear {
            draft = conversation.draft
            engine.prepare(mode: conversation.mode, for: conversation)
            composerFocused = true
        }
        .onDisappear(perform: saveDraft)
        .onChange(of: conversation.mode) { _, mode in
            lastMode = mode.rawValue
            engine.prepare(mode: mode, for: conversation)
        }
        .onChange(of: draft) { old, new in
            // Typing starts: get the model (or the Mac's) ready, so Send doesn't wait.
            if old.isEmpty, !new.isEmpty { engine.prepare(mode: conversation.mode, for: conversation) }
        }
        .onChange(of: engine.running) { _, running in
            if running == nil { clock.replyEnded(in: conversation) }
        }
        .focusedSceneValue(\.chatActions, ChatActions(
            setMode: { setMode($0) },
            toggleThinking: { conversation.thinking = conversation.thinking == .off ? .high : .off },
            thinking: conversation.thinking != .off,
            attach: { importing = true }))
        .fileImporter(isPresented: $importing, allowedContentTypes: AttachmentReader.types, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            receive(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(conversation.messages) { m in
                    if m.isUser {
                        UserMessage(message: m, editing: editingID == m.id)
                            .contextMenu { userMenu(m) }
                    } else if live?.id == m.id, let live {
                        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
                            answer(m, live: live, now: context.date)
                        }
                    } else {
                        answer(m, live: nil, now: .now)
                    }
                }
            }
            .frame(maxWidth: Self.column)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .modifier(SoftBottomEdge())
        // While following, a growing answer keeps the bottom in view; scrolled up, nothing moves.
        // A short chat starts at the top; a long one opens at its end.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(following ? .bottom : nil, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
        } action: { _, atBottom in
            following = atBottom
        }
    }

    private func answer(_ m: StoredMessage, live: LiveReply?, now: Date) -> some View {
        var status: ReplyStatus?
        if let live {
            clock.clock.observe(live, now: now)
            status = clock.clock.status(for: live, modelName: modelName(for: live.mode), now: now)
        }
        return AnswerMessage(
            message: m, live: live, liveText: live?.text, liveThinking: live?.thinking, liveSearches: live?.searches,
            status: status, expanded: expanded.contains(m.id), showDetails: showDetails,
            isSpeaking: Speaker.shared.speaking == m.id,
            toggleThinking: { if expanded.remove(m.id) == nil { expanded.insert(m.id) } },
            switchVersion: { switchVersion(m.id, by: $0) },
            retry: conversation.messages.last?.id == m.id && !engine.isBusy && m.error == nil ? { retry(conversation.mode) } : nil,
            errorActions: { errorActions(m) },
            menu: { answerMenu(m) })
    }

    private func modelName(for mode: Mode) -> String? {
        mode == .mac ? conversation.modelTitle : mode == .apple ? mode.title : engine.model(for: mode)?.name
    }

    /// Another chat (or a model test) holds the one engine.
    private var busyNote: String? {
        if let model = engine.testing { return "Testing \(model.name). Chats can send when it's done." }
        guard let running = engine.running, running != conversation.persistentModelID else { return nil }
        return "Another chat is answering. This one can send when it's done."
    }

    // MARK: - Message box

    /// Width of the transcript and the message box: a comfortable line length for reading.
    static let column: CGFloat = 720

    /// What sits under the transcript: a note when another chat holds the engine, then the box.
    private var bottomBar: some View {
        VStack(spacing: 6) {
            if let note = busyNote {
                Label(note, systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            composer
        }
        .frame(maxWidth: Self.column)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }

    /// The message box: attachments, the text (Return sends, Shift-Return for a new line), then a
    /// row of controls: attach, the model, Think First, and Send or Stop.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingID != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil")
                    Text("Editing a message. Sending replaces it and everything after it.")
                    Spacer()
                    Button("Cancel", action: cancelEditing).buttonStyle(.link).keyboardShortcut(.cancelAction)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { a in
                            AttachmentChipView(attachment: a) { attachments.removeAll { $0.id == a.id } }
                        }
                    }
                }
            }
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: PlatformFont.lanternBodySize))
                .lineLimit(1...12)
                .focused($composerFocused)
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .onKeyPress(.return, phases: .down) { press in
                    // Return sends; Shift- or Option-Return is a new line.
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                    send()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard editingID != nil else { return .ignored }
                    cancelEditing()
                    return .handled
                }
                .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in receive(providers) }
            if let attachProblem {
                Label(attachProblem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ComposerButton(title: "Attach", symbol: "paperclip", help: "Attach a file or picture (⌘O)") { importing = true }
                modelMenu
                if conversation.mode != .apple {
                    ComposerButton(title: "Think First", symbol: "lightbulb", on: conversation.thinking != .off,
                                   help: conversation.thinking != .off ? "Thinks before answering (⇧⌘T)" : "Answer straight away (⇧⌘T)") {
                        conversation.thinking = conversation.thinking == .off ? .high : .off
                    }
                    .disabled(live != nil)
                }
                Spacer()
                if live != nil {
                    SendButton(symbol: "stop.fill", enabled: true, help: "Stop (⌘.)") { engine.stop() }
                } else {
                    SendButton(symbol: editingID == nil ? "arrow.up" : "checkmark", enabled: canSend,
                               help: editingID == nil ? "Send (Return)" : "Send the edited message (Return)", action: send)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.background, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(composerFocused ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor),
                              lineWidth: composerFocused ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
        .animation(.easeOut(duration: 0.15), value: composerFocused)
        .contentShape(.rect)
        .onTapGesture { composerFocused = true }
    }

    private var placeholder: String {
        conversation.messages.isEmpty ? "Ask \(conversation.modelTitle)" : "Reply to \(conversation.modelTitle)"
    }

    private var canSend: Bool {
        !engine.isBusy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    // MARK: - Model menu

    private var modelMenu: some View {
        Menu {
            let macModels = engine.mac.models
            Section("On This Mac") {
                if macModels.isEmpty {
                    Text(engine.mac.route.host == nil ? "Looking for Ollama or LM Studio…" : "No models: add one in Ollama or LM Studio")
                } else {
                    ForEach(macModels, id: \.self) { name in
                        Toggle(MacLink.displayName(name), isOn: Binding(
                            get: { conversation.mode == .mac && conversation.resolvedMacModel == name },
                            set: { _ in setMode(.mac, macModel: name) }))
                    }
                }
            }
            Section("Lantern's Models") {
                ForEach([Mode.fast, .smart, .qwen], id: \.self) { mode in
                    Toggle(isOn: Binding(get: { conversation.mode == mode }, set: { _ in setMode(mode) })) {
                        Text(mode.title)
                        if !isAvailable(mode) { Text("Download in Settings › Models") }
                    }
                    .disabled(!isAvailable(mode))
                }
                Toggle(isOn: Binding(get: { conversation.mode == .apple }, set: { _ in setMode(.apple) })) {
                    Text(Mode.apple.title)
                    if !isAvailable(.apple) { Text(engine.apple.status.short) }
                }
                .disabled(!isAvailable(.apple))
            }
            Divider()
            Toggle("Think First", isOn: Binding(
                get: { conversation.thinking != .off },
                set: { conversation.thinking = $0 ? .high : .off }))
            .disabled(conversation.mode == .apple)
            Divider()
            Button("Manage Models…") { openSettings() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: conversation.mode.symbol)
                Text(conversation.modelTitle)
            }
            .font(.callout)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.horizontal, 6)
        .foregroundStyle(.secondary)
        .disabled(live != nil)
        .help("Which model answers (⌘1–5)")
    }

    private func isAvailable(_ mode: Mode) -> Bool {
        if mode == .mac { return true }
        if mode == .apple { return engine.apple.status.isAvailable }
        return engine.model(for: mode).map { engine.store.states[$0.id] == .ready } ?? false
    }

    /// `macModel`: for `.mac`, which of the Mac's models; it's also the one new chats start with.
    private func setMode(_ mode: Mode, macModel: String? = nil) {
        guard live == nil, isAvailable(mode) else { return }
        conversation.mode = mode
        if let macModel {
            conversation.macModel = macModel
            UserDefaults.standard.set(macModel, forKey: MacLink.modelKey)
        } else if mode == .mac, conversation.macModel.isEmpty, let first = engine.mac.models.first {
            conversation.macModel = first
        }
    }

    // MARK: - Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        // Edit & Resend: the chat goes back to just before the edited message.
        if let id = editingID, let i = conversation.index(of: id) {
            Speaker.shared.stop()
            conversation.messages.removeSubrange(i...)
        }
        let files = attachments
        editingID = nil
        draft = ""
        attachments = []
        attachProblem = nil
        following = true
        conversation.draft = ""
        engine.send(text, attachments: files, in: conversation)
    }

    private func saveDraft() {
        let text = editingID == nil ? draft : draftBeforeEdit
        guard conversation.modelContext != nil, !conversation.isDeleted, conversation.draft != text else { return }
        conversation.draft = text
    }

    private func retry(_ mode: Mode, macModel: String? = nil) {
        guard let old = conversation.messages.last, !old.isUser, !engine.isBusy else { return }
        if Speaker.shared.speaking == old.id { Speaker.shared.stop() }
        following = true
        engine.retry(in: conversation, mode: mode, macModel: macModel)
    }

    private func switchVersion(_ id: UUID, by delta: Int) {
        guard live?.id != id, let i = conversation.index(of: id) else { return }
        let current = conversation.messages[i].allVersions.current
        conversation.messages[i].showVersion(current + delta)
        try? conversation.modelContext?.save()
    }

    private func beginEditing(_ m: StoredMessage) {
        guard m.isUser, !engine.isBusy else { return }
        if editingID == nil { draftBeforeEdit = draft }
        editingID = m.id
        draft = m.content
        attachments = m.attachments ?? []
        composerFocused = true
    }

    private func cancelEditing() {
        editingID = nil
        draft = draftBeforeEdit
        attachments = []
    }

    // MARK: - Menus

    @ViewBuilder
    private func userMenu(_ m: StoredMessage) -> some View {
        Button("Copy") { copy(m.content) }
        Button("Edit & Resend") { beginEditing(m) }.disabled(engine.isBusy)
    }

    @ViewBuilder
    private func answerMenu(_ m: StoredMessage) -> some View {
        if !m.content.isEmpty {
            Button("Copy", systemImage: "doc.on.doc") { copy(m.content) }
            if Speaker.shared.speaking == m.id {
                Button("Stop Reading", systemImage: "stop.circle") { Speaker.shared.stop() }
            } else {
                Button("Read Aloud", systemImage: "speaker.wave.2") { Speaker.shared.speak(m.content, id: m.id) }
            }
        }
        if conversation.messages.last?.id == m.id, !engine.isBusy {
            Divider()
            Button("Retry", systemImage: "arrow.clockwise") { retry(conversation.mode) }
                .disabled(!isAvailable(conversation.mode))
            Menu("Retry With", systemImage: "arrow.triangle.branch") {
                ForEach(engine.mac.models.filter { conversation.mode != .mac || $0 != conversation.resolvedMacModel }, id: \.self) { name in
                    Button(MacLink.displayName(name)) { retry(.mac, macModel: name) }
                }
                Divider()
                ForEach([Mode.fast, .smart, .qwen, .apple].filter { $0 != conversation.mode }, id: \.self) { mode in
                    Button(mode.title) { retry(mode) }.disabled(!isAvailable(mode))
                }
            }
        }
    }

    /// Retry, plus a way to fix the cause: the models for a missing one, a fresh look for the Mac.
    @ViewBuilder
    private func errorActions(_ m: StoredMessage) -> some View {
        let last = conversation.messages.last?.id == m.id
        if last {
            Button("Retry", systemImage: "arrow.clockwise") { retry(conversation.mode) }.disabled(engine.isBusy)
        }
        switch m.errorKind ?? (conversation.mode == .mac ? .macUnreachable : .other) {
        case .notDownloaded:
            Button("Open Models", systemImage: "arrow.down.circle") { openSettings() }
        case .macUnreachable, .macNoModel, .macFailed:
            Button("Look Again", systemImage: "arrow.triangle.2.circlepath") { Task { await engine.mac.resolve() } }
        case .contextFull where last:
            Button("Drop Oldest Messages and Continue", systemImage: "scissors") { engine.continueTrimmed(in: conversation) }
                .disabled(engine.isBusy)
            Button("Continue in New Chat", systemImage: "square.and.pencil") { openChat(engine.continueInNewChat(from: conversation)) }
        default:
            EmptyView()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Attachments

    private func add(_ urls: [URL]) {
        Task {
            var problems: [String] = []
            for url in urls {
                do {
                    let a = try await Task.detached { try AttachmentReader.read(url) }.value
                    if a.isImage, !engine.canSeeImages(conversation.mode) {
                        problems.append("\(conversation.modelTitle) can't see pictures.")
                    }
                    attachments.append(a)
                } catch {
                    problems.append(error.localizedDescription)
                }
            }
            attachProblem = problems.first
        }
    }

    /// Files and pictures dropped or pasted.
    private func receive(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in add([url]) } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    let a = AttachmentReader.attachment(image, name: "Pasted Image.jpg")
                    Task { @MainActor in if let a { attachments.append(a) } }
                }
            }
        }
    }
}

/// Holds the reply clock outside SwiftUI's state: it's updated as the live reply is drawn.
@MainActor
final class ClockBox {
    var clock = PhaseClock()

    /// Keeps how long the reply thought, once it's over.
    func replyEnded(in conversation: Conversation) {
        guard let id = clock.replyID, let seconds = clock.thoughtSeconds(), let i = conversation.index(of: id),
              !conversation.messages[i].thinking.isEmpty, conversation.messages[i].thoughtSeconds == nil else { return }
        conversation.messages[i].thoughtSeconds = seconds
        try? conversation.modelContext?.save()
    }
}

/// The window title: the chat's name, editable in place once it has one; "New Chat" before.
private struct ChatTitle: ViewModifier {
    @Bindable var conversation: Conversation

    func body(content: Content) -> some View {
        if conversation.messages.isEmpty {
            content.navigationTitle("New Chat")
        } else {
            content.navigationTitle($conversation.title)
        }
    }
}

/// The transcript fades under the message box rather than ending at a hard line (macOS 26+).
private struct SoftBottomEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
    }
}

/// An icon button in the message box's control row: tinted while on (Think First).
private struct ComposerButton: View {
    let title: String
    let symbol: String
    var on = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityValue(on ? "On" : "")
    }
}

/// Send (or Stop): a filled circle in the accent colour, grey while there's nothing to send.
private struct SendButton: View {
    let symbol: String
    let enabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? Color.white : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 26, height: 26)
                .background(enabled ? Color.accentColor : Color(nsColor: .tertiarySystemFill), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
