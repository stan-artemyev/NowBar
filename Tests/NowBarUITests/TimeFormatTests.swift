import Testing
@testable import NowBarUI

@Suite("Time formatting")
struct TimeFormatTests {
    @Test func formatsMinutesAndSeconds() {
        #expect(TimeFormat.clock(0) == "0:00")
        #expect(TimeFormat.clock(5) == "0:05")
        #expect(TimeFormat.clock(59) == "0:59")
        #expect(TimeFormat.clock(60) == "1:00")
        #expect(TimeFormat.clock(84) == "1:24")
        #expect(TimeFormat.clock(217) == "3:37")
        #expect(TimeFormat.clock(3599) == "59:59")
    }

    @Test func dropsFractionsInsteadOfRounding() {
        #expect(TimeFormat.clock(59.99) == "0:59")
        #expect(TimeFormat.clock(84.5) == "1:24")
    }

    @Test func addsHoursFromOneHour() {
        #expect(TimeFormat.clock(3600) == "1:00:00")
        #expect(TimeFormat.clock(3725) == "1:02:05")
        #expect(TimeFormat.clock(36_000) == "10:00:00")
    }

    @Test func readsBadValuesAsZero() {
        #expect(TimeFormat.clock(-3) == "0:00")
        #expect(TimeFormat.clock(.nan) == "0:00")
        #expect(TimeFormat.clock(.infinity) == "0:00")
    }

    @Test func formatsRemainingTimeWithAMinusSign() {
        #expect(TimeFormat.remaining(position: 84, duration: 217) == "-2:13")
        #expect(TimeFormat.remaining(position: 0, duration: 217) == "-3:37")
        #expect(TimeFormat.remaining(position: 217, duration: 217) == "-0:00")
    }

    @Test func remainingIsMeasuredFromTheWholeSecondShownAsElapsed() {
        // 84.9 s reads "1:24", so the remaining time must be 217 - 84 = 2:13, not 2:12.
        #expect(TimeFormat.clock(84.9) == "1:24")
        #expect(TimeFormat.remaining(position: 84.9, duration: 217) == "-2:13")
    }

    @Test func remainingNeverGoesBelowZero() {
        #expect(TimeFormat.remaining(position: 300, duration: 217) == "-0:00")
    }
}
