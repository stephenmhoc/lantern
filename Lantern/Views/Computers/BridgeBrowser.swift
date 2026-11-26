import Foundation
import Network
import Observation

/// Finds Macs running Lantern's bridge on this network (Bonjour `_lantern._tcp`, which
/// `lantern-bridge` advertises with its certificate's fingerprint), while pairing is on screen:
/// they're where a typed code is tried (`MacPairing.pair(code:device:bridges:)`).
@Observable
final class BridgeBrowser {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let fingerprint: String?
        let endpoint: NWEndpoint
    }

    /// The ones a typed code can be tried with.
    var advertised: [MacPairing.Advertised] {
        found.compactMap { f in f.fingerprint.map { .init(name: f.name, fingerprint: $0, endpoint: f.endpoint) } }
    }

    private(set) var found: [Found] = []
    /// Why Bonjour can't browse, such as local network access being off.
    private(set) var problem: String?
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_lantern._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            #if DEBUG
            print("BONJOUR \(state)")
            #endif
            let problem: String? = switch state {
            case .failed(let error), .waiting(let error):
                if case .dns(let code) = error, code == -65570 {  // kDNSServiceErr_PolicyDenied
                    "Local network access is off for Lantern. Turn it on in Settings › Privacy & Security › Local Network."
                } else {
                    "Can't look on this network: \(error.localizedDescription)"
                }
            default: nil
            }
            Task { @MainActor in self?.problem = problem }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found: [Found] = results.compactMap { result in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var fp: String?
                if case .bonjour(let txt) = result.metadata { fp = txt["fp"] }
                return Found(name: name, fingerprint: fp, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.found = Array(Set(found)).sorted { $0.name < $1.name } }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
