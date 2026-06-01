import Foundation
import FoundationModels

/// Generates a commit message under a single invariant: no model call ever
/// receives more than fits the context window, so the model never guesses at
/// content that was truncated away. Small diffs take a single fast-path call;
/// large diffs are summarized per file (MAP) and synthesized (REDUCE).
enum Generator {
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

    static func generate(stat: String, patch: String) async throws -> CommitMessage {
        let files = DiffParser.parse(patch)
        let fastContext = "Files changed:\n\(stat)\n\nDiff:\n\(patch)"
        if files.count <= maxFastFiles, fastContext.count <= windowChars {
            return try await generateSingle(context: fastContext)
        }

        progress("large change; summarizing \(files.count) files…")
        let summaries = try await condenseIfNeeded(mapSummaries(files))
        return try await reduce(summaries: summaries, files: files)
    }

    /// Human-readable plan for `--dry-run`, exercising the deterministic parser
    /// without any model call (works even when Apple Intelligence is off).
    static func dryRunDescription(stat: String, patch: String) -> String {
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

    // MARK: - Recursive REDUCE (condense oversized summary sets)

    private static func condenseIfNeeded(_ summaries: [LabeledSummary]) async throws -> [LabeledSummary] {
        var current = summaries
        while joined(current).count > batchChars {
            progress("condensing \(current.count) summaries…")
            var next: [LabeledSummary] = []
            for group in chunk(current) {
                next.append(contentsOf: try await condenseCall(group))
            }
            // Safety: stop if a pass fails to shrink the set.
            if next.count >= current.count { break }
            current = next
        }
        return current
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

    private static func reduce(summaries: [LabeledSummary], files: [FileChange]) async throws -> CommitMessage {
        let type = DiffParser.aggregateType(files: files, perFileTypes: summaries.map(\.suggestedType))
        let scope = DiffParser.deriveScope(files)

        // Cap the summary list to the budget so the reduce call honors the
        // no-call-exceeds-the-window invariant even when condense could not fully
        // shrink the set; any drop is stated honestly rather than silently.
        var lines = ""
        var omitted = 0
        for s in summaries {
            let line = "- [\(s.label)] \(s.summary)\n"
            if lines.count + line.count > batchChars {
                omitted += 1
            } else {
                lines += line
            }
        }
        var prompt = "Write a commit message from these per-file change summaries. Use ONLY these summaries; never infer anything not stated.\n\n\(lines)"
        if omitted > 0 {
            prompt += "\n(\(omitted) further summaries omitted to fit the context window.)\n"
        }

        let session = LanguageModelSession(instructions: Prompts.reduce)
        let response = try await session.respond(
            to: prompt, generating: ReducedMessage.self,
            options: GenerationOptions(temperature: 0.2)
        )
        return CommitMessage(type: type, scope: scope, subject: response.content.subject, body: response.content.body)
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
