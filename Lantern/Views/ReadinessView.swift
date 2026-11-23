import LlamaKit
import StoreKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// "Will Lantern work without internet?" Models on this device (get, test, delete), the
/// Mac on each route, and when this build stops launching.
struct ReadinessView: View {
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var tests: [String: Result<GenerationStats, Error>] = [:]
    @State private var deleting: CatalogModel?
    @State private var lan: Bool?
    @State private var tailnet: Bool?
    @State private var checkingMac = false
    @State private var choosingFile = false
    @State private var importing: String?
    @State private var importError: String?
    @State private var dropTargeted = false
    @State private var reminders: UNAuthorizationStatus?

    var body: some View {
        List {
            Section {
                let ready = Readiness.isReady(store: store, engine: engine)
                // Coloured icon, primary text: green or orange text is hard to read on white.
                Label {
                    Text(Readiness.summary(store: store, engine: engine)).font(.headline)
                } icon: {
                    Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ready ? .green : .orange)
                }
            }

            Section {
                ForEach(CatalogModel.all) { row($0) }
            } header: {
                Text("On this device")
            } footer: {
                Text("""
                    Download while you have internet. Without it, copy the file from your Mac: in Finder, \
                    select this device, then Files, and drag it onto Lantern, using the name shown.
                    """)
            }

            Section {
                if let importing {
                    HStack {
                        ProgressView()
                        Text("Copying \(importing)…").padding(.leading, 6)
                    }
                } else {
                    Button("Import a Model File…", systemImage: "square.and.arrow.down") { choosingFile = true }
                }
            } footer: {
                Text("Already have one of the files above, from your Mac or the Files app? Import it, or drag it onto this list.")
            }

            Section {
                macRow("Home network", ok: lan)
                macRow("Tailnet", ok: tailnet)
                Button(checkingMac ? "Checking…" : "Check the Mac", action: checkMac).disabled(checkingMac)
            } header: {
                Text("Mac")
            } footer: {
                Text("With the internet down, the home network still works if the router and Mac have power.")
            }

            Section("This app") {
                LabeledContent("Free storage", value: ByteCountFormatter.string(fromByteCount: ModelStore.freeBytes, countStyle: .file))
                if let expiry = Readiness.expiry {
                    LabeledContent {
                        Text(expiry.formatted(date: .abbreviated, time: .omitted))
                    } label: {
                        HStack(spacing: 6) {
                            if Readiness.expiresSoon {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Text("Stops launching")
                        }
                    }
                    reminderRow
                } else {
                    LabeledContent("Installed from Xcode", value: "No TestFlight expiry")
                }
            }
        }
        .navigationTitle("Readiness")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { store.refresh() }
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
        .confirmationDialog(
            "Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible, presenting: deleting
        ) { model in
            Button("Delete", role: .destructive) {
                if engine.loadedModel == model { engine.unload() }
                store.delete(model)
            }
        } message: { model in
            Text("Frees \(size(model.bytes)). Getting it back needs internet or your Mac.")
        }
    }

    @ViewBuilder
    private func row(_ model: CatalogModel) -> some View {
        let state = store.states[model.id] ?? .missing
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(model.name, systemImage: model.tier.symbol).font(.headline)
                if CatalogModel.preferred(for: model.tier, downloaded: []) == model {
                    Text("Best fit").font(.caption).padding(.horizontal, 6).background(.tint.opacity(0.2), in: .capsule)
                }
            }
            Text(model.detail).font(.callout).foregroundStyle(.secondary)
            Text("\(model.filename) · \(size(model.bytes))")
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            switch state {
            case .missing:
                Button("Download") { store.download(model) }.buttonStyle(.borderedProminent)
            case .downloading(let p):
                HStack {
                    ProgressView(value: p).accessibilityLabel("Downloading")
                    Text("\(Int(p * 100))%").font(.caption.monospacedDigit())
                    Button("Cancel") { store.cancel(model) }
                }
            case .incomplete(let bytes):
                Label("Incomplete: \(size(bytes)) of \(size(model.bytes)). If it's still copying, wait.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Delete", role: .destructive) { deleting = model }
            case .failed(let message):
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Retry") { store.download(model) }
                }
            case .ready:
                HStack {
                    testResult(model)
                    Spacer()
                    Button("Test") { test(model) }.disabled(engine.isBusy)
                    Button("Delete", role: .destructive) { deleting = model }.disabled(engine.isBusy)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func testResult(_ model: CatalogModel) -> some View {
        if engine.testing == model {
            Label("Testing…", systemImage: "hourglass")
        } else {
            switch tests[model.id] {
            case .success(let s):
                Label {
                    Text(String(format: "Works · %.1f tok/s", s.tokensPerSecond))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failure(let e): Label(e.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case nil: Label("On this device", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func macRow(_ title: String, ok: Bool?) -> some View {
        LabeledContent(title) {
            // An HStack, not a Label: a Label here makes the row several lines tall.
            switch ok {
            case true?:
                HStack(spacing: 6) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text("Answers") }
            case false?:
                HStack(spacing: 6) { Image(systemName: "xmark.circle"); Text("No answer") }.foregroundStyle(.secondary)
            case nil: Text(checkingMac ? "Checking…" : "Not set up").foregroundStyle(.secondary)
            }
        }
    }

    /// Expiry reminders: asked for here, where the date they're about is on screen, never at launch.
    @ViewBuilder
    private var reminderRow: some View {
        switch reminders {
        case .notDetermined?:
            Button("Remind Me Before It Expires", systemImage: "bell") {
                Task { reminders = await ExpiryReminders.enable() }
            }
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

    private func test(_ model: CatalogModel) {
        Task {
            do { tests[model.id] = .success(try await engine.test(model)) } catch { tests[model.id] = .failure(error) }
        }
    }

    private func checkMac() {
        checkingMac = true
        Task {
            let d = UserDefaults.standard
            let lanHost = MacLink.normalized(d.string(forKey: MacLink.lanKey) ?? MacLink.defaultLAN)
            let tailHost = MacLink.normalized(d.string(forKey: MacLink.tailnetKey) ?? "")
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

    /// Ready means a Fast model and the best-fitting Smart model are complete on this device and the
    /// build isn't about to expire. The Mac is a bonus.
    static func isReady(store: ModelStore, engine: Engine) -> Bool {
        missing(store: store, engine: engine).isEmpty && !expiresSoon
    }

    static func summary(store: ModelStore, engine: Engine) -> String {
        if expiresSoon, let expiry { return "This build stops launching \(expiry.formatted(.relative(presentation: .named))). Install the latest from TestFlight." }
        let missing = missing(store: store, engine: engine)
        return missing.isEmpty ? "Ready to work offline." : "Not ready: get \(missing.joined(separator: " and "))."
    }

    private static func missing(store: ModelStore, engine: Engine) -> [String] {
        [Mode.fast, .smart].compactMap { mode in
            guard let model = CatalogModel.preferred(for: mode, downloaded: store.downloaded) else { return nil }
            return store.states[model.id] == .ready ? nil : model.name
        }
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
