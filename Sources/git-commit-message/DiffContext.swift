import Foundation

/// Builds the textual context handed to the model from the staged diff.
///
/// The on-device model has a small (~4k token) context window, so large diffs
/// are reduced with a staged fallback (Q4): always keep the `--stat` header and
/// the structural lines of the patch (file and hunk headers), then fill the
/// remaining budget with changed lines.
enum DiffContext {
    /// Rough character budget for the patch body. ~4 chars per token leaves
    /// room for the (few-shot) instructions, stat header and generated output
    /// within the model's ~4k-token context window.
    static let maxPatchCharacters = 7_000

    static func build(stat: String, patch: String) -> String {
        let header = "Files changed:\n\(stat)"
        if patch.count <= maxPatchCharacters {
            return "\(header)\n\nDiff:\n\(patch)"
        }
        let thinned = thin(patch: patch, budget: maxPatchCharacters)
        return "\(header)\n\nDiff (truncated to fit the on-device context window):\n\(thinned)"
    }

    /// Minimal context used as a last-resort fallback when even the thinned
    /// patch overflows the context window: only the file list and counts.
    static func statOnly(stat: String) -> String {
        "Files changed:\n\(stat)"
    }

    private static func thin(patch: String, budget: Int) -> String {
        var kept: [String] = []
        var used = 0
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if used + line.count + 1 > budget && !isStructural(line) {
                continue
            }
            kept.append(line)
            used += line.count + 1
        }
        return kept.joined(separator: "\n")
    }

    /// Structural lines describe *which* files and regions changed and are
    /// always kept so the model can still reason about scope.
    private static func isStructural(_ line: String) -> Bool {
        line.hasPrefix("diff --git")
            || line.hasPrefix("@@")
            || line.hasPrefix("+++")
            || line.hasPrefix("---")
            || line.hasPrefix("new file")
            || line.hasPrefix("deleted file")
            || line.hasPrefix("rename ")
    }
}
