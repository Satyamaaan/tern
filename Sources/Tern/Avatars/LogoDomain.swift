import Foundation

/// Which domain's icon stands for an address: its registrable domain (`mail.notifications.apple.com`
/// → `apple.com`), or nil for personal mailbox providers, where the provider's logo would be wrong
/// for a person, and for anything that isn't a plain DNS name.
enum LogoDomain {
    /// The registrable domain of the address's host, or nil when no logo should be looked for.
    static func forEmail(_ email: String) -> String? {
        let address = email.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>")))
        guard let at = address.lastIndex(of: "@") else { return nil }
        guard let domain = registrable(String(address[address.index(after: at)...])), !isPersonal(domain) else { return nil }
        return domain
    }

    /// The host reduced to the name its owner registered: the last two labels, or three under a
    /// multi-part public suffix such as `co.uk`. Nil for IP addresses, single labels and non-ASCII names.
    static func registrable(_ host: String) -> String? {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253,
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }),
              let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) || tld.hasPrefix("xn--") else { return nil }
        let keep = multiPartSuffixes.contains(labels.suffix(2).joined(separator: ".")) ? 3 : 2
        guard labels.count >= keep else { return nil }
        return labels.suffix(keep).joined(separator: ".")
    }

    /// True for providers whose addresses belong to people (Gmail, Outlook, iCloud…) and for relay and
    /// alias services; their senders get initials.
    static func isPersonal(_ domain: String) -> Bool {
        personalDomains.contains(domain) || personalBrands.contains(String(domain.prefix { $0 != "." }))
    }

    /// Providers with a domain in many countries (`hotmail.co.uk`, `yahoo.co.jp`, `gmx.de`): matched on
    /// the registrable domain's first label.
    private static let personalBrands: Set<String> = [
        "hotmail", "outlook", "live", "yahoo", "aol", "gmx", "yandex",
    ]

    private static let personalDomains: Set<String> = [
        // Google, Microsoft, Apple, Yahoo, AOL
        "gmail.com", "googlemail.com", "msn.com", "passport.com", "windowslive.com", "ymail.com", "rocketmail.com",
        "icloud.com", "me.com", "mac.com", "appleid.com", "aim.com",
        // Privacy-focused and independent providers
        "proton.me", "protonmail.com", "protonmail.ch", "pm.me", "tutanota.com", "tutanota.de", "tutamail.com",
        "tuta.io", "tuta.com", "keemail.me", "fastmail.com", "fastmail.fm", "messagingengine.com", "hey.com",
        "duck.com", "mailbox.org", "posteo.de", "posteo.net", "hushmail.com", "runbox.com", "startmail.com",
        "skiff.com", "disroot.org", "riseup.net", "zoho.com", "zohomail.com",
        // Alias, relay and throwaway services
        "mozmail.com", "simplelogin.com", "simplelogin.fr", "slmail.me", "aleeas.com", "anonaddy.com", "anonaddy.me",
        "addy.io", "33mail.com", "guerrillamail.com", "mailinator.com", "yopmail.com",
        // Mail.com family
        "mail.com", "email.com", "usa.com", "myself.com", "inbox.com",
        // Europe
        "web.de", "freenet.de", "t-online.de", "arcor.de", "orange.fr", "wanadoo.fr", "free.fr", "laposte.net",
        "sfr.fr", "neuf.fr", "libero.it", "virgilio.it", "tiscali.it", "alice.it", "seznam.cz", "centrum.cz",
        "wp.pl", "o2.pl", "interia.pl", "onet.pl", "op.pl", "abv.bg", "btinternet.com", "sky.com",
        "virginmedia.com", "ntlworld.com", "talktalk.net", "blueyonder.co.uk",
        // Russia and Ukraine
        "ya.ru", "mail.ru", "inbox.ru", "list.ru", "bk.ru", "internet.ru", "rambler.ru", "ukr.net", "i.ua",
        // Asia
        "qq.com", "foxmail.com", "163.com", "126.com", "188.com", "139.com", "yeah.net", "sina.com", "sina.cn",
        "sohu.com", "aliyun.com", "naver.com", "daum.net", "hanmail.net", "rediffmail.com",
        // North American and Australian ISPs
        "comcast.net", "verizon.net", "att.net", "sbcglobal.net", "bellsouth.net", "cox.net", "charter.net",
        "earthlink.net", "optonline.net", "juno.com", "netzero.net", "shaw.ca", "rogers.com", "sympatico.ca",
        "telus.net", "bigpond.com", "bigpond.net.au", "optusnet.com.au", "xtra.co.nz",
    ]

    /// Second-level public suffixes under which names are registered one level deeper.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "nhs.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "asn.au", "id.au",
        "co.nz", "net.nz", "org.nz", "ac.nz", "govt.nz", "school.nz",
        "co.in", "net.in", "org.in", "firm.in", "gen.in", "ind.in", "ac.in", "edu.in", "gov.in", "res.in",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "gr.jp", "ad.jp", "ed.jp", "lg.jp",
        "co.kr", "or.kr", "ac.kr", "go.kr", "ne.kr",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg", "per.sg",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "com.tw", "org.tw", "net.tw", "edu.tw", "gov.tw",
        "com.my", "net.my", "org.my", "edu.my", "gov.my",
        "co.id", "or.id", "ac.id", "go.id", "web.id",
        "co.th", "ac.th", "or.th", "go.th", "in.th",
        "com.ph", "com.vn", "com.pk", "com.bd", "com.np", "com.lk",
        "co.za", "org.za", "net.za", "gov.za", "ac.za", "co.ke", "com.ng", "com.eg", "com.sa",
        "co.il", "org.il", "ac.il", "gov.il", "com.tr", "org.tr", "edu.tr", "gov.tr", "com.ua", "com.cy", "com.mt",
        "com.mx", "org.mx", "gob.mx", "edu.mx", "com.ar", "com.co", "com.pe", "com.uy", "com.ve", "com.ec",
        "co.at", "or.at", "ac.at", "com.pl", "gouv.fr",
    ]
}
