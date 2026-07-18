import Foundation

/// The only product events CheekyPint records (master prompt §20). The list is intentionally
/// tiny and carries NO personal data — no locations, notes, names, images, emails, totals, or
/// QR payloads. New events must stay in this enum so the privacy surface can't drift.
enum AnalyticsEvent: String, Sendable {
    case onboardingCompleted = "onboarding_completed"
    case pintFlowOpened = "pint_flow_opened"
    case pintSaved = "pint_saved"
    case pintUndone = "pint_undone"
    case friendQROpened = "friend_qr_opened"
    case friendQRScanned = "friend_qr_scanned"
    case friendRequestAccepted = "friend_request_accepted"
    case sessionCreated = "session_created"
    case sessionJoined = "session_joined"
}

/// A protocol so analytics can be disabled or swapped without touching feature code. The MVP
/// ships with a no-op by default; a console implementation aids development. No advertising or
/// cross-app tracking SDKs are permitted.
protocol AnalyticsService: Sendable {
    func track(_ event: AnalyticsEvent)
}

/// Default: records nothing. This is the shipping default until a privacy-preserving backend
/// event sink is wired up and disclosed in APP_PRIVACY_DATA_MAPPING.md.
struct NoOpAnalytics: AnalyticsService {
    func track(_ event: AnalyticsEvent) {}
}

/// Development helper — prints event names only.
struct ConsoleAnalytics: AnalyticsService {
    func track(_ event: AnalyticsEvent) {
        #if DEBUG
        print("[analytics] \(event.rawValue)")
        #endif
    }
}
