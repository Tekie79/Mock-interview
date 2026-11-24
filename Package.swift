// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiveMockInterviewAssistant",
    platforms: [.macOS("14.2")],
    products: [.library(name: "ConversationCore", targets: ["ConversationCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "ConversationCore", dependencies: ["CSQLite"]),
        .testTarget(name: "ConversationCoreTests", dependencies: ["ConversationCore"])
    ]
)
