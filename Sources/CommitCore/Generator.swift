import Foundation
import FoundationModels

/// Generates a commit message under a single invariant: no model call ever
/// receives more than fits the context window, so the model never guesses at
/// content that was truncated away. Small diffs take a single fast-path call;
/// large diffs are summarized per file (MAP) and synthesized (REDUCE).
public enum Generator {
    /// Generates a rendered Conventional Commits message from the staged diff.
    public static func generateMessage(stat: String, patch: String) async throws -> String {
        try await generate(stat: stat, patch: patch).rendered()
    }

    /// If the whole diff fits this many characters, one call may suffice.
    static let windowChars = 7_000
    /// Per-call input budget for MAP / condense batches (leaves room for output).
    static let batchChars = 6_000
    /// The single-call fast path is only safe for a handful of files. Beyond
    /// this, even a diff that fits the window numerically overwhelms the small
    /// model (it starts parroting examples), so route it through map-reduce.
    static let maxFastFiles = 4
    /// Cap files per MAP batch so each summarization call stays focused.
    static let maxBatchFiles = 6
    /// Floor for a category group's condense budget, so a small group keeps detail.
    static let minGroupChars = 400

    private struct CategoryGroup {
        let name: String
        let summaries: [LabeledSummary]
    }

    static func generate(stat: String, patch: String) async throws -> CommitMessage {
        let files = DiffParser.parse(patch)
        let fastContext = "Files changed:\n\(stat)\n\nDiff:\n\(patch)"
        if files.count <= maxFastFiles, fastContext.count <= windowChars {
            return try await generateSingle(context: fastContext)
        }

        progress("large change; summarizing \(files.count) files…")
        let perFile = try await mapSummaries(files)
        let groups = try await groupAndCondense(summaries: perFile, files: files)
        return try await reduce(groups: groups, files: files)
    }

    /// Human-readable plan for `--dry-run`, exercising the deterministic parser
    /// without any model call (works even when Apple Intelligence is off).
    public static func dryRunDescription(stat: String, patch: String) -> String {
        let files = DiffParser.parse(patch)
        let fastContext = "Files changed:\n\(stat)\n\nDiff:\n\(patch)"
        if files.count <= maxFastFiles, fastContext.count <= windowChars {
            return "[fast path: single call]\n\n\(fastContext)"
        }
        let scope = DiffParser.deriveScope(files)
        var out = "[slow path: map-reduce over \(files.count) files]\n\nFiles changed:\n\(stat)\n\nParsed files:\n"
        for file in files {
            out += "- \(file.path) [\(file.status.rawValue), \(file.category), +\(file.additions)/-\(file.deletions)]\n"
        }
        out += "\nDerived scope: \(scope.isEmpty ? "(none)" : scope)"
        return out
    }

    // MARK: - Fast path

    private static func generateSingle(context: String) async throws -> CommitMessage {
        let session = LanguageModelSession(instructions: Prompts.single)
        let prompt = "Generate a commit message for the following staged changes.\n\n\(context)"
        let response = try await session.respond(
            to: prompt, generating: CommitMessage.self,
            options: GenerationOptions(temperature: 0.3)
        )
        return response.content
    }

    // MARK: - MAP

    private static func mapSummaries(_ files: [FileChange]) async throws -> [LabeledSummary] {
        var deterministic: [LabeledSummary] = []
        var pieces: [(label: String, text: String)] = []

        for file in files {
            if file.isBinary {
                deterministic.append(LabeledSummary(
                    label: file.path,
                    summary: "binary file \(file.status.rawValue)",
                    suggestedType: DiffParser.categoryType(file.category) ?? "chore"))
                continue
            }
            if file.patch.count <= batchChars {
                pieces.append((file.path, file.patch))
                continue
            }
            // A single file over budget: summarize hunk by hunk so each call
            // still fits. A single hunk over budget is summarized honestly as
            // partial rather than truncated-and-passed-off-as-complete.
            var addedPartial = false
            for hunk in file.hunks {
                let text = file.header.isEmpty ? hunk : "\(file.header)\n\(hunk)"
                if text.count <= batchChars {
                    pieces.append(("\(file.path) \(hunkLabel(hunk))", text))
                } else if !addedPartial {
                    // Emit at most one partial summary per file, however many
                    // of its hunks are individually over budget.
                    deterministic.append(LabeledSummary(
                        label: file.path,
                        summary: "large change in \(file.path) (+\(file.additions)/-\(file.deletions)); shown only partially",
                        suggestedType: "chore",
                        partial: true))
                    addedPartial = true
                }
            }
        }

        var results = deterministic
        let batches = batch(pieces)
        for (index, batch) in batches.enumerated() {
            progress("summarizing batch \(index + 1)/\(batches.count)…")
            let summaries = try await mapCall(batch)
            // Re-associate by label; the model may reorder, duplicate, or omit
            // items even when asked to preserve order.
            for piece in batch {
                if let match = summaries.first(where: { $0.label == piece.label }) {
                    results.append(LabeledSummary(label: piece.label, summary: match.summary, suggestedType: match.suggestedType))
                } else {
                    results.append(LabeledSummary(label: piece.label, summary: "changed", suggestedType: "chore"))
                }
            }
        }
        return results
    }

    private static func mapCall(_ pieces: [(label: String, text: String)]) async throws -> [FileSummary] {
        var prompt = "Summarize each labeled file diff below. Return exactly one summary per label, in the same order.\n\n"
        for piece in pieces {
            prompt += "=== \(piece.label) ===\n\(piece.text)\n\n"
        }
        let session = LanguageModelSession(instructions: Prompts.map)
        let response = try await session.respond(
            to: prompt, generating: FileSummaryList.self,
            options: GenerationOptions(temperature: 0.2)
        )
        return response.content.summaries
    }

    // MARK: - Group & condense

    /// Groups per-file summaries by deterministic FileCategory, then condenses
    /// each group down to a proportional share of the budget so the assembled
    /// groups fit the reduce window. Grouping happens before condensing so the
    /// labels still map back to categories.
    private static func groupAndCondense(summaries: [LabeledSummary], files: [FileChange]) async throws -> [CategoryGroup] {
        var buckets: [FileCategory: [LabeledSummary]] = [:]
        for summary in summaries {
            let category = DiffParser.category(forLabel: summary.label, files: files)
            buckets[category, default: []].append(summary)
        }

        var ordered: [(category: FileCategory, summaries: [LabeledSummary])] = []
        for category in DiffParser.categoryOrder where buckets[category] != nil {
            ordered.append((category, buckets[category]!))
        }

        // Proportional budget weighted by summary volume, with a floor, so the
        // dominant group is not starved and tiny groups are not over-allocated.
        let weights = ordered.map { max(joined($0.summaries).count, 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        // Allocate the per-group floor first, then split the remainder
        // proportionally, so the sum of targets never exceeds the budget. With
        // at most 7 categories the floors always leave room.
        let remaining = max(0, batchChars - ordered.count * minGroupChars)

        var result: [CategoryGroup] = []
        for (index, group) in ordered.enumerated() {
            let target = minGroupChars + remaining * weights[index] / totalWeight
            var current = group.summaries
            while joined(current).count > target {
                progress("condensing \(group.category.groupName) (\(current.count) summaries)…")
                var next: [LabeledSummary] = []
                for piece in chunk(current) {
                    next.append(contentsOf: try await condenseCall(piece))
                }
                if next.count >= current.count { break }
                current = next
            }
            result.append(CategoryGroup(name: group.category.groupName, summaries: current))
        }
        return result
    }

    private static func condenseCall(_ summaries: [LabeledSummary]) async throws -> [LabeledSummary] {
        var prompt = "Merge these per-file change summaries into a few grouped summaries, one per logical theme. Use only the text given; do not invent.\n\n"
        for s in summaries { prompt += "- [\(s.label)] \(s.summary)\n" }
        let session = LanguageModelSession(instructions: Prompts.condense)
        let response = try await session.respond(
            to: prompt, generating: FileSummaryList.self,
            options: GenerationOptions(temperature: 0.2)
        )
        return response.content.summaries.map {
            LabeledSummary(label: $0.label, summary: $0.summary, suggestedType: $0.suggestedType)
        }
    }

    // MARK: - REDUCE

    private static func reduce(groups: [CategoryGroup], files: [FileChange]) async throws -> CommitMessage {
        let type = DiffParser.aggregateType(
            files: files,
            perFileTypes: groups.flatMap { $0.summaries.map(\.suggestedType) })
        let scope = DiffParser.deriveScope(files)

        var prompt = "Write a commit message from these grouped change summaries. Use ONLY these summaries; never infer anything not stated. Produce exactly one bullet per group, copying its name.\n\n"
        for group in groups {
            prompt += "## group: \(group.name)\n"
            for summary in group.summaries { prompt += "- \(summary.summary)\n" }
            prompt += "\n"
        }

        let session = LanguageModelSession(instructions: Prompts.reduce)
        let response = try await session.respond(
            to: prompt, generating: ReducedMessage.self,
            options: GenerationOptions(temperature: 0.2)
        )

        // Deterministic assembly: exactly one bullet per group, in priority
        // order, matched to the model's output by group name with a fallback.
        var bullets: [String] = []
        for group in groups {
            let text = response.content.bullets
                .first { normalizeGroup($0.group) == normalizeGroup(group.name) }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? (group.summaries.first?.summary ?? "update \(group.name)")
            bullets.append("- \(text)")
        }
        return CommitMessage(
            type: type, scope: scope,
            subject: response.content.subject,
            body: bullets.joined(separator: "\n"))
    }

    /// Canonicalizes a model-produced group name to a FileCategory.groupName,
    /// tolerant of prefixes ("## group: source"), singular/plural variants, and
    /// stray newlines, since small models rarely copy a label exactly.
    private static func normalizeGroup(_ name: String) -> String {
        let lower = name.lowercased()
        let table: [(needle: String, canonical: String)] = [
            ("test", "tests"), ("dependenc", "dependencies"), ("doc", "docs"),
            ("config", "config"), ("source", "source"), ("binar", "binary"),
            ("generated", "generated"),
        ]
        for entry in table where lower.contains(entry.needle) {
            return entry.canonical
        }
        return lower.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func batch(_ pieces: [(label: String, text: String)]) -> [[(label: String, text: String)]] {
        var batches: [[(label: String, text: String)]] = []
        var current: [(label: String, text: String)] = []
        var used = 0
        for piece in pieces {
            let size = piece.label.count + piece.text.count + 16
            if !current.isEmpty, used + size > batchChars || current.count >= maxBatchFiles {
                batches.append(current)
                current = []
                used = 0
            }
            current.append(piece)
            used += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private static func chunk(_ summaries: [LabeledSummary]) -> [[LabeledSummary]] {
        var groups: [[LabeledSummary]] = []
        var current: [LabeledSummary] = []
        var used = 0
        for s in summaries {
            let size = s.label.count + s.summary.count + 8
            if used + size > batchChars, !current.isEmpty {
                groups.append(current)
                current = []
                used = 0
            }
            current.append(s)
            used += size
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func joined(_ summaries: [LabeledSummary]) -> String {
        summaries.map { "- [\($0.label)] \($0.summary)" }.joined(separator: "\n")
    }

    private static func hunkLabel(_ hunk: String) -> String {
        String(hunk.prefix { !$0.isNewline })
    }

    private static func progress(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
