import SwiftUI

/// Pairing with a Mac, from its QR code's link (`lantern://pair`) or a code typed here: connects,
/// gets this device's token, joins the Mac's tailnet if it handed over a key, saves the Mac, and
/// says so, including whether it answers away from home.
struct PairingSheet: View {
    let request: Request
    @Environment(MacLink.self) private var mac
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .pairing

    init(offer: PairOffer) { request = .link(offer) }
    init(code: String, bridges: [MacPairing.Advertised]) { request = .code(code, bridges) }

    enum Request: Identifiable {
        case link(PairOffer)
        case code(String, [MacPairing.Advertised])
        var id: String {
            switch self {
            case .link(let offer): offer.id
            case .code(let code, _): code
            }
        }
    }

    enum Phase {
        case pairing
        case paired(name: String, away: String)
        case failed(String)
    }

    private var name: String {
        if case .link(let offer) = request { return offer.name }
        return "your Mac"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                switch phase {
                case .pairing:
                    ProgressView().controlSize(.large)
                    Text("Pairing with \(name)…").font(.title3.weight(.semibold))
                    Text("Lantern checks it's the Mac that showed the code, then sets up an encrypted connection to it.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                case .paired(let name, let away):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                        .symbolEffect(.bounce, value: name)
                    Text("Paired with \(name)").font(.title2.weight(.semibold))
                    Text(away).multilineTextAlignment(.center).foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 50)).foregroundStyle(.orange)
                    Text("Couldn't Pair").font(.title2.weight(.semibold))
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if case .pairing = phase {} else { Button("Done") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled({ if case .pairing = phase { true } else { false } }())
        .task { await pair() }
    }

    private func pair() async {
        do {
            let paired = switch request {
            case .link(let offer): try await MacPairing.pair(offer, device: Device.pairingName)
            case .code(let code, let bridges): try await MacPairing.pair(code: code, device: Device.pairingName, bridges: bridges)
            }
            mac.configure(name: paired.name, lan: paired.lan, tailnet: paired.tailnet)
            let away = await joinTailnet(paired)
            await mac.resolve()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            phase = .paired(name: paired.name, away: away)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Joins the Mac's tailnet with the key it handed over (this device's own node), and says how
    /// the Mac answers away from home.
    private func joinTailnet(_ paired: MacPairing.Pairing) async -> String {
        switch paired.join {
        case .key(let key):
            if mac.tailnet.canJoin {
                await mac.tailnet.join(authKey: key)
                if mac.tailnet.state == .connected { return "It answers at home and, through your tailnet, away from home too." }
                return "It answers at home. Joining its tailnet didn't work (\(mac.tailnet.state.label)), so away from home it won't."
            }
            // A Mac can't join by itself: the Tailscale app does it.
            return "It answers at home, and away from home if the Tailscale app on this Mac is signed in to the same tailnet."
        case .notConfigured:
            return "It answers on your home network. To reach it away from home, set up Tailscale in Lantern's Settings on that Mac, then pair again."
        case .failed(let message):
            return "It answers on your home network. Away from home it won't: \(message)"
        }
    }
}
