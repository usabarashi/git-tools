import Foundation

/// Why a branch is considered already integrated. These describe *content*
/// equivalence against the base, not merge provenance: a branch is a candidate
/// when its work is already represented on the base, however it got there.
public enum CleanReason: Sendable {
    /// The branch tip is an ancestor of the base (a normal, non-squash merge).
    case merged
    /// The branch's aggregate diff from the merge-base already exists on the
    /// base as an equivalent patch — the typical squash-merge signature.
    case patchEquivalent
    /// The branch has no net change from the merge-base (e.g. work then revert).
    case sameTree

    public var label: String {
        switch self {
        case .merged: return "merged"
        case .patchEquivalent: return "patch-equivalent"
        case .sameTree: return "no-diff"
        }
    }

    public func explanation(base: String) -> String {
        switch self {
        case .merged: return "merged into \(base)"
        case .patchEquivalent: return "patch already on \(base) (squash-merged)"
        case .sameTree: return "no changes vs \(base)"
        }
    }
}

public struct CleanCandidate: Sendable {
    public let branch: String
    public let tip: String
    public let reason: CleanReason
}

public enum BranchCleaner {
    /// Non-protected local branches whose content is already represented on
    /// `base` (e.g. `origin/main`). Branches with unrelated history (no
    /// merge-base) are left untouched.
    public static func candidates(
        base: String,
        protectedBranches: Set<String>,
        protectedPrefixes: [String]
    ) -> [CleanCandidate] {
        var result: [CleanCandidate] = []
        for branch in Git.localBranches() {
            if protectedBranches.contains(branch) { continue }
            if protectedPrefixes.contains(where: branch.hasPrefix) { continue }
            guard let reason = classify(branch: branch, base: base) else { continue }
            result.append(CleanCandidate(branch: branch, tip: Git.tipSHA(branch), reason: reason))
        }
        return result
    }

    private static func classify(branch: String, base: String) -> CleanReason? {
        if Git.isAncestor(branch, of: base) {
            return .merged
        }
        guard let mergeBase = Git.mergeBase(branch, base) else {
            return nil  // unrelated history; never a candidate
        }
        if Git.hasNoDiff(from: mergeBase, to: branch) {
            return .sameTree
        }
        // Squash detection: a synthetic commit carrying the branch's whole diff
        // from the merge-base; if its patch already exists upstream, the branch
        // was squash-merged.
        guard let tree = try? Git.run(["rev-parse", "\(branch)^{tree}"])
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !tree.isEmpty,
            let synthetic = try? Git.commitTree(tree: tree, parent: mergeBase)
        else { return nil }
        return Git.patchExistsUpstream(base: base, commit: synthetic, limit: mergeBase)
            ? .patchEquivalent : nil
    }
}
