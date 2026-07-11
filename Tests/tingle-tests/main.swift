import Foundation
import TingleCore

// Minimal dependency-free test harness: XCTest is unavailable under bare
// CommandLineTools, and tests that only run in CI can't drive a
// data-driven local loop. Run: swift run tingle-tests
var failures = 0
var passes = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String,
            file: StaticString = #filePath, line: UInt = #line) {
    if condition() {
        passes += 1
    } else {
        failures += 1
        print("FAIL  \(label)  (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
    if a == b {
        passes += 1
    } else {
        failures += 1
        print("FAIL  \(label): \(a) != \(b)  (\(file):\(line))")
    }
}

runTranscriptTyperTests()
runGoertzelDetectorTests()
runConfigTests()
runTriggerReconcilerTests()
runTriggerRoutingTests()
runBatteryEstimateTests()
runReplacementTests()
runWhiteFallbackTests()

print(failures == 0 ? "OK — \(passes) assertions passed"
                    : "FAILED — \(failures) failures, \(passes) passed")
exit(failures == 0 ? 0 : 1)
