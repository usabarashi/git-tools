import Foundation
import FoundationModels
import GitCore

/// Generates a commit message under a single invariant: no model call ever
/// receives more than fits the context window, so the model never guesses at
/// content that was truncated away. Small diffs take a single fast-path call;
/// large diffs are summarized per file (MAP) and synthesized (REDUCE).
public enum Generator {
    /// Generates a rendered Conventional Commits message from the staged diff.
    public static func generateMessage(stat: String, patch: String) async throws -> String {
        try await generate(stat: stat, patch: patch).rendered()
    }

    // MARK: - Context budget
    //
    // Apple's on-device model has a hard context window (in TOKENS) that must
    // hold the instructions, the prompt, AND the generated output for a single
    // call; one overflowing call aborts the whole run. We plan in characters but
    // size every budget against that ceiling with a deliberately pessimistic
    // chars-per-token ratio, because dense diffs (code, punctuation, non-ASCII)
    // tokenize far below English prose's ~4 chars/token — on symbol-heavy hunks
    // closer to ~1.6. Each budget also subtracts the live instruction length, so
    // it stays correct when a prompt in `Prompts` is edited.

    /// Apple FoundationModels hard context window, in tokens (input + output).
    static let contextTokens = 4_096
    /// Tokens held back for the model's own structured output.
    static let reservedOutputTokens = 1_200
    /// Pessimistic characters-per-token for diff content. Plain English code
    /// tokenizes at ~4 chars/token, but CJK and other non-ASCII text can hit
    /// ~1 char/token, so we plan low. This is only a first guess: the MAP step
    /// also splits-and-retries on a real overflow (see `summarize`), so the
    /// exact value trades call count for safety, it does not gate correctness.
    static let charsPerToken = 1.2
    /// Characters one call may spend on instructions + prompt scaffolding + text.
    static let callChars = Int(Double(contextTokens - reservedOutputTokens) * charsPerToken)

    /// The single-call fast path is only safe for a handful of files. Beyond
    /// this, even a diff that fits the window numerically overwhelms the small
    /// model (it starts parroting examples), so route it through map-reduce.
    static let maxFastFiles = 4
    /// Cap files per MAP batch so each summarization call stays focused.
    static let maxBatchFiles = 6
    /// Floor for a category group's condense budget, so a small group keeps detail.
    static let minGroupChars = 400

    /// Characters of input TEXT a call may carry after reserving the window for
    /// the given instructions and an estimate of the fixed prompt scaffolding.
    /// Clamped at zero, not at `minGroupChars`: a per-group floor belongs only to
    /// the condense targets (see `groupAndCondense`); applying it here would admit
    /// input that is guaranteed to overflow when a prompt grows past the window.
    static func inputBudget(instructions: String, scaffold: Int) -> Int {
        max(0, callChars - instructions.count - scaffold)
    }

    private struct CategoryGroup {
        let name: String
        let summaries: [LabeledSummary]
    }

    static func generate(stat: String, patch: String) async throws -> CommitMessage {
        let files = DiffParser.parse(patch)
        let fastContext = "Files changed:\n\(stat)\n\nDiff:\n\(patch)"
        if files.count <= maxFastFiles, fastContext.count <= inputBudget(instructions: Prompts.single, scaffold: 80) {
            do {
                return try await generateSingle(context: fastContext)
            } catch let error where isContextOverflow(error) {
                // The char budget under-counted the tokens (e.g. dense or CJK
                // content): fall through to the map-reduce path, which fits each
                // call to the window and retries on overflow.
                progress("fast path overflowed the model window; falling back to map-reduce…")
            }
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
        if files.count <= maxFastFiles, fastContext.count <= inputBudget(instructions: Prompts.single, scaffold: 80) {
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
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: reservedOutputTokens)
        )
        return response.content
    }

    // MARK: - MAP

    private static func mapSummaries(_ files: [FileChange]) async throws -> [LabeledSummary] {
        var deterministic: [LabeledSummary] = []
        var pieces: [(label: String, text: String)] = []
        // Reserve the window for the MAP instructions, the static prompt prefix,
        // and one label wrapper ("=== … ===\n…\n\n").
        let mapBudget = inputBudget(instructions: Prompts.map, scaffold: 150)

        for file in files {
            if file.isBinary {
                deterministic.append(LabeledSummary(
                    label: file.path,
                    summary: "binary file \(file.status.rawValue)",
                    suggestedType: DiffParser.categoryType(file.category) ?? "chore"))
                continue
            }
            if file.patch.count <= mapBudget {
                pieces.append((file.path, file.patch))
                continue
            }
            // A single file over budget: summarize hunk by hunk so each call
            // still fits. A single hunk over budget is summarized honestly as
            // partial rather than truncated-and-passed-off-as-complete.
            var addedPartial = false
            for hunk in file.hunks {
                let text = file.header.isEmpty ? hunk : "\(file.header)\n\(hunk)"
                if text.count <= mapBudget {
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
        let batches = batch(pieces, budget: mapBudget)
        for (index, batch) in batches.enumerated() {
            progress("summarizing batch \(index + 1)/\(batches.count)…")
            results.append(contentsOf: try await summarize(batch))
        }
        return results
    }

    /// Summarizes one batch, retrying on a real context overflow by halving the
    /// batch. The character budget is only a guess — the model counts tokens,
    /// and CJK or otherwise dense diffs can tokenize at ~1 char/token, so a batch
    /// that fit by characters may still overflow. Halving (down to a single piece
    /// summarized as partial) keeps the run honest and complete instead of
    /// aborting the whole commit message on one oversized batch.
    private static func summarize(_ pieces: [(label: String, text: String)]) async throws -> [LabeledSummary] {
        guard !pieces.isEmpty else { return [] }
        do {
            let summaries = try await mapCall(pieces)
            // Re-associate by label; the model may reorder, duplicate, or omit
            // items even when asked to preserve order.
            return pieces.map { piece in
                if let match = summaries.first(where: { $0.label == piece.label }) {
                    return LabeledSummary(label: piece.label, summary: match.summary, suggestedType: match.suggestedType)
                }
                return LabeledSummary(label: piece.label, summary: "changed", suggestedType: "chore")
            }
        } catch let error where isContextOverflow(error) {
            guard pieces.count > 1 else {
                return try await summarizeOversized(pieces[0])
            }
            let mid = pieces.count / 2
            let head = try await summarize(Array(pieces[..<mid]))
            let tail = try await summarize(Array(pieces[mid...]))
            return head + tail
        }
    }

    /// Handles a single piece that overflows the window on its own (common when
    /// its diff is short in characters but dense in tokens, e.g. CJK strings).
    /// Splits the text in half and summarizes each part so the change is still
    /// grounded; only when it can no longer be split do we fall back to an honest
    /// partial summary rather than truncating and passing it off as complete. The
    /// "\(label) @@part…" labels keep each part mapped to the file's category.
    private static func summarizeOversized(_ piece: (label: String, text: String)) async throws -> [LabeledSummary] {
        let halves = splitText(piece.text)
        guard halves.count == 2 else {
            progress("piece too large for the model window; summarizing partially: \(piece.label)")
            return [LabeledSummary(
                label: piece.label,
                summary: "large change in \(piece.label); summarized only partially",
                suggestedType: "chore",
                partial: true)]
        }
        var out: [LabeledSummary] = []
        for (index, half) in halves.enumerated() {
            out.append(contentsOf: try await summarize([("\(piece.label) @@part\(index + 1)", half)]))
        }
        return out
    }

    /// Splits text into two halves on line boundaries. Returns a single element
    /// (the input) when it cannot make progress — a single line, or a split that
    /// would yield an empty or unchanged half — so the caller emits a partial
    /// instead of recursing forever. Guaranteeing both halves are non-empty and
    /// strictly smaller makes the recursion's line count a monotonic measure.
    private static func splitText(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return [text] }
        let mid = lines.count / 2
        let head = lines[..<mid].joined(separator: "\n")
        let tail = lines[mid...].joined(separator: "\n")
        guard !head.isEmpty, !tail.isEmpty, head != text, tail != text else { return [text] }
        return [head, tail]
    }

    /// True for the FoundationModels error raised when a call's tokens exceed the
    /// context window, the one overflow we recover from by splitting the input.
    private static func isContextOverflow(_ error: Error) -> Bool {
        guard let generationError = error as? LanguageModelSession.GenerationError else { return false }
        if case .exceededContextWindowSize = generationError { return true }
        return false
    }

    private static func mapCall(_ pieces: [(label: String, text: String)]) async throws -> [FileSummary] {
        var prompt = "Summarize each labeled file diff below. Return exactly one summary per label, in the same order.\n\n"
        for piece in pieces {
            prompt += "=== \(piece.label) ===\n\(piece.text)\n\n"
        }
        let session = LanguageModelSession(instructions: Prompts.map)
        let response = try await session.respond(
            to: prompt, generating: FileSummaryList.self,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: reservedOutputTokens)
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

        // The condensed groups all feed the single REDUCE call, so their total
        // size is bounded by what that call's window allows (its instructions +
        // the per-group headers consume the rest). Each condense call itself is
        // a separate, smaller window.
        let reduceBudget = inputBudget(instructions: Prompts.reduce, scaffold: 260)
        let condenseBudget = inputBudget(instructions: Prompts.condense, scaffold: 180)

        // Proportional budget weighted by summary volume, with a floor, so the
        // dominant group is not starved and tiny groups are not over-allocated.
        let weights = ordered.map { max(joined($0.summaries).count, 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        // Allocate the per-group floor first, then split the remainder
        // proportionally, so the sum of targets never exceeds the budget. The
        // floor is scaled down when the budget cannot seat every group at the
        // nominal floor (many categories against a tight reduce window), so
        // `ordered.count * floor` never exceeds `reduceBudget`.
        let floor = min(minGroupChars, reduceBudget / max(ordered.count, 1))
        let remaining = max(0, reduceBudget - ordered.count * floor)

        var result: [CategoryGroup] = []
        for (index, group) in ordered.enumerated() {
            let target = floor + remaining * weights[index] / totalWeight
            var current = group.summaries
            while joined(current).count > target {
                progress("condensing \(group.category.groupName) (\(current.count) summaries)…")
                var next: [LabeledSummary] = []
                for piece in chunk(current, budget: condenseBudget) {
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
        do {
            let response = try await session.respond(
                to: prompt, generating: FileSummaryList.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: reservedOutputTokens)
            )
            return response.content.summaries.map {
                LabeledSummary(label: $0.label, summary: $0.summary, suggestedType: $0.suggestedType)
            }
        } catch is LanguageModelSession.GenerationError {
            // Condensing is only an optimization to shrink the reduce input; if
            // the model fails on this chunk, keep the inputs as-is. The caller's
            // loop breaks when a round stops shrinking, so this cannot spin.
            progress("condense step failed; keeping summaries as-is")
            return summaries
        }
    }

    // MARK: - REDUCE

    private static func reduce(groups: [CategoryGroup], files: [FileChange]) async throws -> CommitMessage {
        // Only source/other files (grouped under "source") may contribute
        // model-suggested types; every other category (docs, test, config,
        // dependency, generated, binary) gets a deterministic type, so their
        // summaries must not feed in. At most one group is the source group.
        let type = DiffParser.aggregateType(
            files: files,
            sourceSuggestedTypes: groups
                .first { $0.name == FileCategory.source.groupName }?
                .summaries.map(\.suggestedType) ?? [])
        let scope = DiffParser.deriveScope(files)

        // The reduce model call only authors prose; the type, scope, and one
        // bullet per group are assembled deterministically. If the model
        // overflows or returns malformed/looping output (a small model can do
        // either on thin input, e.g. a lone "shown only partially" summary), we
        // keep an entirely deterministic message rather than failing the run.
        // `reduceCall` returns nil only for that generation failure; any other
        // error (e.g. the model becoming unavailable) still propagates here.
        let reduced = try await reduceCall(groups: groups)
        if reduced == nil {
            progress("reduce step failed; assembling a deterministic message")
        }

        var bullets: [String] = []
        for group in groups {
            let text = reduced?.bullets
                .first { normalizeGroup($0.group) == normalizeGroup(group.name) }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? (group.summaries.first?.summary ?? "update \(group.name)")
            bullets.append("- \(text)")
        }
        let trimmedSubject = reduced?.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = (trimmedSubject?.isEmpty == false ? trimmedSubject : nil)
            ?? fallbackSubject(groups: groups, scope: scope)
        return CommitMessage(
            type: type, scope: scope,
            subject: subject,
            body: bullets.joined(separator: "\n"))
    }

    /// The one model call in REDUCE, isolated so `reduce` can recover from a
    /// generation failure (overflow or malformed output) with a deterministic
    /// message. Returns nil on any generation error.
    private static func reduceCall(groups: [CategoryGroup]) async throws -> ReducedMessage? {
        var prompt = "Write a commit message from these grouped change summaries. Use ONLY these summaries; never infer anything not stated. Produce exactly one bullet per group, copying its name.\n\n"
        for group in groups {
            prompt += "## group: \(group.name)\n"
            for summary in group.summaries { prompt += "- \(summary.summary)\n" }
            prompt += "\n"
        }
        let session = LanguageModelSession(instructions: Prompts.reduce)
        do {
            let response = try await session.respond(
                to: prompt, generating: ReducedMessage.self,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: reservedOutputTokens)
            )
            return response.content
        } catch is LanguageModelSession.GenerationError {
            return nil
        }
    }

    /// A grounded subject used when the model cannot author one: the dominant
    /// group's first real summary, trimmed to the subject length at a word
    /// boundary, or a scoped generic when only partial summaries exist.
    private static func fallbackSubject(groups: [CategoryGroup], scope: String) -> String {
        let seed = groups.flatMap(\.summaries).first { !$0.partial }?.summary
        if let seed, !seed.isEmpty {
            guard seed.count > 50 else { return seed }
            let clipped = seed.prefix(50)
            if let lastSpace = clipped.lastIndex(of: " ") {
                return String(clipped[..<lastSpace])
            }
            return String(clipped)
        }
        return scope.isEmpty ? "update changed files" : "update \(scope)"
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

    private static func batch(_ pieces: [(label: String, text: String)], budget: Int) -> [[(label: String, text: String)]] {
        var batches: [[(label: String, text: String)]] = []
        var current: [(label: String, text: String)] = []
        var used = 0
        for piece in pieces {
            let size = piece.label.count + piece.text.count + 16
            if !current.isEmpty, used + size > budget || current.count >= maxBatchFiles {
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

    private static func chunk(_ summaries: [LabeledSummary], budget: Int) -> [[LabeledSummary]] {
        var groups: [[LabeledSummary]] = []
        var current: [LabeledSummary] = []
        var used = 0
        for s in summaries {
            let size = s.label.count + s.summary.count + 8
            if used + size > budget, !current.isEmpty {
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
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
    }
}
