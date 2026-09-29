/// Lets one refresh run at a time. A request that arrives while a refresh runs is remembered, however many
/// come in, and exactly one more refresh follows the running one. Pure, so it is unit tested.
///
/// Usage: start a refresh when `request()` returns true, and call `finish()` when it has ended (and pushed).
/// While `finish()` returns true, run another refresh and call `finish()` again.
struct RefreshGate {
    private var isRunning = false
    private var hasPendingRequest = false

    /// A refresh was asked for. Returns true when the caller starts one now. Returns false while one is
    /// already running: the request is remembered for `finish()`.
    mutating func request() -> Bool {
        guard !isRunning else {
            hasPendingRequest = true
            return false
        }
        isRunning = true
        return true
    }

    /// The running refresh has ended. Returns true when a request came in while it ran: the caller runs one
    /// more refresh now (the gate stays busy until that one calls `finish()` too). Returns false when nothing
    /// is waiting, and the gate is idle again.
    mutating func finish() -> Bool {
        guard hasPendingRequest else {
            isRunning = false
            return false
        }
        hasPendingRequest = false
        return true
    }

    /// Forgets the requests that arrived while a refresh runs, so none follows it. The running refresh still
    /// ends through `finish()`.
    mutating func dropPending() {
        hasPendingRequest = false
    }
}
