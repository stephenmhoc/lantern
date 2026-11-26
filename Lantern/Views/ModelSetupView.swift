import SwiftUI
import UIKit

/// This device's model: the one place it's downloaded and removed. The welcome on first launch, a
/// sheet from a chat that needs it, and the model's page in Settings are all this view.
///
/// Until a model is here it's a few words and one control that follows the download (get it, its
/// progress with Pause, Resume, Try Again). Once one is, it says what the model is and how much
/// room it takes, and offers a better one if this device can run it: offered, never forced, and
/// the model already here keeps answering until the new one has arrived. There's nothing to
/// choose: the model is the best this device runs.
struct ModelSetupView: View {
    enum Style {
        /// First launch: says what Lantern is, and ends with Start Chatting.
        case welcome
        /// From a chat: just the model, with Done.
        case sheet
        /// Pushed in Settings.
        case page
    }
    let style: Style

    @Environment(Engine.self) private var engine
    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingDelete = false
    @State private var deleting = false
    /// The welcome's points come in one after another.
    @State private var appeared = false

    private var device: String { Device.name }
    /// What the page is about: the model answering, or the one to get.
    private var model: CatalogModel { store.isReady ? store.model : store.best }
    private var showsControls: Bool { style == .welcome || !store.isReady || store.hasUpgrade }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                if style == .welcome {
                    points
                } else if store.isReady {
                    details
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, style == .welcome ? 56 : 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsControls {
                controls
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: phase)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if style == .sheet {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .confirmationDialog("Remove \(store.model.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove Model", role: .destructive) {
                deleting = true
                Task {
                    await engine.deleteModel()
                    deleting = false
                }
            }
        } message: {
            Text("This frees \(Self.size(store.model.bytes)). Your chats stay, and you can download it again whenever you like. Until then Lantern can't answer on this \(device).")
        }
        .onChange(of: store.model) { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        .onChange(of: store.isReady) { _, ready in
            if ready { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
        .onAppear { appeared = true }
    }

    // MARK: - What it is

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "flame.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 88, height: 88)
                .background(.tint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: .circle)
                .accessibilityHidden(true)
            Text(style == .welcome ? "Welcome to Lantern" : model.name)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(style == .welcome
                 ? "An assistant that runs on this \(device), and keeps working when the internet doesn't."
                 : "Lantern's model on this \(device). It writes, explains and summarizes, reads the files and photos you attach, and needs no connection.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: 22) {
            point(0, "lock.fill", "Private", "Your chats are answered and kept on this \(device).")
            point(1, "wifi.slash", "Always There", "Once its model is here, Lantern needs no connection at all.")
            point(2, "desktopcomputer", "Your Mac, Too", "Pair a Mac later to use its larger model from anywhere.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func point(_ index: Int, _ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        // One after another, rising into place; with Reduce Motion they're simply there.
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 14)
        .animation(reduceMotion ? nil : .spring(duration: 0.55, bounce: 0.15).delay(0.25 + 0.12 * Double(index)), value: appeared)
    }

    /// Once the model is here: what it takes up, and the way to remove it.
    private var details: some View {
        VStack(spacing: 0) {
            LabeledContent("Made By", value: "Google")
                .padding(.horizontal, 16).frame(minHeight: 48)
            Divider().padding(.leading, 16)
            LabeledContent("Size on This \(device)", value: Self.size(store.model.bytes))
                .padding(.horizontal, 16).frame(minHeight: 48)
            Divider().padding(.leading, 16)
            LabeledContent("Reads Photos", value: store.hasProjector ? "Yes" : "Still Downloading")
                .padding(.horizontal, 16).frame(minHeight: 48)
            if style == .page {
                Divider().padding(.leading, 16)
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Text("Remove Model").frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).frame(minHeight: 48).contentShape(.rect)
                }
                .disabled(deleting || engine.isBusy)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20, style: .continuous))
    }

    // MARK: - The one control

    /// Which control shows; the progress within a phase doesn't animate the layout.
    private enum Phase { case missing, downloading, paused, failed, ready }

    private var phase: Phase {
        switch store.state {
        case .missing: .missing
        case .downloading: .downloading
        case .paused: .paused
        case .failed: .failed
        case .ready: .ready
        }
    }

    @ViewBuilder
    private var controls: some View {
        let best = store.best
        VStack(spacing: 12) {
            if store.hasUpgrade {
                VStack(spacing: 4) {
                    Text("A better model is available for this \(device)").font(.headline)
                    Text("\(best.name) gives better answers. \(store.model.name) keeps answering until it's here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
            }
            switch store.state {
            case .missing:
                primary("Download \(best.name)") { store.download() }
                caption("\(Self.size(best.bytes)), once. Wi‑Fi is best.")
            case .downloading(let fraction):
                progress(fraction, label: "Downloading \(best.name)")
                HStack {
                    caption("You can leave Lantern while it downloads.")
                    Spacer(minLength: 12)
                    Button("Pause") { store.pause() }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .tint(.primary)
                }
            case .paused(let fraction):
                progress(fraction, label: "Paused")
                primary("Resume Download") { store.download() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                primary("Try Again") { store.download() }
                caption("It carries on from where it stopped.")
            case .ready:
                Label {
                    Text("\(best.name) is ready")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.headline)
                .symbolEffect(.bounce, value: store.isReady)
                primary("Start Chatting") { dismiss() }
            }
            if phase == .paused || phase == .failed {
                Button("Cancel Download", role: .destructive) { store.cancelDownload() }.frame(minHeight: 44)
            } else if style == .welcome, phase != .ready {
                Button(phase == .downloading ? "Continue" : store.isReady ? "Keep \(store.model.name)" : "Not Now") { dismiss() }
                    .font(.body.weight(.medium))
                    .frame(minHeight: 44)
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
                .modifier(ProminentLabel())
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func progress(_ fraction: Double, label: String) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: fraction)
            HStack {
                Text(label)
                Spacer()
                Text("\(Self.size(Int64(fraction * Double(store.best.bytes)))) of \(Self.size(store.best.bytes))")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
