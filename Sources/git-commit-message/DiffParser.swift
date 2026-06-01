import Foundation

enum FileStatus: String {
    case added, modified, deleted, renamed
}

/// Deterministic classification of a changed file, used to weight the commit
/// type and to ground the model rather than letting it guess (e.g. a lockfile
/// change is a chore, not a feat).
enum FileCategory {
    case source, test, docs, config, dependency, generated, binary, other
}

/// One file's worth of a unified diff, parsed deterministically before any
/// model call so the model only ever sees real, bounded evidence.
struct FileChange {
    let path: String
    let oldPath: String?
    let status: FileStatus
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let category: FileCategory
    /// Header lines (`diff --git`, mode, index, ---/+++) before the first hunk.
    let header: String
    /// Hunk texts, each starting with `@@`.
    let hunks: [String]
    /// The full per-file patch text (header + hunks).
    let patch: String
}

enum DiffParser {
    /// Splits a `git diff` into per-file sections at each `diff --git` boundary
    /// and parses each one.
    static func parse(_ patch: String) -> [FileChange] {
        let lines = patch.components(separatedBy: "\n")
        var sections: [[String]] = []
        var current: [String]?
        for line in lines {
            if line.hasPrefix("diff --git ") {
                if let c = current { sections.append(c) }
                current = [line]
            } else {
                current?.append(line)
            }
        }
        if let c = current { sections.append(c) }
        return sections.map(parseSection)
    }

    private static func parseSection(_ lines: [String]) -> FileChange {
        let isBinary = lines.contains { $0.hasPrefix("Binary files ") }
        let status: FileStatus
        if lines.contains(where: { $0.hasPrefix("new file mode") }) {
            status = .added
        } else if lines.contains(where: { $0.hasPrefix("deleted file mode") }) {
            status = .deleted
        } else if lines.contains(where: { $0.hasPrefix("rename from ") }) {
            status = .renamed
        } else {
            status = .modified
        }

        let oldPath = lines.first { $0.hasPrefix("rename from ") }
            .map { String($0.dropFirst("rename from ".count)) }

        let path = parsePath(lines: lines, status: status)

        var additions = 0
        var deletions = 0
        for line in lines {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 }
            else if line.hasPrefix("-") { deletions += 1 }
        }

        // Split header vs hunks at the first "@@" line.
        var headerLines: [String] = []
        var hunks: [String] = []
        var currentHunk: [String]?
        for line in lines {
            if line.hasPrefix("@@") {
                if let h = currentHunk { hunks.append(h.joined(separator: "\n")) }
                currentHunk = [line]
            } else if currentHunk != nil {
                currentHunk?.append(line)
            } else {
                headerLines.append(line)
            }
        }
        if let h = currentHunk { hunks.append(h.joined(separator: "\n")) }

        return FileChange(
            path: path,
            oldPath: oldPath,
            status: status,
            additions: additions,
            deletions: deletions,
            isBinary: isBinary,
            category: classify(path: path, isBinary: isBinary),
            header: headerLines.joined(separator: "\n"),
            hunks: hunks,
            patch: lines.joined(separator: "\n")
        )
    }

    private static func parsePath(lines: [String], status: FileStatus) -> String {
        if status == .renamed, let to = lines.first(where: { $0.hasPrefix("rename to ") }) {
            return String(to.dropFirst("rename to ".count))
        }
        if status == .deleted, let minus = lines.first(where: { $0.hasPrefix("--- a/") }) {
            return String(minus.dropFirst("--- a/".count))
        }
        if let plus = lines.first(where: { $0.hasPrefix("+++ b/") }) {
            return String(plus.dropFirst("+++ b/".count))
        }
        // Fall back to the "diff --git a/X b/Y" line.
        if let git = lines.first(where: { $0.hasPrefix("diff --git ") }),
           let range = git.range(of: " b/") {
            return String(git[range.upperBound...])
        }
        return "(unknown)"
    }

    // MARK: - Deterministic classification

    static func classify(path: String, isBinary: Bool) -> FileCategory {
        if isBinary { return .binary }
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension

        let depNames: Set<String> = [
            "package.resolved", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
            "cargo.lock", "gemfile.lock", "podfile.lock", "go.sum", "poetry.lock",
            "composer.lock", "requirements.txt",
        ]
        if depNames.contains(name) { return .dependency }
        if lower.contains("/generated/") || lower.hasPrefix("generated/")
            || name.contains(".generated.") || name.contains(".pb.") { return .generated }
        if lower.hasPrefix("docs/") || lower.contains("/docs/")
            || ["md", "rst", "txt", "adoc"].contains(ext)
            || name == "license" || name.hasPrefix("readme") { return .docs }
        if lower.contains("test") || lower.contains("spec") || lower.contains("__tests__") {
            return .test
        }
        let configExts: Set<String> = ["yml", "yaml", "toml", "ini", "cfg", "plist"]
        if configExts.contains(ext) || name == "package.swift" || name == "dockerfile"
            || name == "makefile" || lower.hasPrefix(".github/") || name.hasPrefix(".") {
            return .config
        }
        return .source
    }

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
        for (index, file) in files.enumerated() {
            if let forced = categoryType(file.category) {
                effective.append(forced)
            } else if index < perFileTypes.count {
                effective.append(perFileTypes[index].lowercased())
            }
        }
        for candidate in typePriority where effective.contains(candidate) {
            return candidate
        }
        return effective.first ?? "chore"
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
