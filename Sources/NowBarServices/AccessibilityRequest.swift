import Foundation
import os

private let accessLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NowBar", category: "Accessibility")

/// What NowBar does when it asks for the Accessibility permission, and in which order.
///
/// macOS remembers the permission for one particular build of an app. After an update the old approval stays
/// listed in System Settings, still switched on, but doesn't count for the new build, and there is nothing left
/// for the user to switch on. So the first request of a launch removes NowBar's own entry before it asks macOS
/// to list NowBar afresh, which shows the system's prompt. macOS may not show that prompt a second time, so a
/// later request opens the Accessibility settings as well.
///
/// The decision is pure, so it is unit tested; `MediaKeyTap` carries the steps out.
enum AccessibilityRequest {
    enum Step: Equatable {
        /// Remove NowBar's own entry from the Accessibility list, in case it belongs to an older build.
        case clearOldApproval
        /// Ask macOS to list NowBar and show its prompt.
        case prompt
        /// Open the Accessibility pane of System Settings.
        case openSettings
    }

    /// Nothing when NowBar already has the permission: a request must never touch an approval that works.
    static func steps(isTrusted: Bool, isFirstRequest: Bool) -> [Step] {
        if isTrusted { return [] }
        return isFirstRequest ? [.clearOldApproval, .prompt] : [.prompt, .openSettings]
    }

    /// The command that removes the Accessibility entry of the app `bundleIdentifier`, and nothing else.
    static func clearCommand(bundleIdentifier: String) -> (executable: URL, arguments: [String]) {
        (URL(fileURLWithPath: "/usr/bin/tccutil"), ["reset", "Accessibility", bundleIdentifier])
    }

    /// Removes NowBar's own Accessibility entry, then calls `completion` on the main actor, whether or not it
    /// worked: the request goes on either way. Without a bundle identifier (a bare executable) there is no
    /// entry to remove.
    @MainActor
    static func clearOldApproval(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        completion: @escaping @MainActor () -> Void
    ) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return completion() }
        let command = clearCommand(bundleIdentifier: bundleIdentifier)
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 {
                accessLog.error("Clearing the old Accessibility approval failed (\(finished.terminationStatus))")
            }
            Task { @MainActor in completion() }
        }
        do {
            try process.run()
        } catch {
            // The system's error text isn't ours, so it stays private (the default).
            accessLog.error("Could not clear the old Accessibility approval: \(error.localizedDescription)")
            return completion()
        }
        // The command answers at once. Should it ever hang, the request must still go on.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) {
            if process.isRunning { process.terminate() }
        }
    }
}
