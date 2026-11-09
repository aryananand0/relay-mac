import Foundation

/// The small subset of ASN.1 DER needed to build X.509 certificates (TLSIdentity).
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func sequence(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: Data...) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func boolean(_ v: Bool) -> Data { tlv(0x01, Data([v ? 0xff : 0x00])) }
    static func octetString(_ d: Data) -> Data { tlv(0x04, d) }
    static func utf8String(_ s: String) -> Data { tlv(0x0c, Data(s.utf8)) }
    static func null() -> Data { Data([0x05, 0x00]) }

    /// A non-negative INTEGER from big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        var b = Data(bytes.drop { $0 == 0 })
        if b.isEmpty { b = Data([0]) }
        if b.first! & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }
    static func integer(_ v: Int) -> Data {
        var bytes = Data()
        var x = v
        repeat { bytes.insert(UInt8(x & 0xff), at: 0); x >>= 8 } while x > 0
        return integer(bytes)
    }

    /// BIT STRING with `unused` padding bits in the last byte.
    static func bitString(_ d: Data, unused: UInt8 = 0) -> Data { tlv(0x03, Data([unused]) + d) }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").map { UInt64($0)! }
        var body = Data([UInt8(parts[0] * 40 + parts[1])])
        for var p in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(p & 0x7f)]
            p >>= 7
            while p > 0 { chunk.insert(UInt8(p & 0x7f) | 0x80, at: 0); p >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tlv(0x06, body)
    }

    /// UTCTime before 2050, GeneralizedTime after (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: f.timeZone, from: date).year!
        f.dateFormat = year < 2050 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return tlv(year < 2050 ? 0x17 : 0x18, Data(f.string(from: date).utf8))
    }

    /// Context-specific tag: EXPLICIT (constructed) or IMPLICIT primitive.
    static func explicit(_ n: UInt8, _ content: Data) -> Data { tlv(0xa0 | n, content) }
    static func implicit(_ n: UInt8, _ raw: Data) -> Data { tlv(0x80 | n, raw) }
    static func implicitConstructed(_ n: UInt8, _ content: Data) -> Data { tlv(0xa0 | n, content) }
}
