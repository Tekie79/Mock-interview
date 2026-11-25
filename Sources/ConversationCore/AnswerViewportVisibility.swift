import Foundation

public enum AnswerViewportVisibility {
    /// Require a meaningful portion of the first useful line in a visible window.
    public static func containsUsefulText(_ text: CGRect, in viewport: CGRect, windowVisible: Bool) -> Bool {
        guard windowVisible, !text.isEmpty, !viewport.isEmpty else { return false }
        let visible = text.intersection(viewport)
        guard !visible.isNull else { return false }
        return visible.height >= text.height * 0.75 && visible.width >= text.width * 0.75
    }
}
