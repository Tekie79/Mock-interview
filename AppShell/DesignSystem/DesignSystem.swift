import AppKit
import ConversationCore
import SwiftUI

enum InterviewAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum Studio {
    static let canvas = adaptive(0xF7F8FA, 0x151922)
    static let surface = adaptive(0xFFFFFF, 0x1C222E)
    static let elevated = adaptive(0xEEF2F9, 0x262E3C)
    static let primary = adaptive(0x202938, 0xEDF1F8)
    static let secondary = adaptive(0x4D5B70, 0xB4C1D6)
    static let muted = adaptive(0x626F82, 0x9BAAC1)
    static let accent = adaptive(0x3655D7, 0xA0B5FF)
    static let success = adaptive(0x187854, 0x68D9A9)
    static let warning = adaptive(0x875B17, 0xF1C479)
    static let error = adaptive(0xA92B43, 0xFF9CAB)
    static let separator = adaptive(0xDCE3ED, 0x333E50)
    static let selection = adaptive(0xE8EEFF, 0x303F67)

    static let small: CGFloat = 4
    static let tight: CGFloat = 8
    static let row: CGFloat = 12
    static let section: CGFloat = 16
    static let page: CGFloat = 24
    static let group: CGFloat = 32

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct StudioHeading: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.small) {
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(Studio.primary)
                .accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).font(.callout).foregroundStyle(Studio.secondary) }
        }
    }
}

struct StudioEmpty: View {
    let title: String
    let icon: String
    let detail: String

    var body: some View {
        VStack(spacing: Studio.tight) {
            Image(systemName: icon).font(.title2).foregroundStyle(Studio.accent).accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Studio.primary)
            Text(detail).font(.callout).foregroundStyle(Studio.secondary).multilineTextAlignment(.center)
        }
        .padding(Studio.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioStatus: View {
    let state: LiveState
    var detail: String? = nil

    private var color: Color {
        switch state {
        case .listening: Studio.success
        case .failed: Studio.error
        case .reconnecting, .degraded, .paused: Studio.warning
        default: Studio.muted
        }
    }

    var body: some View {
        Label {
            Text(detail ?? state.rawValue.capitalized).font(.callout.weight(.medium))
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(color)
        }
        .foregroundStyle(Studio.secondary)
        .accessibilityElement(children: .combine)
    }
}

struct StudioSessionClock: View {
    let startedAt: Date?
    let endedAt: Date?

    var body: some View {
        if let startedAt {
            Group {
                if let endedAt {
                    Text(Duration.seconds(max(0, endedAt.timeIntervalSince(startedAt))).formatted(.time(pattern: .minuteSecond)))
                } else {
                    Text(startedAt, style: .timer)
                }
            }
            .monospacedDigit().font(.callout).foregroundStyle(Studio.muted)
            .accessibilityLabel("Elapsed session time")
        }
    }
}

extension View {
    func studioIcon(_ label: String) -> some View { accessibilityLabel(label).help(label) }

    func studioSurface() -> some View {
        background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
