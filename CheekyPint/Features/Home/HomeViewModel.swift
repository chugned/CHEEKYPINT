import SwiftUI
import CheekyPintCore

/// Drives the Home screen. All counting is delegated to the tested `CheekyPintCore` types —
/// this class only orchestrates loading and presentation.
@MainActor
@Observable
final class HomeViewModel {
    let container: AppContainer
    private(set) var profile: Profile

    var selectedPeriod: LeaderboardPeriod = .week
    private(set) var activeSession: PubSession?
    private(set) var entries: [PintEntry] = []
    private(set) var totals: PersonalTotals = .init(session: nil, week: .zero, month: .zero, year: .zero)
    private(set) var standings: [LeaderboardRow] = []
    private(set) var activeMembers: [SessionMember] = []

    private(set) var isLoading = false
    private(set) var loadError: SupabaseError?
    var lastLogged: PintEntry?
    /// The confirmation copy for the last log: "Pint logged. Cheers." or a welfare nudge (§3.7).
    private(set) var confirmationMessage = WelfareMonitor.cheersMessage
    private(set) var lastWasWelfare = false
    /// Drives the succulent pint-pour celebration — only for a normal (non-welfare) log.
    var showCelebration = false

    init(container: AppContainer, profile: Profile) {
        self.container = container
        self.profile = profile
    }

    func onAppear() async {
        // Default the period to the active session when there is one.
        await load()
        if activeSession != nil { selectedPeriod = .session }
        await loadStandings()
    }

    func load() async {
        isLoading = true; loadError = nil
        defer { isLoading = false }
        do {
            async let session = container.sessions.fetchActiveSession()
            async let entries = container.diary.fetchEntries()
            self.activeSession = try await session
            self.entries = try await entries
            recomputeTotals()
            if let sessionID = activeSession?.id {
                activeMembers = (try? await container.sessions.fetchActiveMembers(sessionID: sessionID)) ?? []
            } else {
                activeMembers = []
            }
        } catch let error as SupabaseError {
            loadError = error
        } catch {
            loadError = .unknown("Couldn't load your pub.")
        }
    }

    func loadStandings() async {
        do {
            standings = try await container.leaderboard.preview(
                period: selectedPeriod, profile: profile, session: activeSession)
        } catch {
            standings = [] // standings are best-effort on Home; the tab shows full errors
        }
    }

    func selectPeriod(_ period: LeaderboardPeriod) async {
        selectedPeriod = period
        await loadStandings()
    }

    private func recomputeTotals() {
        totals = PersonalTotalsCalculator(profile: profile)
            .totals(entries: entries, now: Date(), session: activeSession)
    }

    // MARK: Derived display

    var sessionCountText: String {
        guard activeSession != nil, let total = totals.session else { return "No active pub session" }
        let n = total.recordedCount
        return "\(n) pint\(n == 1 ? "" : "s") this session"
    }

    var hasActiveSession: Bool { activeSession != nil }

    var homeGlassFill: CGFloat {
        let count = totals.session?.recordedCount ?? totals.week.recordedCount
        return min(0.9, 0.14 + CGFloat(count) * 0.13)
    }

    /// The just-logged entry can be undone from the Home banner for a short while.
    func undoLast() async {
        guard let entry = lastLogged else { return }
        do {
            try await container.diary.undoPint(id: entry.id)
            container.analytics.track(.pintUndone)
            lastLogged = nil
            await load()
            await loadStandings()
        } catch {
            // Leave the banner; the user can retry.
        }
    }

    /// Called after a successful log to refresh counts + standings, and to decide whether the
    /// confirmation should be celebratory or a gentle welfare nudge (master prompt §3.7).
    func didLog(_ entry: PintEntry) async {
        lastLogged = entry
        // `entries` still holds the *prior* entries here; WelfareMonitor adds the new one itself.
        let recentDates = entries.filter { $0.countsTowardAlcoholTotals }.map(\.occurredAt)
        let monitor = WelfareMonitor()
        lastWasWelfare = monitor.tone(forEntryAt: entry.occurredAt, recentEntryDates: recentDates) == .welfare
        confirmationMessage = monitor.message(forEntryAt: entry.occurredAt, recentEntryDates: recentDates)
        if !lastWasWelfare, let beerName = BeerCatalog.beerName(in: entry.privateNote) {
            confirmationMessage = "\(beerName) logged. The committee has been notified."
        }
        // Celebrate a normal pint; stay calm (no animation) when the welfare nudge applies.
        showCelebration = !lastWasWelfare
        if lastWasWelfare { Haptics.warning() }
        await load()
        await loadStandings()
    }

    var avatarURL: URL? { container.profiles.avatarURL(for: profile.avatarPath) }
}
