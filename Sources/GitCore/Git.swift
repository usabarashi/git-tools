import Foundation

public enum GitError: Error, CustomStringConvertible {
    case commandFailed(args: [String], message: String)

    public var description: String {
        switch self {
        case let .commandFailed(args, message):
            let cmd = (["git"] + args).joined(separator: " ")
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "`\(cmd)` failed" : "`\(cmd)` failed: \(detail)"
        }
    }
}

/// Thin wrapper over the `git` executable. Holds only generic plumbing — no
/// knowledge of commit messages or branch cleaning — so any tool in the suite
/// can depend on it without pulling in FoundationModels.
public enum Git {
    /// Outcome of a git invocation that is allowed to fail: callers that treat
    /// a non-zero exit as data (e.g. `merge-base --is-ancestor`) inspect `code`
    /// instead of catching an error.
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    /// Runs `git` and returns its captured streams plus exit status, never
    /// throwing on a non-zero exit. stdout and stderr are drained concurrently
    /// so that a large diff on one stream cannot fill its pipe buffer and
    /// deadlock the child while we block reading the other.
    @discardableResult
    public static func capture(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // The semaphore strictly orders the background write to errData before
        // the main thread reads it after errSemaphore.wait(), so the access is
        // synchronized; `nonisolated(unsafe)` documents that to the compiler.
        nonisolated(unsafe) var errData = Data()
        let errSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            errSemaphore.signal()
        }
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        errSemaphore.wait()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Runs `git` and returns its standard output, throwing on a non-zero exit.
    @discardableResult
    public static func run(_ arguments: [String]) throws -> String {
        let result = try capture(arguments)
        guard result.status == 0 else {
            throw GitError.commandFailed(args: arguments, message: result.stderr)
        }
        return result.stdout
    }

    // MARK: - Staged diff (used by the message/branch-name generators)

    public static func stagedStat() throws -> String {
        try run(["diff", "--staged", "--stat"])
    }

    public static func stagedPatch() throws -> String {
        try run(["diff", "--staged"])
    }
}
