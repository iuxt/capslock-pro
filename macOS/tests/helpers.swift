// 由 test_macos.py 与生产源码的函数部分一起编译，无需辅助功能权限。
let testArguments = Array(CommandLine.arguments.dropFirst())
switch testArguments[0] {
case "window-handoff":
    let original = WindowIdentity(pid: 123, number: 42)
    let otherWindow = WindowIdentity(pid: 123, number: 43)
    let otherApp = WindowIdentity(pid: 456, number: 42)
    func select(_ identity: WindowIdentity?) -> String? {
        targetWindow(expected: original, focused: "AX window", identify: { _ in identity })
    }
    precondition(select(original) == "AX window")
    precondition(select(otherWindow) == nil && select(otherApp) == nil && select(nil) == nil)
    precondition(targetWindow(expected: original, focused: nil as String?, identify: { _ in original }) == nil)
case "fullscreen-rollback":
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let normal = CGRect(x: 20, y: 50, width: 800, height: 600)
    var frame = screen
    let rollback = ordinaryFrame(initial: screen, fullScreen: true, exitAndWait: { frame = normal },
                                 readFrame: { frame })
    precondition(rollback == normal)
    // An invalid AX object must never substitute the fullscreen size for a failed read.
    precondition(ordinaryFrame(initial: screen, fullScreen: true, exitAndWait: {}, readFrame: { nil }) == nil)
    precondition(ordinaryFrame(initial: normal, fullScreen: false, exitAndWait: { fatalError("Unexpected exit") },
                               readFrame: { fatalError("Unexpected AX read") }) == normal)
case "geometry":
    let large = CGRect(x: -2560, y: -200, width: 2560, height: 1400)
    let small = CGRect(x: 0, y: 25, width: 1440, height: 875)
    assert(fillsVisibleFrame(large, in: large))
    // iTerm2 等应用按字符网格缩小几个点，往返后仍铺满目标显示器。
    let gridWindow = CGRect(x: large.minX, y: large.minY, width: 2548, height: 1384)
    assert(fillsVisibleFrame(gridWindow, in: large))
    let onSmall = movedSize(gridWindow.size, maximized: fillsVisibleFrame(gridWindow, in: large), in: small)
    assert(onSmall == small.size)
    let smallFrame = CGRect(origin: small.origin, size: onSmall)
    assert(movedSize(onSmall, maximized: fillsVisibleFrame(smallFrame, in: small), in: large) == large.size)
    assert(!fillsVisibleFrame(CGRect(x: large.minX, y: large.minY, width: 1280, height: 1400), in: large))
    assert(!fillsVisibleFrame(large.offsetBy(dx: 100, dy: 0), in: large))
    let normal = CGSize(width: 800, height: 600)
    assert(movedSize(normal, maximized: false, in: small) == normal)
    assert(movedSize(CGSize(width: 2000, height: 1000), maximized: false, in: small) == CGSize(width: 1440, height: 720))
    assert(axRect(CGRect(x: 0, y: 1080, width: 1440, height: 900), primaryTop: 1080).minY == -900)
    print("geometry passed")
case "lock":
    if let descriptor = try acquireOperationLock(at: testArguments[1]) {
        print("acquired")
        fflush(stdout)
        if testArguments.count > 2 { sleep(30) }
        close(descriptor)
    } else {
        print("busy")
    }
case "spawn":
    try launchInBackground(executable: "/bin/sh", arguments: [testArguments[1]], logPath: testArguments[2])
    // 测试会杀掉此进程组，子进程应继续完成。
    sleep(30)
default:
    fatalError("unknown test")
}
