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
            name: "ModelCore",
            path: "Sources/ModelCore"
        ),
        .target(
            name: "CommitCore",
            dependencies: ["GitCore"],
            path: "Sources/CommitCore"
        ),
        .target(
            name: "SecretScan",
            dependencies: ["GitCore"],
            path: "Sources/SecretScan"
        ),
        .executableTarget(
            name: "git-commit-message",
            dependencies: ["CommitCore", "GitCore", "ModelCore"],
            path: "Sources/git-commit-message"
        ),
        .executableTarget(
            name: "git-branch-name",
            dependencies: ["CommitCore", "GitCore", "ModelCore"],
            path: "Sources/git-branch-name"
        ),
        .executableTarget(
            name: "git-branch-clean",
            dependencies: ["GitCore"],
            path: "Sources/git-branch-clean"
        ),
        .executableTarget(
            name: "git-secret-check",
            dependencies: ["SecretScan", "GitCore", "ModelCore"],
            path: "Sources/git-secret-check"
        ),
    ]
)
