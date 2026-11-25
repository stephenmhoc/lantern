import LlamaKit
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The Models page: a row per on-device model (details, image reading, Test and Delete behind a tap),
/// the Mac in one line, then importing a file, old files and when this build stops launching.
struct ReadinessView: View {
    /// Closes the sheet it's in (it's pushed inside Settings, where `dismiss` would only go back).
    var close: (() -> Void)?
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tests: ModelTestResults = [:]
    @State private var deleting: CatalogModel?
    @State private var detail: CatalogModel?
    @State private var appleDetail = false
    @State private var lan: Bool?
    @State private var tailnet: Bool?
    @State private var checkingMac = false
    @State private var choosingFile = false
    @State private var importing: String?
    @State private var importError: String?
    @State private var dropTargeted = false
    @State private var reminders: UNAuthorizationStatus?
    @State private var deletingRetired = false


    var body: some View {
        list
            #if DEBUG
            .modifier(DebugScroll(to: "end"))
            #endif
    }

    private var list: some View {
        List {
            Section {
                ForEach(CatalogModel.all) { row($0) }
                AppleModelRow(test: tests[AppleModelRow.testKey], open: { appleDetail = true },
                              runTest: { Readiness.runAppleTest(engine: engine, into: $tests) })
            } header: {
                Text("On This Device")
            } footer: {
                Text("\(ByteCountFormatter.string(fromByteCount: ModelStore.freeBytes, countStyle: .file)) available on this device.")
            }

            Section("On Your Computers") {
                macRow
            }

            Section {
                if let importing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Copying \(importing)…").foregroundStyle(.secondary)
                    }
                } else {
                    Button { choosingFile = true } label: {
                        Label {
                            Text("Import a Model File…")
                        } icon: {
                            Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
                if !store.retired.isEmpty {
                    Button(role: .destructive) { deletingRetired = true } label: {
                        LabeledContent("Delete Unused Files", value: size(store.retired.reduce(0) { $0 + $1.bytes }))
                    }
                }
                if let expiry = Readiness.expiry {
                    LabeledContent {
                        Text(expiry.formatted(date: .abbreviated, time: .omitted))
                    } label: {
                        if Readiness.expiresSoon {
                            Label("Stops launching", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(OrangeIconLabelStyle())
                        } else {
                            Text("Stops launching")
                        }
                    }
                    reminderRow
                }
            } footer: {
                Text("Already have a model file, from your Mac or the Files app? Import it, or drag it onto this page.")
            }
            .id("end")
        }
        .navigationTitle("Models")
        .navigationDestination(item: $detail) { ModelDetailView(model: $0, tests: $tests) }
        .navigationDestination(isPresented: $appleDetail) { AppleModelDetailView(tests: $tests) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { if let close { close() } else { dismiss() } } }
        }
        .onAppear {
            store.refresh()
            store.refreshRetired()
            #if DEBUG
            // `-readinessDetail <model id>`: opens that model's page, for screenshots.
            let args = ProcessInfo.processInfo.arguments
            if detail == nil, let i = args.firstIndex(of: "-readinessDetail"), args.indices.contains(i + 1) {
                if args[i + 1] == AppleModelRow.testKey { appleDetail = true }
                detail = CatalogModel.all.first { $0.id == args[i + 1] }
            }
            #endif
        }
        .confirmsModelDeletion($deleting)
        .confirmationDialog("Delete files no longer used?", isPresented: $deletingRetired, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.deleteRetired() }
        } message: {
            Text("""
                Inkling 2 Mini no longer runs on this device: it was too big and slow for it. Your Mac can \
                still run it. Frees \(size(store.retired.reduce(0) { $0 + $1.bytes })).
                """)
        }
        .task { checkMac() }
        .task { reminders = await ExpiryReminders.status() }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.gguf]) { result in
            switch result {
            case .success(let url): importModel(url, move: false)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        // Drag a .gguf from Files (or another app) onto the list.
        .onDrop(of: [.gguf], isTargeted: $dropTargeted) { providers in
            guard importing == nil, let provider = providers.first else { return false }
            importing = provider.suggestedName.map { "\($0).gguf" } ?? "the model"
            // The provided file is deleted when the handler returns, so it's moved in right there.
            _ = provider.loadFileRepresentation(for: .gguf, openInPlace: false) { url, _, error in
                let outcome: Result<CatalogModel, Error>
                if let url {
                    outcome = Result { try ModelImport.importFile(at: url, move: true) }
                } else {
                    outcome = .failure(error ?? CocoaError(.fileReadUnknown))
                }
                Task { @MainActor in finishImport(outcome) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .alert("Couldn't Import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func row(_ model: CatalogModel) -> some View {
        ModelRow(model: model, test: tests[model.id], open: { detail = model },
                 runTest: { Readiness.runTest(model, engine: engine, into: $tests) },
                 delete: { deleting = $0 })
    }

    // MARK: - Mac

    /// The computer in one line; opens its page.
    private var macRow: some View {
        NavigationLink { ComputersView() } label: {
            HStack(spacing: 12) {
                Label { Text(MacLink.isConfigured ? MacLink.computerName : "Add a Computer") } icon: {
                    Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(macStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var macStatus: String {
        if checkingMac { return "Checking…" }
        switch (lan, tailnet) {
        case (true?, true?): return "Home network and tailnet"
        case (true?, _): return "Home network"
        case (_, true?): return "Tailnet"
        case (nil, nil): return "Not set up"
        default: return "No answer"
        }
    }

    /// Expiry reminders: asked for here, where the date they're about is on screen, never at launch.
    @ViewBuilder
    private var reminderRow: some View {
        switch reminders {
        case .notDetermined?:
            Button {
                Task { reminders = await ExpiryReminders.enable() }
            } label: {
                Label {
                    Text("Remind Me Before It Expires")
                } icon: {
                    Image(systemName: "bell").foregroundStyle(.secondary)
                }
            }
            .tint(.primary)
        case .authorized?, .provisional?, .ephemeral?:
            LabeledContent("Reminders", value: "14 and 3 days before")
        case .denied?:
            LabeledContent("Reminders", value: "Notifications are off for Lantern")
        default:
            EmptyView()
        }
    }

    private func importModel(_ url: URL, move: Bool) {
        importing = url.lastPathComponent
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try ModelImport.importFile(at: url, move: move) }
            }.value
            finishImport(outcome)
        }
    }

    private func finishImport(_ outcome: Result<CatalogModel, Error>) {
        importing = nil
        store.refresh()
        if case .failure(let error) = outcome { importError = error.localizedDescription }
    }

    private func checkMac() {
        checkingMac = true
        Task {
            let d = UserDefaults.standard
            let lanHost = MacLink.normalized(d.string(forKey: MacLink.lanKey) ?? MacLink.defaultLAN)
            let tailHost = MacLink.normalized(d.string(forKey: MacLink.tailnetKey) ?? MacLink.defaultTailnet)
            async let l = MacLink.tags(lanHost)
            async let t = MacLink.tags(tailHost)
            let (lr, tr) = await (l, t)
            lan = lanHost == nil ? nil : lr != nil
            tailnet = tailHost == nil ? nil : tr != nil
            checkingMac = false
        }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Orange icon, primary text: orange text is hard to read on white.
private struct OrangeIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.foregroundStyle(.orange)
            configuration.title
        }
    }
}

enum Readiness {
    /// TestFlight builds stop launching 90 days after upload. The build date is stamped into
    /// Info.plist at build time; nil when installed from Xcode.
    static var expiry: Date? {
        guard isTestFlight, let built = Bundle.main.object(forInfoDictionaryKey: "LanternBuildDate") as? Date else { return nil }
        return built.addingTimeInterval(90 * 86_400)
    }

    /// Set at launch from StoreKit: TestFlight installs run in the sandbox environment. Observable,
    /// since it's only known after the first render.
    static var isTestFlight: Bool { TestFlightState.shared.isTestFlight }

    @Observable
    final class TestFlightState {
        static let shared = TestFlightState()
        fileprivate(set) var isTestFlight = false
    }

    static func checkEnvironment() async {
        #if DEBUG
        // `-testflight`: show the expiry and reminders in a build from Xcode.
        if ProcessInfo.processInfo.arguments.contains("-testflight") {
            TestFlightState.shared.isTestFlight = true
            return
        }
        #endif
        if case .verified(let t)? = try? await AppTransaction.shared {
            TestFlightState.shared.isTestFlight = t.environment == .sandbox
        }
    }

    static var expiresSoon: Bool { expiry.map { $0.timeIntervalSinceNow < 30 * 86_400 } ?? false }

    /// Settings needs a look (the gear is badged) only when there's no model to answer with at all or
    /// this build is about to stop launching. A model not downloaded yet is just a choice; Apple
    /// Intelligence, when it's on, is a model to answer with.
    static func needsAttention(store: ModelStore) -> Bool {
        (store.downloaded.isEmpty && !AppleStatus.current.isAvailable) || expiresSoon
    }
}

/// Local notifications 14 and 3 days before the build stops launching.
enum ExpiryReminders {
    private static let ids = ["expiry-14", "expiry-3"]

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for permission (from Readiness's button) and schedules.
    static func enable() async -> UNAuthorizationStatus {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await reschedule()
        return await status()
    }

    /// Replaces the pending reminders with ones for this build. Does nothing without permission.
    static func reschedule() async {
        let center = UNUserNotificationCenter.current()
        guard [.authorized, .provisional].contains(await status()) else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        guard let expiry = Readiness.expiry else { return }
        for (id, days) in zip(ids, [14, 3]) {
            let date = expiry.addingTimeInterval(-Double(days) * 86_400)
            guard date > .now else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Update Lantern"
            content.body = "This build stops launching in \(days) days. Install the latest from TestFlight."
            content.sound = .default
            let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(
                identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
            try? await center.add(request)
        }
    }
}
