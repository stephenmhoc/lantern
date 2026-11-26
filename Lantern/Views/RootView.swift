import SwiftData
import SwiftUI
import UIKit

/// The one window, opening on a new chat. Past chats and Settings are in a side panel: a sidebar
/// column on iPad, a drawer that slides over the chat on iPhone.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Conversation.lastActive, order: .reverse) private var conversations: [Conversation]
    @State private var selection: Conversation?
    @State private var started = false
    @State private var sheet: Sheet?
    @State private var settingsPath: [SettingsPage] = []
    @State private var columns = NavigationSplitViewVisibility.all
    /// iPhone: whether the side panel is out, and how far a drag has moved it. The drag is plain
    /// state, not `@GestureState`: that snaps back to 0 the instant the finger lifts, so the panel
    /// jumped shut for a frame before animating open. It's put back to 0 in the same animation that
    /// opens or closes the panel, which then carries on from where the finger left it.
    @State private var drawerOpen = false
    @State private var drawerDrag: CGFloat = 0
    /// Whether a drag is under way: to settle the panel when one is cancelled without ending.
    @GestureState private var drawerDragging = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// What the sidebar shows while a query is typed, computed off the main actor in `search`.
    @State private var results: [ChatSearch.Result] = []
    /// The query `results` are for: "No results" waits until the current one has run.
    @State private var resultsFor: SearchKey?
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?
    /// The chat last asked to scroll to a search match (`ChatJump`), to clear a request nobody took.
    @State private var jumpRequested: PersistentIdentifier?
    /// The welcome is shown once, to someone with no model yet.
    @AppStorage("setup.welcomed") private var welcomed = false
    /// The better model already offered (its id), so the offer comes up once.
    @AppStorage("setup.offered") private var offeredModel = ""
    /// A Mac being paired from its QR code.
    @State private var pairing: PairOffer?

    enum Sheet: String, Identifiable {
        /// `role`: the Mac's first run (`MacWelcomeView`).
        case settings, welcome, model, role
        var id: String { rawValue }
    }

    private func showSettings(_ page: SettingsPage? = nil) {
        #if targetEnvironment(macCatalyst)
        SettingsWindow.shared.show(page, open: openWindow)
        #else
        settingsPath = page.map { [$0] } ?? []
        sheet = .settings
        #endif
    }

    /// The chats the side panel lists: an empty chat is just the new-chat page, not history.
    private var history: [Conversation] { conversations.filter { !$0.messages.isEmpty } }
    private var sections: [ChatSection] { ChatSection.group(history) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedQuery.isEmpty }
    private var isWide: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isWide { splitView } else { drawerLayout }
        }
        .onChange(of: sheet) { _, shown in
            // The message box keeps focus behind a sheet, and its keyboard would cover the sheet.
            if shown != nil { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .sheet(item: $sheet) { content(for: $0) }
        .sheet(item: $pairing) { PairingSheet(offer: $0) }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { c in
            Button("Delete Chat", role: .destructive) { withAnimation { delete(c) } }
        } message: { _ in
            Text("This can't be undone.")
        }
        .environment(\.showModel, OpenSheetAction { sheet = .model })
        .environment(\.showSettings, OpenSheetAction { showSettings() })
        .environment(\.showMacSettings, OpenSheetAction { showSettings(.mac) })
        .environment(\.openChat, OpenChatAction { selection = $0 })
        .focusedSceneValue(\.sceneActions, sceneActions)
        .onAppear(perform: start)
        #if targetEnvironment(macCatalyst)
        .onChange(of: selection?.title, initial: true) { _, title in MacWindow.configure(title: title) }
        #endif
        .task(id: searchKey) { await search(searchKey) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            SearchIndex.shared.clear()
        }
        .onChange(of: selection) { _, c in
            if let requested = jumpRequested, requested != c?.persistentModelID {
                ChatJump.shared.clear(for: requested)  // a jump nobody took shouldn't fire on a later visit
                jumpRequested = nil
            }
        }
        .onChange(of: conversations) {
            // Don't keep showing a chat that's gone.
            if let s = selection, s.isDeleted || s.modelContext == nil || !conversations.contains(s) {
                newChat(excluding: s)
            }
        }
        // The Mac's pairing code, scanned with the camera, opens `lantern://pair`.
        .onOpenURL { url in
            guard let offer = PairOffer(url: url) else { return }
            sheet = nil
            DispatchQueue.main.async { pairing = offer }
        }
        .task {
            // Only once a Mac is paired: looking for one would otherwise ask for local network
            // access at launch. It doesn't hold anything up.
            if MacLink.isConfigured, engine.mac.route == .unknown { await engine.mac.resolve() }
        }
        .task {
            // Short titles for chats that still have their question as the title, after launch settles.
            try? await Task.sleep(for: .seconds(3))
            ChatTitler.shared.backfill(conversations)
        }
    }

    @ViewBuilder private func content(for shown: Sheet) -> some View {
        switch shown {
        case .settings:
            // The Mac: never a sheet, Settings has a window of its own (`SettingsWindow`).
            SettingsStack(path: $settingsPath).presentationSizing(.page)
        case .welcome:
            ModelSetupView(style: .welcome).presentationSizing(.page)
        case .model:
            NavigationStack { ModelSetupView(style: .sheet) }.presentationSizing(.page)
        case .role:
            #if targetEnvironment(macCatalyst)
            MacWelcomeView { role in
                sheet = nil
                Task {
                    await MacRole.choose(role, link: engine.mac)
                    if role == .client { showSettings(.mac) }  // pairing is next
                }
            }
            .presentationSizing(.fitted)
            #else
            EmptyView()
            #endif
        }
    }

    /// iPad and Mac: the side panel as a column, which can be hidden.
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columns) {
            #if targetEnvironment(macCatalyst)
            macSidebar
            #else
            sidebar
            #endif
        } detail: {
            chat
                .toolbar {
                    #if !targetEnvironment(macCatalyst)  // the Mac's own sidebar button stays in the title bar
                    if columns == .detailOnly {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Show Sidebar", systemImage: "sidebar.left") { toggleSidebar() }
                        }
                    }
                    #endif
                    ToolbarItem(placement: .topBarTrailing) { newChatButton.help("New Chat (⌘N)") }
                }
        }
    }

    @ViewBuilder
    private var chat: some View {
        if let selection {
            ChatScreen(conversation: selection).id(selection.persistentModelID)
        }
    }

    /// Nothing to do on the new-chat page itself.
    private var newChatButton: some View {
        Button("New Chat", systemImage: "square.and.pencil") { newChat() }
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
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape) { setDrawer(false) }
            }
            // A drag the system cancelled (no `onEnded`) goes back to where it started.
            .onChange(of: drawerDragging) { _, dragging in
                if !dragging, drawerDrag != 0 { setDrawer(drawerOpen) }
            }
        }
    }

    /// Opening drags right from the edge, closing drags left over the chat; past a third of the
    /// panel (or a flick) it goes the rest of the way.
    private func drawerGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($drawerDragging) { _, dragging, _ in dragging = true }
            .onChanged { drawerDrag = $0.translation.width }
            .onEnded { value in
                let moved = value.predictedEndTranslation.width
                let flip = drawerOpen ? moved < -width / 3 : moved > width / 3
                setDrawer(flip ? !drawerOpen : drawerOpen)
            }
    }

    private func setDrawer(_ open: Bool) {
        // The message box's keyboard would sit over the panel.
        if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3)) {
            drawerOpen = open
            drawerDrag = 0
        }
        if !open { searchFocused = false }
    }

    /// Settings needs a look only when nothing here can answer or this build is about to stop
    /// launching.
    private var needsAttention: Bool {
        (!store.isReady && !MacLink.isConfigured) || BuildExpiry.isSoon
    }

    private var attentionBadge: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(.black, .orange)  // white on orange is about 2:1
            .offset(x: 4, y: -4)
            .accessibilityHidden(true)
    }

    // MARK: - Sidebar

    /// The side panel: Lantern and search at the top, the chats as plain rows (the open one
    /// highlighted), Settings and New Chat at the bottom. The same view is the iPad's sidebar column
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
        .modifier(TopBar { sidebarHeader })
        .modifier(BottomBar { sidebarButtons })
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        .overlay { sidebarEmpty }
    }

    @ViewBuilder private var sidebarEmpty: some View {
        if history.isEmpty, !isSearching {
            ContentUnavailableView {
                Label("No Chats Yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Your chats show up here. They stay on this \(Device.name).")
            }
        } else if isSearching, resultsFor == searchKey, results.isEmpty {
            ContentUnavailableView.search(text: trimmedQuery)
        }
    }

    #if targetEnvironment(macCatalyst)
    /// The Mac's sidebar is the system's: a sidebar list with its own selection, the search field
    /// and the sidebar button where a Mac app has them. Settings is in the app menu, New Chat in
    /// the toolbar.
    private var macSidebar: some View {
        let byID = Dictionary(conversations.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = Binding<Conversation?>(
            get: { selection },
            set: { c in
                guard let c else { return }  // a click on nothing keeps the chat open
                if isSearching, let r = results.first(where: { $0.id == c.persistentModelID }) { requestJump(to: r) }
                selection = c
            })
        return List(selection: picked) {
            if isSearching {
                ForEach(results) { r in
                    if let c = byID[r.id] {
                        SearchResultRow(result: r).padding(.vertical, 2).tag(c).contextMenu { chatMenu(c) }
                    }
                }
            } else {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.chats) { c in
                            ChatRow(conversation: c, answering: engine.running == c.persistentModelID)
                                .padding(.vertical, 2)
                                .tag(c)
                                .contextMenu { chatMenu(c) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .searchFocused($searchFocused)
        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        .overlay { sidebarEmpty }
    }
    #endif

    @ViewBuilder private func chatMenu(_ c: Conversation) -> some View {
        Button("Rename", systemImage: "pencil") { startRename(c) }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = c }
    }

    /// "Lantern" with the flame, the iPad's hide-sidebar button and the search field.
    private var sidebarHeader: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill").foregroundStyle(.tint).accessibilityHidden(true)
                Text("Lantern").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if isWide {
                    Button("Hide Sidebar", systemImage: "sidebar.left") { toggleSidebar() }
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
                TextField("Search", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, isWide ? 4 : 8)
        .padding(.bottom, 8)
    }

    /// Settings on the left (badged when it needs a look), New Chat on the right, as round glass buttons.
    private var sidebarButtons: some View {
        HStack {
            Button { showSettings() } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 28, height: 28)
            }
            .modifier(RoundGlass(prominent: false))
            .overlay(alignment: .topTrailing) { if needsAttention { attentionBadge.font(.footnote) } }
            .accessibilityLabel(needsAttention ? "Settings, needs attention" : "Settings")
            Spacer()
            // ⌘N lives in the menu bar (LanternCommands), so it works with the sidebar hidden.
            Button { newChat() } label: {
                Label("New Chat", systemImage: "square.and.pencil")
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

    /// The chats by date. The dates are plain rows rather than section headers, which a plain
    /// list pins to the top with a bar behind them.
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

    /// A chat in the panel: opens it (at the match, for a search result) and puts the drawer away.
    /// Rename and Delete are the list's swipe actions and the row's menu. The open chat is highlighted.
    private func chatButton(_ c: Conversation, result: ChatSearch.Result? = nil,
                            @ViewBuilder label: () -> some View) -> some View {
        Button {
            if let result { requestJump(to: result) }
            selection = c
            if !isWide { setDrawer(false) }
        } label: {
            label()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(SidebarRowStyle(selected: selection == c))
        .accessibilityAddTraits(selection == c ? .isSelected : [])
        .contextMenu { chatMenu(c) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = c }
            Button("Rename", systemImage: "pencil") { startRename(c) }.tint(.gray)
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Asks the chat screen showing `r`'s chat to scroll to its match.
    private func requestJump(to r: ChatSearch.Result) {
        if let requested = jumpRequested, requested != r.id { ChatJump.shared.clear(for: requested) }
        guard let hit = r.target else { ChatJump.shared.clear(for: r.id); jumpRequested = nil; return }
        ChatJump.shared.request(.init(conversation: r.id, message: hit.message, version: hit.version, query: trimmedQuery))
        jumpRequested = r.id
    }

    /// What `results` depends on. `revision` changes when a chat is added, removed, renamed, has a
    /// turn start or end, or shows another answer, so results don't go stale while the query
    /// stays the same.
    struct SearchKey: Hashable {
        var query: String
        var revision: Int
    }

    private var searchKey: SearchKey {
        // Only while searching: it reads every chat's messages.
        guard isSearching else { return SearchKey(query: "", revision: 0) }
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
        return SearchKey(query: trimmedQuery, revision: h.finalize())
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
        let found = await ChatSearch.search(documents, query: key.query)
        guard !Task.isCancelled else { return }
        results = found
        resultsFor = key
    }

    private func toggleSidebar() {
        if isWide {
            withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
        } else {
            setDrawer(!drawerOpen)
        }
    }

    private func find() {
        if isWide {
            withAnimation { columns = .all }
        } else {
            setDrawer(true)
        }
        searchFocused = true
    }

    // MARK: - Chats

    private func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        DebugLaunch.seed(context)
        #endif
        newChat()
        #if targetEnvironment(macCatalyst)
        // A Mac has no model to download: its first run asks what it does instead.
        if MacRole.current == nil {
            sheet = .role
        } else {
            MacRole.resume(engine.mac)
        }
        MacUpdater.start()
        #else
        // First run: the welcome, which downloads the model. Once.
        if store.isReady || MacLink.isConfigured { welcomed = true }
        if !welcomed {
            welcomed = true
            sheet = .welcome
        } else if store.hasUpgrade, store.state == .missing, offeredModel != store.best.id {
            // A better model than the one here: offered once, never forced. It stays in Settings.
            offeredModel = store.best.id
            sheet = .model
        }
        #endif
        #if DEBUG
        DebugLaunch.open(in: self.debugHooks)
        #endif
    }

    /// `excluding`: a chat being deleted, which the query may still list.
    @discardableResult
    private func newChat(excluding: Conversation? = nil) -> Conversation {
        query = ""
        if !isWide, drawerOpen { setDrawer(false) }
        // Reuse an empty chat rather than stacking up empty ones.
        if let empty = conversations.first(where: {
            $0.messages.isEmpty && $0 != excluding && !$0.isDeleted && $0.modelContext != nil
        }) {
            empty.mode = ChatDefaults.mode
            empty.thinking = ChatDefaults.thinking
            empty.webSearch = ChatDefaults.webSearch
            // A prompt as it would be written today: the date, and any change to the instructions.
            empty.systemPrompt = Engine.systemPrompt()
            empty.lastActive = .now
            selection = empty
            return empty
        }
        let c = Conversation(mode: ChatDefaults.mode)
        context.insert(c)
        try? context.save()  // a permanent identifier, for `Engine.running`
        selection = c
        return c
    }

    /// What the menu bar can do in this window.
    private var sceneActions: SceneActions {
        SceneActions(
            newChat: { newChat() }, showSettings: { showSettings() }, find: { find() },
            toggleSidebar: { toggleSidebar() }, sidebarVisible: isWide ? columns != .detailOnly : drawerOpen,
            thinking: chatSetting { $0.thinking != .off }, webSearch: chatSetting { $0.webSearch },
            setThinking: { on in changeChat { $0.thinking = on ? .high : .off } },
            setWebSearch: { on in changeChat { $0.webSearch = on } })
    }

    /// One of the open chat's settings, for the menu bar: nil while it can't change (no chat, or
    /// it's answering).
    private func chatSetting(_ value: (Conversation) -> Bool) -> Bool? {
        guard let selection, engine.running != selection.persistentModelID else { return nil }
        return value(selection)
    }

    /// Changes the open chat's Think First or Search the Web from the menu bar, as the model
    /// picker does: remembered for new chats, and the model gets ready for the new system turn.
    private func changeChat(_ change: (Conversation) -> Void) {
        guard let selection, engine.running != selection.persistentModelID else { return }
        change(selection)
        ChatDefaults.remember(selection)
        engine.prepare(selection)
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

    /// Deleting the chat on screen goes to a new chat.
    private func delete(_ c: Conversation) {
        if engine.running == c.persistentModelID { engine.stop() }
        engine.forgetState(for: c)  // its saved model state in Caches/kv
        let shown = selection == c
        context.delete(c)
        try? context.save()
        if shown { newChat(excluding: c) }
    }

    #if DEBUG
    /// What `-ui` can open from outside the view (see `DebugLaunch`).
    private var debugHooks: DebugLaunch.Hooks {
        DebugLaunch.Hooks(
            settings: { showSettings($0) },
            sheet: { sheet = $0 },
            sidebar: { if isWide { columns = .all } else { setDrawer(true) } },
            search: { query = $0 },
            open: { title in if let c = conversations.first(where: { $0.title == title }) { selection = c } })
    }
    #endif
}

#if targetEnvironment(macCatalyst)
/// The Mac's window: a size it can't be shrunk past, and the open chat's title (the Window menu
/// lists it by that).
enum MacWindow {
    static func configure(title: String?) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes where scene !== SettingsWindow.shared.scene {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 700, height: 480)
            scene.title = title ?? ""
        }
    }
}
#endif

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
