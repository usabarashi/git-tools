import Foundation

/// Kinds of secret this advisory pass looks for. Deliberately narrow (real
/// credentials), leaving broader, noisier categories like PII out of v1.
public enum SecretCategory: String, Sendable {
    case apiKey = "API key"
    case token
    case password
    case privateKey = "private key"
    case credential
    case other

    /// Maps a free-form model label onto a known category, defaulting to
    /// `.credential` so an unrecognized-but-flagged value is still reported.
    static func from(_ raw: String) -> SecretCategory {
        let lower = raw.lowercased()
        if lower.contains("private") && lower.contains("key") { return .privateKey }
        if lower.contains("api") { return .apiKey }
        if lower.contains("token") { return .token }
        if lower.contains("password") || lower.contains("passwd") { return .password }
        if lower.contains("credential") || lower.contains("secret") { return .credential }
        return .credential
    }
}

/// How sure the model is. Ordered so a `--fail-on` threshold can compare.
public enum Confidence: Int, Sendable, Comparable {
    case low = 0, medium = 1, high = 2

    public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        }
    }

    static func from(_ raw: String) -> Confidence {
        switch raw.lowercased() {
        case "high": return .high
        case "low": return .low
        default: return .medium
        }
    }

    /// Parses a `--fail-on` argument value.
    public static func parse(_ raw: String) -> Confidence? {
        switch raw.lowercased() {
        case "high": return .high
        case "medium", "med": return .medium
        case "low": return .low
        default: return nil
        }
    }
}

public struct Finding: Sendable {
    public let file: String
    public let category: SecretCategory
    public let confidence: Confidence
    public let reason: String
    /// A short, locally-masked hint — never the raw secret.
    public let masked: String
}

public struct ScanResult: Sendable {
    public let findings: [Finding]
    /// Files whose diff could not be fully scanned (e.g. a single line larger
    /// than the model window). Surfaced so a clean result is never overstated.
    public let incompleteFiles: [String]

    public var isIncomplete: Bool { !incompleteFiles.isEmpty }
}
