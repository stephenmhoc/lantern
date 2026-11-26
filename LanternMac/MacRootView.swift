import SwiftData
import SwiftUI

/// One Lantern window: the chats in a sidebar (pinned, then by day; search across every message)
/// and the open chat. A window opened for a chat ("Open in New Window") starts on it; a plain one
/// on a new chat. Every window shares the app's one `Engine`, so one reply runs at a time.
struct MacRootView: View {
    let opened: PersistentIdentifier?

    @Environment(Engine.self) private var engine
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \Conversation.lastActive, order: .reverse) private var conversations: [Conversation]
    @AppStorage(DefaultMode.key) private var lastMode = ""
    @SceneStorage("selection") private var storedSelection: String?

    @State private var selection: Conversation?
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var results: [ChatSearch.Result] = []
    @State private var renaming: Conversation?
    @State private var renameText = ""

    /// The chats the sidebar lists: an empty chat is just the new-chat page, not history.
    private var history: [Conversation] { conversations.filter { !$0.messages.isEmpty || $0.pinned } }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            if let selection, selection.modelContext != nil, !selection.isDeleted {
                ChatPane(conversation: selection, openChat: { self.selection = $0 })
                    .id(selection.persistentModelID)
            } else {
                Color.clear
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Chats")
        .searchScopes($scope) {
            ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .task(id: searchKey) { await search() }
        .onAppear(perform: restoreSelection)
        #if DEBUG
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            if ProcessInfo.processInfo.arguments.contains("-settings") { openSettings() }
            if let c = selection { await DebugAsk.run(in: c, engine: engine) }
        }
        #endif
        .onChange(of: selection) { _, c in storedSelection = c?.persistentModelID.stored }
        .onChange(of: engine.mac.route.host) { _, host in
            // This Mac's models answer once the bridge is connected, a moment after launch: a new
            // chat that started on something else for want of them moves over, unless the user
            // chose otherwise last time.
            guard host != nil, let c = selection, c.messages.isEmpty, c.mode != .mac,
                  lastMode.isEmpty || lastMode == Mode.mac.rawValue else { return }
            c.mode = .mac
        }
        .onChange(of: conversations) {
            // Deleted in another window: don't keep showing a chat that's gone.
            if let s = selection, s.isDeleted || s.modelContext == nil || !conversations.contains(s) { newChat(excluding: s) }
        }
        .focusedSceneValue(\.macActions, MacActions(
            newChat: { newChat() },
            deleteChat: selection.flatMap { c in c.messages.isEmpty ? nil : { delete(c) } },
            renameChat: selection.flatMap { c in c.messages.isEmpty ? nil : { startRename(c) } }))
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if trimmedQuery.isEmpty {
                ForEach(ChatSection.group(history)) { section in
                    Section(section.title) {
                        ForEach(section.chats) { c in
                            row(c).tag(c)
                        }
                    }
                }
            } else {
                let byID = Dictionary(conversations.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
                ForEach(results) { r in
                    if let c = byID[r.id] {
                        SearchResultRow(result: r)
                            .padding(.vertical, 2)
                            .tag(c)
                            .contextMenu { menu(for: c) }
                    }
                }
                if results.isEmpty {
                    Text("No Results").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if history.isEmpty, trimmedQuery.isEmpty {
                Text("Your chats show up here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .toolbar {
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") { newChat() }
                    .help("New Chat (⌘N)")
            }
        }
        .onDeleteCommand { if let c = selection, !c.messages.isEmpty { delete(c) } }
    }

    private func row(_ c: Conversation) -> some View {
        ChatRow(conversation: c, answering: engine.running == c.persistentModelID)
            .padding(.vertical, 3)
            .contextMenu { menu(for: c) }
    }

    @ViewBuilder
    private func menu(for c: Conversation) -> some View {
        Button("Open in New Window") { openWindow(id: LanternMacApp.mainWindow, value: c.persistentModelID) }
        Divider()
        Button(c.pinned ? "Unpin" : "Pin") { withAnimation { c.pinned.toggle() } }
        Button("Rename…") { startRename(c) }
        Button("Export as Markdown…") { MarkdownExport.save(c) }
        Divider()
        Button("Delete", role: .destructive) { delete(c) }
    }

    // MARK: - Search

    private var searchKey: String { "\(trimmedQuery)|\(scope.rawValue)|\(conversations.count)" }

    private func search() async {
        let q = trimmedQuery
        guard !q.isEmpty else { results = []; return }
        try? await Task.sleep(for: .milliseconds(150))  // typing on cancels this one
        guard !Task.isCancelled else { return }
        let found = await ChatSearch.search(ChatSearch.documents(history), query: q, scope: scope)
        if !Task.isCancelled { results = found }
    }

    // MARK: - Chats

    private func restoreSelection() {
        guard selection == nil else { return }
        let id = opened ?? PersistentIdentifier(stored: storedSelection)
        if let id, let c = conversations.first(where: { $0.persistentModelID == id }) {
            selection = c
        } else {
            newChat()
        }
    }

    @discardableResult
    private func newChat(mode: Mode? = nil, excluding: Conversation? = nil) -> Conversation {
        let mode = mode ?? DefaultMode.pick(last: lastMode, engine: engine)
        query = ""
        // Reuse an empty chat rather than stacking up empty ones.
        if let empty = conversations.first(where: {
            $0.messages.isEmpty && !$0.pinned && $0 != excluding && !$0.isDeleted && $0.modelContext != nil
        }) {
            empty.mode = mode
            empty.lastActive = .now
            selection = empty
            return empty
        }
        let c = Conversation(mode: mode)
        context.insert(c)
        try? context.save()  // a permanent identifier, for @SceneStorage and Engine.running
        selection = c
        return c
    }

    private func startRename(_ c: Conversation) {
        renameText = c.title
        renaming = c
    }

    private func rename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let renaming, !title.isEmpty { renaming.title = title }
        renaming = nil
    }

    /// Immediate, with no undo, as on the iPhone. Deleting the chat on screen goes to a new chat.
    private func delete(_ c: Conversation) {
        if engine.running == c.persistentModelID { engine.stop() }
        engine.forgetState(for: c)
        let shown = selection == c
        withAnimation { context.delete(c) }
        try? context.save()
        if shown { newChat(excluding: c) }
    }
}

// MARK: - Menu bar commands

struct MacActions {
    var newChat: () -> Void
    var deleteChat: (() -> Void)?
    var renameChat: (() -> Void)?
}

extension FocusedValues {
    @Entry var macActions: MacActions?
    @Entry var chatActions: ChatActions?
}

/// What the open chat can do from the menu bar: pick a model (⌘1–5 as on the iPad), stop.
struct ChatActions {
    var setMode: (Mode) -> Void
    var toggleThinking: () -> Void
    var thinking: Bool
    var attach: () -> Void
}

struct MacCommands: Commands {
    let engine: Engine
    @FocusedValue(\.macActions) private var actions
    @FocusedValue(\.chatActions) private var chat

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { actions?.newChat() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Attach File…") { chat?.attach() }
                .keyboardShortcut("o")
                .disabled(chat == nil)
            Divider()
            Button("Rename Chat…") { actions?.renameChat?() }
                .disabled(actions?.renameChat == nil)
            Button("Delete Chat") { actions?.deleteChat?() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(actions?.deleteChat == nil)
        }
        CommandMenu("Chat") {
            ForEach(Array(Mode.allCases.enumerated()), id: \.element) { i, mode in
                Button(mode == .mac ? "This Mac's Models" : mode.title) { chat?.setMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    .disabled(chat == nil)
            }
            Divider()
            Toggle("Think First", isOn: Binding(get: { chat?.thinking ?? false }, set: { _ in chat?.toggleThinking() }))
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(chat == nil)
            Divider()
            Button("Stop") { engine.stop() }
                .keyboardShortcut(".")
                .disabled(engine.running == nil)
        }
    }
}
