import Foundation

/// The tone of the confirmation feedback after logging a pint.
public enum PintFeedbackTone: Sendable, Equatable {
    /// The normal, warm confirmation: "Pint logged. Cheers."
    case cheers
    /// A neutral welfare nudge that replaces any celebration when entries cluster (§3.7).
    case welfare
}

/// Decides whether to show a cheerful confirmation or a gentle welfare notice.
///
/// This is core to the app's safety positioning (master prompt §3): the app must never
/// celebrate heavy or rapid drinking. When several drinks are logged within a short window,
/// the celebratory feedback is *replaced* — not supplemented — by a caring message. It does
/// not diagnose, judge, or block; it just softens the tone.
public struct WelfareMonitor: Sendable {
    public let windowSeconds: TimeInterval
    public let threshold: Int

    /// - Parameters:
    ///   - windowSeconds: how far back to look. Default 90 minutes.
    ///   - threshold: number of entries within the window (including the new one) that
    ///     switches the tone to welfare. Default 3.
    public init(windowSeconds: TimeInterval = 90 * 60, threshold: Int = 3) {
        self.windowSeconds = windowSeconds
        self.threshold = threshold
    }

    /// The neutral welfare copy (master prompt §3.7). No celebration, no medical claim.
    public static let welfareMessage = "Take it easy. Have some water and look after yourself."

    /// The standard confirmation copy (master prompt §1).
    public static let cheersMessage = "Pint logged. Cheers."

    /// Determine the tone for a new entry given the timestamps of the user's recent
    /// *alcoholic* entries (callers should pass alcohol-free entries too only if they want
    /// them to count toward the nudge; by default the app passes alcoholic ones).
    public func tone(forEntryAt newDate: Date, recentEntryDates: [Date]) -> PintFeedbackTone {
        let windowStart = newDate.addingTimeInterval(-windowSeconds)
        // Count recent entries in (windowStart, newDate], plus the new one itself.
        let recentCount = recentEntryDates.filter { $0 > windowStart && $0 <= newDate }.count
        let total = recentCount + 1
        return total >= threshold ? .welfare : .cheers
    }

    public func message(forEntryAt newDate: Date, recentEntryDates: [Date]) -> String {
        tone(forEntryAt: newDate, recentEntryDates: recentEntryDates) == .welfare
            ? Self.welfareMessage
            : Self.cheersMessage
    }
}
