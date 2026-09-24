import Testing
@testable import DshForMac

struct TaskReminderTests {
    @Test func duplicateAndInvalidBridgeEventsAreIgnored() {
        var gate = TaskReminderGate()
        let first = gate.accept(kind: "attention", sessionId: "session-1", key: "event-1")
        let duplicate = gate.accept(kind: "attention", sessionId: "session-1", key: "event-1")
        let unknown = gate.accept(kind: "unknown", sessionId: "session-1", key: "event-2")
        let missingSession = gate.accept(kind: "completed", sessionId: "", key: "event-3")
        let missingKey = gate.accept(kind: "ended", sessionId: "session-1", key: "")
        #expect(first)
        #expect(!duplicate)
        #expect(!unknown)
        #expect(!missingSession)
        #expect(!missingKey)
    }

    @Test func deduplicationMemoryIsBoundedWithoutStoringReminderHistory() {
        var gate = TaskReminderGate()
        for index in 0..<513 {
            let accepted = gate.accept(kind: "completed", sessionId: "session-\(index)", key: "event-\(index)")
            #expect(accepted)
        }
        let duplicate = gate.accept(kind: "completed", sessionId: "session-512", key: "event-512")
        #expect(!duplicate)
        #expect(TaskReminder(kind: "test", sessionId: "").title == "DshForMac 测试提醒")
    }
}
