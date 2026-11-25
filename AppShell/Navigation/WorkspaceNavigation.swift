import AppKit
import ConversationCore
import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case live = "Live Interview"
    case profiles = "Profiles"
    case history = "History"
    case practice = "Practice"
    case settings = "Settings"

    var id: Self { self }
    var icon: String {
        switch self {
        case .live: "waveform"
        case .profiles: "person.crop.rectangle"
        case .history: "clock.arrow.circlepath"
        case .practice: "text.bubble"
        case .settings: "gearshape"
        }
    }
}

struct WorkspaceNavigation: View {
    @Bindable var model: WorkspaceModel
    @AppStorage("workspaceSidebarCollapsed") private var collapsed = false
    @State private var destination: WorkspaceDestination? = .live
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(get: { collapsed ? .detailOnly : .all }, set: { collapsed = $0 == .detailOnly })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if collapsed { rail }
                NavigationSplitView(columnVisibility: columns) {
                    List(selection: $destination) {
                        Section("Mock Interview") {
                            ForEach(WorkspaceDestination.allCases) { item in
                                Label(item.rawValue, systemImage: item.icon).tag(item)
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
                    .accessibilityLabel("Workspace navigation")
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Studio.canvas)
                }
            }
            Rectangle().fill(Studio.separator).frame(height: 1).accessibilityHidden(true)
            SessionControlBar(model: model, compact: false)
        }
        .sheet(isPresented: $model.showAudioConfiguration) {
            AudioConfigurationSheet(model: model)
        }

        .task {
            if model.store == nil { await model.load() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            model.prepareForSleep()
        }
    }

    private var rail: some View {
        VStack(spacing: Studio.tight) {
            Button { collapsed = false } label: { Image(systemName: "sidebar.left").frame(width: 30, height: 30) }
                .studioIcon("Expand sidebar")
            ForEach(WorkspaceDestination.allCases) { item in
                Button {
                    destination = item
                } label: {
                    Image(systemName: item.icon).frame(width: 34, height: 34)
                        .background(destination == item ? Studio.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .studioIcon(item.rawValue)
                .accessibilityAddTraits(destination == item ? .isSelected : [])
            }
            Spacer()
        }
        .buttonStyle(.plain)
        .padding(Studio.tight)
        .background(Studio.elevated)
    }

    @ViewBuilder private var detail: some View {
        switch destination ?? .live {
        case .live: WorkspaceView(model: model)
        case .profiles:
            if let store = model.store { ProfileEditor(model: model, store: store, embedded: true) }
            else { storeUnavailable }
        case .history:
            if let store = model.store {
                InterviewReviewView(model: model, store: store, current: model.finishedRecord(), embedded: true)
            } else { storeUnavailable }
        case .practice: SoloPracticeView(model: model)
        case .settings: ProviderSettingsView(model: model)
        }
    }

    private var storeUnavailable: some View {
        StudioEmpty(title: "Local storage unavailable", icon: "externaldrive.badge.exclamationmark",
                    detail: model.error ?? "The workspace is opening its local library.")
    }
}

private struct AudioConfigurationSheet: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.section) {
            HStack {
                StudioHeading(title: "Audio configuration")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let issue = model.error {
                Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(Studio.warning)
            }
            AudioSourceEditor(model: model)
        }
        .padding(Studio.page)
        .frame(minWidth: 630)
    }
}
