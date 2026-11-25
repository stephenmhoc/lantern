import LlamaKit
import SwiftUI

/// The self-test's last result per model id, kept by the Models page so its rows and detail pages agree.
typealias ModelTestResults = [String: Result<GenerationStats, Error>]

extension Readiness {
    /// A model file's state, as the Models page shows it.
    static func state(_ model: CatalogModel, store: ModelStore) -> ModelStore.State {
        #if DEBUG
        if let state = debugStates[model.id] { return state }
        #endif
        return store.states[model.id] ?? .missing
    }

    /// "2.6 GB", "1 GB": one decimal at most, like the App Store.
    static func size(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(0...1))) + " GB"
    }

    /// `ModelStore` reports an interrupted download it can resume as "Paused. Retry resumes it."
    static func isPaused(_ message: String) -> Bool { message.hasPrefix("Paused") }

    /// One short status: "Downloaded", "Downloading 42%", "Needs 8 GB"…
    static func status(of model: CatalogModel, store: ModelStore, engine: Engine,
                       test: Result<GenerationStats, Error>?) -> String {
        if engine.testing == model { return "Testing…" }
        switch state(model, store: store) {
        case .ready:
            switch test {
            case .success(let s)?: return String(format: "Works, %.1f tok/s", s.tokensPerSecond)
            case .failure?: return "Test failed"
            case nil: return "Downloaded"
            }
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .incomplete: return "Incomplete"
        case .failed(let message): return isPaused(message) ? "Paused" : message
        case .missing:
            if !CatalogModel.fits(model) { return "Needs \(model.minDeviceGB) GB" }
            return "Not downloaded"
        }
    }

    static func runTest(_ model: CatalogModel, engine: Engine, into tests: Binding<ModelTestResults>) {
        Task {
            do { tests.wrappedValue[model.id] = .success(try await engine.test(model)) } catch { tests.wrappedValue[model.id] = .failure(error) }
        }
    }

    #if DEBUG
    /// `-readinessState <id>=downloading:0.42` (also `missing`, `incomplete`, `failed:<message>`),
    /// repeatable: shows a model in that state on the Models page, for screenshots. Nothing is downloaded.
    static let debugStates: [String: ModelStore.State] = {
        let args = ProcessInfo.processInfo.arguments
        var states: [String: ModelStore.State] = [:]
        for (i, arg) in args.enumerated() where arg == "-readinessState" && args.indices.contains(i + 1) {
            let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            switch value[0] {
            case "downloading": states[parts[0]] = .downloading(Double(value.last ?? "") ?? 0.42)
            case "incomplete": states[parts[0]] = .incomplete(1_000_000_000)
            case "failed": states[parts[0]] = .failed(value.count > 1 ? value[1] : "Paused. Retry resumes it.")
            case "missing": states[parts[0]] = .missing
            default: break
            }
        }
        return states
    }()
    #endif
}

// MARK: - Row

/// One model on the Models page: icon, name, "2.6 GB · Downloaded", and one control. Tapping it
/// opens the detail page; VoiceOver reads it as one element with the actions as custom actions.
struct ModelRow: View {
    let model: CatalogModel
    var title: String?
    var symbol: String?
    var test: Result<GenerationStats, Error>?
    /// Opens the detail page; nil for a row that is already on it (image reading).
    var open: (() -> Void)?
    var runTest: (() -> Void)?
    let delete: (CatalogModel) -> Void
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 28

    private var name: String { title ?? model.name }
    private var state: ModelStore.State { Readiness.state(model, store: store) }

    private var status: String {
        var status = Readiness.status(of: model, store: store, engine: engine, test: test)
        // The image reading file's download shows here too, so it isn't missed on the main page.
        if open != nil, let projector = model.projector {
            switch Readiness.state(projector, store: store) {
            case .downloading(let p): status += " · Image reading \(Int(p * 100))%"
            case .failed(let m): status += Readiness.isPaused(m) ? " · Image reading paused" : " · Image reading failed"
            default: break
            }
        }
        return status
    }

    private var canDelete: Bool {
        switch state {
        case .ready, .incomplete: !engine.isBusy
        default: false
        }
    }

    var body: some View {
        let large = typeSize.isAccessibilitySize
        let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                Image(systemName: symbol ?? model.tier.symbol)
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(width: iconWidth)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    // A model not downloaded yet shows only its size: its Download button says the rest.
                    Text(state == .missing && status == "Not downloaded"
                         ? Readiness.size(model.bytes) : "\(Readiness.size(model.bytes)) · \(status)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !large { Spacer(minLength: 8) }
            HStack(spacing: 12) {
                // At accessibility sizes the checkmark would sit alone on its own line; the status says it.
                if !(large && state == .ready && engine.testing != model) { ModelControl(model: model) }
                if open != nil, !large {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture { open?() }
        .contextMenu { menu }
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button("Delete", systemImage: "trash") { delete(model) }.tint(.red)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(Readiness.size(model.bytes)), \(status)")
        .accessibilityAddTraits(open != nil ? .isButton : [])
        .accessibilityAction { open?() }
        .accessibilityActions { menu }
    }

    /// The context menu, also the row's VoiceOver actions.
    @ViewBuilder
    private var menu: some View {
        switch state {
        case .missing:
            Button("Download", systemImage: "arrow.down.circle") { store.download(model) }
        case .downloading:
            Button("Stop Download", systemImage: "stop.circle") { store.cancel(model) }
        case .failed(let message):
            Button(Readiness.isPaused(message) ? "Resume Download" : "Retry Download", systemImage: "arrow.clockwise") { store.download(model) }
            Button("Cancel Download", systemImage: "xmark.circle") { store.cancel(model) }
        case .ready:
            if let runTest, !model.isExtra {
                Button("Test", systemImage: "checkmark.circle", action: runTest).disabled(engine.isBusy)
            }
        case .incomplete:
            EmptyView()
        }
        if let open { Button("Details", systemImage: "info.circle", action: open) }
        if canDelete {
            Button("Delete", systemImage: "trash", role: .destructive) { delete(model) }
        }
    }
}

/// A row's one trailing control: Download (or Resume), a progress ring that stops the download,
/// a spinner while testing, or a checkmark once downloaded.
struct ModelControl: View {
    let model: CatalogModel
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @ScaledMetric(relativeTo: .body) private var ring: CGFloat = 26

    var body: some View {
        switch Readiness.state(model, store: store) {
        case .missing:
            Button("Download") { store.download(model) }
                .modelButton()
                .accessibilityLabel("Download \(model.name)")
        case .downloading(let p):
            Button { store.cancel(model) } label: {
                ProgressRing(progress: p).frame(width: ring, height: ring)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop downloading \(model.name)")
            .accessibilityValue("\(Int(p * 100)) percent")
        case .failed(let message):
            Button(Readiness.isPaused(message) ? "Resume" : "Retry") { store.download(model) }
                .modelButton()
        case .incomplete:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
        case .ready:
            if engine.testing == model {
                ProgressView()
            } else {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
    }
}

/// The App Store's download ring: amber progress around a stop square.
struct ProgressRing: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(.quaternary, lineWidth: side * 0.1)
                Circle()
                    .trim(from: 0, to: max(progress, 0.02))
                    .stroke(.tint, style: StrokeStyle(lineWidth: side * 0.1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
                RoundedRectangle(cornerRadius: side * 0.06).fill(.tint).frame(width: side * 0.32, height: side * 0.32)
            }
            .frame(width: side, height: side)
        }
    }
}

extension View {
    /// The small capsule a row's Download or Resume button uses, like the App Store's Get.
    func modelButton() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small).fontWeight(.semibold)
    }

    /// Asks before deleting a model file, then unloads it if it's loaded and deletes it.
    func confirmsModelDeletion(_ model: Binding<CatalogModel?>) -> some View {
        modifier(DeleteModelDialog(model: model))
    }
}

private struct DeleteModelDialog: ViewModifier {
    @Binding var model: CatalogModel?
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete \(model?.name ?? "")?", isPresented: Binding(get: { model != nil }, set: { if !$0 { model = nil } }),
            titleVisibility: .visible, presenting: model
        ) { model in
            Button("Delete", role: .destructive) {
                if engine.loadedModel == model { engine.unload() }
                store.delete(model)
            }
        } message: { model in
            Text("Frees \(Readiness.size(model.bytes)). Getting it back needs internet or your Mac.")
        }
    }
}

#if DEBUG
/// `-readinessScroll`: scrolls a Models page to its end a second after it opens, for screenshots.
struct DebugScroll: ViewModifier {
    let to: String

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.task {
                guard ProcessInfo.processInfo.arguments.contains("-readinessScroll") else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo(to, anchor: .top)
            }
        }
    }
}
#endif

// MARK: - Detail

/// Everything about one model: what it is, its file, whether it fits this device, image reading,
/// the self-test and Delete.
struct ModelDetailView: View {
    let model: CatalogModel
    @Binding var tests: ModelTestResults
    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @State private var deleting: CatalogModel?

    var body: some View {
        let state = Readiness.state(model, store: store)
        List {
            Section {
                Text(model.detail)
                LabeledContent {
                    ModelControl(model: model)
                } label: {
                    Text(Readiness.status(of: model, store: store, engine: engine, test: nil))
                }
                if case .downloading(let p) = state {
                    ProgressView(value: p).accessibilityLabel("Downloading")
                }
            } footer: {
                if case .incomplete(let bytes) = state {
                    Text("\(Readiness.size(bytes)) of \(Readiness.size(model.bytes)) is here. If it's still copying, wait; otherwise delete it and download again.")
                } else if case .failed(let message) = state, !Readiness.isPaused(message) {
                    Text("The download stopped. Retry starts it again.")
                }
            }

            Section {
                LabeledContent("Size", value: Readiness.size(model.bytes))
                LabeledContent("File") {
                    Text(model.filename).font(.footnote.monospaced()).textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Made for", value: "\(model.minDeviceGB) GB devices")
                LabeledContent("This device", value: MemoryStats.gb(MemoryStats.deviceBytes))
            } header: {
                Text("Details")
            } footer: {
                if CatalogModel.fits(model) {
                    Text("Without internet, copy the file from your Mac: in Finder, select this device, then Files, and drag it onto Lantern, using the name above.")
                } else {
                    Text("This device has less memory than \(model.name) needs. It may run slowly or not at all.")
                }
            }

            if let projector = model.projector {
                Section {
                    ModelRow(model: projector, title: "Image reading", symbol: "photo", delete: { deleting = $0 })
                } footer: {
                    Text("Lets \(model.name) see photos and screenshots you attach. It's loaded beside the model only when a chat has an image.")
                }
            }

            if state == .ready {
                Section {
                    Button("Test \(model.name)") { Readiness.runTest(model, engine: engine, into: $tests) }
                        .disabled(engine.isBusy)
                    testResult
                } footer: {
                    Text("Loads the model and writes a short answer, to check it works on this device.")
                }
            }

            deleteSection(state: state)
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .modifier(DebugScroll(to: "delete"))
        #endif
        .confirmsModelDeletion($deleting)
    }

    @ViewBuilder
    private var testResult: some View {
        if engine.testing == model {
            Label("Testing…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else {
            switch tests[model.id] {
            case .success(let s)?:
                Label(String(format: "Works, %.1f tokens a second", s.tokensPerSecond), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .failure(let error)?:
                Label(error.localizedDescription, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func deleteSection(state: ModelStore.State) -> some View {
        let canDeleteModel = state == .ready || { if case .incomplete = state { true } else { false } }()
        let projectorReady = model.projector.map { Readiness.state($0, store: store) == .ready } ?? false
        if canDeleteModel || projectorReady {
            Section {
                if canDeleteModel {
                    Button("Delete \(model.name)", role: .destructive) { deleting = model }
                }
                if projectorReady, let projector = model.projector {
                    Button("Delete Image Reading", role: .destructive) { deleting = projector }
                }
            }
            .disabled(engine.isBusy)
            .id("delete")
        }
    }
}

// MARK: - Apple Intelligence

extension Readiness {
    static func runAppleTest(engine: Engine, into tests: Binding<ModelTestResults>) {
        Task {
            do {
                tests.wrappedValue[AppleModelRow.testKey] = .success(try await engine.testApple())
            } catch {
                tests.wrappedValue[AppleModelRow.testKey] = .failure(error)
            }
        }
    }

    /// "Built in", "Works, 30.2 tok/s", "Turn on in Settings"…
    static func appleStatus(engine: Engine, test: Result<GenerationStats, Error>?) -> String {
        if engine.testingApple { return "Testing…" }
        let status = engine.apple.status
        guard status.isAvailable else { return status.short }
        switch test {
        case .success(let s)? where s.generatedTokens > 0: return String(format: "Works, %.1f tok/s", s.tokensPerSecond)
        case .success?: return "Works"
        case .failure?: return "Test failed"
        case nil: return status.short
        }
    }
}

/// Apple Intelligence's model on the Models page: no file, size or download, just whether the
/// system has it ready. Tapping opens its page.
struct AppleModelRow: View {
    /// Its entry in `ModelTestResults`, and `-readinessDetail apple`.
    static let testKey = "apple"
    var test: Result<GenerationStats, Error>?
    let open: () -> Void
    let runTest: () -> Void
    @Environment(Engine.self) private var engine
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 28

    var body: some View {
        let status = Readiness.appleStatus(engine: engine, test: test)
        HStack(spacing: 12) {
            Image(systemName: Mode.apple.symbol)
                .font(.title3).foregroundStyle(.secondary)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(Mode.apple.title)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if engine.testingApple {
                ProgressView()
            } else if engine.apple.status.isAvailable, !typeSize.isAccessibilitySize {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            if !typeSize.isAccessibilitySize {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Mode.apple.title), \(status)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityActions { menu }
    }

    @ViewBuilder
    private var menu: some View {
        if engine.apple.status.isAvailable {
            Button("Test", systemImage: "checkmark.circle", action: runTest).disabled(engine.isBusy)
        }
        Button("Details", systemImage: "info.circle", action: open)
    }
}

/// What Apple Intelligence's model is, whether it's ready, and its test.
struct AppleModelDetailView: View {
    @Binding var tests: ModelTestResults
    @Environment(Engine.self) private var engine

    var body: some View {
        let status = engine.apple.status
        List {
            Section {
                Text("Apple's model, built into the system. Nothing to download, and it works without internet. It holds less of a chat than the others, and doesn't think before it answers.")
                LabeledContent("Status", value: status.short)
            } footer: {
                if !status.isAvailable { Text(status.explanation) }
            }

            Section("Details") {
                LabeledContent("Runs on", value: "This device, outside Lantern")
                LabeledContent("Context", value: "\(engine.apple.contextSize.formatted()) tokens")
                LabeledContent("Sees images", value: engine.apple.seesImages ? "Yes" : "No")
            }

            if status.isAvailable {
                Section {
                    Button("Test \(Mode.apple.title)") { Readiness.runAppleTest(engine: engine, into: $tests) }
                        .disabled(engine.isBusy)
                    testResult
                } footer: {
                    Text("Writes a short answer, to check it works on this device.")
                }
            }
        }
        .navigationTitle(Mode.apple.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var testResult: some View {
        if engine.testingApple {
            Label("Testing…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else {
            switch tests[AppleModelRow.testKey] {
            case .success(let s)? where s.generatedTokens > 0:
                Label(String(format: "Works, %.1f tokens a second", s.tokensPerSecond), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .success?:
                Label("Works", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .failure(let error)?:
                Label(error.localizedDescription, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
        }
    }
}
