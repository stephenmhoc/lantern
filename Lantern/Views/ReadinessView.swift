import LlamaKit
import StoreKit
import SwiftUI

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

    var body: some View {
        List {
            Section {
                Label(Readiness.summary(store: store, engine: engine), systemImage: Readiness.isReady(store: store, engine: engine)
                      ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(Readiness.isReady(store: store, engine: engine) ? .green : .orange)
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
                    LabeledContent("Stops launching", value: expiry.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(Readiness.expiresSoon ? .orange : .primary)
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
            case .success(let s): Label(String(format: "Works · %.1f tok/s", s.tokensPerSecond), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            case .failure(let e): Label(e.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case nil: Label("On this device", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func macRow(_ title: String, ok: Bool?) -> some View {
        LabeledContent(title) {
            switch ok {
            case true?: Label("Answers", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Label("No answer", systemImage: "xmark.circle").foregroundStyle(.secondary)
            case nil: Text(checkingMac ? "Checking…" : "Not set up").foregroundStyle(.secondary)
            }
        }
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

    /// Set at launch from StoreKit: TestFlight installs run in the sandbox environment.
    private(set) static var isTestFlight = false

    static func checkEnvironment() async {
        if case .verified(let t)? = try? await AppTransaction.shared { isTestFlight = t.environment == .sandbox }
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
