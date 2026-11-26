import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pairs an iPhone or iPad: a QR code holding a `lantern://pair` link (this Mac's addresses, its
/// certificate's fingerprint and a one-time code), for the device's camera. The code works once,
/// for one device, for ten minutes; a new one replaces it whenever it's needed.
struct PairingView: View {
    static let windowID = "pair"
    @Environment(BridgeController.self) private var bridge
    @State private var pairing: BridgeController.Pairing?
    @State private var failure: String?
    /// The devices when this code was made, to notice the one that pairs with it.
    @State private var before: Set<String> = []

    var body: some View {
        VStack(spacing: 16) {
            if let paired = newlyPaired {
                done(paired)
            } else {
                code
            }
        }
        .padding(28)
        .frame(width: 380)
        .task { await makeCode() }
    }

    private var newlyPaired: BridgeController.Device? {
        guard pairing != nil else { return nil }
        return bridge.status?.devices.first { !before.contains($0.id) }
    }

    @ViewBuilder private var code: some View {
        Text("Pair a Device").font(.title2.weight(.semibold))
        Text("Point your iPhone or iPad's camera at this code and open the link in Lantern. Its models then work from the device, at home or over Tailscale, encrypted all the way to this Mac.")
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.white)
            if let pairing, let image = Self.qr(pairing.link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
            } else if let failure {
                Text(failure).foregroundStyle(.secondary).padding()
            } else {
                ProgressView()
            }
        }
        .frame(width: 260, height: 260)
        if let pairing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date < pairing.expires {
                    Text("Works once, for one device, until \(pairing.expires.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("This code has expired. Make a New One") { Task { await makeCode() } }
                }
            }
            HStack {
                ShareLink(item: URL(string: pairing.link)!) {
                    Label("Send to a Device…", systemImage: "square.and.arrow.up")
                }
                .help("AirDrop the link to an iPad or iPhone nearby instead.")
                Button("New Code") { Task { await makeCode() } }
            }
        }
    }

    private func done(_ device: BridgeController.Device) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("\(device.name) is paired").font(.title2.weight(.semibold))
            Text("Its chats with this Mac's models are encrypted from the device to this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Pair Another") { Task { await makeCode() } }
        }
    }

    private func makeCode() async {
        failure = nil
        before = Set(bridge.status?.devices.map(\.id) ?? [])
        do {
            pairing = try await bridge.newPairing()
        } catch {
            pairing = nil
            failure = "Lantern couldn't make a code: the bridge isn't running."
        }
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
