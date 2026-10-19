import Foundation
import Testing
@testable import TernCore

private func v4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> RemoteDestination.Address { .v4(a << 24 | b << 16 | c << 8 | d) }

@Test(arguments: [
    ("127.0.0.1", v4(127, 0, 0, 1)), ("127.1", v4(127, 0, 0, 1)), ("0x7f.1", v4(127, 0, 0, 1)),
    ("0177.0.0.1", v4(127, 0, 0, 1)), ("2130706433", v4(127, 0, 0, 1)), ("0x7F000001", v4(127, 0, 0, 1)),
    ("3232235777", v4(192, 168, 1, 1)), ("0xC0A80101", v4(192, 168, 1, 1)), ("0300.0250.1.1", v4(192, 168, 1, 1)),
    ("192.168.257", v4(192, 168, 1, 1)), ("0", v4(0, 0, 0, 0)), ("0xcafe", v4(0, 0, 0xCA, 0xFE)),
    ("93.184.216.34", v4(93, 184, 216, 34)),
])
func readsEveryIPv4FormTheStackReads(_ host: String, _ expected: RemoteDestination.Address) {
    #expect(RemoteDestination.literal(host) == expected, "\(host)")
}

@Test func namesAreNotAddresses() {
    for host in ["cdn.example.com", "cafe.de", "dead.beef", "ab", "1.2.3.4.5", "999.1.1.1", "0x1g", "1..2"] {
        #expect(RemoteDestination.literal(host) == nil, "\(host)")
    }
}

@Test(arguments: [
    // IPv4: this network, private, CGNAT, loopback, link-local, IETF, documentation, 6to4 relay, benchmark,
    // multicast, reserved, broadcast.
    ("0.0.0.0", false), ("0.1.2.3", false), ("10.0.0.1", false), ("10.255.255.255", false), ("100.64.0.1", false),
    ("100.127.255.254", false), ("127.0.0.1", false), ("127.255.0.9", false), ("169.254.169.254", false),
    ("172.16.0.1", false), ("172.31.255.255", false), ("192.0.0.8", false), ("192.0.2.10", false),
    ("192.88.99.1", false), ("192.168.0.1", false), ("198.18.0.1", false), ("198.19.255.1", false),
    ("198.51.100.7", false), ("203.0.113.9", false), ("224.0.0.251", false), ("239.255.255.250", false),
    ("240.0.0.1", false), ("255.255.255.255", false),
    ("8.8.8.8", true), ("93.184.216.34", true), ("100.63.255.255", true), ("100.128.0.1", true), ("172.15.255.255", true),
    ("172.32.0.1", true), ("169.253.1.1", true), ("192.169.0.1", true), ("198.20.0.1", true), ("223.255.255.254", true),
    // IPv6: loopback, unspecified, IPv4-compatible, link-local, site-local, ULA, multicast, discard, documentation,
    // Teredo and the rest of 2001::/23; IPv4 inside IPv6 is judged as IPv4.
    ("::1", false), ("::", false), ("::10.0.0.1", false), ("fe80::1", false), ("febf::1", false), ("fec0::1", false),
    ("fc00::1", false), ("fd12:3456::1", false), ("ff02::1", false), ("100::1", false), ("2001:db8::1", false),
    ("2001::1", false), ("2001:10::1", false), ("3fff::1", false), ("64:ff9b:1::1", false),
    ("::ffff:192.168.1.1", false), ("::ffff:c0a8:101", false), ("::ffff:127.0.0.1", false), ("::ffff:0:0", false),
    ("64:ff9b::a00:1", false), ("2002:c0a8:101::1", false), ("2002:7f00:1::", false),
    ("2606:4700:4700::1111", true), ("2a00:1450:4001:81b::200e", true), ("::ffff:93.184.216.34", true),
    ("64:ff9b::5db8:d822", true), ("2002:5db8:d822::1", true), ("2001:4860:4860::8888", true),
])
func classifiesAddresses(_ host: String, _ isPublic: Bool) throws {
    let address = try #require(RemoteDestination.literal(host), "\(host)")
    #expect(RemoteDestination.isPublic(address) == isPublic, "\(host)")
}

@Test(arguments: [
    "http://127.0.0.1/x.png", "http://127.1/x.png", "http://0x7f.1/x.png", "http://0x7f000001/", "http://2130706433/",
    "http://3232235777/x.png", "http://0300.0250.1.1/", "http://1572395042/", "http://0x5db8d822/", "http://93.184.55302/",
    "http://093.184.216.34/", "http://0x1c0a80101/", "http://[::1]/x.png", "http://[::ffff:192.168.1.1]/x.png",
    "http://[::ffff:c0a8:101]/", "http://[fe80::1%25en0]/", "http://[fd00::1]/", "http://192.168.1.1./",
    "http://localhost/x.png", "http://LOCALHOST./x.png", "http://a.localhost/", "http://printer.local/",
    "http://router.home.arpa/", "http://db.internal/", "http://nas.lan/", "http://intranet/", "http://wpad/",
    "http://127.0.0.%31/", "http://1.2.3.4.5/", "http://999.1.1.1/", "http://4294967296/", "http://example.0x1/",
    "http://169.254.169.254/latest/meta-data/", "http://100.100.100.100/", "http://cdn.example.com:8080/x.png",
    "https://cdn.example.com:22/", "http://cdn.example.com:0/", "https://user:pw@cdn.example.com/x.png",
    "https://user@cdn.example.com/x.png", "ftp://cdn.example.com/x.png", "file:///etc/passwd", "gopher://cdn.example.com/",
    "http:///x.png", "http://exa mple.com/",
])
func refusesLocalDestinations(_ string: String) {
    guard let url = URL(string: string) else { return }
    #expect(!RemoteDestination.allows(url), "\(string)")
}

@Test(arguments: [
    "https://res.cloudinary.com/acme/image/upload/v1/emails/logo.png", "http://cdn.example.com/x.png",
    "https://cdn.example.com:443/x.png", "http://cdn.example.com:80/x.png", "https://CDN.Example.COM./x.png",
    "http://93.184.216.34/x.png", "http://[2606:4700:4700::1111]/x.png", "https://img_1.cdn-host.co.uk/a/b.gif",
])
func allowsPublicDestinations(_ string: String) throws {
    #expect(RemoteDestination.allows(try #require(URL(string: string))), "\(string)")
}

@Test func loopbackOnlyForTheHarnessAndOnlyAsAnAddress() throws {
    let server = try #require(URL(string: "http://127.0.0.1:18766/hero.png"))
    #expect(!RemoteDestination.allows(server))
    #expect(RemoteDestination.allows(server, allowLoopback: true))
    #expect(RemoteDestination.allows(try #require(URL(string: "http://[::1]:18766/x")), allowLoopback: true))
    for other in ["http://localhost:18766/x", "http://10.0.0.1:18766/x", "http://192.168.1.1/x", "http://[fe80::1]/x"] {
        #expect(!RemoteDestination.allows(try #require(URL(string: other)), allowLoopback: true), "\(other)")
    }
}

@Test func resolvesNumericHostsWithoutTheNetwork() async throws {
    let addresses = try #require(await RemoteDestination.resolve("127.0.0.1"))
    #expect(addresses.contains(v4(127, 0, 0, 1)) && !addresses.contains(where: RemoteDestination.isPublic))
}
