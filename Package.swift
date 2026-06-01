// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "git-tools",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "CommitCore",
            path: "Sources/CommitCore"
        ),
        .executableTarget(
            name: "git-commit-message",
            dependencies: ["CommitCore"],
            path: "Sources/git-commit-message"
        ),
        .executableTarget(
            name: "git-branch-name",
            dependencies: ["CommitCore"],
            path: "Sources/git-branch-name"
        ),
    ]
)
