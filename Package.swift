// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LANCast",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "LANCast",
            path: "Sources/LANCast"
        )
    ]
)
