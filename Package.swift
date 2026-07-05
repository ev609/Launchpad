// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Launchpad",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Launchpad",
            path: "Sources/Launchpad"
        )
    ]
)
