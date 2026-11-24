// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveMockInterviewAssistant",
    platforms: [.macOS("14.2")],
    products: [.library(name: "ConversationCore", targets: ["ConversationCore"])],
    targets: [
        .target(name: "ConversationCore"),
        .testTarget(name: "ConversationCoreTests", dependencies: ["ConversationCore"])
    ]
)
