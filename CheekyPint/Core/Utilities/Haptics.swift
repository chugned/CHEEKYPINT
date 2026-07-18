import UIKit

/// Supplementary haptic feedback (master prompt §21 — haptics must never be the *only* signal).
/// All feedback is also conveyed visually and via VoiceOver announcements.
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
