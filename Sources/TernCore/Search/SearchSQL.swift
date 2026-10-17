import Foundation
import GRDB

/// A piece of SQL with its bound values, so conditions can be combined without losing the order of `?`.
struct SQLFragment {
    var sql: String
    var arguments: [DatabaseValue]

    init(_ sql: String, _ arguments: [any DatabaseValueConvertible] = []) {
        self.sql = sql
        self.arguments = arguments.map(\.databaseValue)
    }

    static let always = SQLFragment("1")
    static let never = SQLFragment("0")

    var isNever: Bool { sql == "0" }
    var isAlways: Bool { sql == "1" }

    /// Always a single parenthesized expression, safe to splice after `AND`.
    static func all(_ parts: [SQLFragment]) -> SQLFragment {
        if parts.contains(where: \.isNever) { return .never }
        let parts = parts.filter { !$0.isAlways }
        if parts.isEmpty { return .always }
        return SQLFragment("(" + parts.map { "(\($0.sql))" }.joined(separator: " AND ") + ")", parts.flatMap(\.arguments))
    }

    static func any(_ parts: [SQLFragment]) -> SQLFragment {
        if parts.contains(where: \.isAlways) { return .always }
        let parts = parts.filter { !$0.isNever }
        if parts.isEmpty { return .never }
        return SQLFragment("(" + parts.map { "(\($0.sql))" }.joined(separator: " OR ") + ")", parts.flatMap(\.arguments))
    }

    var negated: SQLFragment {
        if isNever { return .always }
        if isAlways { return .never }
        return SQLFragment("NOT (\(sql))", arguments.map { $0 as any DatabaseValueConvertible })
    }

    /// `(?, ?, ?)` list for an IN clause.
    static func list(_ values: [any DatabaseValueConvertible]) -> SQLFragment {
        SQLFragment("(" + values.map { _ in "?" }.joined(separator: ", ") + ")", values)
    }
}

extension StatementArguments {
    init(_ values: [DatabaseValue]) {
        self.init(values.map { $0 as (any DatabaseValueConvertible)? })
    }
}

enum SearchSQL {
    /// `%text%` for `LIKE ? ESCAPE '\'`, with the wildcards in `text` made literal.
    static func containsPattern(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%" + escaped + "%"
    }

    /// Lowercased, with spaces and slashes folded to hyphens, so `label:"Work / Clients"` finds `Work/Clients`.
    static func normalizedName(_ name: String) -> String {
        var result = ""
        var lastWasSeparator = false
        for character in name.lowercased() {
            if character.isWhitespace || character == "/" || character == "-" {
                if !lastWasSeparator { result.append("-") }
                lastWasSeparator = true
            } else {
                result.append(character)
                lastWasSeparator = false
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
