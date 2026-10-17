import Foundation

// Gmail and OAuth use base64url (RFC 4648 §5): "-" and "_" instead of "+" and "/", usually unpadded.

extension Data {
    /// Encodes as base64url without padding.
    public func base64URLEncodedString() -> String {
        var bytes = Array(base64EncodedData())
        while bytes.last == UInt8(ascii: "=") { bytes.removeLast() }
        for i in bytes.indices {
            switch bytes[i] {
            case UInt8(ascii: "+"): bytes[i] = UInt8(ascii: "-")
            case UInt8(ascii: "/"): bytes[i] = UInt8(ascii: "_")
            default: break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Decodes base64url (or plain base64), padded or not. Whitespace is ignored.
    public init?(base64URLEncoded string: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count + 3)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "-"): bytes.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"): bytes.append(UInt8(ascii: "/"))
            case UInt8(ascii: "="), UInt8(ascii: " "), UInt8(ascii: "\r"), UInt8(ascii: "\n"), UInt8(ascii: "\t"): break
            default: bytes.append(byte)
            }
        }
        switch bytes.count % 4 {
        case 1: return nil
        case 2: bytes += [UInt8(ascii: "="), UInt8(ascii: "=")]
        case 3: bytes.append(UInt8(ascii: "="))
        default: break
        }
        self.init(base64Encoded: Data(bytes))
    }
}
