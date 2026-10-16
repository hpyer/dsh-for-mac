import AppKit
import XCTest
@testable import DshForMac

final class TaskReminderTests: XCTestCase {
    @MainActor
    func testCompletionSoundFollowsBackgroundCompletionGateAndCanBePreviewed() {
        _ = NSApplication.shared
        var playCount = 0
        let controller = TaskReminderController(playCompletionSound: { playCount += 1 })
        defer { controller.dismissToast() }

        controller.receive(kind: "completed", sessionId: "session-1", key: "foreground", isAppVisible: true)
        controller.receive(kind: "attention", sessionId: "session-1", key: "attention", isAppVisible: false)
        controller.receive(kind: "ended", sessionId: "session-1", key: "ended", isAppVisible: false)
        controller.receive(kind: "unknown", sessionId: "session-1", key: "unknown", isAppVisible: false)
        controller.receive(kind: "completed", sessionId: "", key: "invalid", isAppVisible: false)
        XCTAssertEqual(playCount, 0)

        controller.receive(kind: "completed", sessionId: "session-1", key: "completed-1", isAppVisible: false)
        controller.receive(kind: "completed", sessionId: "session-1", key: "completed-1", isAppVisible: false)
        XCTAssertEqual(playCount, 1)

        controller.receive(kind: "completed", sessionId: "session-2", key: "completed-2", isAppVisible: false)
        XCTAssertEqual(playCount, 2)
        controller.sendTestReminder()
        XCTAssertEqual(playCount, 3)
    }

    func testDuplicateAndInvalidBridgeEventsAreIgnored() {
        var gate = TaskReminderGate()
        let first = gate.accept(kind: "attention", sessionId: "session-1", key: "event-1")
        let duplicate = gate.accept(kind: "attention", sessionId: "session-1", key: "event-1")
        let unknown = gate.accept(kind: "unknown", sessionId: "session-1", key: "event-2")
        let missingSession = gate.accept(kind: "completed", sessionId: "", key: "event-3")
        let missingKey = gate.accept(kind: "ended", sessionId: "session-1", key: "")
        XCTAssertTrue(first)
        XCTAssertTrue(!duplicate)
        XCTAssertTrue(!unknown)
        XCTAssertTrue(!missingSession)
        XCTAssertTrue(!missingKey)
    }

    func testDeduplicationMemoryIsBoundedWithoutStoringReminderHistory() {
        var gate = TaskReminderGate()
        for index in 0..<513 {
            let accepted = gate.accept(kind: "completed", sessionId: "session-\(index)", key: "event-\(index)")
            XCTAssertTrue(accepted)
        }
        let duplicate = gate.accept(kind: "completed", sessionId: "session-512", key: "event-512")
        XCTAssertTrue(!duplicate)
        XCTAssertTrue(TaskReminder(kind: "test", sessionId: "").title == "DshForMac 测试提醒")
    }
}
