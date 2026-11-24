import CoreSpotlight
import LlamaKit
import SwiftData
import SwiftUI
import UIKit

/// One window: the chats in a sidebar and the selected chat. Each window keeps its own selection
/// (restored with `@SceneStorage`); all of them share the app's one `Engine`.
struct RootView: View {
    /// The chat this window was opened for with "Open in New Window", if any.
    let opened: PersistentIdentifier?

    @Environment(\.modelContext) private var context
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Query(sort: \Conversation.lastActive, order: .reverse) private var conversations: [Conversation]
    @State private var selection: Conversation?
    @SceneStorage("selection") private var storedSelection: String?
    @State private var restored = false
    @State private var sheet: Sheet?
    @State private var settingsPath: [SettingsPage] = []
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var query = ""
    @State private var searching = false
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleted: DeletedChat?
    @AppStorage(DefaultMode.key) private var lastMode = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var window = WindowProbe()
    private let router = SystemRouter.shared

    /// Readiness lives inside Settings: showing it opens Settings with it pushed.
    enum Sheet: String, Identifiable {
        case settings
        var id: String { rawValue }
    }

    private func showSettings(readiness: Bool = false) {
        settingsPath = readiness ? [.readiness] : []
        sheet = .settings
    }

    private var sections: [ChatSection] { ChatSection.group(ChatSection.filter(conversations, query: query)) }
    private var ordered: [Conversation] { sections.flatMap(\.chats) }
    private var hasSidebarToggle: Bool { sizeClass == .regular }

    var body: some View {
        // The undo toast sits above both columns, so it shows with the sidebar hidden too.
        ZStack(alignment: .bottom) {
            splitView
            if let deleted {
                UndoToast(deleted: deleted) { undoDelete(deleted) }
                    .zIndex(1)
                    .task(id: deleted.id) {
                        try? await Task.sleep(for: .seconds(6))
                        if !Task.isCancelled { withAnimation { self.deleted = nil } }
                    }
            }
        }
        .onChange(of: sheet) { _, shown in
            // The message box keeps focus behind a sheet, and its keyboard would cover the sheet.
            if shown != nil { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .sheet(item: $sheet) { _ in
            NavigationStack(path: $settingsPath) {
                SettingsView()
                    .navigationDestination(for: SettingsPage.self) { page in
                        switch page {
                        case .readiness: ReadinessView { sheet = nil }
                        }
                    }
            }
            .presentationSizing(.page)
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .environment(\.showReadiness, OpenSheetAction { showSettings(readiness: true) })
        .environment(\.showSettings, OpenSheetAction { showSettings() })
        .environment(\.openChat, OpenChatAction { selection = $0 })
        .focusedSceneValue(\.sceneActions, actions)
        .onAppear(perform: restoreSelection)
        .onChange(of: selection) { _, c in
            // A new chat's identifier is temporary until it's saved; newChat() saves first.
            storedSelection = c?.persistentModelID.stored
            // The chat screen warms its model when it appears (Engine.prepare).
        }
        .onChange(of: conversations) {
            // Deleted in another window: don't keep showing a chat that's gone.
            if let s = selection, s.isDeleted || s.modelContext == nil || !conversations.contains(s) {
                selection = hasSidebarToggle ? conversations.first : nil
            }
        }
        // Deep links, App Intents and Spotlight (Lantern/System).
        .background { WindowReader(probe: window) }
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onOpenURL { url in if let link = LanternLink(url: url) { handle(link) } }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { handle(.chat(id: id)) }
        }
        .onChange(of: router.pending) { claimRequest() }
        .onChange(of: scenePhase) { claimRequest() }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in claimRequest() }
        .task {
            // Only if the Mac has been used: checking it would otherwise ask for local network
            // access at launch. It doesn't hold anything up.
            if lastMode == Mode.mac.rawValue, engine.mac.route == .unknown { await engine.mac.resolve() }
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            Group {
                if let selection {
                    ChatScreen(conversation: selection).id(selection.persistentModelID)
                } else {
                    ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .toolbar {
                if hasSidebarToggle && columns == .detailOnly {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Show sidebar", systemImage: "sidebar.left") { toggleSidebar() }
                    }
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // Selection-driven rows (no NavigationLink): on iPhone a NavigationLink here pushes twice.
        List(selection: $selection) {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.chats) { c in
                        ChatRow(conversation: c, answering: engine.running == c.persistentModelID)
                            .tag(c)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) { delete(c) }
                                Button("Rename", systemImage: "pencil") { startRename(c) }.tint(.indigo)
                            }
                            .swipeActions(edge: .leading) {
                                Button(c.pinned ? "Unpin" : "Pin", systemImage: c.pinned ? "pin.slash" : "pin") {
                                    togglePin(c)
                                }
                                .tint(.orange)
                            }
                            .contextMenu { menu(for: c) }
                    }
                }
            }
        }
        .searchable(text: $query, isPresented: $searching, placement: .sidebar, prompt: "Search chats")
        // Rows carry a preview and a date: give them room on iPad.
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        .navigationTitle("Lantern")
        // Our own sidebar button, at the far left of the header instead of beside New chat.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if hasSidebarToggle {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hide sidebar", systemImage: "sidebar.left") { toggleSidebar() }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                // Readiness is inside Settings; a warning on the gear says when it needs a look.
                let ready = Readiness.isReady(store: store, engine: engine)
                Button { showSettings(readiness: !ready) } label: {
                    Image(systemName: "gearshape")
                        .overlay(alignment: .topTrailing) {
                            if !ready {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white, .orange)
                                    .offset(x: 6, y: -6)
                            }
                        }
                }
                .accessibilityLabel(ready ? "Settings" : "Settings, not ready to work offline")
                Spacer()
                // ⌘N lives in the menu bar (LanternCommands), so it works with the sidebar hidden.
                Button("New chat", systemImage: "square.and.pencil", action: { newChat() })
            }
        }
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView {
                    Label(store.downloaded.isEmpty ? "Welcome to Lantern" : "No chats yet", systemImage: "flame")
                } description: {
                    Text(store.downloaded.isEmpty
                         ? "Get the models while you have internet. After that, Lantern answers on this device with no connection."
                         : "Start one, and it stays on this device.")
                } actions: {
                    if store.downloaded.isEmpty {
                        Button("Get models") { showSettings(readiness: true) }.buttonStyle(.borderedProminent)
                    } else {
                        Button("New chat", action: { newChat() }).buttonStyle(.borderedProminent)
                    }
                }
            } else if sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private func menu(for c: Conversation) -> some View {
        Button("Rename", systemImage: "pencil") { startRename(c) }
        Button(c.pinned ? "Unpin" : "Pin", systemImage: c.pinned ? "pin.slash" : "pin") { togglePin(c) }
        if supportsMultipleWindows {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                try? context.save()  // so the window gets a permanent identifier
                openWindow(id: LanternApp.mainWindow, value: c.persistentModelID)
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { delete(c) }
    }

    // MARK: - Menu bar

    private var actions: SceneActions {
        var deleteSelected: (() -> Void)?
        if let c = selection { deleteSelected = { delete(c) } }
        let canStep = !ordered.isEmpty
        let previous: (() -> Void)? = canStep ? { step(-1) } : nil
        let next: (() -> Void)? = canStep ? { step(1) } : nil
        let toggle: (() -> Void)? = hasSidebarToggle ? { toggleSidebar() } : nil
        return SceneActions(
            newChat: { newChat() },
            showSettings: { showSettings() },
            showReadiness: { showSettings(readiness: true) },
            find: { find() },
            deleteSelected: deleteSelected,
            previous: previous,
            next: next,
            toggleSidebar: toggle,
            sidebarVisible: columns != .detailOnly
        )
    }

    private func toggleSidebar() {
        withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
    }

    private func find() {
        if hasSidebarToggle {
            withAnimation { columns = .all }
        } else {
            selection = nil  // back to the list on iPhone
        }
        searching = true
    }

    private func step(_ offset: Int) {
        let list = ordered
        guard !list.isEmpty else { return }
        guard let current = selection, let i = list.firstIndex(of: current) else {
            selection = offset > 0 ? list.first : list.last
            return
        }
        selection = list[min(max(i + offset, 0), list.count - 1)]
    }

    // MARK: - Chats

    private func restoreSelection() {
        guard !restored else { return }
        restored = true
        #if DEBUG
        DebugLaunch.seed(context)
        switch DebugLaunch.ui {
        case "readiness"?: showSettings(readiness: true)
        case "settings"?: showSettings()
        case let ui? where ui.hasPrefix("search:"):
            query = String(ui.dropFirst("search:".count))
            searching = true
        case let ui?:
            // Menu-bar actions, once the window has settled: delete, newchat, sidebar, next, window.
            Task {
                try? await Task.sleep(for: .seconds(1))
                switch ui {
                case "delete": actions.deleteSelected?()
                case "newchat": newChat()
                case "sidebar": actions.toggleSidebar?()
                case "next": actions.next?()
                case "window": if let c = conversations.last { openWindow(id: LanternApp.mainWindow, value: c.persistentModelID) }
                default: break
                }
            }
        default: break
        }
        if let path = DebugLaunch.importPath {
            Task.detached {
                let result = Result { try ModelImport.importFile(at: URL(filePath: path)) }
                print("IMPORT \(path): \(result.map(\.name))")
            }
        }
        #endif
        if let id = PersistentIdentifier(stored: storedSelection) ?? opened,
           let c = conversations.first(where: { $0.persistentModelID == id }) {
            selection = c
            if opened != nil, storedSelection == nil, hasSidebarToggle { columns = .detailOnly }
        } else if hasSidebarToggle {
            // iPad: open on the latest chat rather than "No chat selected".
            selection = conversations.first
        }
        // First run: straight to getting the models (in the first window only).
        if opened == nil, conversations.isEmpty, store.downloaded.isEmpty { showSettings(readiness: true) }
    }

    @discardableResult
    private func newChat(mode: Mode? = nil) -> Conversation {
        let mode = mode ?? DefaultMode.pick(last: lastMode, engine: engine)
        query = ""
        // Reuse an empty chat rather than stacking up "New chat" rows.
        if let empty = conversations.first(where: { $0.messages.isEmpty && !$0.pinned }) {
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

    // MARK: - Deep links and intents

    private func claimRequest() {
        if let link = router.claim(active: scenePhase == .active, window: window.window) { handle(link) }
    }

    /// A `lantern://` link, an App Intent or a Spotlight result, in this window.
    private func handle(_ link: LanternLink) {
        restoreSelection()  // first, in case this arrives before the window appeared
        sheet = nil
        searching = false
        switch link {
        case .new(let mode):
            newChat(mode: mode.flatMap(Mode.init(rawValue:)))
        case .ask(let text, let mode):
            let c = newChat(mode: mode.flatMap(Mode.init(rawValue:)))
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // Another chat is answering: leave the question in the message box to send after.
            if engine.isBusy { c.draft = text } else { engine.send(text, in: c) }
        case .chat(let id):
            query = ""
            if let c = conversations.first(where: { $0.stateID == id }) { selection = c }
        }
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

    private func togglePin(_ c: Conversation) {
        withAnimation { c.pinned.toggle() }
    }

    private func delete(_ c: Conversation) {
        if engine.running == c.persistentModelID { engine.stop() }
        engine.forgetState(for: c)  // its saved model state in Caches/kv
        if selection == c {
            // iPad moves to the next chat; iPhone goes back to the list.
            let list = ordered
            let next = list.firstIndex(of: c).flatMap { i in list.indices.contains(i + 1) ? list[i + 1] : i > 0 ? list[i - 1] : nil }
            selection = hasSidebarToggle ? next : nil
        }
        withAnimation { deleted = DeletedChat(c) }
        context.delete(c)
        try? context.save()
    }

    private func undoDelete(_ d: DeletedChat) {
        let c = d.restore(into: context)
        withAnimation { deleted = nil }
        selection = c
    }
}
