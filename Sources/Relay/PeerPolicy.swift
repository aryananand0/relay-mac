import Foundation
import Network

/// Only devices on the local network may talk to Relay: private/link-local
/// addresses, or any address on the same subnet as one of this Mac's interfaces
/// (covers global IPv6 addresses handed out on the home LAN).
enum PeerPolicy {
    static func isAllowed(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr):
            let b = [UInt8](addr.rawValue)
            return isPrivateIPv4(b) || isOnLink(b, family: AF_INET)
        case .ipv6(let addr):
            let b = [UInt8](addr.rawValue)
            guard b.count == 16 else { return false }
            if addr == .loopback { return true }
            if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true } // fe80::/10 link-local
            if (b[0] & 0xfe) == 0xfc { return true }                  // fc00::/7 unique local
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                return isPrivateIPv4(Array(b[12..<16]))               // IPv4-mapped
            }
            return isOnLink(b, family: AF_INET6)
        default:
            return false
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let addr): return addr.rawValue.first == 127
        case .ipv6(let addr): return addr == .loopback
        default: return false
        }
    }

    /// Key for pairing lockouts: the IPv4 address, or the /64 network for IPv6 (a device can
    /// pick any address within its /64, so per-address limits alone are easy to sidestep).
    static func lockoutKey(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "\(endpoint)" }
        if case .ipv6(let addr) = host {
            let b = [UInt8](addr.rawValue)
            if b.count == 16, !(b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xff && b[11] == 0xff) {
                return b[0..<8].map { String(format: "%02x", $0) }.joined() + "::/64"
            }
        }
        return "\(host)"
    }

    /// Host part of an endpoint, for the log.
    static func hostKey(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    static func localIPv4Addresses() -> [String] {
        interfaceAddresses(family: AF_INET)
            .filter { !$0.name.hasPrefix("lo") }
            .compactMap { IPv4Address(Data($0.address))?.debugDescription }
    }

    private static func isPrivateIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        return b[0] == 10
            || (b[0] == 172 && (b[1] & 0xf0) == 16)
            || (b[0] == 192 && b[1] == 168)
            || (b[0] == 169 && b[1] == 254)
            || b[0] == 127
    }

    private static func isOnLink(_ bytes: [UInt8], family: Int32) -> Bool {
        for iface in interfaceAddresses(family: family) where iface.mask.contains(where: { $0 != 0 }) {
            guard iface.address.count == bytes.count else { continue }
            var same = true
            for i in 0..<bytes.count where (iface.address[i] & iface.mask[i]) != (bytes[i] & iface.mask[i]) {
                same = false
                break
            }
            if same { return true }
        }
        return false
    }

    private struct InterfaceAddress {
        let name: String
        let address: [UInt8]
        let mask: [UInt8]
    }

    private static func interfaceAddresses(family: Int32) -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [InterfaceAddress] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, let nm = p.pointee.ifa_netmask,
                  Int32(sa.pointee.sa_family) == family else { continue }
            let name = String(cString: p.pointee.ifa_name)
            if family == AF_INET {
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let m = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                result.append(InterfaceAddress(name: name,
                                               address: withUnsafeBytes(of: a) { Array($0) },
                                               mask: withUnsafeBytes(of: m) { Array($0) }))
            } else {
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let m = nm.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                result.append(InterfaceAddress(name: name,
                                               address: withUnsafeBytes(of: a) { Array($0) },
                                               mask: withUnsafeBytes(of: m) { Array($0) }))
            }
        }
        return result
    }
}
