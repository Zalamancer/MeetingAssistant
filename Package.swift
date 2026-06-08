// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingAssistant",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MeetingAssistant", targets: ["MeetingAssistant"])
    ],
    dependencies: [
        // Using native URLSession - no external dependencies needed
    ],
    targets: [
        .executableTarget(
            name: "MeetingAssistant",
            dependencies: [],
            path: "MeetingAssistant",
            exclude: ["Resources/Info.plist"]
        )
    ]
)
