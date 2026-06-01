import Foundation
import GitCore

/// Commit-message-specific meaning layered onto GitCore's generic diff model:
/// how file categories map to Conventional Commits types, body group names and
/// ordering, and the deterministic scope. Kept out of GitCore so the generic
/// diff parser carries no commit-message opinions.
extension FileCategory {
    /// Display name used as the deterministic group key in the reduce step.
    var groupName: String {
        switch self {
        case .source, .other: return "source"
        case .test: return "tests"
        case .docs: return "docs"
        case .config: return "config"
        case .dependency: return "dependencies"
        case .generated: return "generated"
        case .binary: return "binary"
        }
    }
}

extension DiffParser {
    /// The Conventional Commits type implied purely by a file's category, when
    /// unambiguous. `nil` means "depends on the actual code change" (source).
    static func categoryType(_ category: FileCategory) -> String? {
        switch category {
        case .docs: return "docs"
        case .test: return "test"
        case .dependency, .config, .generated, .binary: return "chore"
        case .source, .other: return nil
        }
    }

    // MARK: - Type weighting & scope (deterministic, so they can't be hallucinated)

    private static let typePriority = [
        "feat", "fix", "perf", "refactor", "style",
        "test", "docs", "build", "ci", "chore",
    ]

    /// Picks one commit type from per-file evidence, letting the most meaningful
    /// change win (source semantics outrank tests/docs/chore) so a large commit
    /// full of test/config noise doesn't drown the real change.
    static func aggregateType(files: [FileChange], perFileTypes: [String]) -> String {
        var effective: [String] = []
        for file in files {
            if let forced = categoryType(file.category) {
                effective.append(forced)
            }
        }
        // Source/other files have no category-forced type; fold in every
        // model-suggested type. The summaries are not index-aligned with `files`
        // once the pipeline prepends binary/partial summaries or splits a file
        // into per-hunk summaries, so this must not index by position.
        effective.append(contentsOf: perFileTypes.map { $0.lowercased() })
        for candidate in typePriority where effective.contains(candidate) {
            return candidate
        }
        return effective.first ?? "chore"
    }

    /// Order in which category groups appear in the body (most meaningful first).
    static let categoryOrder: [FileCategory] = [
        .source, .test, .docs, .config, .dependency, .generated, .binary,
    ]

    /// Maps a summary label back to its file's category for grouping. Labels are
    /// either an exact path or "path <hunk header>"; `.other` folds into source.
    static func category(forLabel label: String, files: [FileChange]) -> FileCategory {
        // Prefer the longest matching path so shared prefixes don't collide.
        // Hunk labels are "path @@…", so match on " @@" rather than a bare space.
        let match = files
            .filter { label == $0.path || label.hasPrefix($0.path + " @@") }
            .max { $0.path.count < $1.path.count }
        let category = match?.category ?? .source
        return category == .other ? .source : category
    }

    /// Derives a scope deterministically from paths (single file -> its stem;
    /// single common directory -> its name), or omits it. Never invented.
    static func deriveScope(_ files: [FileChange]) -> String {
        if files.count == 1 {
            let name = (files[0].path as NSString).lastPathComponent
            return (name as NSString).deletingPathExtension
        }
        let dirs = Set(files.map { ($0.path as NSString).deletingLastPathComponent })
        if dirs.count == 1, let dir = dirs.first, !dir.isEmpty {
            return (dir as NSString).lastPathComponent
        }
        return ""
    }
}
