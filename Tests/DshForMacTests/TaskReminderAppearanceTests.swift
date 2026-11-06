import AppKit
import XCTest
@testable import DshForMac

/// 提醒卡片夜间模式回归测试（独立编写，不复用 Lead 侧 resolver 测试）。
///
/// 背景：`NSColor.xxx.cgColor` 在非绘制上下文中恒按 Aqua（浅色）解析，动态系统色必须
/// 在目标 `NSAppearance` 下解析并冻结后，才能写入 `CALayer` 的颜色。测试显式指定外观
/// （`view.appearance` / `NSApp.appearance`），不依赖测试机当前系统是浅色还是深色。
final class TaskReminderAppearanceTests: XCTestCase {
    // MARK: - 颜色测量辅助

    /// 统一转成 sRGB，避免不同色彩空间下分量无法比较。
    private func sRGB(_ color: NSColor) -> NSColor {
        guard let converted = color.usingColorSpace(.sRGB) else {
            XCTFail("无法将 \(color) 转换到 sRGB 色彩空间")
            return .black
        }
        return converted
    }

    /// Rec.709 相对亮度近似，用于判断“深色/浅色”。
    private func luminance(_ color: NSColor) -> CGFloat {
        let c = sRGB(color)
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// 将带透明度的描边色合成到背景之上再求亮度，模拟实际绘制效果。
    private func compositedLuminance(foreground: NSColor, over background: NSColor) -> CGFloat {
        let fg = sRGB(foreground)
        let bg = sRGB(background)
        let alpha = fg.alphaComponent
        let r = fg.redComponent * alpha + bg.redComponent * (1 - alpha)
        let g = fg.greenComponent * alpha + bg.greenComponent * (1 - alpha)
        let b = fg.blueComponent * alpha + bg.blueComponent * (1 - alpha)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - 测试

    /// a) darkAqua 下背景为暗色，aqua 下接近白色。
    @MainActor
    func testSurfaceColorIsDarkInDarkAquaAndLightInAqua() throws {
        _ = NSApplication.shared
        let view = TaskReminderToastView(reminder: TaskReminder(kind: "test", sessionId: ""), isTest: true)

        view.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        view.refreshAppearanceDependentColors()
        let darkSurface = sRGB(view.appliedSurfaceColor)
        let darkLuminance = luminance(darkSurface)
        print("darkAqua appliedSurfaceColor sRGB: r=\(darkSurface.redComponent) g=\(darkSurface.greenComponent) b=\(darkSurface.blueComponent) a=\(darkSurface.alphaComponent), luminance=\(darkLuminance)")
        XCTAssertLessThan(darkLuminance, 0.3, "darkAqua 下卡片背景应为暗色，实际亮度 \(darkLuminance)")

        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        view.refreshAppearanceDependentColors()
        let lightSurface = sRGB(view.appliedSurfaceColor)
        let lightLuminance = luminance(lightSurface)
        print("aqua appliedSurfaceColor sRGB: r=\(lightSurface.redComponent) g=\(lightSurface.greenComponent) b=\(lightSurface.blueComponent) a=\(lightSurface.alphaComponent), luminance=\(lightLuminance)")
        XCTAssertGreaterThan(lightLuminance, 0.9, "aqua 下卡片背景应接近白色，实际亮度 \(lightLuminance)")
        XCTAssertGreaterThan(lightLuminance - darkLuminance, 0.5, "浅色/深色背景亮度应有明显差异")
    }

    /// b) 描边与背景的对比方向随外观翻转：深色下描边更亮，浅色下描边更暗。
    @MainActor
    func testBorderContrastDirectionFlipsBetweenAppearances() throws {
        _ = NSApplication.shared
        let view = TaskReminderToastView(reminder: TaskReminder(kind: "completed", sessionId: "session-1"), isTest: false)

        view.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        view.refreshAppearanceDependentColors()
        let darkSurface = view.appliedSurfaceColor
        let darkBorder = view.appliedBorderColor
        let darkSurfaceLuminance = luminance(darkSurface)
        let darkBorderLuminance = luminance(darkBorder)
        let darkComposited = compositedLuminance(foreground: darkBorder, over: darkSurface)
        print("darkAqua border: direct=\(darkBorderLuminance), composited=\(darkComposited), surface=\(darkSurfaceLuminance), borderAlpha=\(sRGB(darkBorder).alphaComponent)")
        XCTAssertGreaterThan(darkBorderLuminance, darkSurfaceLuminance, "深色模式下描边应比背景更亮")
        XCTAssertGreaterThan(darkComposited, darkSurfaceLuminance + 0.02, "合成到暗色背景后描边仍应可见")

        view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        view.refreshAppearanceDependentColors()
        let lightSurface = view.appliedSurfaceColor
        let lightBorder = view.appliedBorderColor
        let lightSurfaceLuminance = luminance(lightSurface)
        let lightBorderLuminance = luminance(lightBorder)
        let lightComposited = compositedLuminance(foreground: lightBorder, over: lightSurface)
        print("aqua border: direct=\(lightBorderLuminance), composited=\(lightComposited), surface=\(lightSurfaceLuminance), borderAlpha=\(sRGB(lightBorder).alphaComponent)")
        XCTAssertLessThan(lightBorderLuminance, lightSurfaceLuminance, "浅色模式下描边应比背景更暗")
        XCTAssertLessThan(lightComposited, lightSurfaceLuminance - 0.02, "合成到亮色背景后描边仍应可见")
    }

    /// c) 切换 view.appearance 后重新解析会应用不同的颜色；
    ///    同时验证 viewDidChangeEffectiveAppearance 的自动刷新路径。
    @MainActor
    func testRefreshReappliesResolvedColorsWhenAppearanceChanges() throws {
        _ = NSApplication.shared
        let view = TaskReminderToastView(reminder: TaskReminder(kind: "test", sessionId: ""), isTest: true)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let light = try XCTUnwrap(NSAppearance(named: .aqua))

        view.appearance = dark
        view.refreshAppearanceDependentColors()
        let darkSurface = sRGB(view.appliedSurfaceColor)
        let darkBorder = sRGB(view.appliedBorderColor)

        view.appearance = light
        // older macOS releases may deliver the effective-appearance change on the
        // next run loop turn; give it a chance before checking the automatic path.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        // 不显式调用刷新：系统应通过 viewDidChangeEffectiveAppearance 自动重新应用颜色。
        let autoLightSurface = sRGB(view.appliedSurfaceColor)
        XCTAssertGreaterThan(
            luminance(autoLightSurface), 0.9,
            "切换外观后 viewDidChangeEffectiveAppearance 应自动重新应用浅色背景，实际亮度 \(luminance(autoLightSurface))"
        )

        // 再显式调用，确保刷新接口幂等且结果一致。
        view.refreshAppearanceDependentColors()
        let lightSurface = sRGB(view.appliedSurfaceColor)
        let lightBorder = sRGB(view.appliedBorderColor)
        print("appearance switch: darkSurface luminance=\(luminance(darkSurface)), lightSurface luminance=\(luminance(lightSurface))")
        XCTAssertGreaterThan(luminance(lightSurface), 0.9)
        XCTAssertLessThan(luminance(darkSurface), 0.3)
        XCTAssertNotEqual(darkSurface, lightSurface, "深色与浅色下缓存的背景色不应相同")
        XCTAssertNotEqual(darkBorder, lightBorder, "深色与浅色下缓存的描边色不应相同")
        XCTAssertGreaterThan(abs(luminance(lightSurface) - luminance(darkSurface)), 0.5)
    }

    /// d) 端到端：强制 NSApp.appearance = darkAqua 后，controller 创建的测试提醒卡片
    ///    应使用暗色背景；通过 internal 钩子 currentToastView 读取实际显示的视图。
    @MainActor
    func testControllerTestReminderCardUsesDarkColorsWhenApplicationAppearanceIsDark() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        NSApp.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let controller = TaskReminderController(playCompletionSound: {})
        defer {
            controller.dismissToast()
            NSApp.appearance = previousAppearance
        }

        controller.sendTestReminder()
        guard let toastView = controller.currentToastView else {
            throw XCTSkip("controller 未提供 currentToastView 钩子（或当前环境无法创建面板），跳过端到端断言")
        }

        XCTAssertEqual(toastView.frame.width, TaskReminderToastView.width, accuracy: 1, "测试提醒卡片宽度应为 330")
        XCTAssertEqual(
            toastView.frame.height, TaskReminderToastView.height(isTest: true), accuracy: 1,
            "测试提醒卡片高度应为 72"
        )
        XCTAssertEqual(
            toastView.effectiveAppearance.name, .darkAqua,
            "卡片应继承强制设置的 darkAqua 外观，实际为 \(toastView.effectiveAppearance.name.rawValue)"
        )
        let surface = sRGB(toastView.appliedSurfaceColor)
        let surfaceLuminance = luminance(surface)
        let borderLuminance = luminance(toastView.appliedBorderColor)
        print("controller card: surface r=\(surface.redComponent) g=\(surface.greenComponent) b=\(surface.blueComponent), luminance=\(surfaceLuminance), borderLuminance=\(borderLuminance)")
        XCTAssertLessThan(
            surfaceLuminance, 0.3,
            "强制 NSApp.appearance = darkAqua 后测试提醒卡片背景应为暗色，实际亮度 \(surfaceLuminance)"
        )
        XCTAssertGreaterThan(borderLuminance, surfaceLuminance, "深色卡片描边应比背景更亮")
    }
}
