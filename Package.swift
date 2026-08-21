// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIVoiceAgent",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.27.1")),
    ],
    targets: [
        .target(
            name: "VoiceAgentCore",
            path: "Sources/VoiceAgentCore"
        ),
        .executableTarget(
            name: "VoiceAgentMac",
            dependencies: ["VoiceAgentCore"],
            path: "Sources/VoiceAgentMac",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "VoiceAgentWeb",
            dependencies: [
                "VoiceAgentCore",
                .product(name: "FlyingFox", package: "FlyingFox"),
            ],
            path: "Sources/VoiceAgentWeb",
            resources: [
                .copy("Public"),
            ]
        ),
        .testTarget(
            name: "VoiceAgentCoreTests",
            dependencies: ["VoiceAgentCore"],
            path: "Tests/VoiceAgentCoreTests"
        ),
    ]
)
