import Foundation
import FoundationModels

/// Structured commit message produced via guided generation (`@Generable`),
/// so the model returns typed fields instead of free text we would have to
/// parse. Shape follows Conventional Commits (Q2).
@Generable
struct CommitMessage {
    @Guide(description: "Conventional Commits type. One of: feat, fix, docs, style, refactor, perf, test, build, ci, chore.")
    let type: String

    @Guide(description: "Optional narrow scope such as a module or filename. Use an empty string when no obvious scope applies.")
    let scope: String

    @Guide(description: "Imperative-mood summary, lower-case, no trailing period, at most 50 characters.")
    let subject: String

    @Guide(description: "Optional body explaining WHY the change was made, wrapped at 72 columns. Use an empty string for trivial changes.")
    let body: String
}

extension CommitMessage {
    /// Renders the structured fields into a Conventional Commits string.
    ///
    /// The on-device model is an unreliable instruction-follower for two
    /// mechanical conventions, so they are enforced deterministically here
    /// rather than left to the prompt: the subject's first word is lower-cased,
    /// and a trailing file extension is stripped from the scope.
    func rendered() -> String {
        var header = Self.normalizeType(type)
        let scope = Self.normalizeScope(Self.cleanedOptional(scope))
        if !scope.isEmpty {
            header += "(\(scope))"
        }
        header += ": \(Self.normalizeSubject(subject))"

        let trimmedBody = Self.cleanedOptional(body)
        if trimmedBody.isEmpty {
            return header
        }
        return "\(header)\n\n\(trimmedBody)"
    }

    static let knownTypes: Set<String> = [
        "feat", "fix", "docs", "style", "refactor",
        "perf", "test", "build", "ci", "chore", "revert",
    ]

    static let typeSynonyms: [String: String] = [
        "feature": "feat", "features": "feat",
        "bugfix": "fix", "bug": "fix", "fixes": "fix",
        "documentation": "docs", "doc": "docs",
        "refactoring": "refactor", "performance": "perf",
        "tests": "test", "testing": "test", "chores": "chore",
    ]

    /// Coerces the model's free-text type into a single lower-case Conventional
    /// Commits token, mapping common synonyms (e.g. "feature" -> "feat"). An
    /// unrecognized non-empty token is kept as-is (the spec permits custom
    /// types); an empty token falls back to "chore".
    static func normalizeType(_ type: String) -> String {
        let token = String(
            type.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .prefix { $0.isLetter }
        )
        if let mapped = typeSynonyms[token] { return mapped }
        if knownTypes.contains(token) { return token }
        return token.isEmpty ? "chore" : token
    }

    /// Treats sentinel placeholders the model may copy verbatim from the
    /// few-shot examples (e.g. "(empty)") as an empty value, so they never
    /// reach the rendered message as literal text.
    static func cleanedOptional(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentinels: Set<String> = ["(empty)", "empty", "none", "n/a", "na", "-"]
        return sentinels.contains(trimmed.lowercased()) ? "" : trimmed
    }

    /// Normalizes the subject into a single Conventional Commits header line:
    /// collapses any newlines to spaces, strips trailing periods/whitespace,
    /// and lower-cases the first letter when it is an ordinary capitalized word
    /// (e.g. "Added" -> "added"), leaving acronyms ("URL ...") and identifiers
    /// ("processBatch ...") untouched.
    static func normalizeSubject(_ subject: String) -> String {
        var line = subject
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        while let last = line.last, last == "." || last == " " {
            line.removeLast()
        }

        let firstWord = line.prefix { !$0.isWhitespace }
        guard let first = firstWord.first,
              first.isUppercase,
              firstWord.dropFirst().allSatisfy({ !$0.isUppercase })
        else {
            return line
        }
        return first.lowercased() + line.dropFirst()
    }

    /// Strips a trailing file extension from the scope (e.g. "net.py" -> "net",
    /// "README.md" -> "README"), but only when the suffix looks like an
    /// extension: short and all ASCII letters. Leaves dotted scopes like
    /// "api.v2" alone.
    static func normalizeScope(_ scope: String) -> String {
        // A scope is a single token; collapse to the first line so a stray
        // newline cannot break the header.
        let firstLine = String(scope.prefix { !$0.isNewline })
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard let dot = trimmed.lastIndex(of: ".") else { return trimmed }
        let ext = trimmed[trimmed.index(after: dot)...]
        let base = trimmed[..<dot]
        let looksLikeExtension = !ext.isEmpty
            && ext.count <= 5
            && ext.allSatisfy { $0.isLetter && $0.isASCII }
        return (looksLikeExtension && !base.isEmpty) ? String(base) : trimmed
    }
}
