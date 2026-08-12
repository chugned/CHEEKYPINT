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

    /// The ordering half of the Cheers bug, left open by the reconciliation fix above: each tap
    /// used to spawn its own unguarded `Task`, so two rapid taps on the *same* post raced two
    /// requests over one HTTP/2 connection with no ordering guarantee. If the second request's
    /// reply (say, "off") landed before the first's ("on"), `reconcile` applied whichever arrived
    /// last — reconciling from a response doesn't help when the wrong response is the one that
    /// arrives last. `FeedViewModel` now tracks per-post in-flight state and ignores a tap on a
    /// post that already has one outstanding, which removes the race by construction: at most one
    /// request per post can ever be outstanding, so there is nothing left to arrive out of order.
    /// This test proves that by forcing two taps to overlap and asserting only one request fires;
    /// without the in-flight guard, both taps reach the injected closure and this fails 2 != 1.
    func testConcurrentCheersTapsOnTheSamePostIgnoreTheSecondWhileOneIsOutstanding() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        var callCount = 0
        let model = FeedViewModel(container: container, toggleCheers: { _ in
            callCount += 1
            // Long enough that, without the in-flight guard, a second concurrent tap reaches
            // this closure before the first call below has a chance to return.
            try await Task.sleep(nanoseconds: 100_000_000)
            return ToggleCheersDTO(cheered: true, cheersCount: 1)
        })
        await model.load()

        guard let target = model.posts.first else {
            XCTFail("expected at least one seeded post")
            return
        }

        // Two taps issued back-to-back, exactly as two fast taps on the same button would: each
        // becomes its own `Task` in `FeedView`'s `onToggleCheers` closure, with nothing between
        // them.
        async let first: Void = model.toggleCheers(target)
        async let second: Void = model.toggleCheers(target)
        _ = await (first, second)

        XCTAssertEqual(callCount, 1,
                       "a second tap on a post with a Cheers request already outstanding must be " +
                       "ignored rather than firing its own request")
    }
}
