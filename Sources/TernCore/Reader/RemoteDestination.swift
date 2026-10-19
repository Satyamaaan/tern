import Darwin
import Foundation

/// Where Tern may fetch a mail image from: the public internet, and nothing else. Images load without a
/// click, so mail must not be able to make the Mac reach itself or its network (a router page, a printer, a
/// dev server). Loopback, private, link-local, shared, multicast and reserved addresses are refused, in any
/// form the network stack reads (`3232235777`, `0x7f.1`, `[::ffff:192.168.1.1]`); IPv4 is accepted only as a
/// plain dotted quad. Local names are refused too.
/// Only ports 80 and 443 are allowed: mail images live there, and the other ports are where local and
/// admin services listen, which also keeps a DNS answer that changes between the check and the fetch
/// away from them.
public enum RemoteDestination {
    /// An IP address, as the network stack would connect to it.
    public enum Address: Hashable, Sendable {
        case v4(UInt32)
        case v6([UInt8])
    }

    /// Names that never mean a public site: local ones, and the reserved names that never resolve (refused without
    /// asking DNS).
    static let localSuffixes = [
        "localhost", "local", "internal", "home.arpa", "localdomain", "lan", "intranet", "corp", "home", "private",
        "example", "test", "invalid", "onion", "alt",
    ]

    /// Checks `url` without touching the network: http(s), no user info, port 80 or 443, and a host that is a
    /// public address or a public-looking name (resolve it with `resolve` before connecting).
    /// `allowLoopback` lets loopback addresses through on any port, for the snapshot harness's image server in
    /// debug builds; names stay refused.
    public static func allows(_ url: URL, allowLoopback: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, let host = host(of: url) else { return false }
        if let address = literal(host) {
            if allowLoopback, isLoopback(address) { return true }
            // Decimal, hex, octal and short IPv4 forms only ever hide where a request goes.
            if case .v4 = address, !isDottedQuad(host) { return false }
            return isPublic(address) && standardPort(url.port)
        }
        return isPublicName(host) && standardPort(url.port)
    }

    /// The URL's host, lowercased, without brackets or trailing dots; nil when it is missing or percent-encoded.
    public static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: true)?.lowercased(), !host.contains("%") else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    private static func standardPort(_ port: Int?) -> Bool { port == nil || port == 80 || port == 443 }

    /// A host the network stack would read as an address, in any of the forms it accepts: dotted, short
    /// (`127.1`), decimal, octal and hex IPv4, and IPv6.
    public static func literal(_ host: String) -> Address? {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
            return .v6(withUnsafeBytes(of: &address) { Array($0) })
        }
        guard !host.isEmpty, host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" }) else { return nil }
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return nil }
        return .v4(UInt32(bigEndian: address.s_addr))
    }

    /// `a.b.c.d` with four decimal parts of 0–255 and no leading zeros.
    static func isDottedQuad(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  part == "0" || !part.hasPrefix("0"), let value = Int(part) else { return false }
            return value <= 255
        }
    }

    /// A name that can only resolve on the public internet: dotted, plain ASCII, not a local suffix, and not
    /// ending in a number (an address the stack couldn't read, like `1.2.3.4.5`).
    static func isPublicName(_ host: String) -> Bool {
        guard host.contains("."), host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") })
        else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }), let last = labels.last,
              !last.allSatisfy(\.isNumber), !last.hasPrefix("0x") else { return false }
        return !localSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// True for an address on the public internet. IPv6 counts only in global unicast (2000::/3) outside its
    /// special ranges; an IPv4 address carried inside IPv6 (mapped, NAT64, 6to4) is judged as IPv4.
    public static func isPublic(_ address: Address) -> Bool {
        switch address {
        case .v4(let value):
            return !reservedV4.contains { value >> (32 - $0.bits) == $0.base >> (32 - $0.bits) }
        case .v6(let bytes):
            if let embedded = embeddedV4(bytes) { return isPublic(.v4(embedded)) }
            guard bytes[0] & 0xE0 == 0x20 else { return false }
            if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] < 0x02 { return false } // 2001::/23 incl. Teredo
            if bytes[0..<4] == [0x20, 0x01, 0x0D, 0xB8] { return false }           // 2001:db8::/32 documentation
            if bytes[0] == 0x3F, bytes[1] == 0xFF, bytes[2] & 0xF0 == 0 { return false } // 3fff::/20 documentation
            return true
        }
    }

    static func isLoopback(_ address: Address) -> Bool {
        switch address {
        case .v4(let value): value >> 24 == 127
        case .v6(let bytes): bytes == Array(repeating: 0, count: 15) + [1] || embeddedV4(bytes).map { $0 >> 24 == 127 } == true
        }
    }

    /// The IPv4 address inside an IPv4-mapped (::ffff:0:0/96), NAT64 (64:ff9b::/96) or 6to4 (2002::/16) address.
    static func embeddedV4(_ bytes: [UInt8]) -> UInt32? {
        func value(_ slice: ArraySlice<UInt8>) -> UInt32 { slice.reduce(0) { $0 << 8 | UInt32($1) } }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF { return value(bytes[12..<16]) }
        if bytes[0..<4] == [0x00, 0x64, 0xFF, 0x9B], bytes[4..<12].allSatisfy({ $0 == 0 }) { return value(bytes[12..<16]) }
        if bytes[0] == 0x20, bytes[1] == 0x02 { return value(bytes[2..<6]) }
        return nil
    }

    /// IPv4 ranges that aren't the public internet: this network, private, shared (CGNAT), loopback,
    /// link-local, IETF and documentation blocks, the 6to4 relay, benchmarking, multicast and reserved.
    static let reservedV4: [(base: UInt32, bits: UInt32)] = [
        (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
        (0xAC10_0000, 12), (0xC000_0000, 24), (0xC000_0200, 24), (0xC058_6300, 24), (0xC0A8_0000, 16),
        (0xC612_0000, 15), (0xC633_6400, 24), (0xCB00_7100, 24), (0xE000_0000, 4), (0xF000_0000, 4),
    ]

    /// The addresses `host` resolves to, looked up on a thread of its own; nil when it doesn't resolve.
    public static func resolve(_ host: String) async -> [Address]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_flags = AI_DEFAULT
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var list: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { freeaddrinfo(first) }
                var addresses: [Address] = []
                for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
                    guard let socket = entry.pointee.ai_addr else { continue }
                    switch Int32(socket.pointee.sa_family) {
                    case AF_INET:
                        socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                            addresses.append(.v4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)))
                        }
                    case AF_INET6:
                        socket.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                            var address = $0.pointee.sin6_addr
                            addresses.append(.v6(withUnsafeBytes(of: &address) { Array($0) }))
                        }
                    default:
                        continue
                    }
                }
                continuation.resume(returning: addresses.isEmpty ? nil : addresses)
            }
        }
    }
}
