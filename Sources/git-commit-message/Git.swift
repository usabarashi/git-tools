import Foundation

enum GitError: Error, CustomStringConvertible {
    case commandFailed(args: [String], message: String)

    var description: String {
        switch self {
        case let .commandFailed(args, message):
            let cmd = (["git"] + args).joined(separator: " ")
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "`\(cmd)` failed" : "`\(cmd)` failed: \(detail)"
        }
    }
}

enum Git {
    /// Runs `git` with the given arguments and returns its standard output.
    /// stdout and stderr are drained concurrently so that a large diff on one
    /// stream cannot fill its pipe buffer and deadlock the child while we block
    /// reading the other.
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // The semaphore strictly orders the write in the background queue
        // before the read after wait(), so the access is synchronized;
        // `nonisolated(unsafe)` documents that to the Swift 6 compiler.
        nonisolated(unsafe) var errData = Data()
        let errSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            errSemaphore.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errSemaphore.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw GitError.commandFailed(args: arguments, message: message)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    static func stagedStat() throws -> String {
        try run(["diff", "--staged", "--stat"])
    }

    static func stagedPatch() throws -> String {
        try run(["diff", "--staged"])
    }
}
