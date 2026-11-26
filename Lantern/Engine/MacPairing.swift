import CryptoKit
import Foundation
import os
import Security

/// Lantern's pairing with the bridge on a computer (Lantern for Mac's `lantern-bridge`): TLS with
/// the computer's own certificate, which Lantern pins, and an access key it sends with every request.
/// Once paired, every request to the computer, home network and tailnet alike, is encrypted from
/// this device to the computer, and only goes to the computer that was paired: a certificate that
/// isn't the pinned one fails, and nothing falls back to plain HTTP.
///
/// Pairing comes from the link "Pair a Device" shows as a QR code (`LanternLink.pair`): the device
/// trades its one-time code for a token of its own (`pair(_:device:)`). The access key below is that
/// token, the pin the certificate's SHA-256 from the link. Unpaired, the bridge turns every request down.
nonisolated enum MacPairing {
    /// The certificate's SHA-256 (hex, from the pairing link). Not secret: in UserDefaults.
    static let pinKey = "mac.pin"
    /// The bridge's port, when a host has none.
    static let bridgePort = 11443

    struct Paired: Sendable, Equatable {
        let pin: Data
        let key: String
    }

    /// The pairing, if there is one: read once, then kept until it changes.
    static var current: Paired? {
        cache.withLock { cached in
            if let cached { return cached.value }
            let value = load()
            cached = .some(.init(value: value))
            return value
        }
    }

    static var isPaired: Bool { current != nil }

    private struct Cached: Sendable { let value: Paired? }
    private static let cache = OSAllocatedUnfairLock<Cached?>(initialState: nil)

    private static func load() -> Paired? {
        guard let hex = UserDefaults.standard.string(forKey: pinKey), let pin = Data(hex: hex), pin.count == 32,
              let key = storedKey, !key.isEmpty else { return nil }
        return Paired(pin: pin, key: key)
    }

    /// Keeps the pairing: the pin in UserDefaults, the key in the Keychain (this device only).
    static func save(pin hex: String, key: String) -> Bool {
        guard let pin = Data(hex: hex), pin.count == 32, !key.isEmpty else { return false }
        SecItemDelete(keyQuery as CFDictionary)
        var item = keyQuery
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        UserDefaults.standard.set(pin.hex, forKey: pinKey)
        cache.withLock { $0 = nil }
        return true
    }

    static func forget() {
        SecItemDelete(keyQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: pinKey)
        cache.withLock { $0 = nil }
    }

    private static var storedKey: String? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.merimerimeri.Lantern.mac",
         kSecAttrAccount as String: "access-key"]
    }

    // MARK: - Pairing

    enum PairError: LocalizedError {
        case badLink, codeRefused, wrongComputer, unreachable(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .badLink: "This pairing link isn't complete. Make a new code in Lantern on the computer."
            case .codeRefused: "This code has been used or has expired. Make a new one in Lantern on the computer."
            case .wrongComputer: "The computer that answered isn't the one in the code, so Lantern didn't pair with it."
            case .unreachable(let name): "Lantern couldn't reach \(name). Check that this device is on the same network or your tailnet, and that Lantern is open on it."
            case .failed(let message): message
            }
        }
    }

    /// What a pairing found: the computer's name and its addresses by route.
    struct Pairing: Sendable {
        let name: String
        let lan: String
        let tailnet: String
    }

    /// Pairs with the bridge in a pairing link: tries each address (home network first), trusting
    /// only the certificate the link names, and trades the one-time code for this device's token.
    /// Keeps the pin and token; the caller saves the addresses.
    static func pair(_ offer: LanternLink.PairOffer, device: String) async throws -> Pairing {
        guard let pin = Data(hex: offer.fingerprint), pin.count == 32 else { throw PairError.badLink }
        let lan = offer.addresses.filter { !isTailnet($0) }
        let tailnet = offer.addresses.filter(isTailnet)
        let session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(pin: pin), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var wrongComputer = false
        for address in lan + tailnet {
            guard let url = url(address, "/lantern/v1/pair") else { continue }
            var request = URLRequest(url: url, timeoutInterval: 6)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["code": offer.code, "device": device])
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
                                                 .secureConnectionFailed].contains(error.code) {
                wrongComputer = true
                continue
            } catch {
                continue  // not on this route: the next one
            }
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                guard let paired = try? JSONDecoder().decode(BridgeAPI.Paired.self, from: data),
                      save(pin: offer.fingerprint, key: paired.token) else { throw PairError.failed("Lantern couldn't keep the pairing.") }
                // The first of each route answered as the computer; the bridge lists names first.
                return Pairing(name: paired.name ?? offer.name, lan: lan.first ?? "", tailnet: tailnet.first ?? "")
            case 403: throw PairError.codeRefused
            default:
                let message = (try? JSONDecoder().decode(BridgeAPI.ErrorBody.self, from: data))?.message
                throw PairError.failed(message ?? "The computer turned the pairing down.")
            }
        }
        throw wrongComputer ? PairError.wrongComputer : PairError.unreachable(offer.name)
    }

    /// A tailnet address: a MagicDNS name or an address in 100.64.0.0/10.
    static func isTailnet(_ address: String) -> Bool {
        let host = address.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        if host.hasSuffix(".ts.net") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    // MARK: - Requests

    /// The URL of `path` on a host ("mac-studio.local:11443"). Always HTTPS: nothing goes to a
    /// computer unencrypted, paired or not.
    static func url(_ host: String, _ path: String) -> URL? {
        URL(string: "https://\(host)\(path)")
    }

    /// A request to the computer, carrying the access key once paired.
    static func request(_ host: String, _ path: String, timeout: TimeInterval) -> URLRequest? {
        guard let url = url(host, path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let key = current?.key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// For the computer over the home network or the Tailscale app's VPN: trusts only the paired
    /// certificate. (Lantern's own tailnet node has a session of its own with the same delegate.)
    static let session = URLSession(configuration: .default, delegate: PinningDelegate.shared, delegateQueue: nil)

    /// Whether a link's error says the computer's certificate isn't the paired one.
    static func isUntrusted(_ error: Error) -> Bool {
        isCertificateError(error) && isPaired
    }

    /// Whether a link failed on the server's certificate.
    static func isCertificateError(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                .serverCertificateHasBadDate, .secureConnectionFailed].contains(error.code)
    }
}

/// Accepts a server only if its certificate is the one paired with (SHA-256 of the whole
/// certificate); its name and issuer don't matter, since it's the computer's own. Anything else is
/// left to the system, which turns a self-signed certificate down.
nonisolated final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    static let shared = PinningDelegate()
    /// A certificate to trust instead of the paired one: the one in a pairing link, while pairing.
    private let fixedPin: Data?

    init(pin: Data? = nil) { fixedPin = pin }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let pin = fixedPin ?? MacPairing.current?.pin,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { return (.performDefaultHandling, nil) }
        let presented = Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))
        // Not the paired certificate: the system's own check, which fails it as untrusted.
        guard presented == pin else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

extension Data {
    nonisolated init?(hex: String) {
        let clean = hex.lowercased().filter { !$0.isWhitespace && $0 != ":" }
        guard clean.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    nonisolated var hex: String { map { String(format: "%02x", $0) }.joined() }
}
