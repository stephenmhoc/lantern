import Foundation

/// Lantern on the Mac chats with this Mac's model servers (Ollama, LM Studio…) the way an iPhone
/// does: through the bridge, so it gets the same model list, capabilities, kept-loaded models and
/// API. It pairs itself with its own bridge over the admin socket (no QR code) and reaches it on
/// 127.0.0.1, with the bridge's certificate pinned like any device. `MacLink` then works unchanged.
enum ThisMac {
    /// The device name the bridge lists for this app; the Mac's own lists leave it out.
    static let deviceName = "Lantern on This Mac"
    static let displayName = "This Mac"

    /// Pairs if this app isn't paired with the running bridge (first launch, a new certificate,
    /// or the pairing removed), then points `MacLink` at it.
    /// Every window asks; one connects at a time.
    private static var connecting = false

    static func connect(_ mac: MacLink, bridge: BridgeController) async {
        guard let status = bridge.status, !connecting else { return }
        connecting = true
        defer { connecting = false }
        let paired = MacPairing.current
        let samePin = paired.map { $0.pin.hex == status.fingerprint.lowercased() } ?? false
        let listed = status.devices.contains { $0.name == deviceName }
        if !(samePin && listed) {
            do {
                let pairing = try await bridge.newPairing()
                guard let url = URL(string: pairing.link), case .pair(let offer)? = LanternLink(url: url) else { return }
                // Only the loopback address: the bridge is on this Mac.
                let local = LanternLink.PairOffer(
                    name: offer.name, fingerprint: offer.fingerprint, code: offer.code,
                    addresses: ["127.0.0.1:\(status.port)"])
                _ = try await MacPairing.pair(local, device: deviceName)
                // Earlier pairings of this app are of no use any more.
                for old in status.devices where old.name == deviceName { await bridge.remove(old) }
            } catch {
                return
            }
        }
        let host = "127.0.0.1:\(status.port)"
        if MacLink.lanHost != host || !MacLink.tailnetHost.isEmpty {
            mac.configure(name: displayName, lan: host, tailnet: "")
        }
        await mac.resolve()
    }
}
