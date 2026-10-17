import Foundation

/// Gmail's batch format: one `multipart/mixed` POST to `/batch/gmail/v1` carrying up to 100 HTTP
/// requests, each in an `application/http` part with a `Content-ID`. The response is
/// `multipart/mixed` too; each part holds an HTTP response whose `Content-ID` is
/// `response-<request Content-ID>`. Every inner request costs its normal quota.
enum GmailBatch {
    /// The most sub-requests Tern puts in one batch. Google allows 100 but advises staying under 50
    /// to avoid rate limiting.
    static let maxRequests = 50

    struct Part {
        var contentId: String?
        var status: Int
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Builds the request body. `paths` are `/gmail/v1/…` paths with their query; part `i` gets
    /// `Content-ID: <item-i>`.
    static func body(paths: [String], boundary: String) -> Data {
        var text = ""
        for (index, path) in paths.enumerated() {
            text += "--\(boundary)\r\n"
            text += "Content-Type: application/http\r\n"
            text += "Content-ID: <item-\(index)>\r\n"
            text += "\r\n"
            text += "GET \(path)\r\n"
            text += "\r\n"
        }
        text += "--\(boundary)--\r\n"
        return Data(text.utf8)
    }

    /// The request index a response part answers, from `<response-item-N>`.
    static func index(of part: Part) -> Int? {
        guard var id = part.contentId?.trimmingCharacters(in: .whitespaces) else { return nil }
        if id.hasPrefix("<") && id.hasSuffix(">") { id = String(id.dropFirst().dropLast()) }
        for prefix in ["response-", "item-"] where id.hasPrefix(prefix) { id.removeFirst(prefix.count) }
        return Int(id)
    }

    /// `boundary` parameter of a `multipart/…` Content-Type.
    static func boundary(fromContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else { continue }
            return pair[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Splits a batch response into its HTTP responses.
    static func parse(_ data: Data, boundary: String) throws -> [Part] {
        try MultipartReader.split(data, boundary: boundary).map { section in
            let (outerHeaders, httpMessage) = MultipartReader.headersAndBody(section)
            let (statusLine, headers, body) = try parseHTTPResponse(httpMessage)
            let words = statusLine.split(separator: " ")
            guard words.count >= 2, words[0].hasPrefix("HTTP/"), let status = Int(words[1]) else {
                throw GmailAPIError.server(status: 0, message: "Bad batch part status line: \(statusLine)")
            }
            let contentId = outerHeaders.first { $0.key.caseInsensitiveCompare("Content-ID") == .orderedSame }?.value
            return Part(contentId: contentId, status: status, headers: headers, body: body)
        }
    }

    private static func parseHTTPResponse(_ data: Data) throws -> (String, [String: String], Data) {
        let (lines, body) = MultipartReader.headerLinesAndBody(data)
        guard let statusLine = lines.first else {
            throw GmailAPIError.server(status: 0, message: "Empty batch part")
        }
        return (statusLine, MultipartReader.headerFields(lines.dropFirst()), body)
    }
}

/// Minimal MIME multipart reading, enough for batch responses (and tests of Tern's own output).
enum MultipartReader {
    /// The bodies between the boundary delimiters, without the CRLF that belongs to each delimiter.
    static func split(_ data: Data, boundary: String) throws -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var sections: [Data] = []
        var searchStart = data.startIndex
        guard var current = data.range(of: delimiter, in: searchStart..<data.endIndex) else {
            throw GmailAPIError.server(status: 0, message: "Multipart body without its boundary")
        }
        while true {
            searchStart = current.upperBound
            // "--" right after the delimiter closes the multipart.
            if data[searchStart...].starts(with: Data("--".utf8)) { break }
            guard let next = data.range(of: delimiter, in: searchStart..<data.endIndex) else { break }
            var section = data[searchStart..<next.lowerBound]
            section = dropLeadingLineBreak(section)
            section = dropTrailingLineBreak(section)
            sections.append(Data(section))
            current = next
        }
        return sections
    }

    /// Splits a part into its header fields and body at the first empty line.
    static func headersAndBody(_ data: Data) -> ([String: String], Data) {
        let (lines, body) = headerLinesAndBody(data)
        return (headerFields(lines[...]), body)
    }

    static func headerLinesAndBody(_ data: Data) -> ([String], Data) {
        let crlf = data.range(of: Data("\r\n\r\n".utf8))
        let lf = data.range(of: Data("\n\n".utf8))
        let separator: Range<Data.Index>?
        switch (crlf, lf) {
        case let (crlf?, lf?): separator = crlf.lowerBound <= lf.lowerBound ? crlf : lf
        case let (crlf?, nil): separator = crlf
        case let (nil, lf?): separator = lf
        case (nil, nil): separator = nil
        }
        let head = separator.map { data[data.startIndex..<$0.lowerBound] } ?? data[...]
        let body = separator.map { Data(data[$0.upperBound...]) } ?? Data()
        var lines: [String] = []
        for raw in String(decoding: head, as: UTF8.self).components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        return (lines, body)
    }

    static func headerFields(_ lines: ArraySlice<String>) -> [String: String] {
        var fields: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    private static func dropLeadingLineBreak(_ data: Data) -> Data {
        if data.starts(with: Data("\r\n".utf8)) { return data.dropFirst(2) }
        if data.starts(with: Data("\n".utf8)) { return data.dropFirst(1) }
        return data
    }

    private static func dropTrailingLineBreak(_ data: Data) -> Data {
        if data.count >= 2, data.suffix(2) == Data("\r\n".utf8) { return data.dropLast(2) }
        if data.last == UInt8(ascii: "\n") { return data.dropLast(1) }
        return data
    }
}
