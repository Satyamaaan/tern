import Foundation

/// Character references for mail HTML: numeric references and the named ones mail actually uses.
/// Unknown names stay literal, which is also what browsers show.
enum HTMLEntities {
    static func decode(_ text: String) -> String {
        guard text.utf8.contains(0x26) else { return text }
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while let amp = text[index...].firstIndex(of: "&") {
            output += text[index..<amp]
            if let (decoded, end) = reference(in: text, at: amp) {
                output += decoded
                index = end
            } else {
                output.append("&")
                index = text.index(after: amp)
            }
        }
        output += text[index...]
        return output
    }

    /// Escapes text for use inside a double-quoted attribute value or element content.
    static func escape(_ text: String) -> String {
        guard text.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 }) else { return text }
        var output = ""
        output.reserveCapacity(text.utf8.count + 16)
        for character in text.unicodeScalars {
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            default: output.unicodeScalars.append(character)
            }
        }
        return output
    }

    private static func reference(in text: String, at amp: String.Index) -> (String, String.Index)? {
        var cursor = text.index(after: amp)
        guard cursor < text.endIndex else { return nil }
        if text[cursor] == "#" {
            cursor = text.index(after: cursor)
            var hex = false
            if cursor < text.endIndex, text[cursor] == "x" || text[cursor] == "X" {
                hex = true
                cursor = text.index(after: cursor)
            }
            let digitsStart = cursor
            while cursor < text.endIndex, text[cursor].isASCII,
                  hex ? text[cursor].isHexDigit : text[cursor].isNumber {
                cursor = text.index(after: cursor)
            }
            guard cursor > digitsStart else { return nil }
            let digits = text[digitsStart..<cursor].prefix(8)
            let value = UInt32(digits, radix: hex ? 16 : 10) ?? 0xFFFD
            if cursor < text.endIndex, text[cursor] == ";" { cursor = text.index(after: cursor) }
            return (String(scalar(for: value)), cursor)
        }
        let nameStart = cursor
        while cursor < text.endIndex, text[cursor].isASCII, text[cursor].isLetter || text[cursor].isNumber,
              text.distance(from: nameStart, to: cursor) < 12 {
            cursor = text.index(after: cursor)
        }
        let name = String(text[nameStart..<cursor])
        guard !name.isEmpty else { return nil }
        if cursor < text.endIndex, text[cursor] == ";", let value = named[name] {
            return (value, text.index(after: cursor))
        }
        if legacy.contains(name), let value = named[name] {
            if cursor < text.endIndex, text[cursor] == "=" { return nil }
            return (value, cursor)
        }
        return nil
    }

    private static func scalar(for value: UInt32) -> Character {
        if (0x80...0x9F).contains(value), let mapped = windows1252[value] { return Character(Unicode.Scalar(mapped)!) }
        guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return Character(scalar)
    }

    /// Names browsers also accept without the trailing semicolon.
    private static let legacy: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg", "AMP", "LT", "GT", "QUOT"]

    private static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
        0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
        0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    private static let named: [String: String] = [
        "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">", "quot": "\"", "QUOT": "\"",
        "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™", "hellip": "…",
        "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”",
        "bdquo": "„", "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "times": "×", "divide": "÷",
        "plusmn": "±", "para": "¶", "sect": "§", "dagger": "†", "Dagger": "‡", "permil": "‰", "prime": "′",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}", "shy": "\u{00AD}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "hairsp": "\u{200A}",
        "iexcl": "¡", "iquest": "¿", "acute": "´", "uml": "¨", "ordf": "ª", "ordm": "º", "not": "¬",
        "macr": "¯", "sup1": "¹", "sup2": "²", "sup3": "³", "frac14": "¼", "frac12": "½", "frac34": "¾",
        "micro": "µ", "cedil": "¸", "curren": "¤", "brvbar": "¦", "larr": "←", "rarr": "→", "uarr": "↑",
        "darr": "↓", "harr": "↔", "check": "✓", "star": "☆", "hearts": "♥", "spades": "♠", "clubs": "♣",
        "diams": "♦", "loz": "◊", "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "minus": "−",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í",
        "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ",
        "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý",
        "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å",
        "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "igrave": "ì",
        "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô",
        "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü",
        "yacute": "ý", "yuml": "ÿ", "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
    ]
}
