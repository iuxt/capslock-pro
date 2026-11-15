let testArguments = Array(CommandLine.arguments.dropFirst())
switch testArguments.first {
case "protocol":
    // Captured response from the HDMI monitor, followed by checksum-preserving semantic errors.
    let valid: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 70, 0x86, 0]
    precondition(try! decodeBrightness(valid) == Brightness(current: 70, maximum: 100))
    // Captured AOC Q2790 HDMI response after correcting the Get VCP checksum.
    let aocReply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 80, 0x90, 0]
    precondition(try! decodeBrightness(aocReply) == Brightness(current: 80, maximum: 100))
    for index in 0..<11 {
        var bad = valid
        bad[index] ^= 1
        do { _ = try decodeBrightness(bad); fatalError("Accepted corrupted reply") } catch {}
    }
    for (index, value) in [(3, UInt8(1)), (4, UInt8(0x12)), (7, UInt8(0)), (9, UInt8(101))] {
        var bad = valid
        bad[index] = value
        bad[10] = bad.prefix(10).reduce(UInt8(0x50), ^)
        do { _ = try decodeBrightness(bad); fatalError("Accepted invalid reply") } catch {}
    }
    do { _ = try decodeBrightness(Array(valid.prefix(10))); fatalError("Accepted truncated reply") } catch {}
    precondition(Brightness(current: 2, maximum: 100).adjusted(direction: -1) == 0)
    precondition(Brightness(current: 99, maximum: 100).adjusted(direction: 1) == 100)
    precondition(Brightness(current: 100, maximum: 200).adjusted(direction: 1) == 110)
    precondition(Brightness(current: 1, maximum: 10).adjusted(direction: -1) == 0)
    precondition(Brightness(current: 70, maximum: 100).percentage == 70)
    precondition(Brightness(current: 140, maximum: 200).percentage == 70)
    precondition(Brightness(current: 1, maximum: 3).percentage == 33)
    precondition(Brightness(current: 0, maximum: 100).percentage == 0)
    precondition(Brightness(current: 100, maximum: 100).percentage == 100)
    // Fixed wire vectors, including a command whose checksum ends in zero.
    precondition(brightnessPacket(value: nil) == [0x82, 0x01, 0x10, 0xac])
    precondition(brightnessPacket(value: 65) == [0x84, 0x03, 0x10, 0, 65, 0xe9])
    precondition(brightnessPacket(value: 168) == [0x84, 0x03, 0x10, 0, 168, 0])
    print("protocol passed")
case "increment":
    let path = testArguments[1]
    let fd = try acquireBrightnessLock(at: path + ".lock")
    let value = Int(try String(contentsOfFile: path, encoding: .utf8))!
    usleep(50_000) // Provoke overlap between concurrent read/modify/write operations.
    try String(value + 1).write(toFile: path, atomically: true, encoding: .utf8)
    close(fd)
case "toast-activity":
    let cache = URL(fileURLWithPath: testArguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let paths = BrightnessToastPaths(directory: cache, displayID: 42)
    // Show pending immediately even without a prior value, without inventing a percentage.
    _ = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: cache)
    let pending = try JSONDecoder().decode(BrightnessToastState.self, from: Data(contentsOf: paths.state))
    precondition(pending.percentage == nil && pending.pending == true)
    // A confirmed value is reused for an immediate preview before hardware reads.
    let adjustmentPaths = BrightnessAdjustmentPaths(cache: cache, displayID: 42)
    var adjustment = try adjustmentPaths.load()
    adjustment.confirmed = Brightness(current: 65, maximum: 100)
    adjustment.target = adjustment.confirmed
    adjustment.directions = []
    adjustment.completedRevision = adjustment.revision
    try adjustmentPaths.save(adjustment, displayID: 42, cache: cache)
    _ = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: cache)
    let refreshed = try JSONDecoder().decode(BrightnessToastState.self, from: Data(contentsOf: paths.state))
    precondition(refreshed.percentage == 70)
    precondition(refreshed.pending == true)
    precondition(ProcessInfo.processInfo.systemUptime - refreshed.updatedAt < 0.5)
    precondition(!brightnessOperationIsRunning(displayID: 42, cache: cache))
    let fd = try acquireBrightnessLock(at: cache.appendingPathComponent("brightness-42.lock").path)
    precondition(brightnessOperationIsRunning(displayID: 42, cache: cache))
    close(fd)
    precondition(!brightnessOperationIsRunning(displayID: 42, cache: cache))
    // Completion closes the viewer at the hide deadline; unrelated DDC reads cannot extend it.
    precondition(shouldDisplayToast(age: 1.29, pending: false, operationIsRunning: false))
    precondition(!shouldDisplayToast(age: 1.3, pending: false, operationIsRunning: true))
    precondition(shouldDisplayToast(age: 2, pending: true, operationIsRunning: true))
    precondition(!shouldDisplayToast(age: 2, pending: true, operationIsRunning: false))
    precondition(!shouldDisplayToast(age: 5, pending: true, operationIsRunning: true))
    precondition(!shouldDisplayToast(age: -1, pending: false, operationIsRunning: false))
    print("toast activity passed")
case "expired-toast":
    // Run the actual viewer against a recent but already-hidden toast. No panel is shown.
    guard let id = NSScreen.screens.first.flatMap(screenID) else { exit(77) }
    let cache = URL(fileURLWithPath: testArguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let paths = BrightnessToastPaths(directory: cache, displayID: id)
    let state = BrightnessToastState(percentage: 50, updatedAt: ProcessInfo.processInfo.systemUptime - 2)
    try JSONEncoder().encode(state).write(to: paths.state, options: .atomic)
    try runBrightnessToast(displayID: id, cache: cache)
case "debounce":
    let root = URL(fileURLWithPath: testArguments[1], isDirectory: true)
    func directory(_ name: String) throws -> URL {
        let result = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    func toast(_ cache: URL, id: UInt32 = 42) throws -> BrightnessToastState {
        try JSONDecoder().decode(BrightnessToastState.self,
                                 from: Data(contentsOf: BrightnessToastPaths(directory: cache, displayID: id).state))
    }
    let cache = try directory("burst")
    var clock = 100.0
    var reads = 0
    var writes: [UInt16] = []
    var injected = false
    let burst = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: cache, now: clock)!
    try applyBrightnessAdjustments(displayID: 42, cache: cache, lease: burst, read: {
        reads += 1
        // A second key arrives while the initial monitor read is still running.
        clock += 0.05
        _ = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: cache, now: clock)
        return Brightness(current: 50, maximum: 100)
    }, write: { value in
        precondition(clock >= 100.2 + brightnessSettleDelay)
        writes.append(value)
    }, now: { clock }, wait: {
        precondition(writes.isEmpty)
        if !injected {
            // Preview is visible and no hardware write has happened yet.
            precondition(try! toast(cache).percentage == 60)
            clock = 100.2
            _ = try! enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: cache, now: clock)
            precondition(try! toast(cache).percentage == 65)
            _ = try! enqueueBrightnessAdjustment(direction: -1, displayID: 42, cache: cache, now: clock)
            injected = true
        }
        clock += 0.01
    })
    precondition(reads == 1 && writes == [60])
    precondition(try! toast(cache).pending == false)
    precondition(try! toast(cache).percentage == 60)
    precondition(!brightnessOperationIsRunning(displayID: 42, cache: cache))

    // New burst previews immediately, but rebases on the actual OSD value (20%).
    clock = 102
    let nextBurst = try enqueueBrightnessAdjustment(direction: -1, displayID: 42, cache: cache, now: clock)!
    precondition(try! toast(cache).percentage == 55)
    try applyBrightnessAdjustments(displayID: 42, cache: cache, lease: nextBurst,
                                   read: { Brightness(current: 20, maximum: 100) },
                                   write: { writes.append($0) }, now: { clock }, wait: { clock += 0.01 })
    precondition(writes == [60, 15])

    let bounds = try directory("bounds")
    let bounding = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: bounds, now: clock)!
    _ = try enqueueBrightnessAdjustment(direction: -1, displayID: 42, cache: bounds, now: clock)
    var boundaryWrites: [UInt16] = []
    try applyBrightnessAdjustments(displayID: 42, cache: bounds, lease: bounding,
                                   read: { Brightness(current: 100, maximum: 100) },
                                   write: { boundaryWrites.append($0) }, now: { clock }, wait: { clock += 0.01 })
    precondition(boundaryWrites == [95])

    let inflight = try directory("inflight")
    var concurrentWrites: [UInt16] = []
    let inFlight = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: inflight, now: clock)!
    try applyBrightnessAdjustments(displayID: 42, cache: inflight, lease: inFlight,
                                   read: { Brightness(current: 50, maximum: 100) }, write: { value in
        concurrentWrites.append(value)
        if concurrentWrites.count == 1 {
            clock += 0.05
            _ = try enqueueBrightnessAdjustment(direction: -1, displayID: 42, cache: inflight, now: clock)
            precondition(try! toast(inflight).percentage == 50)
            // A competing worker exits without touching hardware or stealing the newer input.
            precondition(try! BrightnessWorkerLease(claiming: BrightnessAdjustmentPaths(cache: inflight, displayID: 42).owner) == nil)
        }
    }, now: { clock }, wait: { clock += 0.01 })
    precondition(concurrentWrites == [55, 50])
    precondition(try! toast(inflight).pending == false)
    precondition(try! toast(inflight).percentage == 50)

    let failed = try directory("failed")
    var failureReads = 0
    let firstFailure = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: failed, now: clock)!
    do {
        try applyBrightnessAdjustments(displayID: 42, cache: failed, lease: firstFailure, read: {
            failureReads += 1
            return Brightness(current: failureReads == 1 ? 50 : 48, maximum: 100)
        }, write: { _ in throw BrightnessError("Simulated DDC failure") },
           now: { clock }, wait: { clock += 0.01 })
        fatalError("Write failure was hidden")
    } catch {}
    precondition(try! toast(failed).failed == true)
    precondition(try! toast(failed).pending == false)
    precondition(try! toast(failed).percentage == 48)
    let retry = try enqueueBrightnessAdjustment(direction: -1, displayID: 42, cache: failed, now: clock)!
    try applyBrightnessAdjustments(displayID: 42, cache: failed, lease: retry,
                                   read: { Brightness(current: 48, maximum: 100) },
                                   write: { precondition($0 == 43) }, now: { clock }, wait: { clock += 0.01 })
    precondition(try! toast(failed).failed == false)
    print("debounce passed")
case "abandoned":
    let cache = URL(fileURLWithPath: testArguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    // A worker dies before acknowledging "up"; a new "down" must act on the hardware reading.
    var owner = try enqueueBrightnessAdjustment(direction: 1, displayID: 99, cache: cache, now: 100)
    precondition(owner != nil)
    owner = nil
    let fresh = try enqueueBrightnessAdjustment(direction: -1, displayID: 99, cache: cache, now: 100.1)!
    var writes: [UInt16] = []
    try applyBrightnessAdjustments(displayID: 99, cache: cache, lease: fresh,
                                  read: { Brightness(current: 80, maximum: 100) },
                                  write: { writes.append($0) }, now: { 102 })
    precondition(writes == [75])
case "enqueue":
    let cache = URL(fileURLWithPath: testArguments[1], isDirectory: true)
    if let lease = try enqueueBrightnessAdjustment(direction: 1, displayID: 42, cache: cache) {
        try launchInBackground(executable: CommandLine.arguments[0], arguments: ["apply-mock", cache.path],
                               logPath: cache.appendingPathComponent("worker.log").path, workerFD: lease.fd)
        withExtendedLifetime(lease) {}
    }
case "apply-mock":
    let cache = URL(fileURLWithPath: testArguments[1], isDirectory: true)
    let lease = BrightnessWorkerLease(inherited: 3, path: BrightnessAdjustmentPaths(cache: cache, displayID: 42).owner)!
    try applyBrightnessAdjustments(displayID: 42, cache: cache, lease: lease, read: {
        try Data("read\n".utf8).write(to: cache.appendingPathComponent("read"))
        usleep(100_000)
        return Brightness(current: 50, maximum: 100)
    }, write: { value in
        // A single hardware setter is allowed for the whole burst.
        let path = cache.appendingPathComponent("writes").path
        let fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        precondition(fd >= 0)
        defer { close(fd) }
        let data = Data("\(value)\n".utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    })
case "timeout":
    let path = testArguments[1]
    let fd = try acquireBrightnessLock(at: path)
    defer { close(fd) }
    do {
        let other = try acquireBrightnessLock(at: path, timeout: 0.05)
        close(other)
        fatalError("Overlapping lock acquired")
    } catch { print("timeout passed") }
default:
    fatalError("Unknown test")
}
