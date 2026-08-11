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
    private(set) var entries: [PintEntry] = []
    private(set) var totals: PersonalTotals = .init(session: nil, week: .zero, month: .zero, year: .zero)

    private(set) var isLoading = false
    private(set) var loadError: SupabaseError?
    var lastLogged: PintEntry?
    /// The confirmation copy for the last log.
    private(set) var confirmationMessage = WelfareMonitor.cheersMessage
    private(set) var lastWasWelfare = false
    init(container: AppContainer, profile: Profile) {
        self.container = container
        self.profile = profile
    }

    func syncProfile(_ profile: Profile) {
        self.profile = profile
        recomputeTotals()
    }

    func onAppear() async {
        await load()
    }

    func load() async {
        isLoading = true; loadError = nil
        defer { isLoading = false }
        do {
            entries = try await container.diary.fetchEntries()
            recomputeTotals()
        } catch let error as SupabaseError {
            loadError = error
        } catch {
            loadError = .unknown("Couldn't load your beer log.")
        }
    }

    func selectPeriod(_ period: LeaderboardPeriod) {
        selectedPeriod = period
    }

    private func recomputeTotals() {
        totals = PersonalTotalsCalculator(profile: profile)
            .totals(entries: entries, now: Date(), session: nil)
    }

    // MARK: Derived display

    var displayedCount: Int {
        switch selectedPeriod {
        case .session: return 0
        case .week: return totals.week.recordedCount
        case .month: return totals.month.recordedCount
        case .year: return totals.year.recordedCount
        }
    }

    var periodCountText: String {
        let noun = displayedCount == 1 ? "beer" : "beers"
        return "\(displayedCount) \(noun) logged \(selectedPeriod.leaderboardTitle.lowercased())"
    }

    var homeGlassFill: CGFloat {
        min(0.9, 0.14 + CGFloat(displayedCount) * 0.13)
    }

    /// The just-logged entry can be undone from the Home banner for a short while.
    func undoLast() async {
        guard let entry = lastLogged else { return }
        do {
            try await container.diary.undoPint(id: entry.id)
            container.analytics.track(.pintUndone)
            lastLogged = nil
            await load()
        } catch {
            // Leave the banner; the user can retry.
        }
    }

    /// Called after a successful log to refresh counts + standings.
    func didLog(_ entry: PintEntry) async {
        lastLogged = entry
        lastWasWelfare = false
        if let beerName = BeerCatalog.beerName(in: entry.privateNote) {
            confirmationMessage = "\(beerName) logged. The committee has been notified."
        } else {
            confirmationMessage = WelfareMonitor.cheersMessage
        }
        await load()
    }

    var avatarURL: URL? { container.profiles.avatarURL(for: profile.avatarPath) }
}
