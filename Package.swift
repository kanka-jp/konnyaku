// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Konnyaku",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "Konnyaku",
            path: "Sources/Konnyaku",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "KonnyakuTests",
            dependencies: ["Konnyaku"],
            path: "Tests/KonnyakuTests"
        ),
    ]
)
