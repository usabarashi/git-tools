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
    --dry-run    Print the dry-run execution plan (fast vs map-reduce path and
                 parsed files), then exit. Works even when Apple Intelligence is
                 not enabled.
    -h, --help   Show this help.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
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

// --dry-run exits before touching the model so the plan can be inspected
// even when Apple Intelligence is not yet enabled.
if isDryRun {
    print(Generator.dryRunDescription(stat: stat, patch: patch))
    exit(0)
}

// MARK: - Availability gate (before any model call)

if let reason = ModelAvailability.unavailableReason() {
    fail(reason)
}

// MARK: - Generate

do {
    let message = try await Generator.generate(stat: stat, patch: patch)
    print(message.rendered())
} catch {
    fail("generation failed: \(error)")
}
