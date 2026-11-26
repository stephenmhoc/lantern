import CommonCrypto
import CryptoKit
import Foundation
import Network
import os
import Security

/// Lantern's pairing with the bridge on a computer (Lantern for Mac's `lantern-bridge`): TLS with
/// the computer's own certificate, which Lantern pins, and an access key it sends with every request.
/// Once paired, every request to the computer, home network and tailnet alike, is encrypted from
/// this device to the computer, and only goes to the computer that was paired: a certificate that
/// isn't the pinned one fails, and nothing falls back to plain HTTP.
///
/// Pairing comes from the link "Pair a Device" shows as a QR code (`PairOffer`): the device
/// trades its one-time code for a token of its own (`pair(_:device:)`); or from the code it shows
/// to type, proved to a Mac found by Bonjour without sending it (`pair(code:device:bridges:)`,
/// Bridge/README.md). The access key below is that token, the pin the certificate's SHA-256.
/// Unpaired, the bridge turns every request down. Either way the Mac may hand over a one-time key
/// to join its tailnet (`Pairing.tailnet`).
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
        guard let pin = Data(hex: hex), pin.count == 32, !key.isEmpty,
              Keychain.write(key, service: keyService, account: "access-key") else { return false }
        UserDefaults.standard.set(pin.hex, forKey: pinKey)
        cache.withLock { $0 = nil }
        return true
    }

    static func forget() {
        Keychain.delete(service: keyService, account: "access-key")
        UserDefaults.standard.removeObject(forKey: pinKey)
        cache.withLock { $0 = nil }
    }

    private static var storedKey: String? { Keychain.read(service: keyService, account: "access-key") }

    /// Per app: a Debug build on the Mac is another app, with a pairing of its own.
    private static var keyService: String { "\(Bundle.main.bundleIdentifier ?? "com.merimerimeri.Lantern").mac" }

    // MARK: - Pairing

    enum PairError: LocalizedError {
        case badLink, codeRefused, wrongComputer, unreachable(String), failed(String)
        case badCode, typedCodeRefused, tooManyTries, noMacFound
        var errorDescription: String? {
            switch self {
            case .badLink: "This pairing link isn't complete. Make a new code in Lantern on the computer."
            case .codeRefused: "This code has been used or has expired. Make a new one in Lantern on the computer."
            case .badCode: "A code has eight letters and numbers, like K7QM-3XPA."
            case .typedCodeRefused: "No Mac nearby is showing this code. Check it, or show a new one on the Mac."
            case .tooManyTries: "Too many wrong tries: that code is gone. Show a new one on the Mac."
            case .noMacFound: "No Mac serving Inkling was found on this network. Pairing with a code works at home; away from home, scan the QR code."
            case .wrongComputer: "The computer that answered isn't the one in the code, so Lantern didn't pair with it."
            case .unreachable(let name): "Lantern couldn't reach \(name). Check that this device is on the same network or your tailnet, and that Lantern is open on it."
            case .failed(let message): message
            }
        }
    }

    /// What a pairing found: the computer's name, its addresses by route, and its tailnet's answer.
    struct Pairing: Sendable {
        let name: String
        let lan: String
        let tailnet: String
        var join: TailnetJoin = .notConfigured
    }

    /// The pair response's `tailnet`: a one-time key to join the Mac's tailnet, or why there's none.
    enum TailnetJoin: Sendable, Equatable {
        case key(String)
        case notConfigured
        case failed(String)

        init(_ answer: BridgeAPI.Paired.Tailnet?) {
            switch answer?.status {
            case "ok": self = answer?.auth_key.map { .key($0) } ?? .notConfigured
            case "failed": self = .failed(answer?.message ?? "The Mac couldn't make a key for its tailnet.")
            default: self = .notConfigured
            }
        }
    }

    /// The address on the Mac's tailnet the pair response names, else the first given before.
    private static func tailnetAddress(_ paired: BridgeAPI.Paired, else fallback: String?) -> String {
        if paired.tailnet?.status == "ok", let address = paired.tailnet?.address, !address.isEmpty { return address }
        return paired.addresses?.first(where: isTailnet) ?? fallback ?? ""
    }

    /// Pairs with the bridge in a pairing link: tries each address (home network first), trusting
    /// only the certificate the link names, and trades the one-time code for this device's token.
    /// Keeps the pin and token; the caller saves the addresses.
    static func pair(_ offer: PairOffer, device: String) async throws -> Pairing {
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
                return Pairing(name: paired.name ?? offer.name, lan: lan.first ?? "",
                               tailnet: tailnetAddress(paired, else: tailnet.first), join: TailnetJoin(paired.tailnet))
            case 403: throw PairError.codeRefused
            default:
                let message = (try? JSONDecoder().decode(BridgeAPI.ErrorBody.self, from: data))?.message
                throw PairError.failed(message ?? "The computer turned the pairing down.")
            }
        }
        throw wrongComputer ? PairError.wrongComputer : PairError.unreachable(offer.name)
    }

    // MARK: - Pairing with a typed code

    /// A Mac found by Bonjour (`_lantern._tcp`), with the fingerprint its TXT record gives.
    struct Advertised: Sendable, Hashable {
        let name: String
        let fingerprint: String
        let endpoint: NWEndpoint
    }

    /// "k7qm-3xpa" → "K7QM3XPA", or nil if it isn't eight letters and digits.
    static func normalizedCode(_ typed: String) -> String? {
        let code = String(typed.uppercased().unicodeScalars.filter { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
        return code.count == 8 ? code : nil
    }

    /// Pairs with whichever Mac found nearby is showing `typed`: for each, a key from the code and
    /// its fingerprint proves the code without sending it, over TLS pinned to that fingerprint, and
    /// the Mac's own proof is checked before its token is kept (Bridge/README.md, "Pairing with a
    /// typed code"). A Mac that says no (403) is passed over for the next.
    static func pair(code typed: String, device: String, bridges: [Advertised]) async throws -> Pairing {
        guard let code = normalizedCode(typed) else { throw PairError.badCode }
        guard !bridges.isEmpty else { throw PairError.noMacFound }
        var reached = false
        var tooMany = false
        for bridge in bridges {
            let fp = bridge.fingerprint.lowercased()
            guard let pin = Data(hex: fp), pin.count == 32, let host = await resolve(bridge.endpoint),
                  let url = url(host, "/lantern/v1/pair-code") else { continue }
            let key = codeKey(code, fingerprint: fp)
            let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).hex
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(
                ["nonce": nonce, "proof": mac(key, "lantern device " + nonce), "device": device])
            let session = URLSession(configuration: .ephemeral, delegate: PinningDelegate(pin: pin), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, response) = try? await session.data(for: request) else { continue }
            reached = true
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                guard let paired = try? JSONDecoder().decode(BridgeAPI.Paired.self, from: data),
                      let proof = paired.proof?.lowercased(),
                      constantTimeEqual(proof, mac(key, "lantern bridge \(nonce) \(paired.token)")) else {
                    continue  // not the Mac showing the code: its token is thrown away
                }
                guard save(pin: fp, key: paired.token) else { throw PairError.failed("Lantern couldn't keep the pairing.") }
                let lan = paired.addresses?.first { !isTailnet($0) } ?? host
                return Pairing(name: paired.name ?? bridge.name, lan: lan,
                               tailnet: tailnetAddress(paired, else: nil), join: TailnetJoin(paired.tailnet))
            case 429: tooMany = true
            default: continue  // 403: not this Mac's code (or an older bridge without codes)
            }
        }
        if tooMany { throw PairError.tooManyTries }
        throw reached ? PairError.typedCodeRefused : PairError.noMacFound
    }

    /// PBKDF2-HMAC-SHA256(code, "lantern-pair-code-v1:" + fingerprint, 100 000 rounds, 32 bytes).
    private static func codeKey(_ code: String, fingerprint: String) -> SymmetricKey {
        let password = Array(code.utf8).map { CChar(bitPattern: $0) }
        let salt = Array("lantern-pair-code-v1:\(fingerprint)".utf8)
        var key = [UInt8](repeating: 0, count: 32)
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count, salt, salt.count,
                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 100_000, &key, key.count)
        return SymmetricKey(data: key)
    }

    /// Lower-case hex HMAC-SHA256.
    private static func mac(_ key: SymmetricKey, _ message: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)).hex
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// A Bonjour service's IPv4 address and port ("192.168.1.20:11443"), by connecting to it.
    static func resolve(_ endpoint: NWEndpoint) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        let once = OSAllocatedUnfairLock(initialState: false)
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: String?) {
                guard once.withLock({ done in defer { done = true }; return !done }) else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        var name = "\(host)"
                        if let percent = name.firstIndex(of: "%") { name = String(name[..<percent]) }
                        finish("\(name):\(port.rawValue)")
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
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

/// Where Lantern's secrets go (the Mac's access key, the Tavily key): the Keychain, this device
/// only. On the Mac that's the data protection keychain, which works because the app carries a
/// provisioning profile (for iCloud). A build without one (-34018) keeps them in files only its
/// user can read, in Lantern's folder beside the bridge's own key, as the first 2.0 builds did;
/// those move into the Keychain once it works.
nonisolated enum Keychain {
    @discardableResult
    static func write(_ value: String, service: String, account: String) -> Bool {
        delete(service: service, account: account)
        let status = add(value, service, account)
        #if targetEnvironment(macCatalyst)
        if status == errSecMissingEntitlement { return writeFile(value, service, account) }
        #endif
        return status == errSecSuccess
    }

    private static func add(_ value: String, _ service: String, _ account: String) -> OSStatus {
        var item = query(service, account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        #if targetEnvironment(macCatalyst)
        guard let value = (try? Data(contentsOf: file(service, account))).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        if add(value, service, account) == errSecSuccess {
            try? FileManager.default.removeItem(at: file(service, account))  // moved into the Keychain
        }
        return value
        #else
        return nil
        #endif
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
        #if targetEnvironment(macCatalyst)
        try? FileManager.default.removeItem(at: file(service, account))
        #endif
    }

    private static func query(_ service: String, _ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        #if targetEnvironment(macCatalyst)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    #if targetEnvironment(macCatalyst)
    private static func file(_ service: String, _ account: String) -> URL {
        Folders.support.appending(path: "Secrets/\(service).\(account)")
    }

    private static func writeFile(_ value: String, _ service: String, _ account: String) -> Bool {
        let url = file(service, account)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return FileManager.default.createFile(atPath: url.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
    }
    #endif
}

/// `lantern://pair?v=1&name=…&fp=<sha256>&code=…&addr=host:port&addr=…`. Its name, its
/// certificate's SHA-256 (hex), a one-time code and the addresses it answers on (home network and
/// tailnet, each with its port). The only `lantern://` link there is.
nonisolated struct PairOffer: Equatable, Sendable, Identifiable {
    let name: String
    let fingerprint: String
    let code: String
    let addresses: [String]
    var id: String { code }

    init?(url: URL) {
        guard ["lantern", "lantern-dev"].contains(url.scheme?.lowercased() ?? ""), url.host()?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        let addresses = items.filter { $0.name == "addr" }.compactMap(\.value).filter { !$0.isEmpty }
        guard let fp = value("fp"), let code = value("code"), !addresses.isEmpty else { return nil }
        name = value("name") ?? "Your Mac"
        fingerprint = fp
        self.code = code
        self.addresses = addresses
    }
}
