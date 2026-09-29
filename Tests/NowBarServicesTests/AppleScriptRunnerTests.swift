import Foundation
import Testing
@testable import NowBarServices

/// These run plain AppleScript that talks to no other application, so they never touch Music.
@Suite struct AppleScriptRunnerTests {
    let source = """
    on nb_echo(amount, flag, caption)
        return {caption, amount * 2, flag, missing value}
    end nb_echo

    on nb_fail()
        error "not allowed" number -1743
    end nb_fail

    on nb_nothing()
    end nb_nothing
    """

    func makeRunner() -> AppleScriptRunner {
        AppleScriptRunner()
    }

    @Test func passesTypedArgumentsAndReturnsTypedValues() async {
        let result = await makeRunner().call("nb_echo", in: source, arguments: [.number(21.25), .bool(true), .text("Café")])
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.value == .list([.text("Café"), .number(42.5), .bool(true), .null]))
    }

    @Test func handlerNamesAreCaseInsensitive() async {
        let result = await makeRunner().call("NB_Echo", in: source, arguments: [.number(1), .bool(false), .text("x")])
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.value == .list([.text("x"), .number(2), .bool(false), .null]))
    }

    @Test func reportsScriptErrors() async {
        let result = await makeRunner().call("nb_fail", in: source)
        #expect(result.value == .null)
        #expect(result.error?.number == -1743, "\(String(describing: result.error))")
        #expect(result.error?.message == "not allowed")
    }

    @Test func reportsAMissingHandler() async {
        let result = await makeRunner().call("nb_missing", in: source)
        #expect(result.error != nil)
    }

    @Test func reportsCompileErrors() async {
        let result = await makeRunner().call("nb_broken", in: "on nb_broken(\n  tell tell\nend nb_broken")
        #expect(result.error != nil)
        #expect(result.value == .null)
    }

    @Test func aHandlerWithNoReturnValueGivesNull() async {
        let result = await makeRunner().call("nb_nothing", in: source)
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.value == .null)
    }

    @Test func reusesACompiledScriptAndKeepsWorkingAfterAnError() async {
        let runner = makeRunner()
        for round in 1...3 {
            let failed = await runner.call("nb_fail", in: source)
            #expect(failed.error?.number == -1743)
            let worked = await runner.call("nb_echo", in: source, arguments: [.number(Double(round)), .bool(true), .text("r")])
            #expect(worked.value == .list([.text("r"), .number(Double(round) * 2), .bool(true), .null]))
        }
    }

    @Test func runsOffTheMainThread() async {
        let runner = makeRunner()
        #expect(await runner.perform { Thread.isMainThread } == false)
    }

    @Test func neverRunsTwoJobsAtOnce() async {
        let runner = makeRunner()
        let gauge = Gauge()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await runner.perform {
                        gauge.enter()
                        Thread.sleep(forTimeInterval: 0.002)
                        gauge.leave()
                    }
                }
            }
        }
        #expect(gauge.total == 20)
        #expect(gauge.maxConcurrent == 1)
    }

    @Test func finishedAtIsWhenTheScriptEnded() async {
        let before = Date()
        let result = await makeRunner().call("nb_nothing", in: source)
        #expect(result.finishedAt >= before)
        #expect(result.finishedAt <= Date())
    }
}

/// Counts how many jobs run at the same time.
private final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var maxConcurrent = 0
    private(set) var total = 0

    func enter() {
        lock.lock()
        defer { lock.unlock() }
        running += 1
        total += 1
        maxConcurrent = max(maxConcurrent, running)
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        running -= 1
    }
}
