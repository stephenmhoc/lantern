import SwiftUI

/// Pairing with a computer from its QR code (`lantern://pair`): connects, trades the one-time code
/// for this device's token, saves the computer and its models, and says so.
struct PairingSheet: View {
    let offer: LanternLink.PairOffer
    @Environment(MacLink.self) private var mac
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .pairing

    enum Phase {
        case pairing
        case paired(name: String, models: Int)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                switch phase {
                case .pairing:
                    ProgressView().controlSize(.large)
                    Text("Pairing with \(offer.name)…").font(.title3.weight(.semibold))
                    Text("Lantern checks the computer is the one in the code, then sets up an encrypted connection to it.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                case .paired(let name, let models):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                    Text("Paired with \(name)").font(.title2.weight(.semibold))
                    Text(models == 0
                         ? "Its models show up in the model picker once it serves some."
                         : "Its \(models == 1 ? "model is" : "\(models) models are") in the model picker, encrypted from this device to the computer.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
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
            let paired = try await MacPairing.pair(offer, device: UIDevice.current.name)
            let previous = mac.modelName
            mac.configure(name: paired.name, lan: paired.lan, tailnet: paired.tailnet)
            await mac.resolve()
            if !mac.models.isEmpty {
                let pick = mac.models.contains(previous) ? previous : mac.models[0]
                UserDefaults.standard.set(pick, forKey: MacLink.modelKey)
            }
            phase = .paired(name: paired.name, models: mac.models.count)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
