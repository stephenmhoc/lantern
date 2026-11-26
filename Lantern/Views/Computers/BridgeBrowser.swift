import Foundation
import Network
import Observation

/// Finds computers running Lantern's bridge on this network (Bonjour `_lantern._tcp`, which
/// `lantern-bridge` advertises with its certificate's fingerprint), while Add a Computer is on
/// screen. They can't be added from here: pairing takes the one-time code the computer shows.
@Observable
final class BridgeBrowser {
    struct Found: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let fingerprint: String?
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
                return Found(name: name, fingerprint: fp)
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
