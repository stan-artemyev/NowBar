import Foundation
import Testing
@testable import NowBarServices

/// The order of a request for the Accessibility permission. Nothing here asks macOS for anything or runs a command.
@Suite struct AccessibilityRequestTests {
    @Test func aRequestWithThePermissionDoesNothing() {
        // Above all it must never clear an approval that works.
        #expect(AccessibilityRequest.steps(isTrusted: true, isFirstRequest: true).isEmpty)
        #expect(AccessibilityRequest.steps(isTrusted: true, isFirstRequest: false).isEmpty)
    }

    @Test func theFirstRequestClearsAnOldApprovalBeforeItPrompts() {
        // After an update the old build's approval is still listed, switched on, and doesn't count. Prompting
        // first would send the user to a switch that is already on.
        #expect(AccessibilityRequest.steps(isTrusted: false, isFirstRequest: true) == [.clearOldApproval, .prompt])
    }

    @Test func aLaterRequestOpensTheSettingsAndClearsNothing() {
        // macOS may not show its prompt twice, and the entry from the first request is the right one now.
        #expect(AccessibilityRequest.steps(isTrusted: false, isFirstRequest: false) == [.prompt, .openSettings])
    }

    @Test func clearingOnlyEverNamesTheGivenApp() {
        let command = AccessibilityRequest.clearCommand(bundleIdentifier: "local.nowbar.NowBar")
        #expect(command.executable.path == "/usr/bin/tccutil")
        // One service and one app: never a reset of everything.
        #expect(command.arguments == ["reset", "Accessibility", "local.nowbar.NowBar"])
    }
}
