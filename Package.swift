// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rill",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Rill", path: "Sources/Rill")
    ]
)
