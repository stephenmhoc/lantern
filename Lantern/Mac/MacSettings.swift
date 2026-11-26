#if targetEnvironment(macCatalyst)
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings' first sections on a Mac: what it does (`MacRole`). One that serves shows how Inkling
/// is doing (Splash, through the bridge), pairs devices and lists them, and keeps the Tailscale
/// client that lets them in from away; one that doesn't shows the Mac it uses.
struct MacRoleSections: View {
    @Environment(MacLink.self) private var mac
    @AppStorage(MacRole.key) private var storedRole = ""
    @State private var server = MacServer.shared
    @State private var switching: MacRole?
    @State private var unpairing: MacServer.PairedDevice?

    private var role: MacRole? { MacRole(rawValue: storedRole) ?? MacRole.current }

    var body: some View {
        Group {
            if role == .serve { serving } else { client }
        }
        .confirmationDialog(
            switching == .client ? "Stop Serving Inkling?" : "Serve Inkling from This Mac?",
            isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
            titleVisibility: .visible, presenting: switching
        ) { next in
            Button(next == .client ? "Stop Serving" : "Serve Inkling") {
                Task { await MacRole.choose(next, link: mac) }
            }
        } message: { next in
            Text(next == .client
                 ? "Your iPhones and iPads can't use this Mac until it serves again. They stay paired."
                 : "This Mac stops using \(mac.computerName) and runs Inkling itself, at login and while Lantern is closed.")
        }
        .confirmationDialog(
            "Unpair \(unpairing?.name ?? "")?",
            isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
            titleVisibility: .visible, presenting: unpairing
        ) { device in
            Button("Unpair", role: .destructive) { Task { await server.remove(device) } }
        } message: { _ in
            Text("It can't use this Mac until it's paired again.")
        }
    }

    // MARK: - Serving

    @ViewBuilder private var serving: some View {
        Section {
            SplashRow(server: server)
            if server.state == .needsApproval {
                Button("Open Login Items…") { server.openLoginItems() }
            }
            NavigationLink("Pair a Device…", value: SettingsPage.pairDevice)
                .disabled(server.state != .running)
        } header: {
            Text("This Mac")
        } footer: {
            Text(server.state == .needsApproval
                 ? "Turn Lantern on in Login Items, and this Mac serves Inkling again."
                 : "This Mac serves Inkling to itself and to the devices paired with it, even while Lantern is closed.")
        }

        Section {
            if server.devices.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(server.devices) { device in
                LabeledContent {
                    Button("Unpair…") { unpairing = device }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(Self.seen(device)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Paired Devices")
        }

        TailscaleSection(server: server)

        Section {
            Button("Use Another Mac Instead…") { switching = .client }
        }
    }

    private static func seen(_ device: MacServer.PairedDevice) -> String {
        if let last = device.lastSeen, last > device.paired {
            return "Last used \(last.formatted(.relative(presentation: .named)))"
        }
        return "Paired \(device.paired.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: - Using another Mac

    @ViewBuilder private var client: some View {
        Section {
            NavigationLink(value: SettingsPage.mac) {
                LabeledContent {
                    Text(MacLink.isConfigured ? mac.computerName : "Not Paired")
                } label: {
                    Label("Mac", systemImage: "desktopcomputer")
                }
            }
        } header: {
            Text("Inkling")
        } footer: {
            Text("This Mac uses Inkling on a Mac that serves it, at home or over your tailnet.")
        }
        Section {
            Button("Serve Inkling from This Mac Instead…") { switching = .serve }
                .disabled(!MacRole.canServe)
        } footer: {
            if let why = MacRole.whyNot { Text(why) }
        }
    }
}

/// Pair a Device: a QR code holding a `lantern://pair` link (this Mac's addresses, its
/// certificate's fingerprint and a one-time code) for an iPhone's or iPad's camera, and a code to
/// type instead (on another Mac, or without a camera), which the device proves to this Mac found by
/// Bonjour. Each works once, for ten minutes; the device that pairs is shown when it does.
struct PairDeviceView: View {
    @State private var server = MacServer.shared
    @State private var pairing: MacServer.Pairing?
    @State private var typed: MacServer.Code?
    @State private var failure: String?
    /// The devices when this code was made, to notice the one that pairs with it.
    @State private var before: Set<String> = []
    @State private var copied = false

    private var newlyPaired: MacServer.PairedDevice? {
        guard pairing != nil else { return nil }
        return server.devices.first { !before.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let device = newlyPaired { paired(device) } else { code }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Pair a Device")
        .navigationBarTitleDisplayMode(.inline)
        .task { await makeCode() }
    }

    @ViewBuilder private var code: some View {
        Text("On your iPhone or iPad, point the camera at the code, or type the code below in Lantern under Settings › Mac.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
            if let pairing, let image = Self.qr(pairing.link) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .accessibilityLabel("QR code for pairing")
            } else if let failure {
                Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            } else {
                ProgressView()
            }
        }
        .frame(width: 200, height: 200)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1))
        }
        if let typed {
            VStack(spacing: 4) {
                Text("Or type this code").font(.callout).foregroundStyle(.secondary)
                Text(typed.code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .textSelection(.enabled)
                    .accessibilityLabel(typed.code.map(String.init).joined(separator: " "))
            }
            .padding(.top, 6)
        }
        if let pairing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date < pairing.expires {
                    Text("Each works once, for one device, until \(pairing.expires.formatted(date: .omitted, time: .shortened)).")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("These have expired. Make New Ones") { Task { await makeCode() } }
                }
            }
            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = pairing.link
                    copied = true
                }
                if let url = URL(string: pairing.link) {
                    ShareLink(item: url) { Label("Send…", systemImage: "square.and.arrow.up") }
                }
                Button("New Codes") { Task { await makeCode() } }
            }
            .padding(.top, 4)
        }
    }

    private func paired(_ device: MacServer.PairedDevice) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: device.id)
                .accessibilityHidden(true)
            Text("\(device.name) Is Paired").font(.title2.weight(.semibold))
            Text("Its chats with Inkling are encrypted all the way to this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Pair Another") { Task { await makeCode() } }
                .padding(.top, 4)
        }
        .padding(.vertical, 40)
    }

    private func makeCode() async {
        failure = nil
        copied = false
        before = Set(server.devices.map(\.id))
        do {
            async let link = server.newPairing()
            async let code = try? server.newCode()
            pairing = try await link
            typed = await code
        } catch {
            pairing = nil
            typed = nil
            failure = "Lantern couldn't make a code: the bridge isn't running yet."
        }
    }

    private static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
/// How Inkling is doing on this Mac, in a line: "Serving Inkling 2 Mini · drafter 2.4 tokens/step",
/// starting, or why it isn't, with what fixes it (install or update Splash, or try again).
private struct SplashRow: View {
    let server: MacServer
    @State private var restarting = false
    @State private var copied = false

    private var splash: MacServer.Splash? { server.status?.splash }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let command {
                    Text(command).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let command {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = command
                    copied = true
                }
            }
            if splash?.isFailed == true {
                Button(command == nil ? "Restart" : "Try Again") {
                    restarting = true
                    Task {
                        await server.restartSplash()
                        restarting = false
                    }
                }
                .disabled(restarting)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var model: String { MacLink.displayName(splash?.model ?? "Inkling 2 Mini") }

    private var title: String {
        switch server.state {
        case .needsApproval: return "Turned off in Login Items"
        case .failed(let message): return message
        case .off, .starting: return "Starting…"
        case .running: break
        }
        guard let splash else { return "Starting…" }
        if splash.isReady {
            if let step = splash.drafter?.tokensPerStep, step > 0 {
                return "Serving \(model) · drafter \(step.formatted(.number.precision(.fractionLength(1)))) tokens/step"
            }
            return "Serving \(model)"
        }
        if splash.isFailed {
            if missing { return "Install Splash to serve Inkling" }
            if outdated { return "Update Splash to serve Inkling" }
            return "Inkling isn't running"
        }
        return "Starting \(model)…"
    }

    /// Why it failed, or what Splash is doing while it starts (the first start downloads Inkling).
    private var detail: String? {
        guard server.state == .running, let splash, !splash.isReady, !missing, !outdated,
              let message = splash.message, !message.isEmpty, message != "The model is starting." else { return nil }
        return message
    }

    private var missing: Bool { splash?.isFailed == true && splash?.message?.localizedCaseInsensitiveContains("isn't installed") == true }
    private var outdated: Bool { splash?.isFailed == true && splash?.message?.localizedCaseInsensitiveContains("too old") == true }

    private var command: String? {
        missing ? "brew install incoai/tap/splash" : outdated ? "brew upgrade splash" : nil
    }

    private var color: Color {
        guard server.state == .running, let splash else {
            return server.state == .needsApproval || { if case .failed = server.state { true } else { false } }() ? .orange : .secondary
        }
        return splash.isReady ? .green : splash.isFailed ? .orange : .yellow
    }
}

/// Away from home: a Tailscale OAuth client the bridge makes a one-time join key with for each
/// device it pairs, so the device is on the tailnet (as `tag:lantern`) without signing in. The
/// secret goes to the bridge and is never shown again.
private struct TailscaleSection: View {
    let server: MacServer
    @State private var clientID = ""
    @State private var secret = ""
    @State private var saving = false
    @State private var problem: String?
    @State private var removing = false

    private var tailscale: MacServer.Tailscale? { server.status?.tailscale }

    var body: some View {
        Section {
            if let tailscale, tailscale.configured {
                LabeledContent("OAuth Client") {
                    Text(tailscale.clientId ?? "Set Up").textSelection(.enabled)
                }
                if let host = tailscale.host, !host.isEmpty {
                    LabeledContent("This Mac", value: host)
                }
                if let error = tailscale.lastError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.callout)
                }
                Button("Remove Tailscale Client…", role: .destructive) { removing = true }
            } else {
                TextField("OAuth Client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $secret)
                HStack {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.callout)
                    }
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("Save", action: save)
                        .disabled(saving || clientID.trimmingCharacters(in: .whitespaces).isEmpty || secret.isEmpty)
                }
            }
        } header: {
            Text("Away From Home")
        } footer: {
            Text("With a Tailscale OAuth client, each device you pair joins your tailnet by itself and reaches this Mac anywhere. The client needs the Auth Keys scope and the tag:lantern tag, which your tailnet policy must allow to reach this Mac on port \(String(server.status?.port ?? MacPairing.bridgePort)).")
        }
        .confirmationDialog("Remove the Tailscale client?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await server.forgetTailscale() } }
        } message: {
            Text("Devices already on your tailnet stay on it. Devices you pair from now on work on your home network only.")
        }
    }

    private func save() {
        saving = true
        problem = nil
        let id = clientID.trimmingCharacters(in: .whitespaces), key = secret
        Task {
            do {
                try await server.setTailscale(clientID: id, secret: key)
                clientID = ""
                secret = ""
            } catch {
                problem = error.localizedDescription
            }
            saving = false
        }
    }
}
#endif
