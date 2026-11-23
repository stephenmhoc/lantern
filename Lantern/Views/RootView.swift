import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Query(sort: \Conversation.updated, order: .reverse) private var conversations: [Conversation]
    @State private var selection: Conversation?
    @State private var sheet: Sheet?
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum Sheet: String, Identifiable {
        case readiness, settings
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            // Selection-driven rows (no NavigationLink): on iPhone a NavigationLink here pushes twice.
            List(selection: $selection) {
                ForEach(conversations) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).lineLimit(1)
                        HStack {
                            Label(c.mode.title, systemImage: c.mode.symbol)
                            if engine.running == c.persistentModelID { Text("· Answering") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(c)
                }
                .onDelete { offsets in offsets.map { conversations[$0] }.forEach(delete) }
            }
            .navigationTitle("Lantern")
            // Our own sidebar button, at the far left of the header instead of beside New chat.
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                if sizeClass == .regular {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Hide sidebar", systemImage: "sidebar.left") { withAnimation { columns = .detailOnly } }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New chat", systemImage: "square.and.pencil", action: newChat)
                        .keyboardShortcut("n")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { sheet = .readiness } label: {
                        Label("Readiness", systemImage: Readiness.isReady(store: store, engine: engine)
                              ? "checkmark.seal" : "exclamationmark.triangle")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(Readiness.isReady(store: store, engine: engine) ? nil : .orange)
                    Spacer()
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
                }
            }
            .overlay {
                if conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No chats", systemImage: "flame")
                    } description: {
                        Text(store.downloaded.isEmpty
                             ? "Get the models while you have internet, so Lantern works when you don't."
                             : "Everything runs on this device.")
                    } actions: {
                        if store.downloaded.isEmpty {
                            Button("Get models") { sheet = .readiness }.buttonStyle(.borderedProminent)
                        } else {
                            Button("New chat", action: newChat).buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        } detail: {
            Group {
                if let selection {
                    ChatScreen(conversation: selection).id(selection.persistentModelID)
                } else {
                    ContentUnavailableView("No chat selected", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .toolbar {
                if sizeClass == .regular && columns == .detailOnly {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Show sidebar", systemImage: "sidebar.left") { withAnimation { columns = .all } }
                    }
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .readiness: ReadinessView()
                case .settings: SettingsView()
                }
            }
        }
        .onAppear {
            // First run: straight to getting the models.
            if conversations.isEmpty && store.downloaded.isEmpty { sheet = .readiness }
        }
    }

    private func newChat() {
        // The best mode that works right now: Smart if it's here, else Fast, else the Mac.
        let ready = { (mode: Mode) in engine.model(for: mode).map { store.states[$0.id] == .ready } ?? false }
        let c = Conversation(mode: ready(.smart) ? .smart : ready(.fast) ? .fast : .mac)
        context.insert(c)
        selection = c
    }

    private func delete(_ c: Conversation) {
        if engine.running == c.persistentModelID { engine.stop() }
        if selection == c { selection = nil }
        context.delete(c)
    }
}
