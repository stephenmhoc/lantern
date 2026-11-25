import CoreSpotlight
import LlamaKit
import SwiftData
import SwiftUI
import UIKit

/// One window, opening on a new chat. Past chats and Settings are in a side panel: a sidebar
/// column on iPad (chat list, chat, and the inspector as a third column), a drawer that slides over
/// the chat on iPhone. A window opened for a chat ("Open in New Window") restores it with
/// `@SceneStorage`; all windows share the app's one `Engine`.
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
    /// iPhone: whether the side panel is out, and how far a drag has moved it.
    @State private var drawerOpen = false
    @GestureState private var drawerDrag: CGFloat = 0
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var scope = SearchScope.all
    /// What the sidebar shows while a query is typed, computed off the main actor in `search`.
    @State private var results: [ChatSearch.Result] = []
    /// The query and scope `results` are for: "No results" waits until the current one has run.
    @State private var resultsFor: SearchKey?
    @State private var renaming: Conversation?
    /// The row whose swipe actions are out, if any.
    @State private var swiped: SwipeOpen?
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

    /// The chats the side panel lists: an empty chat is just the new-chat page, not history.
    private var history: [Conversation] { conversations.filter { !$0.messages.isEmpty || $0.pinned } }
    private var sections: [ChatSection] { ChatSection.group(history) }
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
        Group {
            if hasSidebarToggle { splitView } else { drawerLayout }
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
                newChat(excluding: s)
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
        .task {
            // Short titles for chats that still have their question as the title, after launch settles.
            try? await Task.sleep(for: .seconds(3))
            ChatTitler.shared.backfill(conversations)
        }
    }

    /// iPad: the side panel as a column, which can be hidden.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            chat
                .toolbar {
                    if columns == .detailOnly {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Show sidebar", systemImage: "sidebar.left") { toggleSidebar() }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) { newChatButton }
                }
        }
    }

    @ViewBuilder
    private var chat: some View {
        if let selection {
            ChatScreen(conversation: selection).id(selection.persistentModelID)
        } else {
            ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
        }
    }

    /// Nothing to do on the new-chat page itself.
    private var newChatButton: some View {
        Button("New chat", systemImage: "square.and.pencil") { newChat() }
            .disabled(selection?.messages.isEmpty ?? false)
    }

    // MARK: - iPhone side panel

    private static let drawerMaxWidth: CGFloat = 340

    /// iPhone: the chat fills the screen; the side panel slides over it from the left (the button
    /// at the top left, or a swipe in from the left edge) and goes away with a tap or swipe on the
    /// dimmed chat, or on choosing a chat.
    private var drawerLayout: some View {
        GeometryReader { geo in
            let width = min(geo.size.width * 0.85, Self.drawerMaxWidth)
            let shown = drawerOpen ? max(0, width + min(0, drawerDrag)) : min(width, max(0, drawerDrag))
            ZStack(alignment: .leading) {
                NavigationStack {
                    chat.toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Chats and Settings", systemImage: "sidebar.left") { setDrawer(true) }
                                .overlay(alignment: .topTrailing) { if needsAttention { attentionBadge } }
                        }
                        ToolbarItem(placement: .topBarTrailing) { newChatButton }
                    }
                }
                .accessibilityHidden(drawerOpen)
                // Swipe in from the left edge to open.
                .overlay(alignment: .leading) {
                    if !drawerOpen {
                        Color.clear
                            .frame(width: 20)
                            .contentShape(.rect)
                            .gesture(drawerGesture(width: width))
                    }
                }

                Color.black
                    .opacity(0.3 * shown / width)
                    .ignoresSafeArea()
                    .allowsHitTesting(drawerOpen)
                    .onTapGesture { setDrawer(false) }
                    .gesture(drawerGesture(width: width))
                    .accessibilityHidden(true)

                sidebar
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .frame(width: width)
                    // Rounded at the right, out to the screen's top and bottom edges.
                    .mask { UnevenRoundedRectangle(bottomTrailingRadius: 24, topTrailingRadius: 24).ignoresSafeArea() }
                    .shadow(color: .black.opacity(shown > 0 ? 0.15 : 0), radius: 12)
                    .offset(x: shown - width)
                    .accessibilityHidden(!drawerOpen)
                    .accessibilityAction(.escape) { setDrawer(false) }
            }
        }
    }

    /// Opening drags right from the edge, closing drags left over the chat; past a third of the
    /// panel (or a flick) it goes the rest of the way.
    private func drawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($drawerDrag) { value, state, _ in state = value.translation.width }
            .onEnded { value in
                let moved = value.predictedEndTranslation.width
                if drawerOpen ? moved < -width / 3 : moved > width / 3 { setDrawer(!drawerOpen) }
            }
    }

    private func setDrawer(_ open: Bool) {
        // The message box's keyboard would sit over the panel.
        if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        withAnimation(.snappy(duration: 0.3)) { drawerOpen = open }
        if !open { searchFocused = false }
    }

    private var needsAttention: Bool { Readiness.needsAttention(store: store) }

    private var attentionBadge: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(.black, .orange)  // white on orange is about 2:1
            .offset(x: 4, y: -4)
            .accessibilityHidden(true)
    }

    // MARK: - Sidebar

    /// The side panel: Lantern and search at the top, the chats as plain rows (the open one
    /// highlighted), Settings and New chat at the bottom. The same view is the iPad's sidebar column
    /// and the iPhone's drawer; neither has a navigation bar of its own.
    private var sidebar: some View {
        // Buttons, not list selection: the panel's own highlight, the same on iPhone and iPad, and
        // a tap on the chat already open still closes the drawer.
        List {
            if isSearching {
                searchResults
            } else {
                chatSections
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollDismissesKeyboard(.immediately)
        .onScrollPhaseChange { _, phase in if phase != .idle { putSwipeAway() } }
        .onChange(of: query) { putSwipeAway() }
        .onChange(of: drawerOpen) { putSwipeAway() }
        .modifier(TopBar { sidebarHeader })
        // Settings and New chat sit in the list's own bottom inset.
        .modifier(BottomBar { sidebarButtons })
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(removing: .sidebarToggle)
        .task(id: searchKey) { await search(searchKey) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            SearchIndex.shared.clear()
        }
        .onChange(of: selection) { _, c in
            if let requested = jumpRequested, requested != c?.persistentModelID {
                // This window's jump nobody took shouldn't fire on some later visit. Only its own:
                // another window's is for the chat that window shows.
                ChatJump.shared.clear(for: requested)
                jumpRequested = nil
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        .overlay {
            if history.isEmpty, !isSearching {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Your chats show up here, and stay on this device.")
                }
            } else if isSearching, resultsFor == searchKey, results.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
    }

    /// "Lantern" with the flame, the iPad's hide-sidebar button, the search field and, while a
    /// query is typed, what to search.
    private var sidebarHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill").foregroundStyle(.tint).accessibilityHidden(true)
                Text("Lantern").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if hasSidebarToggle {
                    Button("Hide sidebar", systemImage: "sidebar.left") { toggleSidebar() }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                        .buttonStyle(.borderless)
                        .tint(.primary)
                }
            }
            .frame(minHeight: 44)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search chats", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Color(.tertiarySystemFill), in: .capsule)
            if isSearching {
                Picker("Search in", selection: $scope) {
                    ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, hasSidebarToggle ? 4 : 8)
        .padding(.bottom, 8)
    }

    /// Settings on the left (badged when it needs a look), New chat on the right, as round glass buttons.
    private var sidebarButtons: some View {
        // Models are inside Settings; a mark on the gear only when there's no model at all or the build expires soon.
        let ready = !needsAttention
        return HStack {
            Button { showSettings(readiness: !ready) } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .modifier(RoundGlass(prominent: false))
            .overlay(alignment: .topTrailing) { if !ready { attentionBadge.font(.footnote) } }
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

    /// The chats by date, with their swipe actions and menu. The dates are plain rows rather than
    /// section headers, which a plain list pins to the top with a bar behind them.
    private var chatSections: some View {
        ForEach(Array(sections.enumerated()), id: \.element.id) { i, section in
            Text(section.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .listRowInsets(EdgeInsets(top: i == 0 ? 4 : 18, leading: 20, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            ForEach(section.chats) { c in
                chatButton(c) { ChatRow(conversation: c, answering: engine.running == c.persistentModelID) }
            }
        }
    }

    /// While a query is typed: chats with a match, title matches first, each showing where it matched.
    private var searchResults: some View {
        let byID = Dictionary(conversations.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        return ForEach(results) { r in
            if let c = byID[r.id] {
                chatButton(c, result: r) { SearchResultRow(result: r) }
            }
        }
    }

    /// A chat in the panel: opens it (at the match, for a search result) and puts the drawer away,
    /// with its swipe actions (`SwipeRow`) and menu. The open chat is highlighted.
    private func chatButton(_ c: Conversation, result: ChatSearch.Result? = nil,
                            @ViewBuilder label: () -> some View) -> some View {
        SwipeRow(id: c.persistentModelID, open: $swiped, pinned: c.pinned,
                 onPin: { withAnimation { togglePin(c) } },
                 onRename: { startRename(c) },
                 onDelete: { withAnimation { delete(c) } }) {
            Button {
                // With a row's actions out, a tap anywhere in the list just puts them away.
                if swiped != nil { putSwipeAway(); return }
                if let result { requestJump(to: result) }
                selection = c
                if !hasSidebarToggle { setDrawer(false) }
            } label: {
                label()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(SidebarRowStyle(selected: selection == c))
            .accessibilityAddTraits(selection == c ? .isSelected : [])
            .contextMenu { menu(for: c, result: result) }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func putSwipeAway() {
        guard swiped != nil else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { swiped = nil }
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
        let toggle: (() -> Void)? = { toggleSidebar() }
        return SceneActions(
            newChat: { newChat() },
            showSettings: { showSettings() },
            showReadiness: { showSettings(readiness: true) },
            find: { find() },
            deleteSelected: deleteSelected,
            previous: previous,
            next: next,
            toggleSidebar: toggle,
            sidebarVisible: hasSidebarToggle ? columns != .detailOnly : drawerOpen
        )
    }

    private func toggleSidebar() {
        if hasSidebarToggle {
            withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
        } else {
            setDrawer(!drawerOpen)
        }
    }

    private func find() {
        if hasSidebarToggle {
            withAnimation { columns = .all }
        } else {
            setDrawer(true)
        }
        searchFocused = true
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
        case let ui?:
            // Menu-bar actions, once the window has settled: delete, newchat, sidebar, next, window.
            Task {
                try? await Task.sleep(for: .seconds(1))
                switch ui {
                case "delete": actions.deleteSelected?()
                case "newchat": newChat()
                case "sidebar": actions.toggleSidebar?()
                case "swipe", "swipepin":
                    // The first chat's swipe actions out (Rename and Delete, or Pin), in the open panel.
                    if !hasSidebarToggle { setDrawer(true) }
                    try? await Task.sleep(for: .seconds(0.5))
                    if let c = sections.first?.chats.first {
                        withAnimation { swiped = SwipeOpen(id: c.persistentModelID, edge: ui == "swipe" ? .trailing : .leading) }
                    }
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
        let firstRun = conversations.isEmpty && store.downloaded.isEmpty
        // A window opened for a chat keeps showing it; every other window opens on a new chat.
        if opened != nil, let id = PersistentIdentifier(stored: storedSelection) ?? opened,
           let c = conversations.first(where: { $0.persistentModelID == id }) {
            selection = c
            if storedSelection == nil, hasSidebarToggle { columns = .detailOnly }
        } else {
            newChat()
        }
        // First run: straight to getting the models (in the first window only).
        if opened == nil, firstRun { showSettings(readiness: true) }
    }

    /// `excluding`: a chat being deleted, which the query may still list.
    @discardableResult
    private func newChat(mode: Mode? = nil, excluding: Conversation? = nil) -> Conversation {
        let mode = mode ?? DefaultMode.pick(last: lastMode, engine: engine)
        query = ""
        if !hasSidebarToggle, drawerOpen { setDrawer(false) }
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

    // MARK: - Deep links and intents

    private func claimRequest() {
        if let link = router.claim(active: scenePhase == .active, window: window.window) { handle(link) }
    }

    /// A `lantern://` link, an App Intent or a Spotlight result, in this window.
    private func handle(_ link: LanternLink) {
        restoreSelection()  // first, in case this arrives before the window appeared
        searchFocused = false
        if drawerOpen { setDrawer(false) }
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
    /// Deleting the chat on screen goes to a new chat.
    private func delete(_ c: Conversation) {
        if engine.running == c.persistentModelID { engine.stop() }
        engine.forgetState(for: c)  // its saved model state in Caches/kv
        let shown = selection == c
        withAnimation { context.delete(c) }
        try? context.save()
        if shown { newChat(excluding: c) }
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

/// Buttons in a scroll view's top inset (the side panel's header), like `BottomBar`.
struct TopBar<Bar: View>: ViewModifier {
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top).safeAreaBar(edge: .top) { bar() }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { bar().background(.bar) }
        }
    }
}

/// A chat in the side panel: a rounded highlight in the accent colour when it's the open one, a
/// faint one while pressed or under the pointer.
private struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                          : configuration.isPressed || hovering ? AnyShapeStyle(Color.primary.opacity(0.07))
                          : AnyShapeStyle(Color.clear))
            }
            .onHover { hovering = $0 }
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
