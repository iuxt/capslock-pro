// CapsLock Pro: 把当前前台窗口移动到其他屏幕 (Swift 版本)
//
// 用法: move-window-display [next|prev|1..9|fullscreen]
//   next  移动到下一个屏幕 (默认)
//   prev  移动到上一个屏幕
//   1..9  移动到指定序号的屏幕
//   fullscreen  切换当前窗口的原生全屏状态
//
// 编译: mkdir -p ~/.local/bin && swiftc -O move-window-display.swift -o ~/.local/bin/move-window-display
// 权限: 系统设置 -> 隐私与安全性 -> 辅助功能, 允许 karabiner_grabber (或本程序)

import AppKit
import ApplicationServices
import Foundation

// MARK: - Logging

let debug = ProcessInfo.processInfo.environment["MWD_DEBUG"] != nil
let startedAt = Date()

func writeStderr(_ message: String) {
    guard let data = "\(message)\n".data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

func dbg(_ message: String) {
    guard debug else { return }
    let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
    writeStderr("[\(elapsed)ms] \(message)")
}

// MARK: - AX helpers

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    if error != .success { dbg("read \(name) failed: \(error.rawValue)") }
    return error == .success ? value : nil
}

func elementValue(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func pointValue(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

func sizeValue(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

func boolValue(_ value: CFTypeRef?) -> Bool? {
    guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue((value as! CFBoolean))
}

func stringValue(_ value: CFTypeRef?) -> String? {
    guard let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
    return (value as! String)
}

func isAttributeSettable(_ element: AXUIElement, _ name: String) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
        && settable.boolValue
}

@discardableResult
func setPoint(_ element: AXUIElement, _ name: String, _ point: CGPoint) -> AXError {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
    let error = AXUIElementSetAttributeValue(element, name as CFString, value)
    if error != .success { dbg("write \(name) failed: \(error.rawValue)") }
    return error
}

@discardableResult
func setSize(_ element: AXUIElement, _ name: String, _ size: CGSize) -> AXError {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
    let error = AXUIElementSetAttributeValue(element, name as CFString, value)
    if error != .success { dbg("write \(name) failed: \(error.rawValue)") }
    return error
}

@discardableResult
func setBoolean(_ element: AXUIElement, _ name: String, _ value: Bool) -> AXError {
    let boolean = value ? kCFBooleanTrue : kCFBooleanFalse
    let error = AXUIElementSetAttributeValue(element, name as CFString, boolean!)
    if error != .success { dbg("write \(name) failed: \(error.rawValue)") }
    return error
}

func nearlyEqual(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat = 2) -> Bool {
    abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
}

func nearlyEqual(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 2) -> Bool {
    abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
}

/// AX 写入不是总同步完成的。命中期望值并稳定片刻后返回；应用限制尺寸时等实际值稳定。
func waitForSize(_ element: AXUIElement, expected: CGSize, timeoutMs: Int = 300) -> CGSize? {
    let start = Date()
    var last: CGSize?
    var stableReads = 0

    while true {
        if let current = sizeValue(copyAttribute(element, kAXSizeAttribute as String)) {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1_000)
            if elapsedMs >= 30, nearlyEqual(current, expected) { return current }
            if let last, nearlyEqual(current, last, tolerance: 0.5) {
                stableReads += 1
            } else {
                stableReads = 0
            }
            last = current

            if elapsedMs >= 60, stableReads >= 3 { return current }
        }
        if Int(Date().timeIntervalSince(start) * 1_000) >= timeoutMs { return last }
        usleep(15_000)
    }
}

func waitForPosition(_ element: AXUIElement, expected: CGPoint, timeoutMs: Int = 250) -> CGPoint? {
    let start = Date()
    var last: CGPoint?
    var stableReads = 0

    while true {
        if let current = pointValue(copyAttribute(element, kAXPositionAttribute as String)) {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1_000)
            if elapsedMs >= 30, nearlyEqual(current, expected) { return current }
            if let last, nearlyEqual(current, last, tolerance: 0.5) {
                stableReads += 1
            } else {
                stableReads = 0
            }
            last = current

            if elapsedMs >= 60, stableReads >= 3 { return current }
        }
        if Int(Date().timeIntervalSince(start) * 1_000) >= timeoutMs { return last }
        usleep(15_000)
    }
}

func waitForBoolean(
    _ element: AXUIElement,
    _ name: String,
    expected: Bool,
    timeoutMs: Int
) -> Bool {
    let start = Date()
    while true {
        if boolValue(copyAttribute(element, name)) == expected { return true }
        if Int(Date().timeIntervalSince(start) * 1_000) >= timeoutMs { return false }
        usleep(25_000)
    }
}

func preferredWindow(in application: AXUIElement) -> AXUIElement? {
    if let window = elementValue(copyAttribute(application, kAXFocusedWindowAttribute as String)) {
        return window
    }

    // 少数应用没有 AXFocusedWindow，优先找主窗口，然后回退到第一个有效窗口。
    guard let values = copyAttribute(application, kAXWindowsAttribute as String) as? [AnyObject] else {
        return nil
    }
    var firstWindow: AXUIElement?
    for value in values {
        guard let window = elementValue(value) else { continue }
        if firstWindow == nil { firstWindow = window }
        if boolValue(copyAttribute(window, kAXMainAttribute as String)) == true { return window }
    }
    return firstWindow
}

func focusedWindow() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    if let application = elementValue(
        copyAttribute(systemWide, kAXFocusedApplicationAttribute as String)
    ), let window = preferredWindow(in: application) {
        return window
    }

    // 从 Karabiner 的后台进程启动时，AXFocusedApplication 偶尔返回
    // kAXErrorCannotComplete；使用 AppKit 查询前台应用作为回退。
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    dbg("falling back to frontmost application pid=\(application.processIdentifier)")
    return preferredWindow(in: AXUIElementCreateApplication(application.processIdentifier))
}

func focusedWindow(applicationPID: pid_t) -> AXUIElement? {
    preferredWindow(in: AXUIElementCreateApplication(applicationPID))
}

func failMove(
    _ message: String,
    window: AXUIElement,
    applicationPID: pid_t,
    restoreZoom: Bool,
    restoreFullScreen: Bool
) -> Never {
    writeStderr(message)

    // 移动中途失败也尽量恢复调用前的窗口状态。
    let candidate = focusedWindow(applicationPID: applicationPID) ?? window
    if restoreZoom,
       boolValue(copyAttribute(candidate, "AXZoomed")) != true,
       setBoolean(candidate, "AXZoomed", true) == .success {
        _ = waitForBoolean(candidate, "AXZoomed", expected: true, timeoutMs: 500)
    }
    if restoreFullScreen {
        if boolValue(copyAttribute(candidate, "AXFullScreen")) != true,
           setBoolean(candidate, "AXFullScreen", true) == .success {
            _ = waitForBoolean(candidate, "AXFullScreen", expected: true, timeoutMs: 2_500)
        }
    }

    NSSound.beep()
    exit(1)
}

// MARK: - Geometry

struct ScreenGeometry {
    let frame: CGRect
    let visibleFrame: CGRect
}

func axRect(_ cocoaRect: CGRect, primaryTop: CGFloat) -> CGRect {
    CGRect(
        x: cocoaRect.minX,
        y: primaryTop - cocoaRect.maxY,
        width: cocoaRect.width,
        height: cocoaRect.height
    )
}

func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
}

/// 用窗口在可移动范围内的比例表示位置；贴边窗口跨屏后仍贴边。
func relativeOrigin(_ origin: CGFloat, length: CGFloat, in bounds: ClosedRange<CGFloat>) -> CGFloat {
    let available = bounds.upperBound - bounds.lowerBound - length
    guard available > 1 else { return 0.5 }
    return clamp((origin - bounds.lowerBound) / available, 0, 1)
}

func mappedOrigin(in rect: CGRect, size: CGSize, xRatio: CGFloat, yRatio: CGFloat) -> CGPoint {
    let availableWidth = max(0, rect.width - size.width)
    let availableHeight = max(0, rect.height - size.height)
    return CGPoint(
        x: (rect.minX + xRatio * availableWidth).rounded(),
        y: (rect.minY + yRatio * availableHeight).rounded()
    )
}

func fittedSize(_ size: CGSize, in destination: CGRect) -> CGSize {
    guard size.width > 0, size.height > 0,
          destination.width > 0, destination.height > 0 else {
        return size
    }

    // 跨屏时保持原尺寸；只有目标屏幕放不下时才等比缩小。
    let scale = min(
        1,
        destination.width / size.width,
        destination.height / size.height
    )

    return CGSize(
        width: max(1, (size.width * scale).rounded()),
        height: max(1, (size.height * scale).rounded())
    )
}

func screenIndex(containing point: CGPoint, screens: [ScreenGeometry]) -> Int? {
    if let index = screens.firstIndex(where: { $0.frame.contains(point) }) { return index }

    // 屏幕之间有间隙或窗口中心落在桌面外时，取到矩形边缘距离最近的屏幕。
    return screens.indices.min { lhs, rhs in
        func squaredDistance(to rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
            let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
            return dx * dx + dy * dy
        }
        return squaredDistance(to: screens[lhs].frame) < squaredDistance(to: screens[rhs].frame)
    }
}

// MARK: - Arguments

enum Destination {
    case next
    case previous
    case index(Int)
}

enum Command {
    case move(Destination)
    case toggleFullScreen
}

let usage = "Usage: move-window-display [next|prev|1..9|fullscreen]"
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "-h" || arguments.first == "--help" {
    print(usage)
    exit(0)
}

guard arguments.count <= 1 else {
    writeStderr(usage)
    exit(2)
}

let command: Command
switch arguments.first ?? "next" {
case "next":
    command = .move(.next)
case "prev":
    command = .move(.previous)
case "fullscreen":
    command = .toggleFullScreen
case let value:
    guard let index = Int(value), (1...9).contains(index) else {
        writeStderr(usage)
        exit(2)
    }
    command = .move(.index(index - 1))
}

// MARK: - Main

let trustOptions = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
] as CFDictionary
guard AXIsProcessTrustedWithOptions(trustOptions) else {
    writeStderr("move-window-display: 缺少辅助功能权限")
    exit(1)
}

guard var window = focusedWindow() else {
    writeStderr("move-window-display: 无法获取当前窗口")
    NSSound.beep()
    exit(1)
}
var focusedPID: pid_t = 0
AXUIElementGetPid(window, &focusedPID)
let windowTitle = stringValue(copyAttribute(window, kAXTitleAttribute as String)) ?? ""
let windowRole = stringValue(copyAttribute(window, kAXRoleAttribute as String)) ?? ""
dbg("got focused window pid=\(focusedPID) role=\(windowRole) title=\(windowTitle)")

if case .toggleFullScreen = command {
    guard let isFullScreen = boolValue(copyAttribute(window, "AXFullScreen")),
          isAttributeSettable(window, "AXFullScreen") else {
        writeStderr("move-window-display: 当前窗口不支持原生全屏")
        NSSound.beep()
        exit(1)
    }

    let targetState = !isFullScreen
    dbg("setting full screen to \(targetState)")
    guard setBoolean(window, "AXFullScreen", targetState) == .success,
          waitForBoolean(window, "AXFullScreen", expected: targetState, timeoutMs: 2_500) else {
        writeStderr("move-window-display: 无法切换全屏状态")
        NSSound.beep()
        exit(1)
    }
    exit(0)
}

guard case let .move(destination) = command else { exit(0) }

let appKitScreens = NSScreen.screens
guard let primaryScreen = appKitScreens.first, appKitScreens.count >= 2 else {
    dbg("less than two screens")
    exit(0)
}

// AppKit 是左下原点，AX 是主屏幕左上原点。副屏在主屏上方时 AX y 可以为负数。
let primaryTop = primaryScreen.frame.maxY
let screens = appKitScreens.map {
    ScreenGeometry(
        frame: axRect($0.frame, primaryTop: primaryTop),
        visibleFrame: axRect($0.visibleFrame, primaryTop: primaryTop)
    )
}
dbg("screens=\(screens.map(\.visibleFrame))")

// 先在原始状态下确定当前和目标显示器。目标无效或未变化时，不触碰全屏状态。
guard let initialPosition = pointValue(copyAttribute(window, kAXPositionAttribute as String)),
      let initialSize = sizeValue(copyAttribute(window, kAXSizeAttribute as String)),
      initialSize.width > 0, initialSize.height > 0 else {
    writeStderr("move-window-display: 无法读取当前窗口的位置或尺寸")
    exit(1)
}
let initialCenter = CGPoint(
    x: initialPosition.x + initialSize.width / 2,
    y: initialPosition.y + initialSize.height / 2
)
guard let currentIndex = screenIndex(containing: initialCenter, screens: screens) else { exit(0) }

let targetIndex: Int
switch destination {
case .next:
    targetIndex = (currentIndex + 1) % screens.count
case .previous:
    targetIndex = (currentIndex - 1 + screens.count) % screens.count
case .index(let index):
    guard screens.indices.contains(index) else {
        writeStderr("move-window-display: 显示器 \(index + 1) 不存在（当前共 \(screens.count) 个）")
        exit(2)
    }
    targetIndex = index
}
guard targetIndex != currentIndex else { exit(0) }

// 原生全屏会拦截位置/尺寸写入：先退出，移动完成后在目标显示器恢复全屏。
let wasFullScreen = boolValue(copyAttribute(window, "AXFullScreen")) == true
let wasZoomed = !wasFullScreen && boolValue(copyAttribute(window, "AXZoomed")) == true
if wasFullScreen {
    dbg("leaving full screen")
    guard setBoolean(window, "AXFullScreen", false) == .success,
          waitForBoolean(window, "AXFullScreen", expected: false, timeoutMs: 2_500) else {
        writeStderr("move-window-display: 无法退出全屏状态")
        NSSound.beep()
        exit(1)
    }
    // 属性会先变为 false，Space 切换动画随后才结束。
    usleep(650_000)
    // 某些应用会在退出全屏时替换 AXWindow 对象，需要重新获取。
    if let refreshedWindow = focusedWindow(applicationPID: focusedPID) {
        window = refreshedWindow
    }
}
if wasZoomed {
    dbg("unzooming window")
    if setBoolean(window, "AXZoomed", false) == .success {
        _ = waitForBoolean(window, "AXZoomed", expected: false, timeoutMs: 500)
    }
}

guard let originalPosition = pointValue(copyAttribute(window, kAXPositionAttribute as String)),
      let originalSize = sizeValue(copyAttribute(window, kAXSizeAttribute as String)),
      originalSize.width > 0, originalSize.height > 0 else {
    failMove(
        "move-window-display: 无法读取窗口的位置或尺寸",
        window: window,
        applicationPID: focusedPID,
        restoreZoom: wasZoomed,
        restoreFullScreen: wasFullScreen
    )
}

let source = screens[currentIndex].visibleFrame
let target = screens[targetIndex].visibleFrame
let xRatio = relativeOrigin(
    originalPosition.x,
    length: originalSize.width,
    in: source.minX...source.maxX
)
let yRatio = relativeOrigin(
    originalPosition.y,
    length: originalSize.height,
    in: source.minY...source.maxY
)
let desiredSize = fittedSize(originalSize, in: target)

dbg(
    "window pos=\(originalPosition) size=\(originalSize) "
        + "screen=\(currentIndex + 1)->\(targetIndex + 1) ratio=(\(xRatio), \(yRatio)) "
        + "desiredSize=\(desiredSize)"
)

guard isAttributeSettable(window, kAXPositionAttribute as String) else {
    failMove(
        "move-window-display: 当前窗口不允许移动",
        window: window,
        applicationPID: focusedPID,
        restoreZoom: wasZoomed,
        restoreFullScreen: wasFullScreen
    )
}

// 先把窗口交给目标屏幕管理。若先在小屏上放大，macOS/应用会把尺寸限制在原屏幕内。
let transferOrigin = mappedOrigin(
    in: target,
    size: originalSize,
    xRatio: xRatio,
    yRatio: yRatio
)
setPoint(window, kAXPositionAttribute as String, transferOrigin)
let transferredPosition = waitForPosition(window, expected: transferOrigin) ?? transferOrigin
dbg("transfer position \(transferOrigin) -> \(transferredPosition)")

var actualSize = sizeValue(copyAttribute(window, kAXSizeAttribute as String)) ?? originalSize
if !nearlyEqual(actualSize, desiredSize) {
    if setSize(window, kAXSizeAttribute as String, desiredSize) == .success {
        actualSize = waitForSize(window, expected: desiredSize) ?? actualSize
        // 刚跨屏时窗口管理器偶尔只接受一个维度；稳定后补写一次即可。
        if !nearlyEqual(actualSize, desiredSize),
           setSize(window, kAXSizeAttribute as String, desiredSize) == .success {
            actualSize = waitForSize(window, expected: desiredSize) ?? actualSize
        }
        dbg("size \(desiredSize) -> \(actualSize)")
    } else {
        dbg("window rejected size change; moving without resizing")
    }
}

let finalOrigin = mappedOrigin(
    in: target,
    size: actualSize,
    xRatio: xRatio,
    yRatio: yRatio
)
setPoint(window, kAXPositionAttribute as String, finalOrigin)
guard let actualPosition = waitForPosition(window, expected: finalOrigin) else {
    failMove(
        "move-window-display: 无法确认窗口移动结果",
        window: window,
        applicationPID: focusedPID,
        restoreZoom: wasZoomed,
        restoreFullScreen: wasFullScreen
    )
}
dbg("final position \(finalOrigin) -> \(actualPosition)")

// 应用可能因标题栏安全区或自身最小尺寸修正几像素；只要窗口中心进入目标屏幕就算成功。
let verifiedSize = sizeValue(copyAttribute(window, kAXSizeAttribute as String)) ?? actualSize
let finalCenter = CGPoint(
    x: actualPosition.x + verifiedSize.width / 2,
    y: actualPosition.y + verifiedSize.height / 2
)
if !screens[targetIndex].frame.contains(finalCenter) {
    failMove(
        "move-window-display: 窗口移动失败",
        window: window,
        applicationPID: focusedPID,
        restoreZoom: wasZoomed,
        restoreFullScreen: wasFullScreen
    )
}

if wasZoomed {
    dbg("restoring zoomed state on display \(targetIndex + 1)")
    guard setBoolean(window, "AXZoomed", true) == .success,
          waitForBoolean(window, "AXZoomed", expected: true, timeoutMs: 500) else {
        writeStderr("move-window-display: 窗口已移动，但无法恢复最大化状态")
        NSSound.beep()
        exit(1)
    }
}

if wasFullScreen {
    dbg("restoring full screen on display \(targetIndex + 1)")
    guard setBoolean(window, "AXFullScreen", true) == .success,
          waitForBoolean(window, "AXFullScreen", expected: true, timeoutMs: 2_500) else {
        writeStderr("move-window-display: 窗口已移动，但无法恢复全屏状态")
        NSSound.beep()
        exit(1)
    }

    // 等待全屏 Space 的切换动画结束，再确认全屏窗口确实落在目标显示器。
    usleep(650_000)
    let fullScreenWindow = focusedWindow(applicationPID: focusedPID) ?? window
    guard let fullScreenPosition = pointValue(
        copyAttribute(fullScreenWindow, kAXPositionAttribute as String)
    ), let fullScreenSize = sizeValue(
        copyAttribute(fullScreenWindow, kAXSizeAttribute as String)
    ) else {
        writeStderr("move-window-display: 无法确认全屏窗口的位置")
        NSSound.beep()
        exit(1)
    }
    let fullScreenCenter = CGPoint(
        x: fullScreenPosition.x + fullScreenSize.width / 2,
        y: fullScreenPosition.y + fullScreenSize.height / 2
    )
    guard screens[targetIndex].frame.contains(fullScreenCenter) else {
        writeStderr("move-window-display: 全屏窗口未进入目标显示器")
        NSSound.beep()
        exit(1)
    }
    dbg("full screen restored at \(fullScreenPosition) size=\(fullScreenSize)")
}

dbg("moved successfully")
