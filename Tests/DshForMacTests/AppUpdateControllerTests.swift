import AppKit
import XCTest
@testable import DshForMac

@objc private final class MockUpdaterAvailability: NSObject {
    @objc dynamic var canCheckForUpdates = true
}

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testSettingsButtonRecoversAfterTransientPostFailureAvailabilityDip() {
        let updateController = AppUpdateController()
        let mockUpdater = MockUpdaterAvailability()
        var currentStatus = ""

        let settingsViewController = SettingsViewController(
            onApply: { _, _, _ in },
            onTestTaskReminder: {},
            onCheckUpdates: {},
            onCheckAppUpdates: {},
            onDownloadUpdate: {},
            onOpenVersionsDirectory: {}
        )
        _ = settingsViewController.view

        updateController.onStatusChanged = { status in
            currentStatus = status
            settingsViewController.updateAppUpdate(
                status: status,
                canCheck: updateController.canCheckForUpdates
            )
        }
        updateController.onAvailabilityChanged = {
            settingsViewController.updateAppUpdate(
                status: currentStatus,
                canCheck: updateController.canCheckForUpdates
            )
        }

        updateController.observeAvailability(on: mockUpdater, keyPath: \.canCheckForUpdates)

        let checkButton = allSubviews(in: settingsViewController.view)
            .compactMap { $0 as? NSButton }
            .first { $0.title == "检查应用更新" }
        XCTAssertNotNil(checkButton)
        XCTAssertTrue(checkButton?.isEnabled == true)

        mockUpdater.canCheckForUpdates = false
        drainMainLoop()
        XCTAssertTrue(checkButton?.isEnabled == false)

        // Simulate Sparkle's post-failure cycle where canCheckForUpdates flips
        // true -> false -> true asynchronously via scheduleNextUpdateCheckFiringImmediately.
        mockUpdater.canCheckForUpdates = true
        mockUpdater.canCheckForUpdates = false
        drainMainLoop()
        XCTAssertTrue(checkButton?.isEnabled == false)

        mockUpdater.canCheckForUpdates = true
        drainMainLoop()
        XCTAssertTrue(checkButton?.isEnabled == true)
    }

    private func drainMainLoop() {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.async {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1.0)
    }

    private func allSubviews(in root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { allSubviews(in: $0) }
    }
}
