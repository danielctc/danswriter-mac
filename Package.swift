// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "DansWriter",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "DansWriter", targets: ["WriteOnApp"]),
        .executable(name: "WriteOnLauncher", targets: ["WriteOnLauncher"])
    ],
    targets: [
        .target(name: "WriteOnCore"),
        .target(name: "WriteOnAI", dependencies: ["WriteOnCore"]),
        .executableTarget(name: "WriteOnLauncher"),
        .executableTarget(name: "WriteOnApp", dependencies: ["WriteOnCore", "WriteOnAI"], resources: [.copy("Resources/Markdown")]),
        .executableTarget(name: "WriteOnCoreChecks", dependencies: ["WriteOnCore"], path: "Tests/WriteOnCoreChecks"),
        .executableTarget(name: "WriteOnAIChecks", dependencies: ["WriteOnCore", "WriteOnAI"], path: "Tests/WriteOnAIChecks"),
        .executableTarget(name: "WriteOnResearchChecks", dependencies: ["WriteOnCore", "WriteOnAI"], path: "Tests/WriteOnResearchChecks"),
        .executableTarget(name: "WriteOnUpdateChecks", dependencies: ["WriteOnAI"], path: "Tests/WriteOnUpdateChecks"),
        .testTarget(name: "WriteOnCoreTests", dependencies: ["WriteOnCore"]),
        .testTarget(name: "WriteOnAITests", dependencies: ["WriteOnAI", "WriteOnCore"])
    ]
)
