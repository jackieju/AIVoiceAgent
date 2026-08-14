// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIVoiceAgent",
    platforms: [.macOS(.v13)],
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
        .testTarget(
            name: "VoiceAgentCoreTests",
            dependencies: ["VoiceAgentCore"],
            path: "Tests/VoiceAgentCoreTests"
        ),
    ]
)
