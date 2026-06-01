// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "git-tools",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "GitCore",
            path: "Sources/GitCore"
        ),
        .target(
            name: "CommitCore",
            path: "Sources/CommitCore"
        ),
        .executableTarget(
            name: "git-commit-message",
            dependencies: ["CommitCore", "GitCore"],
            path: "Sources/git-commit-message"
        ),
        .executableTarget(
            name: "git-branch-name",
            dependencies: ["CommitCore", "GitCore"],
            path: "Sources/git-branch-name"
        ),
        .executableTarget(
            name: "git-branch-clean",
            dependencies: ["GitCore"],
            path: "Sources/git-branch-clean"
        ),
    ]
)
