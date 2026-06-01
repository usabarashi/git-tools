enum Prompts {
    /// Fast path: author a full Conventional Commits message from a diff that
    /// fits the window in one call.
    static let single = """
    You write a single git commit message for the given staged changes, following \
    the Conventional Commits specification. The output is consumed programmatically, \
    so be precise.

    Rules:
    - subject: imperative mood, lower-case first word, no trailing period, at most 50 \
    characters. Phrase it as a command ("add", "fix", "guard", "rename"), never past \
    tense ("added", "fixed").
    - type: infer from the NATURE of the change, not from words in the diff:
      - feat: introduces a capability or behavior that did not exist before.
      - fix: corrects wrong behavior or a bug, INCLUDING adding a guard or validation \
    to existing code.
      - refactor: restructures code without changing behavior (rename, extract, move).
      - docs: documentation or comments only. test: tests only.
      - perf: performance. style: formatting only. \
    build/ci/chore: tooling, dependencies, configuration.
    - scope: a short noun for the affected area, such as a module or file name without \
    its extension. Leave empty when it is not obvious.
    - body: explain WHY the change is needed, not WHAT changed line by line. Wrap at 72 \
    columns. Leave empty for trivial or self-evident changes.
    - Write everything in English.

    Examples (change -> fields):
    - Added an early `if not values: return 0` to an existing average() function ->
      type: fix | scope: calc | subject: guard against empty input in average
      body: average() divided by zero on an empty list, crashing callers; return 0 instead.
    - Added a brand-new `--json` flag that prints results as JSON ->
      type: feat | scope: cli | subject: add --json output flag | body: (empty)
    - Renamed doStuff() to processBatch() with no behavior change ->
      type: refactor | scope: (empty) | subject: rename doStuff to processBatch | body: (empty)
    - Fixed typos in the README install section ->
      type: docs | scope: readme | subject: fix typos in install steps | body: (empty)
    """

    /// MAP: produce one grounded summary per labeled file diff.
    static let map = """
    You summarize git file diffs for a commit message. For each labeled diff, write \
    one short natural-English sentence (with spaces, NOT an identifier, slug, or \
    underscore_case) describing what changed and, only if it is visible in the diff, \
    why. Never describe code or files that are not shown. If a diff is marked partial, \
    stay general and do not infer the rest. Return exactly one summary per label, in the \
    same order, with the label copied verbatim. Write in English.
    """

    /// Condense: merge many summaries into fewer grouped ones (recursive reduce).
    static let condense = """
    You merge per-file change summaries into a few grouped summaries, one per logical \
    theme. Use only the text provided; never invent details. Keep each grouped summary \
    to one sentence and label it by its theme. Write in English.
    """

    /// REDUCE: author only the prose; type and scope are decided deterministically.
    static let reduce = """
    You write the subject and body of a single git commit message from a list of \
    per-file change summaries. Use ONLY these summaries; never infer anything not \
    stated in them.
    - subject: a natural-English imperative phrase WITH SPACES (e.g. "add input \
    validation across modules"), lower-case first word, no trailing period, at most 50 \
    characters, capturing the dominant change. Never an identifier, slug, \
    underscore_case, or a file name.
    - body: GROUP files that share the same kind of change into a SINGLE bullet. Produce \
    at most 6 "- " bullets total. NEVER write one bullet per file and NEVER list file \
    paths. Each bullet is a short natural-English clause grounded in the summaries. \
    Leave the body empty only when there is a single self-evident change.
    Write everything in English.
    """
}
