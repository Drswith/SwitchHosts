import XCTest
@testable import SwitchHostsNative

/// The editor's pause callback, which the window saves from.
final class DebouncerTests: XCTestCase {
    func testRunsOnceAfterTheLastCall() {
        let debouncer = Debouncer(delay: 0.05)
        var runs: [Int] = []
        let done = expectation(description: "ran")
        for value in 1...5 {
            debouncer.schedule {
                runs.append(value)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 1)
        // Give any stray earlier action time to run, then check only the last ran.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(runs, [5])
    }

    func testSchedulingAgainRestartsTheWait() {
        let debouncer = Debouncer(delay: 0.15)
        var ran = false
        debouncer.schedule { ran = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        debouncer.schedule { ran = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(ran, "the second call restarts the wait")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertTrue(ran)
    }

    func testCancelDropsTheAction() {
        let debouncer = Debouncer(delay: 0.05)
        var ran = false
        debouncer.schedule { ran = true }
        debouncer.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(ran)
    }
}
