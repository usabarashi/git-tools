import Foundation
import GitCore
import ModelCore
import SecretScan

let helpText = """
git-secret-check — advisory, on-device AI scan of staged changes for secrets.

USAGE:
    git secret-check [--dry-run] [--report-only] [--fail-on LEVEL] [--help]

    Reads `git diff --staged` and asks Apple's on-device model whether any added
    lines look like real secrets (API keys, tokens, passwords, private keys,
    credentials). Detected values are shown masked, never in full.

    This is a COMPLEMENT to a deterministic scanner like gitleaks, not a
    replacement: an on-device model can miss secrets, so a clean result does
    not prove the diff is secret-free.

OPTIONS:
    --dry-run         List the files that would be scanned, then exit (no model).
    --report-only     Exit 0 even when secrets are found (still prints them).
                      An incomplete scan or an unavailable model still exits 2,
                      so a result is never silently treated as clean.
    --fail-on LEVEL   Minimum confidence that causes a non-zero exit:
                      high (default), medium, or low.
    -h, --help        Show this help.

EXIT CODES:
    0  no findings at or above the --fail-on level (or --report-only)
    1  findings at or above the --fail-on level
    2  scan incomplete, model unavailable, or an error occurred
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    try? FileHandle.standardError.write(contentsOf: Data("error: \(message)\n".utf8))
    exit(code)
}

func note(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
}

// MARK: - Argument parsing

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(helpText)
    exit(0)
}
let isDryRun = arguments.contains("--dry-run")
let reportOnly = arguments.contains("--report-only")

var failOn: Confidence = .high
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "--dry-run", "--report-only":
        break
    case "--fail-on":
        guard index + 1 < arguments.count else { fail("--fail-on requires a level (high|medium|low)") }
        guard let level = Confidence.parse(arguments[index + 1]) else {
            fail("invalid --fail-on level '\(arguments[index + 1])'. Use high, medium, or low")
        }
        failOn = level
        index += 1
    default:
        fail("unknown option '\(argument)'. See --help")
    }
    index += 1
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

// --dry-run exits before touching the model so it works even when Apple
// Intelligence is not enabled.
if isDryRun {
    print(SecretScanner.plan(stat: stat, patch: patch))
    exit(0)
}

// MARK: - Availability gate (before any model call)

if let reason = ModelAvailability.unavailableReason() {
    fail(reason)
}

// MARK: - Scan

let result: ScanResult
do {
    result = try await SecretScanner.scan(patch: patch)
} catch {
    // Never interpolate the raw error: a decode/model error can embed response
    // text or diff fragments, i.e. the very secret this tool exists to protect.
    fail("scan failed")
}

// MARK: - Report

if result.findings.isEmpty {
    print("No AI findings.")
} else {
    print("Possible secrets in staged changes (advisory):\n")
    for finding in result.findings {
        print(
            "  \(finding.file) — \(finding.category.rawValue) [\(finding.confidence.label)] \(finding.masked)")
        print("      \(finding.reason)")
    }
    print("")
}

// A clean scan must never be read as a guarantee.
print("This AI pass is advisory and can miss secrets; gitleaks remains the authoritative detector.")

if result.isIncomplete {
    note("warning: could not fully scan: \(result.incompleteFiles.joined(separator: ", "))")
}

// MARK: - Exit

if result.isIncomplete {
    exit(2)  // never report "clean" when coverage was incomplete
}
if reportOnly {
    exit(0)
}
let gating = result.findings.filter { $0.confidence >= failOn }
exit(gating.isEmpty ? 0 : 1)
