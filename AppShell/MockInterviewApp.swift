import AppKit
import ConversationCore
import LocalAuthentication
import Security
import SwiftUI
import UniformTypeIdentifiers

enum WorkspaceWindow: String, Codable, Hashable {
    case main
}

@main
struct MockInterviewApp: App {
    @State private var model = WorkspaceModel()
    @NSApplicationDelegateAdaptor(InterviewAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @AppStorage("interviewAppearance") private var appearance = InterviewAppearance.system
    @AppStorage("pauseShortcut") private var pauseShortcut = "p"
    @AppStorage("compactShortcut") private var compactShortcut = "k"

    var body: some Scene {
        WindowGroup("Mock Interview", id: "workspace", for: WorkspaceWindow.self) { _ in
            WorkspaceNavigation(model: model)
                .onAppear { appDelegate.model = model }
                .frame(minWidth: 760, minHeight: 530)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Studio.accent)
        } defaultValue: {
            .main
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            #if M12_UI_FIXTURES
            CommandMenu("Verification") {
                Button("Load 200 Chat Entries") { model.seedChatLoad() }
                    .keyboardShortcut("9", modifiers: [.command, .option, .control])
            }
            #endif
            CommandMenu("Interview") {
                Button(model.offersInterviewerOutputConfirmation ? "Start With Manual Answers" : "Start or Resume") {
                    model.startOrResume()
                }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                Button("Pause") { model.pause() }
                    .keyboardShortcut(KeyEquivalent(pauseShortcut.first ?? "p"), modifiers: [.command, .shift])
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Show Compact Window") { openWindow(id: "compact") }
                    .keyboardShortcut(KeyEquivalent(compactShortcut.first ?? "k"), modifiers: [.command, .shift])
            }
        }

        Window("Compact Answer", id: "compact") {
            CompactView(model: model)
                .onAppear { appDelegate.model = model }
                .task {
                    if model.store == nil { await model.load() }
                }
                .frame(minWidth: 300, minHeight: 210)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Studio.accent)
        }
        .defaultSize(width: 430, height: 285)

        Window("Solo Practice", id: "solo") {
            SoloPracticeView(model: model)
                .frame(minWidth: 560, minHeight: 430)
        }

        Settings {
            ProviderSettingsView(model: model)
                .frame(width: 730, height: 650)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Studio.accent)
        }
    }
}

@MainActor
private final class InterviewAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: WorkspaceModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.shutdownForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
