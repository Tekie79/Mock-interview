// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveMockInterviewAssistant",
    platforms: [.macOS("14.2")],
    products: [.library(name: "ConversationCore", targets: ["ConversationCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .target(name: "AudioBufferSlots"),
        .target(name: "ConversationCore", dependencies: ["CSQLite", "CZlib", "AudioBufferSlots"]),
        .testTarget(name: "ConversationCoreTests", dependencies: ["ConversationCore", "AudioBufferSlots"])
    ]
)
