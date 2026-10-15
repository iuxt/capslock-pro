// Hardware brightness via DDC/CI, Apple Silicon only.
// Transport selection adapted from waydabber/m1ddc (MIT), commit 04d9497.
// See macOS/THIRD_PARTY_NOTICES.md. Uses private IOKit/CoreDisplay APIs.
import AppKit
import IOKit
import Darwin

struct BrightnessError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// Independent process group: subsequent Karabiner commands must not cancel DDC writes.
func launchInBackground(executable: String, arguments: [String], logPath: String) throws {
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    func check(_ error: Int32) throws {
        if error != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
    }
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
    try check(posix_spawnattr_setpgroup(&attributes, 0))
    try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    try check(posix_spawn_file_actions_addopen(
        &actions, STDOUT_FILENO, logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600
    ))
    try check(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO))

    let strings = ([executable] + arguments).map { strdup($0) }
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    defer { (strings + environment).forEach { free($0) } }
    guard (strings + environment).allSatisfy({ $0 != nil }) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
    }
    var argv = strings + [nil]
    var envp = environment + [nil]
    var pid: pid_t = 0
    try check(posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp))
}

// A separate lock serializes the entire read/modify/write operation across processes.
// Bound the wait so a stalled monitor cannot accumulate requests indefinitely.
func acquireBrightnessLock(at path: String, timeout: Double = 3) throws -> Int32 {
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw BrightnessError("无法创建亮度锁：\(errno)") }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        let error = errno
        if error != EWOULDBLOCK && error != EINTR {
            close(fd)
            throw BrightnessError("无法锁定亮度操作：\(error)")
        }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            close(fd)
            throw BrightnessError("显示器忙，亮度请求等待超时")
        }
        usleep(10_000)
    }
    return fd
}

struct Brightness: Equatable {
    let current: UInt16
    let maximum: UInt16

    var percentage: Int {
        guard maximum > 0 else { return 0 }
        return min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
    }

    func adjusted(direction: Int) -> UInt16 {
        let step = max(1, Int((Double(maximum) * 0.05).rounded()))
        return UInt16(min(Int(maximum), max(0, Int(current) + direction * step)))
    }
}

func decodeBrightness(_ bytes: [UInt8]) throws -> Brightness {
    guard bytes.count >= 11,
          bytes[0] == 0x6e, bytes[1] == 0x88, bytes[2] == 0x02,
          bytes[3] == 0, bytes[4] == 0x10,
          bytes.prefix(11).reduce(UInt8(0x50), ^) == 0 else {
        throw BrightnessError("显示器没有返回有效的 DDC 亮度响应，请检查 DDC/CI 设置")
    }
    let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
    let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
    guard maximum > 0, current <= maximum else {
        throw BrightnessError("显示器返回的亮度范围无效")
    }
    return Brightness(current: current, maximum: maximum)
}

func brightnessPacket(value: UInt16?) -> [UInt8] {
    var bytes: [UInt8]
    let seed: UInt8
    if let value {
        bytes = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xff)]
        seed = 0x6e ^ 0x51
    } else {
        bytes = [0x82, 0x01, 0x10]
        seed = 0x6e
    }
    bytes.append(bytes.reduce(seed, ^))
    return bytes
}

// Resolve C ABI symbols dynamically; missing private APIs produce an explicit error.
final class DisplayAPI {
    typealias DisplayInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    let displayInfo: DisplayInfo
    let create: Create
    let read: Transfer
    let write: Transfer
    private let coreDisplay: UnsafeMutableRawPointer
    private let ioKit: UnsafeMutableRawPointer

    init() throws {
        guard let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY) else {
            throw BrightnessError("无法加载 CoreDisplay")
        }
        guard let io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            dlclose(core)
            throw BrightnessError("无法加载 IOKit")
        }
        guard let info = dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary"),
              let make = dlsym(io, "IOAVServiceCreateWithService"),
              let read = dlsym(io, "IOAVServiceReadI2C"),
              let write = dlsym(io, "IOAVServiceWriteI2C") else {
            dlclose(core); dlclose(io)
            throw BrightnessError("当前 macOS 缺少 DDC 所需接口")
        }
        coreDisplay = core; ioKit = io
        displayInfo = unsafeBitCast(info, to: DisplayInfo.self)
        create = unsafeBitCast(make, to: Create.self)
        self.read = unsafeBitCast(read, to: Transfer.self)
        self.write = unsafeBitCast(write, to: Transfer.self)
    }

    deinit { dlclose(coreDisplay); dlclose(ioKit) }
}

func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

final class DDCDisplay {
    let api: DisplayAPI
    let service: CFTypeRef
    let address: UInt32

    init(displayID: CGDirectDisplayID, api: DisplayAPI) throws {
        self.api = api
        guard let info = api.displayInfo(displayID)?.takeRetainedValue() as? [String: Any],
              let location = info["IODisplayLocation"] as? String else {
            throw BrightnessError("无法定位显示器 DDC 服务")
        }
        let adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard adapter != 0 else { throw BrightnessError("显示器已断开") }
        defer { IOObjectRelease(adapter) }
        var adapterID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(adapter, &adapterID) == KERN_SUCCESS else {
            throw BrightnessError("无法读取显示器设备标识")
        }
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane,
                                      IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            throw BrightnessError("无法枚举显示器服务")
        }
        defer { IOObjectRelease(iterator) }
        var matches = false
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var entryID: UInt64 = 0
                matches = IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS && entryID == adapterID
                continue
            }
            guard matches, IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0,
                  registryProperty(entry, "Location") as? String == "External",
                  let service = api.create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var parent: io_registry_entry_t = 0
            var isHDMIBridge = false
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                isHDMIBridge = registryProperty(parent, "EPICProviderClass") as? String == "AppleDCPMCDP29XX"
                IOObjectRelease(parent)
            }
            self.service = service
            // M1's built-in HDMI bridge routes DDC at 0xB7, ordinary DP uses 0x37.
            address = isHDMIBridge ? 0xb7 : 0x37
            return
        }
        throw BrightnessError("此连接没有可用的 DDC 通路")
    }

    private func send(_ packet: [UInt8]) throws {
        var packet = packet
        for _ in 0..<2 {
            usleep(10_000)
            let result = packet.withUnsafeMutableBytes {
                api.write(service, address, 0x51, $0.baseAddress!, UInt32($0.count))
            }
            guard result == 0 else { throw BrightnessError("DDC 写入失败：\(result)") }
        }
    }

    func brightness() throws -> Brightness {
        var lastError: Error = BrightnessError("DDC 读取失败")
        for _ in 0..<3 {
            do {
                try send(brightnessPacket(value: nil))
                usleep(50_000)
                var bytes = [UInt8](repeating: 0, count: 12)
                let result = bytes.withUnsafeMutableBytes {
                    api.read(service, address, 0x51, $0.baseAddress!, UInt32($0.count))
                }
                guard result == 0 else { throw BrightnessError("DDC 读取失败：\(result)") }
                return try decodeBrightness(bytes)
            } catch { lastError = error; usleep(30_000) }
        }
        throw lastError
    }

    func setBrightness(_ value: UInt16) throws {
        try send(brightnessPacket(value: value))
        usleep(50_000)
        guard try brightness().current == value else {
            throw BrightnessError("亮度写入后读回不一致，请检查显示器模式是否允许调节亮度")
        }
    }
}

func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

func selectExternalScreen(_ screens: [NSScreen], explicitID: UInt32?) throws -> NSScreen {
    let external = screens.filter { screenID($0).map { CGDisplayIsBuiltin($0) == 0 } ?? false }
    if let explicitID {
        guard let screen = external.first(where: { screenID($0) == explicitID }) else {
            throw BrightnessError("指定的外接显示器不存在")
        }
        return screen
    }
    if external.count == 1 { return external[0] }
    if let screen = external.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) { return screen }
    throw BrightnessError(external.isEmpty ? "没有外接显示器" : "请将鼠标移到要调节的外接显示器")
}

// MARK: - Brightness toast

struct BrightnessToastState: Codable {
    let percentage: Int?
    let updatedAt: Double
    let pending: Bool?

    init(percentage: Int?, updatedAt: Double, pending: Bool = false) {
        self.percentage = percentage
        self.updatedAt = updatedAt
        self.pending = pending
    }
}

struct BrightnessToastPaths {
    let state: URL
    let gate: String
    let owner: String

    init(directory: URL, displayID: UInt32) {
        let base = directory.appendingPathComponent("brightness-toast-\(displayID)").path
        state = URL(fileURLWithPath: base + ".json")
        gate = base + ".lock"
        owner = base + "-owner.lock"
    }
}

/// Extend an existing toast as soon as a request arrives, before waiting for DDC.
func keepBrightnessToastVisible(displayID: UInt32, cache: URL) throws {
    let paths = BrightnessToastPaths(directory: cache, displayID: displayID)
    let gate = try acquireBrightnessLock(at: paths.gate)
    defer { close(gate) }
    let previous = (try? Data(contentsOf: paths.state)).flatMap {
        try? JSONDecoder().decode(BrightnessToastState.self, from: $0)
    }
    let state = BrightnessToastState(percentage: previous?.percentage,
                                     updatedAt: ProcessInfo.processInfo.systemUptime, pending: true)
    try JSONEncoder().encode(state).write(to: paths.state, options: .atomic)
}

/// Reuse the viewer instead of launching an AppKit process per key.
func launchBrightnessToastIfNeeded(displayID: UInt32, cache: URL) throws {
    let paths = BrightnessToastPaths(directory: cache, displayID: displayID)
    let gate = try acquireBrightnessLock(at: paths.gate)
    defer { close(gate) }
    let owner = open(paths.owner, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard owner >= 0 else { throw BrightnessError("无法检查亮度提示进程") }
    defer { close(owner) }
    if flock(owner, LOCK_EX | LOCK_NB) != 0 {
        if errno == EWOULDBLOCK { return }
        throw BrightnessError("无法检查亮度提示锁")
    }
    // Release before the child claims ownership; the gate synchronizes startup and shutdown.
    flock(owner, LOCK_UN)
    let log = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CapsLock-Pro", isDirectory: true)
    try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
    try launchInBackground(executable: URL(fileURLWithPath: CommandLine.arguments[0]).path,
                           arguments: ["--toast", String(displayID)],
                           logPath: log.appendingPathComponent("brightness.log").path)
}

/// The shortcut launcher can signal the UI before the DDC worker initializes AppKit/screens.
func shortcutDisplayID(explicitID: UInt32?) -> UInt32? {
    var displays = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
    let external = displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    if let explicitID { return external.contains(explicitID) ? explicitID : nil }
    if external.count == 1 { return external.first }
    guard let cursor = CGEvent(source: nil)?.location else { return nil }
    return external.first { CGDisplayBounds($0).contains(cursor) }
}

func brightnessOperationIsRunning(displayID: UInt32, cache: URL) -> Bool {
    let path = cache.appendingPathComponent("brightness-\(displayID).lock").path
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return false }
    return errno == EWOULDBLOCK
}

/// Replace the pending indication with confirmed brightness.
func showBrightnessToast(_ brightness: Brightness, displayID: UInt32, cache: URL) throws {
    let paths = BrightnessToastPaths(directory: cache, displayID: displayID)
    let gate = try acquireBrightnessLock(at: paths.gate)
    defer { close(gate) }
    let state = BrightnessToastState(percentage: brightness.percentage,
                                     updatedAt: ProcessInfo.processInfo.systemUptime)
    try JSONEncoder().encode(state).write(to: paths.state, options: .atomic)
}

final class BrightnessToastView: NSVisualEffectView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "亮度")
    private let fill = NSView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 244, height: 100))
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .vibrantDark)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true

        let symbol = NSImageView(frame: NSRect(x: 24, y: 43, width: 27, height: 27))
        symbol.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "亮度")
        symbol.contentTintColor = .white
        addSubview(symbol)

        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 62, y: 46, width: 64, height: 22)
        addSubview(titleLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        valueLabel.textColor = .white
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 126, y: 40, width: 94, height: 33)
        addSubview(valueLabel)

        let track = NSView(frame: NSRect(x: 24, y: 23, width: 196, height: 6))
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        track.layer?.cornerRadius = 3
        track.layer?.masksToBounds = true
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.white.cgColor
        fill.layer?.cornerRadius = 3
        track.addSubview(fill)
        addSubview(track)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(percentage: Int?, pending: Bool = false) {
        let percentage = percentage.map { min(100, max(0, $0)) }
        titleLabel.stringValue = pending ? "调节中" : "亮度"
        valueLabel.stringValue = percentage.map { "\($0)%" } ?? "…"
        fill.frame = NSRect(x: 0, y: 0, width: 196 * CGFloat(percentage ?? 0) / 100, height: 6)
        setAccessibilityLabel(pending ? "正在调节亮度" : "亮度 \(percentage ?? 0)%")
    }
}

func runBrightnessToast(displayID: UInt32, cache: URL) throws {
    let paths = BrightnessToastPaths(directory: cache, displayID: displayID)
    let owner: Int32
    do {
        let gate = try acquireBrightnessLock(at: paths.gate)
        defer { close(gate) }
        owner = open(paths.owner, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard owner >= 0 else { throw BrightnessError("无法创建亮度提示锁") }
        if flock(owner, LOCK_EX | LOCK_NB) != 0 { close(owner); return }
    }
    defer { close(owner) }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let screen = NSScreen.screens.first(where: { screenID($0) == displayID }) else { return }
    let view = BrightnessToastView()
    let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.contentView = view
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - view.frame.width / 2,
                                 y: screen.visibleFrame.minY + 72))

    var lastUpdate: Double?
    var finished = false
    func refresh() {
        guard !finished else { return }
        // Synchronize shutdown with publishers so a request at the hide deadline isn't lost.
        guard let gate = try? acquireBrightnessLock(at: paths.gate) else { return }
        defer { close(gate) }
        let state = (try? Data(contentsOf: paths.state)).flatMap { try? JSONDecoder().decode(BrightnessToastState.self, from: $0) }
        let age = state.map { ProcessInfo.processInfo.systemUptime - $0.updatedAt } ?? .infinity
        // Keep the same panel alive during a pending read/write. Cap stale activity if DDC stalls.
        let waitingForBrightness = age < 5 && brightnessOperationIsRunning(displayID: displayID, cache: cache)
        guard let state, age < 60 else {
            finished = true
            panel.orderOut(nil)
            flock(owner, LOCK_UN)
            app.stop(nil)
            // Wake NSApplication.run even when no user event is pending.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                              modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(event, atStart: true)
            }
            return
        }
        guard age < 1.3 || waitingForBrightness else {
            // Retain the AppKit window briefly for fast reappearance on the next key press.
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if lastUpdate != state.updatedAt {
            lastUpdate = state.updatedAt
            view.update(percentage: state.percentage, pending: state.pending == true)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
    refresh()
    guard !finished else { return }
    let timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in refresh() }
    defer { timer.invalidate(); panel.orderOut(nil) }
    app.run()
}

// MARK: - Arguments
let usage = "Usage: display-brightness [--background] [list|get|up|down] [display-id]"
var arguments = Array(CommandLine.arguments.dropFirst())
let background = arguments.first == "--background"
if background { arguments.removeFirst() }
if arguments == ["--help"] || arguments == ["-h"] { print(usage); exit(0) }
if !background, arguments.count == 2, arguments[0] == "--toast", let id = UInt32(arguments[1]) {
    do {
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CapsLock-Pro", isDirectory: true)
        try runBrightnessToast(displayID: id, cache: cache)
        exit(0)
    } catch { writeStderr("display-brightness: \(error)"); exit(1) }
}
guard (1...2).contains(arguments.count), ["list", "get", "up", "down"].contains(arguments[0]),
      arguments.count == 1 || (arguments[0] != "list" && UInt32(arguments[1]) != nil) else {
    writeStderr(usage); exit(2)
}

func run() throws {
    #if !arch(arm64)
    throw BrightnessError("目前仅支持 Apple Silicon Mac")
    #else
    let home = FileManager.default.homeDirectoryForCurrentUser
    if background {
        let logs = home.appendingPathComponent("Library/Logs/CapsLock-Pro", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if ["up", "down"].contains(arguments[0]),
           let id = shortcutDisplayID(explicitID: arguments.count == 2 ? UInt32(arguments[1]) : nil) {
            do {
                let cache = home.appendingPathComponent("Library/Caches/CapsLock-Pro", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try keepBrightnessToastVisible(displayID: id, cache: cache)
                try launchBrightnessToastIfNeeded(displayID: id, cache: cache)
                // Bind the eventual hardware operation to the same screen even if the mouse moves.
                arguments = [arguments[0], String(id)]
            } catch { writeStderr("display-brightness: 无法提前显示亮度提示：\(error)") }
        }
        try launchInBackground(executable: URL(fileURLWithPath: CommandLine.arguments[0]).path,
                               arguments: arguments, logPath: logs.appendingPathComponent("brightness.log").path)
        return
    }
    let screens = NSScreen.screens
    if arguments[0] == "list" {
        for screen in screens {
            if let id = screenID(screen), CGDisplayIsBuiltin(id) == 0 {
                print("\(id)\t\(screen.localizedName)")
            }
        }
        return
    }
    let screen = try selectExternalScreen(screens, explicitID: arguments.count == 2 ? UInt32(arguments[1]) : nil)
    guard let id = screenID(screen) else { throw BrightnessError("无法识别显示器") }
    let cache = home.appendingPathComponent("Library/Caches/CapsLock-Pro", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    if arguments[0] != "get" {
        do {
            try keepBrightnessToastVisible(displayID: id, cache: cache)
            try launchBrightnessToastIfNeeded(displayID: id, cache: cache)
        }
        catch { writeStderr("display-brightness: 无法延长亮度提示：\(error)") }
    }
    let lock = try acquireBrightnessLock(at: cache.appendingPathComponent("brightness-\(id).lock").path)
    defer { close(lock) }
    let display = try DDCDisplay(displayID: id, api: DisplayAPI())
    let original = try display.brightness()
    var current = original.current
    if arguments[0] != "get" {
        current = original.adjusted(direction: arguments[0] == "up" ? 1 : -1)
        if current != original.current { try display.setBrightness(current) }
        do {
            try showBrightnessToast(Brightness(current: current, maximum: original.maximum), displayID: id, cache: cache)
            try launchBrightnessToastIfNeeded(displayID: id, cache: cache)
        } catch {
            writeStderr("display-brightness: 无法显示亮度提示：\(error)")
        }
    }
    print("\(screen.localizedName): \(current)/\(original.maximum)")
    #endif
}

do { try run() } catch {
    writeStderr("display-brightness: \(error)")
    exit(1)
}
