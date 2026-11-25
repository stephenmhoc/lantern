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
    @State private var scope = SearchScope.all
    /// What the sidebar shows while a query is typed, computed off the main actor in `search`.
    @State private var results: [ChatSearch.Result] = []
    /// The query and scope `results` are for: "No results" waits until the current one has run.
    @State private var resultsFor: SearchKey?
    @State private var renaming: Conversation?
    @State private var renameText = ""
    /// The chat this window last asked `ChatJump` to scroll, to clear only its own request.
    @State private var jumpRequested: PersistentIdentifier?
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

    private var sections: [ChatSection] { ChatSection.group(conversations) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }
    /// The chats in the order the sidebar shows them, for ⌘↑/⌘↓ and moving on after a delete.
    private var ordered: [Conversation] {
        guard isSearching else { return sections.flatMap(\.chats) }
        let byID = Dictionary(conversations.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        return results.compactMap { byID[$0.id] }
    }
    private var hasSidebarToggle: Bool { sizeClass == .regular }

    var body: some View {
        splitView
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
            if isSearching {
                searchResults
            } else {
                chatSections
            }
        }
        // Under the large title on iPhone: with `.sidebar` there, iOS 26 put the field at the bottom
        // beside the bar of buttons. The sidebar's own placement on iPad.
        .searchable(text: $query, isPresented: $searching,
                    placement: hasSidebarToggle ? .sidebar : .navigationBarDrawer(displayMode: .always),
                    prompt: "Search chats")
        .searchScopes($scope, activation: .onSearchPresentation) {
            ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .task(id: searchKey) { await search(searchKey) }
        .onChange(of: searching) { _, on in if !on { SearchIndex.shared.clear() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            SearchIndex.shared.clear()
        }
        .onChange(of: selection) { _, c in
            if isSearching, let c, let r = results.first(where: { $0.id == c.persistentModelID }) {
                // Arrow keys onto a result: jump to its match too (a tap already set it).
                requestJump(to: r)
            } else if let requested = jumpRequested, requested != c?.persistentModelID {
                // This window's jump nobody took shouldn't fire on some later visit. Only its own:
                // another window's is for the chat that window shows.
                ChatJump.shared.clear(for: requested)
                jumpRequested = nil
            }
        }
        // Rows carry a preview and a date: give them room on iPad.
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        .navigationTitle("Lantern")
        // The large title in the bar's own row: nothing else sits up there now that New chat is
        // at the bottom, so a separate row for it was only empty space.
        .toolbarTitleDisplayMode(.inlineLarge)
        // Our own sidebar button, at the far left of the header instead of beside New chat.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            if hasSidebarToggle {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hide sidebar", systemImage: "sidebar.left") { toggleSidebar() }
                }
            }
        }
        // Settings and New chat sit in the list's own bottom inset, not the navigation toolbar:
        // on iPhone the sidebar and the chat share one navigation controller, and a toolbar item
        // of the sidebar's stayed drawn over a chat opened by a link.
        .modifier(BottomBar { sidebarButtons })
        .overlay {
            if conversations.isEmpty {
                ContentUnavailableView {
                    Label(store.downloaded.isEmpty ? "Welcome to Lantern" : "No chats yet", systemImage: "flame")
                } description: {
                    Text(store.downloaded.isEmpty
                         ? "Download a model to start chatting."
                         : "Start one, and it stays on this device.")
                } actions: {
                    if store.downloaded.isEmpty {
                        Button { showSettings(readiness: true) } label: { Text("Get models").modifier(ProminentLabel()) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button { newChat() } label: { Text("New chat").modifier(ProminentLabel()) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if isSearching, resultsFor == searchKey, results.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    /// Settings on the left (badged when it needs a look), New chat on the right, as round glass buttons.
    private var sidebarButtons: some View {
        // Models are inside Settings; a mark on the gear only when there's no model at all or the build expires soon.
        let ready = !Readiness.needsAttention(store: store)
        return HStack {
            Button { showSettings(readiness: !ready) } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .modifier(RoundGlass(prominent: false))
            .overlay(alignment: .topTrailing) {
                if !ready {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.black, .orange)  // white on orange is about 2:1
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(ready ? "Settings" : "Settings, needs attention")
            Spacer()
            // ⌘N lives in the menu bar (LanternCommands), so it works with the sidebar hidden.
            Button { newChat() } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.medium))
                    // Dark on the amber: white on it is about 2.3:1, under the 3:1 icons need;
                    // black is about 9:1, in light and dark mode alike (the fill doesn't change).
                    .foregroundStyle(.black)
                    .frame(width: 28, height: 28)
            }
            .modifier(RoundGlass(prominent: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The chats by date, with their swipe actions and menu.
    private var chatSections: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.chats) { c in
                    rowActions(ChatRow(conversation: c, answering: engine.running == c.persistentModelID).tag(c), c)
                }
            } header: {
                // On the title's (and the cards') edge rather than indented to the rows' text.
                // The list ignores header insets, so it's pulled out by the card's inset.
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, -16)
            }
        }
    }

    /// While a query is typed: chats with a match, title matches first, each showing where it matched.
    private var searchResults: some View {
        let byID = Dictionary(conversations.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        return ForEach(results) { r in
            if let c = byID[r.id] {
                // The list's selection opens the chat (onChange(of: selection) sets the jump); the
                // tap also sets it, for the chat already shown on iPad, whose selection doesn't change.
                rowActions(SearchResultRow(result: r).tag(c), c, result: r)
                    .simultaneousGesture(TapGesture().onEnded { requestJump(to: r) })
            }
        }
    }

    /// A row's swipe actions and menu, the same for a chat and a search result. `result`: open
    /// windows at its match too.
    private func rowActions(_ row: some View, _ c: Conversation, result: ChatSearch.Result? = nil) -> some View {
        row
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
            .contextMenu { menu(for: c, result: result) }
    }

    /// Asks the chat screen showing `r`'s chat to scroll to its match. Keyed by the chat, so it
    /// can't be taken or cleared by another window showing another chat.
    private func requestJump(to r: ChatSearch.Result) {
        if let requested = jumpRequested, requested != r.id { ChatJump.shared.clear(for: requested) }
        guard let hit = r.target else { ChatJump.shared.clear(for: r.id); jumpRequested = nil; return }
        ChatJump.shared.request(.init(conversation: r.id, message: hit.message, version: hit.version, query: trimmedQuery))
        jumpRequested = r.id
    }

    /// What `results` depends on. `revision` changes when a chat is added, removed, renamed, has a
    /// turn start or end, or shows another answer (a version switch, Continue With), so results
    /// don't go stale while the query stays the same. Votes don't change what's searched.
    struct SearchKey: Hashable {
        var query: String
        var scope: SearchScope
        var revision: Int
    }

    private var searchKey: SearchKey {
        // Only while searching: it reads every chat's messages.
        guard isSearching else { return SearchKey(query: "", scope: scope, revision: 0) }
        var h = Hasher()
        h.combine(conversations.count)
        for c in conversations {
            h.combine(c.lastActive)
            h.combine(c.title)
            for m in c.messages where !m.isUser {
                h.combine(m.id)
                h.combine(m.versionIndex)
            }
        }
        return SearchKey(query: trimmedQuery, scope: scope, revision: h.finalize())
    }

    /// Runs the search for `key` after a short pause for typing, off the main actor.
    private func search(_ key: SearchKey) async {
        guard !key.query.isEmpty else {
            if !results.isEmpty { results = [] }
            if resultsFor != nil { resultsFor = nil }
            SearchIndex.shared.clear()  // folded text of every chat: not kept between searches
            return
        }
        // Typing restarts the task (its id changes), which cancels this sleep: a debounce.
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        let documents = ChatSearch.documents(conversations)
        let found = await ChatSearch.search(documents, query: key.query, scope: key.scope)
        guard !Task.isCancelled else { return }
        results = found
        resultsFor = key
    }

    @ViewBuilder
    private func menu(for c: Conversation, result: ChatSearch.Result? = nil) -> some View {
        Button("Rename", systemImage: "pencil") { startRename(c) }
        Button(c.pinned ? "Unpin" : "Pin", systemImage: c.pinned ? "pin.slash" : "pin") { togglePin(c) }
        if supportsMultipleWindows {
            Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                if let result { requestJump(to: result) }
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
        ChatSearch.benchmark()
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
        searching = false
        guard sheet == nil else {
            // Selecting while the sheet goes away can be lost: dismiss, then go on next turn.
            sheet = nil
            DispatchQueue.main.async { open(link) }
            return
        }
        open(link)
    }

    private func open(_ link: LanternLink) {
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

    /// Immediate, with no undo. Swipe-delete still takes a tap on its button (no full swipe).
    private func delete(_ c: Conversation) {
        if engine.running == c.persistentModelID { engine.stop() }
        engine.forgetState(for: c)  // its saved model state in Caches/kv
        if selection == c {
            // iPad moves to the next chat; iPhone goes back to the list.
            let list = ordered
            let next = list.firstIndex(of: c).flatMap { i in list.indices.contains(i + 1) ? list[i + 1] : i > 0 ? list[i - 1] : nil }
            selection = hasSidebarToggle ? next : nil
        }
        withAnimation { context.delete(c) }
        try? context.save()
    }
}

/// Buttons in a scroll view's own bottom inset (the sidebar's, the comparison's): on iOS 26 a
/// bar with no background of its own, over the scroll view's soft edge effect; the system bar
/// material before.
struct BottomBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom).safeAreaBar(edge: .bottom) { bar() }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { bar().background(.bar) }
        }
    }
}

/// A round button: glass on iOS 26 (prominent glass in the accent colour for the main action),
/// bordered before.
private struct RoundGlass: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if prominent {
                content.buttonStyle(.glassProminent).tint(.accentColor).buttonBorderShape(.circle).controlSize(.large)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            }
        } else {
            if prominent {
                content.buttonStyle(.borderedProminent).tint(.accentColor).buttonBorderShape(.circle).controlSize(.large)
            } else {
                content.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
            }
        }
    }
}

/// The label of a button filled with the amber accent: black, since white on the amber is about
/// 2.3:1, and secondary when the button is disabled (black on the dimmed fill is about 1.5:1).
struct ProminentLabel: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(Color.black) : AnyShapeStyle(.secondary))
    }
}
