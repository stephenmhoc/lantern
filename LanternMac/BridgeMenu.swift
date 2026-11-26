import SwiftUI

/// The menu bar panel: whether devices can reach this Mac, its models, the paired devices, and
/// pairing another.
struct BridgeMenu: View {
    @Environment(BridgeController.self) private var bridge
    @Environment(\.openWindow) private var openWindow
    @State private var fixingOllama = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if bridge.ollamaIsExposed { ollamaWarning }
            if let status = bridge.status {
                models(status)
                devices(status)
            }
            Button {
                openWindow(id: PairingView.windowID)
                NSApp.activate()
            } label: {
                Label("Pair a Device…", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(bridge.state != .running)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .task { await bridge.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.max.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(bridge.status?.name ?? "Lantern").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        switch bridge.state {
        case .starting: return "Starting…"
        case .failed(let reason): return reason
        case .running:
            guard let status = bridge.status else { return "Starting…" }
            if status.backends.isEmpty { return "No model servers running. Open Ollama or LM Studio." }
            let servers = ListFormatter.localizedString(byJoining: status.backends.map(\.name))
            return "Serving \(servers) to your devices, encrypted"
        }
    }

    private var ollamaWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Ollama is open to your network", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Anything on your Wi-Fi can use it, unencrypted. Your devices only need Lantern's encrypted connection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(fixingOllama ? "Restarting Ollama…" : "Keep Ollama on This Mac") {
                fixingOllama = true
                Task {
                    await bridge.makeOllamaPrivate()
                    fixingOllama = false
                }
            }
            .disabled(fixingOllama)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private func models(_ status: BridgeController.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if status.models.isEmpty {
                Text("None yet").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(status.models) { model in
                ModelRow(model: model, kept: status.keepLoaded.contains(model.id))
            }
        }
    }

    private func devices(_ status: BridgeController.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired Devices").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if status.devices.isEmpty {
                Text("None yet. Pair your iPhone or iPad to use these models from it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(status.devices) { device in
                HStack {
                    Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Text(lastSeen(device)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await bridge.remove(device) }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Unpair \(device.name). It will have to pair again to use this Mac.")
                }
            }
        }
    }

    private func lastSeen(_ device: BridgeController.Device) -> String {
        guard let seen = device.lastSeen, seen > .distantPast else { return "Paired \(device.paired.formatted(.relative(presentation: .named)))" }
        return "Last used \(seen.formatted(.relative(presentation: .named)))"
    }

    private var footer: some View {
        @Bindable var bridge = bridge
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Open at Login", isOn: $bridge.opensAtLogin)
            HStack {
                if case .failed = bridge.state {
                    Button("Restart") { bridge.restart() }
                }
                Spacer()
                Button("Quit Lantern") { NSApp.terminate(nil) }
            }
        }
    }
}

private struct ModelRow: View {
    @Environment(BridgeController.self) private var bridge
    let model: BridgeController.Model
    let kept: Bool

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.id).lineLimit(1).truncationMode(.middle)
                Text(details).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.lantern.backend == "ollama" {
                Button {
                    Task { await bridge.keepLoaded(model, !kept) }
                } label: {
                    Image(systemName: kept ? "pin.fill" : "pin")
                        .foregroundStyle(kept ? Color.orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(kept ? "Kept loaded. Click to let Ollama unload it when it's idle."
                           : "Keep it loaded, so the first question doesn't wait for it to load.")
            }
        }
    }

    private var details: String {
        var parts = [model.owned_by]
        if let size = model.lantern.size, size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        let can = [model.lantern.vision ? "images" : nil, model.lantern.tools ? "web search" : nil,
                   model.lantern.thinking ? "thinking" : nil].compactMap { $0 }
        if !can.isEmpty { parts.append(ListFormatter.localizedString(byJoining: can)) }
        return parts.joined(separator: " · ")
    }
}
