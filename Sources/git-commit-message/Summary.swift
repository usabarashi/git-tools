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

/// One body bullet, anchored to a deterministic group so it can be matched and
/// assembled in code rather than trusting the model's free-form layout.
@Generable
struct GroupBullet {
    @Guide(description: "The bare group name this bullet is for (e.g. \"source\", \"tests\"), without any \"## group:\" prefix.")
    let group: String

    @Guide(description: "One short natural-English clause (with spaces, not a slug or file path) summarizing this group's change. If there is only one group, explain WHY the change was made.")
    let text: String
}

/// The REDUCE call authors only the prose; the type and scope are decided
/// deterministically, and the bullets are assembled per group in code, so the
/// model cannot hallucinate the structure.
@Generable
struct ReducedMessage {
    @Guide(description: "Imperative-mood subject with spaces (not a slug or file name), lower-case first word, no trailing period, at most 50 characters, capturing the dominant change.")
    let subject: String

    @Guide(description: "Exactly one bullet per group shown, with the group name copied verbatim.")
    let bullets: [GroupBullet]
}

/// Internal (non-Generable) carrier used while orchestrating, so deterministic
/// pieces (binary/partial) and model pieces share one type.
struct LabeledSummary {
    let label: String
    let summary: String
    let suggestedType: String
    var partial: Bool = false
}
