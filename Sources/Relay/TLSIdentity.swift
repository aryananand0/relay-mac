import CryptoKit
import Foundation
import Network
import Security

/// Relay's HTTPS identity: a small certificate authority of its own plus a server certificate
/// it issues, so the phone can reach the Mac over real HTTPS without any outside service.
///
/// - **Keys:** both private keys are P-256 keys created in your login Keychain and can't be
///   exported. Public certificates go to ~/Library/Application Support/Relay/tls/.
/// - **The CA can only vouch for local names:** a critical Name Constraints extension limits it
///   to `*.local`, `localhost` and private IPv4 ranges. The iPhone trusts it for those and
///   nothing else, so even a stolen CA key couldn't impersonate real websites.
/// - **Renewal:** the CA is valid for 10 years. The server certificate is valid for 397 days
///   (within Apple's limits) and renewed automatically 30 days before it expires, or whenever
///   the Mac's name or addresses change. The phone never needs to do anything for that.
/// - **Installing on the iPhone:** `profile` is a configuration profile holding just the CA
///   certificate, sent by AirDrop from the menu bar or downloaded from the setup page.
final class TLSIdentity {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Relay/tls")
    static var caCertificateURL: URL { dir.appendingPathComponent("relay-ca.cer") }
    static var caPEMURL: URL { dir.appendingPathComponent("relay-ca.pem") }
    static var profileURL: URL { dir.appendingPathComponent("Relay.mobileconfig") }
    private static var serverCertURL: URL { dir.appendingPathComponent("server.cer") }
    private static var serverNamesURL: URL { dir.appendingPathComponent("server-names") }

    private static let caTag = Data("local.relay.tls.ca".utf8)
    private static let serverTag = Data("local.relay.tls.server".utf8)

    let identity: sec_identity_t
    let caDER: Data
    let profile: Data
    /// SHA-256 of the CA certificate, "AB:CD:…", to compare with what the iPhone shows.
    let caFingerprint: String

    init(hostName: String) throws {
        try FileManager.default.createDirectory(at: TLSIdentity.dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let caName = "Relay Local CA (\(hostName))"
        let serverName = "Relay (\(hostName))"

        // The certificate authority: created once, reused for 10 years.
        let caKey = try TLSIdentity.key(tag: TLSIdentity.caTag, label: caName)
        var caDER = (try? Data(contentsOf: TLSIdentity.caCertificateURL)) ?? Data()
        if caDER.isEmpty || !TLSIdentity.certificate(caDER, matches: caKey) {
            caDER = try TLSIdentity.makeCA(name: caName, key: caKey)
            try TLSIdentity.storeCertificate(caDER, label: caName)
            try TLSIdentity.writeFile(caDER, to: TLSIdentity.caCertificateURL)
            try TLSIdentity.writeFile(Data(TLSIdentity.pem(caDER).utf8), to: TLSIdentity.caPEMURL)
            Log.info("tls: created Relay's certificate authority")
        }

        // The server certificate: renewed when it nears expiry or the Mac's names change.
        let serverKey = try TLSIdentity.key(tag: TLSIdentity.serverTag, label: serverName)
        let dnsNames = ["\(hostName).local", "localhost"]
        let ips = PeerPolicy.localIPv4Addresses().filter { TLSIdentity.isPrivate($0) } + ["127.0.0.1"]
        let names = (dnsNames + ips).joined(separator: " ")
        var serverDER = (try? Data(contentsOf: TLSIdentity.serverCertURL)) ?? Data()
        let savedNames = (try? String(contentsOf: TLSIdentity.serverNamesURL, encoding: .utf8)) ?? ""
        let expiry = TLSIdentity.notAfter(serverDER)
        if serverDER.isEmpty || savedNames != names || (expiry ?? .distantPast) < Date().addingTimeInterval(30 * 86400)
            || !TLSIdentity.certificate(serverDER, matches: serverKey) {
            serverDER = try TLSIdentity.makeServer(name: serverName, key: serverKey, dnsNames: dnsNames, ips: ips,
                                                    caName: caName, caKey: caKey)
            try TLSIdentity.storeCertificate(serverDER, label: serverName)
            try TLSIdentity.writeFile(serverDER, to: TLSIdentity.serverCertURL)
            try TLSIdentity.writeFile(Data(names.utf8), to: TLSIdentity.serverNamesURL)
            Log.info("tls: issued the server certificate for \(names)")
        }

        guard let cert = SecCertificateCreateWithData(nil, serverDER as CFData) else { throw TLSError("bad server certificate") }
        var secIdentity: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, cert, &secIdentity) == errSecSuccess, let secIdentity,
              let identity = sec_identity_create(secIdentity) else { throw TLSError("couldn't load the TLS identity from the Keychain") }
        self.identity = identity
        self.caDER = caDER
        self.caFingerprint = SHA256.hash(data: caDER).map { String(format: "%02X", $0) }.joined(separator: ":")
        self.profile = try TLSIdentity.makeProfile(caDER: caDER, name: caName)
        try? TLSIdentity.writeFile(profile, to: TLSIdentity.profileURL)
    }

    /// TLS 1.2+ server options using this identity.
    func serverOptions() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        return tls
    }

    // MARK: - Certificates

    private static let ecPublicKey = DER.oid("1.2.840.10045.2.1")
    private static let prime256v1 = DER.oid("1.2.840.10045.3.1.7")
    private static let ecdsaSHA256 = DER.sequence(DER.oid("1.2.840.10045.4.3.2"))

    private static func makeCA(name: String, key: SecKey) throws -> Data {
        let spki = try subjectPublicKeyInfo(key)
        let ski = keyIdentifier(spki)
        // Private IPv4 ranges as address ‖ mask, for the Name Constraints extension.
        let ranges: [[UInt8]] = [[10, 0, 0, 0, 255, 0, 0, 0], [172, 16, 0, 0, 255, 240, 0, 0],
                                 [192, 168, 0, 0, 255, 255, 0, 0], [169, 254, 0, 0, 255, 255, 0, 0],
                                 [127, 0, 0, 0, 255, 0, 0, 0]]
        let permitted = [DER.implicit(2, Data("local".utf8)), DER.implicit(2, Data("localhost".utf8))]
            + ranges.map { DER.implicit(7, Data($0)) }
        let nameConstraints = DER.sequence(DER.implicitConstructed(0, permitted.map { DER.sequence($0) }.reduce(Data(), +)))
        let extensions = [
            ext("2.5.29.19", critical: true, DER.sequence(DER.boolean(true), DER.integer(0))),   // CA, path length 0
            ext("2.5.29.15", critical: true, DER.bitString(Data([0x06]), unused: 1)),           // keyCertSign, cRLSign
            ext("2.5.29.30", critical: true, nameConstraints),
            ext("2.5.29.14", critical: false, DER.octetString(ski)),
        ]
        return try sign(tbs(subject: name, issuer: name, spki: spki, years: 10, extensions: extensions), with: key)
    }

    private static func makeServer(name: String, key: SecKey, dnsNames: [String], ips: [String],
                                   caName: String, caKey: SecKey) throws -> Data {
        let spki = try subjectPublicKeyInfo(key)
        let caSKI = keyIdentifier(try subjectPublicKeyInfo(caKey))
        let san = dnsNames.map { DER.implicit(2, Data($0.utf8)) }
            + ips.compactMap { IPv4Address($0).map { DER.implicit(7, $0.rawValue) } }
        let extensions = [
            ext("2.5.29.19", critical: true, DER.sequence()),                                    // not a CA
            ext("2.5.29.15", critical: true, DER.bitString(Data([0x80]), unused: 7)),           // digitalSignature
            ext("2.5.29.37", critical: false, DER.sequence(DER.oid("1.3.6.1.5.5.7.3.1"))),      // serverAuth
            ext("2.5.29.17", critical: false, DER.sequence(san)),
            ext("2.5.29.14", critical: false, DER.octetString(keyIdentifier(spki))),
            ext("2.5.29.35", critical: false, DER.sequence(DER.implicit(0, caSKI))),
        ]
        return try sign(tbs(subject: name, issuer: caName, spki: spki, days: 397, extensions: extensions), with: caKey)
    }

    private static func ext(_ oid: String, critical: Bool, _ value: Data) -> Data {
        DER.sequence([DER.oid(oid)] + (critical ? [DER.boolean(true)] : []) + [DER.octetString(value)])
    }

    private static func distinguishedName(_ cn: String) -> Data {
        DER.sequence(DER.set(DER.sequence(DER.oid("2.5.4.3"), DER.utf8String(cn))),
                     DER.set(DER.sequence(DER.oid("2.5.4.10"), DER.utf8String("Relay"))))
    }

    private static func tbs(subject: String, issuer: String, spki: Data, years: Int = 0, days: Int = 0,
                            extensions: [Data]) -> Data {
        var rng = SystemRandomNumberGenerator()
        var serial = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) })
        serial[0] = (serial[0] & 0x7f) | 0x01
        let start = Date().addingTimeInterval(-3600)   // tolerate a slightly slow phone clock
        let end = Calendar(identifier: .gregorian).date(byAdding: DateComponents(year: years, day: days), to: start)!
        return DER.sequence(
            DER.explicit(0, DER.integer(2)),                 // v3
            DER.integer(serial),
            ecdsaSHA256,
            distinguishedName(issuer),
            DER.sequence(DER.time(start), DER.time(end)),
            distinguishedName(subject),
            spki,
            DER.explicit(3, DER.sequence(extensions)))
    }

    private static func sign(_ tbs: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw TLSError("signing failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return DER.sequence(tbs, ecdsaSHA256, DER.bitString(signature))
    }

    private static func subjectPublicKeyInfo(_ privateKey: SecKey) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(privateKey),
              let point = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { throw TLSError("no public key") }
        return DER.sequence(DER.sequence(ecPublicKey, prime256v1), DER.bitString(point))
    }

    /// RFC 5280 method 1: SHA-1 of the public key bits (an identifier, not a security check).
    private static func keyIdentifier(_ spki: Data) -> Data {
        Data(Insecure.SHA1.hash(data: spki.suffix(65)))
    }

    private static func certificate(_ der: Data, matches key: SecKey) -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData), let certKey = SecCertificateCopyKey(cert),
              let a = SecKeyCopyExternalRepresentation(certKey, nil) as Data?, let pub = SecKeyCopyPublicKey(key),
              let b = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { return false }
        return a == b
    }

    private static func notAfter(_ der: Data) -> Date? {
        guard !der.isEmpty, let cert = SecCertificateCreateWithData(nil, der as CFData),
              let values = SecCertificateCopyValues(cert, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let seconds = entry[kSecPropertyKeyValue] as? Double else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static func isPrivate(_ ip: String) -> Bool {
        guard let b = IPv4Address(ip).map({ [UInt8]($0.rawValue) }) else { return false }
        return b[0] == 10 || (b[0] == 172 && (b[1] & 0xf0) == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }

    static func pem(_ der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n"
    }

    // MARK: - Keychain

    /// The P-256 private key with this tag, created (non-exportable, in the login Keychain) if missing.
    private static func key(tag: Data, label: String) throws -> SecKey {
        let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrApplicationTag: tag,
                                      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item {
            return item as! SecKey   // swiftlint:disable:this force_cast
        }
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true, kSecAttrApplicationTag: tag, kSecAttrLabel: label,
                                  kSecAttrIsExtractable: false] as [CFString: Any],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw TLSError("couldn't create a key in the Keychain: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return key
    }

    private static func storeCertificate(_ der: Data, label: String) throws {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw TLSError("bad certificate") }
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: label] as CFDictionary)
        let status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: cert, kSecAttrLabel: label] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw TLSError("Keychain error \(status)") }
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    // MARK: - iPhone profile

    private static func makeProfile(caDER: Data, name: String) throws -> Data {
        let digest = Array(SHA256.hash(data: caDER))
        let fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        // Stable IDs, so downloading the profile again replaces it instead of adding another.
        func uuid(_ offset: Int) -> String {
            var b = Array(digest[offset..<offset + 16])
            b[6] = (b[6] & 0x0f) | 0x50; b[8] = (b[8] & 0x3f) | 0x80
            return NSUUID(uuidBytes: b).uuidString
        }
        let plist: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "local.relay.ca.\(fingerprint)",
            "PayloadUUID": uuid(0),
            "PayloadDisplayName": name,
            "PayloadDescription": "Lets your iPhone open Relay over a secure HTTPS connection. It is trusted only for devices on your local network (.local names and private addresses).",
            "PayloadOrganization": "Relay",
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
                "PayloadIdentifier": "local.relay.ca.\(fingerprint).cert",
                "PayloadUUID": uuid(16),
                "PayloadDisplayName": name,
                "PayloadCertificateFileName": "relay-ca.cer",
                "PayloadContent": caDER,
            ] as [String: Any]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

struct TLSError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
