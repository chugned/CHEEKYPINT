import XCTest
import CheekyPintCore
@testable import CheekyPint

/// `FeedViewModel.toggleCheers`'s subtlest rule: two rapid Cheers taps by the same user converge
/// to un-cheered server-side (the RPC toggles, it doesn't set), so the view model must end up
/// matching whatever `toggle_post_cheers` actually returned — never the client's own optimistic
/// guess. A regression that keeps the optimistic value instead of reconciling from the response
/// is invisible to every other suite in this app (see the Task 3 report's broken-gate proof), so
/// this test injects a canned response that deliberately disagrees with the optimistic guess in
/// both fields and asserts the final state matches the response.
@MainActor
final class FeedViewModelTests: XCTestCase {

    func testToggleCheersReconcilesFromTheServerResponseNotTheOptimisticGuess() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        // An unreachable host, same defensive style as `FeedRepositoryTests`'s demo-mode test:
        // demo mode intercepts before any network call, but this makes "no real request is
        // possible" true by construction rather than by trusting that interception alone.
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        let model = FeedViewModel(container: container, toggleCheers: { _ in
            // The optimistic guess for a post starting at (cheered: false, cheersCount: 0) is
            // (cheered: true, cheersCount: 1). This response disagrees with that guess in both
            // fields, so only a genuine reconcile-from-response can produce a match.
            ToggleCheersDTO(cheered: false, cheersCount: 7)
        })
        await model.load()

        guard let target = model.posts.first(where: { !$0.viewerHasCheered && $0.cheersCount == 0 }) else {
            XCTFail("expected a seeded post starting un-cheered with zero cheers")
            return
        }

        await model.toggleCheers(target)

        guard let updated = model.posts.first(where: { $0.id == target.id }) else {
            XCTFail("post disappeared after toggling")
            return
        }
        XCTAssertEqual(updated.viewerHasCheered, false,
                       "must match the server's response (false), not the optimistic guess (true)")
        XCTAssertEqual(updated.cheersCount, 7,
                       "must match the server's response (7), not the optimistic guess (1)")
    }
}
