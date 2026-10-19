import Darwin
import Foundation

/// Where Tern may fetch a mail image from: the public internet, by name, and nothing else. Images load without a
/// click, so mail must not be able to make the Mac reach itself or its network (a router page, a printer, a dev
/// server). Local names are refused, a name must resolve to public addresses only, and names are fetched over HTTPS
/// only (`requestURL`). Addresses written as the host are refused outright, public ones too: a router's WAN address
/// (through NAT loopback) or a LAN device's global IPv6 address is public and still reaches the user's own network,
/// and with no name there's no certificate to check, so nothing would stop a request there. Mail images use names.
/// The address checks (`isPublic`, `literal`) judge what names resolve to.
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

    /// Checks `url` without touching the network: http(s), no user info, port 80 or 443, and a public-looking name
    /// (resolve it with `resolve` before connecting). An address as the host is refused in any form the network
    /// stack reads (`3232235777`, `0x7f.1`, `[::ffff:192.168.1.1]`), except that `allowLoopback` lets a loopback
    /// address through on any port, for the snapshot harness's image server in debug builds.
    public static func allows(_ url: URL, allowLoopback: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, let host = host(of: url) else { return false }
        if let address = literal(host) { return allowLoopback && isLoopback(address) }
        return isPublicName(host) && (url.port == nil || url.port == 80 || url.port == 443)
    }

    /// The URL Tern requests for `url`, or nil when it may not be fetched. Names always go over HTTPS: `http://name/…`
    /// becomes `https://name/…`, and a name on any port but the scheme's own is refused. That TLS is load-bearing
    /// against DNS rebinding: the addresses checked before connecting can't be pinned for the connection, so a name
    /// that answers with a private address by then still needs a certificate for that name, which the router or
    /// printer behind the address doesn't have, and the request is never sent.
    public static func requestURL(for url: URL, allowLoopback: Bool = false) -> URL? {
        guard allows(url, allowLoopback: allowLoopback), let host = host(of: url) else { return nil }
        if literal(host) != nil { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch (components.scheme?.lowercased(), url.port) {
        case ("http", nil), ("http", 80), ("https", nil), ("https", 443): break
        default: return nil
        }
        components.scheme = "https"
        components.host = host
        components.port = nil
        return components.url
    }

    /// The URL's host, lowercased, without brackets or trailing dots; nil when it is missing or percent-encoded.
    public static func host(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: true)?.lowercased(), !host.contains("%") else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

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
                // No AI_ADDRCONFIG: every A and AAAA answer is judged, also for a family this Mac isn't using right now.
                var hints = addrinfo()
                hints.ai_flags = 0
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
