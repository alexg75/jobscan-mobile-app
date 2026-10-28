import Foundation

/// A minimal TOML reader: enough for jobscan's config.toml (and hand edits of it).
///
/// Supports comments, `key = value`, `[table]`, `[[array of tables]]`, basic and
/// literal strings, integers, floats, booleans, arrays (also multi-line) and inline
/// tables. Not supported (reported as an error): dotted keys, multi-line strings, dates.
public indirect enum TOMLValue: Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case bool(Bool)
    case array([TOMLValue])
    case table(TOMLTable)

    var typeName: String {
        switch self {
        case .string: return "string"
        case .integer: return "integer"
        case .float: return "number"
        case .bool: return "boolean"
        case .array: return "array"
        case .table: return "table"
        }
    }
}

/// A TOML table that remembers key order (it matters for `extra_params`).
public struct TOMLTable: Sendable {
    public private(set) var entries: [(key: String, value: TOMLValue)] = []

    public init() {}

    public subscript(key: String) -> TOMLValue? {
        entries.first(where: { $0.key == key })?.value
    }

    mutating func insert(_ key: String, _ value: TOMLValue, line: Int) throws {
        guard self[key] == nil else { throw TOMLError(message: "duplicate key '\(key)'", line: line) }
        entries.append((key, value))
    }

    mutating func replace(_ key: String, _ value: TOMLValue) {
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries[index] = (key, value)
        } else {
            entries.append((key, value))
        }
    }
}

public struct TOMLError: Error, LocalizedError, Equatable {
    public let message: String
    public let line: Int
    public var errorDescription: String? { "config.toml line \(line): \(message)" }
}

public enum TOML {
    public static func parse(_ text: String) throws -> TOMLTable {
        var parser = TOMLParser(chars: Array(text))
        return try parser.document()
    }
}

private struct TOMLParser {
    let chars: [Character]
    var i = 0
    var line = 1

    private enum Target { case root, table(String), arrayItem(String) }

    init(chars: [Character]) { self.chars = chars }

    var atEnd: Bool { i >= chars.count }
    var current: Character? { atEnd ? nil : chars[i] }

    func error(_ message: String) -> TOMLError { TOMLError(message: message, line: line) }

    func peek(_ s: String) -> Bool {
        var j = i
        for ch in s {
            guard j < chars.count, chars[j] == ch else { return false }
            j += 1
        }
        return true
    }

    mutating func expect(_ s: String) throws {
        guard peek(s) else { throw error("expected '\(s)'") }
        i += s.count
    }

    /// Spaces and tabs only.
    mutating func skipSpaces() {
        while let c = current, c == " " || c == "\t" { i += 1 }
    }

    mutating func skipComment() {
        guard current == "#" else { return }
        while let c = current, !c.isNewline { i += 1 }
    }

    /// Spaces, tabs, comments and line breaks.
    mutating func skipBlank() {
        while let c = current {
            if c == " " || c == "\t" {
                i += 1
            } else if c == "#" {
                skipComment()
            } else if c.isNewline {
                i += 1
                line += 1
            } else {
                return
            }
        }
    }

    mutating func endOfLine() throws {
        skipSpaces()
        skipComment()
        guard let c = current else { return }
        guard c.isNewline else { throw error("unexpected '\(c)' after value") }
        i += 1
        line += 1
    }

    mutating func document() throws -> TOMLTable {
        var root = TOMLTable()
        var target = Target.root
        while true {
            skipBlank()
            guard !atEnd else { break }
            if peek("[[") {
                i += 2
                skipSpaces()
                let name = try key()
                skipSpaces()
                try expect("]]")
                var items: [TOMLValue] = []
                if let existing = root[name] {
                    guard case .array(let array) = existing else { throw error("'\(name)' is not an array of tables") }
                    items = array
                }
                items.append(.table(TOMLTable()))
                root.replace(name, .array(items))
                target = .arrayItem(name)
            } else if current == "[" {
                i += 1
                skipSpaces()
                let name = try key()
                skipSpaces()
                try expect("]")
                if root[name] == nil { try root.insert(name, .table(TOMLTable()), line: line) }
                guard case .table = root[name]! else { throw error("'\(name)' is not a table") }
                target = .table(name)
            } else {
                let name = try key()
                skipSpaces()
                try expect("=")
                skipSpaces()
                let v = try value()
                try assign(name, v, to: target, in: &root)
            }
            try endOfLine()
        }
        return root
    }

    private func assign(_ name: String, _ v: TOMLValue, to target: Target, in root: inout TOMLTable) throws {
        switch target {
        case .root:
            try root.insert(name, v, line: line)
        case .table(let tableName):
            guard case .table(var table) = root[tableName]! else { return }
            try table.insert(name, v, line: line)
            root.replace(tableName, .table(table))
        case .arrayItem(let arrayName):
            guard case .array(var items) = root[arrayName]!, case .table(var table) = items[items.count - 1] else { return }
            try table.insert(name, v, line: line)
            items[items.count - 1] = .table(table)
            root.replace(arrayName, .array(items))
        }
    }

    mutating func key() throws -> String {
        let name: String
        if current == "\"" {
            name = try basicString()
        } else if current == "'" {
            name = try literalString()
        } else {
            var s = ""
            while let c = current, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" {
                s.append(c)
                i += 1
            }
            guard !s.isEmpty else { throw error(atEnd ? "unexpected end of file" : "unexpected '\(current!)'") }
            name = s
        }
        if current == "." { throw error("dotted keys are not supported") }
        return name
    }

    mutating func value() throws -> TOMLValue {
        guard let c = current else { throw error("missing value") }
        switch c {
        case "\"":
            if peek("\"\"\"") { throw error("multi-line strings are not supported") }
            return .string(try basicString())
        case "'":
            if peek("'''") { throw error("multi-line strings are not supported") }
            return .string(try literalString())
        case "[":
            return try array()
        case "{":
            return try inlineTable()
        case "t", "f":
            if peek("true") { i += 4; return .bool(true) }
            if peek("false") { i += 5; return .bool(false) }
            throw error("unknown value")
        default:
            return try number()
        }
    }

    mutating func array() throws -> TOMLValue {
        i += 1  // [
        var items: [TOMLValue] = []
        while true {
            skipBlank()
            if current == "]" { i += 1; break }
            items.append(try value())
            skipBlank()
            if current == "," { i += 1; continue }
            if current == "]" { i += 1; break }
            throw error("expected ',' or ']' in array")
        }
        return .array(items)
    }

    mutating func inlineTable() throws -> TOMLValue {
        i += 1  // {
        var table = TOMLTable()
        skipSpaces()
        if current == "}" { i += 1; return .table(table) }
        while true {
            skipSpaces()
            let name = try key()
            skipSpaces()
            try expect("=")
            skipSpaces()
            try table.insert(name, try value(), line: line)
            skipSpaces()
            if current == "," { i += 1; continue }
            if current == "}" { i += 1; break }
            throw error("expected ',' or '}' in inline table")
        }
        return .table(table)
    }

    mutating func number() throws -> TOMLValue {
        var s = ""
        while let c = current, c.isASCII, c.isNumber || "+-._eE".contains(c) {
            s.append(c)
            i += 1
        }
        let clean = s.replacingOccurrences(of: "_", with: "")
        if !clean.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let n = Int(clean) {
            return .integer(n)
        }
        if let d = Double(clean) { return .float(d) }
        throw error(s.isEmpty ? "unexpected '\(current.map { String($0) } ?? "end of file")'" : "invalid number '\(s)'")
    }

    mutating func basicString() throws -> String {
        i += 1  // opening quote
        var s = ""
        while true {
            guard let c = current else { throw error("unterminated string") }
            if c.isNewline { throw error("unterminated string") }
            i += 1
            if c == "\"" { return s }
            if c != "\\" { s.append(c); continue }
            guard let e = current else { throw error("unterminated string") }
            i += 1
            switch e {
            case "b": s.append("\u{08}")
            case "t": s.append("\t")
            case "n": s.append("\n")
            case "f": s.append("\u{0C}")
            case "r": s.append("\r")
            case "\"": s.append("\"")
            case "\\": s.append("\\")
            case "u", "U":
                let width = e == "u" ? 4 : 8
                guard i + width <= chars.count,
                      let code = UInt32(String(chars[i..<(i + width)]), radix: 16),
                      let scalar = Unicode.Scalar(code) else { throw error("invalid unicode escape") }
                s.unicodeScalars.append(scalar)
                i += width
            default:
                throw error("invalid escape '\\\(e)'")
            }
        }
    }

    mutating func literalString() throws -> String {
        i += 1  // opening quote
        var s = ""
        while true {
            guard let c = current, !c.isNewline else { throw error("unterminated string") }
            i += 1
            if c == "'" { return s }
            s.append(c)
        }
    }
}
