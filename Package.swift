// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Relay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Relay", path: "Sources/Relay")
    ]
)
