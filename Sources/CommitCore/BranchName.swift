import Foundation

/// Suggests a git branch name from the staged diff. A branch name is just a
/// commit message in disguise, so this reuses the whole commit pipeline
/// (grounding, map-reduce, deterministic type) and reshapes the result into
/// `type/kebab-summary` (e.g. `feat/add-retry-logic`).
public enum BranchName {
    /// Maximum length of the kebab summary segment, trimmed at a word boundary.
    static let maxSlugLength = 40

    public static func generate(stat: String, patch: String) async throws -> String {
        let message = try await Generator.generate(stat: stat, patch: patch)
        return format(type: message.type, subject: message.subject)
    }

    static func format(type: String, subject: String) -> String {
        let normalizedType = CommitMessage.normalizeType(type)
        // For a branch name, restrict the type to the known Conventional Commits
        // set (falling back to chore) so a stray long or odd model type cannot
        // produce a ref component git would reject.
        let safeType = CommitMessage.knownTypes.contains(normalizedType) ? normalizedType : "chore"
        let slug = slugify(subject)
        return slug.isEmpty ? safeType : "\(safeType)/\(slug)"
    }

    /// Lower-cases and reduces text to a git-ref-safe kebab slug: only ASCII
    /// letters and digits survive, runs of anything else become a single dash.
    static func slugify(_ text: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else if !slug.isEmpty {
                pendingDash = true
            }
            if pendingDash, !slug.isEmpty, slug.last != "-" {
                slug.append("-")
                pendingDash = false
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }

        guard slug.count > maxSlugLength else { return slug }
        let clipped = slug.prefix(maxSlugLength)
        if let lastDash = clipped.lastIndex(of: "-") {
            return String(clipped[..<lastDash])
        }
        return String(clipped)
    }
}
