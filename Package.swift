// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "git-commit-message",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "git-commit-message",
            path: "Sources/git-commit-message"
        )
    ]
)
