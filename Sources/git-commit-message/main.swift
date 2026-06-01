import Foundation
import FoundationModels

let helpText = """
git-commit-message — generate a commit message from staged changes using
Apple's on-device foundation model.

USAGE:
    git commit-message [--dry-run] [--help]

    Reads `git diff --staged` and prints a single Conventional Commits message
    to stdout. Pipe it straight into a commit:

        git commit-message | git commit -F -

OPTIONS:
    --dry-run    Print the prompt that would be sent to the model, then exit.
                 Works even when Apple Intelligence is not enabled.
    -h, --help   Show this help.
"""

let instructions = """
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

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func buildPrompt(context: String) -> String {
    """
    Generate a commit message for the following staged changes.

    \(context)
    """
}

func generate(prompt: String) async throws -> CommitMessage {
    let session = LanguageModelSession(instructions: instructions)
    let response = try await session.respond(
        to: prompt,
        generating: CommitMessage.self,
        options: GenerationOptions(temperature: 0.3)
    )
    return response.content
}

// MARK: - Argument parsing

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(helpText)
    exit(0)
}
let isDryRun = arguments.contains("--dry-run")

let recognizedOptions: Set<String> = ["--dry-run"]
for argument in arguments where !recognizedOptions.contains(argument) {
    fail("unknown option '\(argument)'. See --help")
}

// MARK: - Read staged diff

let stat: String
let patch: String
do {
    stat = try Git.stagedStat()
    patch = try Git.stagedPatch()
} catch {
    fail("\(error)")
}

if patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    fail("no staged changes. Stage files with `git add` first")
}

let context = DiffContext.build(stat: stat, patch: patch)
let prompt = buildPrompt(context: context)

// --dry-run exits before touching the model so the prompt can be inspected
// even when Apple Intelligence is not yet enabled.
if isDryRun {
    print(prompt)
    exit(0)
}

// MARK: - Availability gate (before any model call)

if let reason = ModelAvailability.unavailableReason() {
    fail(reason)
}

// MARK: - Generate

do {
    let message: CommitMessage
    do {
        message = try await generate(prompt: prompt)
    } catch let error as LanguageModelSession.GenerationError {
        // Only the context window overflow is recoverable by shrinking the
        // input; any other generation error should surface as-is.
        guard case .exceededContextWindowSize = error else { throw error }
        let minimal = buildPrompt(context: DiffContext.statOnly(stat: stat))
        message = try await generate(prompt: minimal)
    }
    print(message.rendered())
} catch {
    fail("generation failed: \(error)")
}
