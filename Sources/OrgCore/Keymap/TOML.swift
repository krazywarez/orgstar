import Foundation

/// The part of TOML keymaps use: `[table]` and `[[array-of-tables]]` headers, and
/// `key = value` lines with basic or literal strings, booleans and integers. Comments start
/// with `#` outside strings.
public enum TOML {
    public enum Value: Sendable, Equatable {
        case string(String)
        case bool(Bool)
        case integer(Int)

        public var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var bool: Bool? {
            if case .bool(let value) = self { return value }
            return nil
        }

        public var integer: Int? {
            if case .integer(let value) = self { return value }
            return nil
        }
    }

    public struct Table: Sendable, Equatable {
        /// Empty for keys before the first header.
        public var name: String
        /// Declared with `[[name]]`.
        public var isArrayElement: Bool
        public var values: [String: Value]
        /// 1-based line of the header.
        public var line: Int
        /// The keys in the order they appear.
        public var keys: [String] = []
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// Tables in file order.
    public static func parse(_ text: String) throws -> [Table] {
        var tables = [Table(name: "", isArrayElement: false, values: [:], line: 0)]
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = index + 1
            let line = rawLine.trimmingCharacters(in: [" ", "\t", "\r"])
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                let isArray = line.hasPrefix("[[")
                let close = isArray ? "]]" : "]"
                let body = line.dropFirst(isArray ? 2 : 1)
                guard let end = body.range(of: close) else { throw ParseError(line: number, message: "unclosed table header") }
                let rest = body[end.upperBound...].trimmingCharacters(in: [" ", "\t"])
                guard rest.isEmpty || rest.hasPrefix("#") else { throw ParseError(line: number, message: "text after table header") }
                let name = body[..<end.lowerBound].trimmingCharacters(in: [" ", "\t"])
                guard !name.isEmpty else { throw ParseError(line: number, message: "empty table name") }
                tables.append(Table(name: name, isArrayElement: isArray, values: [:], line: number))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { throw ParseError(line: number, message: "expected key = value") }
            let key = line[..<equals].trimmingCharacters(in: [" ", "\t"])
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                throw ParseError(line: number, message: "bad key")
            }
            var rest = Substring(line[line.index(after: equals)...]).drop { $0 == " " || $0 == "\t" }
            let value = try parseValue(&rest, line: number)
            rest = rest.drop { $0 == " " || $0 == "\t" }
            guard rest.isEmpty || rest.first == "#" else { throw ParseError(line: number, message: "text after value") }
            guard tables[tables.count - 1].values[key] == nil else { throw ParseError(line: number, message: "duplicate key \(key)") }
            tables[tables.count - 1].values[key] = value
            tables[tables.count - 1].keys.append(key)
        }
        return tables
    }

    private static func parseValue(_ rest: inout Substring, line: Int) throws -> Value {
        switch rest.first {
        case "\"":
            rest = rest.dropFirst()
            var value = ""
            while let c = rest.first {
                rest = rest.dropFirst()
                if c == "\"" { return .string(value) }
                guard c == "\\" else {
                    value.append(c)
                    continue
                }
                guard let escaped = rest.first else { break }
                rest = rest.dropFirst()
                switch escaped {
                case "\"": value.append("\"")
                case "\\": value.append("\\")
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "u", "U":
                    let digits = escaped == "u" ? 4 : 8
                    guard let code = UInt32(rest.prefix(digits), radix: 16), let scalar = Unicode.Scalar(code), rest.count >= digits else {
                        throw ParseError(line: line, message: "bad unicode escape")
                    }
                    value.unicodeScalars.append(scalar)
                    rest = rest.dropFirst(digits)
                default: throw ParseError(line: line, message: "bad escape \\\(escaped)")
                }
            }
            throw ParseError(line: line, message: "unclosed string")
        case "'":
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "'") else { throw ParseError(line: line, message: "unclosed string") }
            let value = String(rest[..<end])
            rest = rest[rest.index(after: end)...]
            return .string(value)
        default:
            let word = rest.prefix { !$0.isWhitespace && $0 != "#" }
            rest = rest.dropFirst(word.count)
            if word == "true" { return .bool(true) }
            if word == "false" { return .bool(false) }
            if let number = Int(word.replacingOccurrences(of: "_", with: "")) { return .integer(number) }
            throw ParseError(line: line, message: "unsupported value \(word)")
        }
    }
}
