import Foundation

public enum EnvFileParser {
    public static func parse(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeyvaultError.invalidUTF8("Env file")
        }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> [String: String] {
        let characters = Array(text)
        var index = 0
        var values: [String: String] = [:]

        while index < characters.count {
            skipBlankLinesAndComments(characters, index: &index)
            guard index < characters.count else { break }

            let lineStart = index
            let lineEnd = nextLineEnd(characters, from: index)
            var line = String(characters[lineStart..<lineEnd])
            index = lineEnd
            consumeLineEnding(characters, index: &index)

            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }

            guard let equals = line.firstIndex(of: "=") else {
                throw KeyvaultError.invalidEnvFile("expected KEY=VALUE")
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else { throw KeyvaultError.invalidEnvFile("invalid variable name '\(key)'") }

            var valueStart = line.index(after: equals)
            while valueStart < line.endIndex, line[valueStart].isWhitespace { valueStart = line.index(after: valueStart) }
            let rest = String(line[valueStart...])
            let value = try parseValue(rest, characters: characters, index: &index)
            values[key] = value
        }

        return values
    }

    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    private static func parseValue(_ initial: String, characters: [Character], index: inout Int) throws -> String {
        guard let quote = initial.first, quote == "'" || quote == "\"" else {
            let commentStart = initial.indices.first { position in
                initial[position] == "#" && (position == initial.startIndex || initial[initial.index(before: position)].isWhitespace)
            }
            let raw = commentStart.map { String(initial[..<$0]) } ?? initial
            return raw.trimmingCharacters(in: .whitespaces)
        }

        var output = String()
        var line = String(initial.dropFirst())
        var escaped = false
        while true {
            var position = line.startIndex
            while position < line.endIndex {
                let character = line[position]
                if quote == "\"", escaped {
                    switch character {
                    case "n": output.append("\n")
                    case "r": output.append("\r")
                    case "t": output.append("\t")
                    case "\\", "\"", "$": output.append(character)
                    default:
                        output.append("\\")
                        output.append(character)
                    }
                    escaped = false
                    position = line.index(after: position)
                    continue
                }
                if quote == "\"", character == "\\" {
                    escaped = true
                    position = line.index(after: position)
                    continue
                }
                if character == quote {
                    let trailing = String(line[line.index(after: position)...]).trimmingCharacters(in: .whitespaces)
                    guard trailing.isEmpty || trailing.hasPrefix("#") else {
                        throw KeyvaultError.invalidEnvFile("unexpected text after quoted value")
                    }
                    return output
                }
                output.append(character)
                position = line.index(after: position)
            }

            guard index < characters.count else { throw KeyvaultError.invalidEnvFile("unterminated quoted value") }
            output.append("\n")
            let lineEnd = nextLineEnd(characters, from: index)
            line = String(characters[index..<lineEnd])
            index = lineEnd
            consumeLineEnding(characters, index: &index)
        }
    }

    private static func skipBlankLinesAndComments(_ characters: [Character], index: inout Int) {
        while index < characters.count {
            let end = nextLineEnd(characters, from: index)
            let line = String(characters[index..<end]).trimmingCharacters(in: .whitespaces)
            guard line.isEmpty || line.hasPrefix("#") else { return }
            index = end
            consumeLineEnding(characters, index: &index)
        }
    }

    private static func nextLineEnd(_ characters: [Character], from start: Int) -> Int {
        var index = start
        while index < characters.count, characters[index] != "\n", characters[index] != "\r" { index += 1 }
        return index
    }

    private static func consumeLineEnding(_ characters: [Character], index: inout Int) {
        if index < characters.count, characters[index] == "\r" { index += 1 }
        if index < characters.count, characters[index] == "\n" { index += 1 }
    }
}
