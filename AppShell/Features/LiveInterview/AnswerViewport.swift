import AppKit
import ConversationCore
import SwiftUI

/// The probe covers the first useful line, rather than a card or scroll target.
struct AnswerViewport: NSViewRepresentable {
    let revision: UUID
    let acknowledge: (UUID) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.revision = revision
        nsView.acknowledge = acknowledge
        nsView.scheduleSample()
    }

    static func dismantleNSView(_ nsView: Probe, coordinator: ()) { nsView.disconnect() }

    final class Probe: NSView {
        var revision: UUID?
        var acknowledge: ((UUID) -> Void)?
        private var reported: UUID?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disconnect()
            guard let window else { return }
            if let clip = enclosingScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, clip)
            }
            observe(NSWindow.didChangeOcclusionStateNotification, window)
            observe(NSWindow.didResizeNotification, window)
            scheduleSample()
        }

        override func layout() {
            super.layout()
            scheduleSample()
        }

        private func observe(_ name: Notification.Name, _ sender: AnyObject) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: sender, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.scheduleSample() }
            })
        }

        func scheduleSample() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                guard let revision, revision != reported, let window,
                      !isHiddenOrHasHiddenAncestor,
                      AnswerViewportVisibility.containsUsefulText(bounds, in: visibleRect,
                          windowVisible: window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
                else { return }
                reported = revision
                acknowledge?(revision)
            }
        }

        func disconnect() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}
