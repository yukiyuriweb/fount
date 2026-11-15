// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Fount",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Fount", path: "Sources/Fount")
    ],
    swiftLanguageModes: [.v5]
)
