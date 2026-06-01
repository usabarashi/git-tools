import FoundationModels

/// One grounded, per-file summary produced by the MAP step. Kept deliberately
/// small so the collected summaries fit the REDUCE call's context window.
@Generable
struct FileSummary {
    @Guide(description: "The label this summary is for, copied verbatim from the input header.")
    let label: String

    @Guide(description: "One sentence on what changed and, only if visible in the shown diff, why. Never describe code that is not present in the input.")
    let summary: String

    @Guide(description: "Best Conventional Commits type for this file: feat, fix, refactor, perf, docs, test, build, ci, chore, or style.")
    let suggestedType: String
}

/// The MAP / condense calls return a list (one item per labeled input piece).
@Generable
struct FileSummaryList {
    let summaries: [FileSummary]
}

/// The REDUCE call only authors the prose; the type and scope are decided
/// deterministically, so the model cannot hallucinate them.
@Generable
struct ReducedMessage {
    @Guide(description: "Imperative-mood subject, lower-case first word, no trailing period, at most 50 characters, capturing the dominant change.")
    let subject: String

    @Guide(description: "Body: one '- ' bullet per distinct logical change, grounded ONLY in the provided summaries. Leave empty for a single self-evident change.")
    let body: String
}

/// Internal (non-Generable) carrier used while orchestrating, so deterministic
/// pieces (binary/partial) and model pieces share one type.
struct LabeledSummary {
    let label: String
    let summary: String
    let suggestedType: String
    var partial: Bool = false
}
