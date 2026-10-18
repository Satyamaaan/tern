// Writes the Sparkle appcast for one release: a single item whose description is the release notes, rendered from
// a small Markdown subset (# headings, - bullets, paragraphs, **bold**, `code`) to the simple HTML the update
// window reads. Run by release.sh:
//   swift scripts/appcast.swift --version 0.2.0 --build 2 --notes release-notes/0.2.0.md --url <zip url> \
//     --length <bytes> --signature <edSignature> --out build/appcast.xml

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("appcast.swift: \(message)\n".utf8))
    exit(1)
}

var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let key = arguments.popFirst() {
    guard key.hasPrefix("--"), let value = arguments.popFirst() else { fail("expected --name value pairs, got \(key)") }
    options[String(key.dropFirst(2))] = value
}
func option(_ name: String) -> String {
    guard let value = options[name], !value.isEmpty else { fail("missing --\(name)") }
    return value
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// `**bold**` and `` `code` `` inside an already escaped line.
func inline(_ text: String) -> String {
    var html = escape(text)
    for (marker, tag) in [("\\*\\*", "b"), ("`", "code")] {
        html = html.replacingOccurrences(of: "\(marker)(.+?)\(marker)", with: "<\(tag)>$1</\(tag)>", options: .regularExpression)
    }
    return html
}

func render(_ markdown: String) -> String {
    var html: [String] = []
    var paragraph: [String] = []
    var bullets: [String] = []
    func flush() {
        if !paragraph.isEmpty { html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
        if !bullets.isEmpty { html.append("<ul>" + bullets.map { "<li>\(inline($0))</li>" }.joined() + "</ul>") }
        paragraph = []
        bullets = []
    }
    for raw in markdown.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            flush()
        } else if line.hasPrefix("#") {
            flush()
            html.append("<h3>\(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))</h3>")
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            if !paragraph.isEmpty { flush() }
            bullets.append(String(line.dropFirst(2)))
        } else if !bullets.isEmpty, raw.hasPrefix(" ") {
            bullets[bullets.count - 1] += " " + line
        } else {
            if !bullets.isEmpty { flush() }
            paragraph.append(line)
        }
    }
    flush()
    return html.joined(separator: "\n")
}

let version = option("version")
let build = option("build")
let url = option("url")
let length = option("length")
let signature = option("signature")
let minimumSystem = options["min-system"] ?? "15.0"
let out = URL(fileURLWithPath: option("out"))
guard let notes = try? String(contentsOfFile: option("notes"), encoding: .utf8) else { fail("can't read \(option("notes"))") }

let date = DateFormatter()
date.locale = Locale(identifier: "en_US_POSIX")
date.timeZone = TimeZone(identifier: "UTC")
date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
let description = render(notes).replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")

let xml = """
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tern</title>
    <link>https://github.com/dhruvalgolakiya/tern-releases</link>
    <description>Tern updates</description>
    <language>en</language>
    <item>
      <title>Tern \(escape(version))</title>
      <pubDate>\(date.string(from: Date()))</pubDate>
      <sparkle:version>\(escape(build))</sparkle:version>
      <sparkle:shortVersionString>\(escape(version))</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>\(escape(minimumSystem))</sparkle:minimumSystemVersion>
      <description><![CDATA[
\(description)
      ]]></description>
      <enclosure url="\(escape(url))" length="\(escape(length))" type="application/octet-stream" sparkle:edSignature="\(escape(signature))"/>
    </item>
  </channel>
</rss>

"""
do {
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try xml.write(to: out, atomically: true, encoding: .utf8)
} catch {
    fail("can't write \(out.path): \(error)")
}
