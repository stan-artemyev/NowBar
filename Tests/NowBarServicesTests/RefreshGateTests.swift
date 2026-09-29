import Testing
@testable import NowBarServices

/// A `RefreshGate` to call from `#expect`. A class, because `#expect` can't call a mutating method on a struct.
private final class RefreshGateHarness {
    var gate = RefreshGate()

    func request() -> Bool { gate.request() }
    func finish() -> Bool { gate.finish() }
    func dropPending() { gate.dropPending() }
}

/// Any process can post the notification that makes the controller refresh, and Music can take seconds to
/// answer, so refreshes must not pile up: one runs at a time, and the requests made meanwhile become one more.
@Suite struct RefreshGateTests {
    /// Plays the controller's loop for one request on an idle gate: a refresh runs, and runs again for as long
    /// as `finish()` says a request came in during the last run. `requestsDuringEachRun[n]` is how many requests
    /// arrive while run `n` is in progress (none once the list is used up). Returns how many refreshes ran.
    func refreshesRun(requestsDuringEachRun: [Int]) -> Int {
        let harness = RefreshGateHarness()
        var counts = requestsDuringEachRun[...]
        var ran = 0
        #expect(harness.request())
        repeat {
            ran += 1
            for _ in 0..<(counts.popFirst() ?? 0) {
                #expect(!harness.request(), "a request during a refresh must not start another one")
            }
        } while harness.finish() && ran < 1_000   // a gate that never lets go must fail the test, not hang it
        return ran
    }

    @Test func aRequestOnAnIdleGateStartsARefresh() {
        let harness = RefreshGateHarness()
        #expect(harness.request())
    }

    @Test func noRequestsDuringARefreshMeansNoTrailingRefresh() {
        let harness = RefreshGateHarness()
        #expect(harness.request())
        #expect(!harness.finish())
        #expect(refreshesRun(requestsDuringEachRun: []) == 1)
        #expect(refreshesRun(requestsDuringEachRun: [0]) == 1)
    }

    @Test func aBurstDuringARefreshGivesExactlyOneTrailingRefresh() {
        let harness = RefreshGateHarness()
        #expect(harness.request())                          // the first refresh starts...
        for _ in 1...100 { #expect(!harness.request()) }    // ...and none of the burst starts another
        #expect(harness.finish())                           // one trailing refresh...
        #expect(!harness.finish())                          // ...and no more than one
        #expect(refreshesRun(requestsDuringEachRun: [100]) == 2)
    }

    @Test func aSingleRequestDuringARefreshAlsoGivesOneTrailingRefresh() {
        let harness = RefreshGateHarness()
        #expect(harness.request())
        #expect(!harness.request())
        #expect(harness.finish())
        #expect(!harness.finish())
    }

    @Test func requestsDuringATrailingRefreshGiveAnotherOne() {
        // Each run is followed by exactly one more for as long as requests keep coming in during it.
        #expect(refreshesRun(requestsDuringEachRun: [3]) == 2)
        #expect(refreshesRun(requestsDuringEachRun: [5, 5, 5]) == 4)
        #expect(refreshesRun(requestsDuringEachRun: [1, 0, 7]) == 2)   // the third run never happens
    }

    @Test func theGateIsIdleAgainOnceNothingIsWaiting() {
        let harness = RefreshGateHarness()
        #expect(harness.request())
        #expect(!harness.request())
        #expect(harness.finish())
        #expect(!harness.finish())
        // Idle: the next request starts a refresh at once, as the very first one did.
        #expect(harness.request())
        #expect(!harness.finish())
        #expect(harness.request())
    }

    @Test func refreshesNeverOverlapAndNeverOutnumberTheRequests() {
        let harness = RefreshGateHarness()
        var seed: UInt64 = 2024
        var isRunning = false
        var requests = 0
        var refreshes = 0
        for _ in 0..<5_000 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            if (seed >> 33) % 3 != 0 || !isRunning {
                // A request: it starts a refresh only when none is running.
                requests += 1
                if harness.request() {
                    #expect(!isRunning, "a refresh started while another one was running")
                    isRunning = true
                    refreshes += 1
                }
            } else if harness.finish() {
                refreshes += 1   // the trailing refresh starts as the running one ends
            } else {
                isRunning = false
            }
        }
        #expect(requests > 1_000)
        #expect(refreshes > 0)
        #expect(refreshes <= requests)
    }

    @Test func droppingThePendingRequestsLetsTheRunningRefreshEndWithoutAnotherOne() {
        let harness = RefreshGateHarness()
        #expect(harness.request())
        #expect(!harness.request())
        #expect(!harness.request())
        harness.dropPending()          // the controller was stopped
        #expect(!harness.finish())
        #expect(harness.request())     // and the gate is idle again
    }

    @Test func aRequestAfterDroppingIsRememberedAgain() {
        // Stopped and started again while a refresh was still running: that refresh is followed by one more.
        let harness = RefreshGateHarness()
        #expect(harness.request())
        #expect(!harness.request())
        harness.dropPending()
        #expect(!harness.request())
        #expect(harness.finish())
        #expect(!harness.finish())
    }

    @Test func droppingWhileIdleChangesNothing() {
        let harness = RefreshGateHarness()
        harness.dropPending()
        #expect(harness.request())
        #expect(!harness.finish())
    }
}
