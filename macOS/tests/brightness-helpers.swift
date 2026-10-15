let testArguments = Array(CommandLine.arguments.dropFirst())
switch testArguments.first {
case "protocol":
    // Captured response from the HDMI monitor, followed by checksum-preserving semantic errors.
    let valid: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 70, 0x86, 0]
    precondition(try! decodeBrightness(valid) == Brightness(current: 70, maximum: 100))
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
    precondition(brightnessPacket(value: nil) == [0x82, 0x01, 0x10, 0xfd])
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
    try keepBrightnessToastVisible(displayID: 42, cache: cache)
    let pending = try JSONDecoder().decode(BrightnessToastState.self, from: Data(contentsOf: paths.state))
    precondition(pending.percentage == nil && pending.pending == true)
    let stale = BrightnessToastState(percentage: 65, updatedAt: ProcessInfo.processInfo.systemUptime - 2)
    try JSONEncoder().encode(stale).write(to: paths.state)
    try keepBrightnessToastVisible(displayID: 42, cache: cache)
    let refreshed = try JSONDecoder().decode(BrightnessToastState.self, from: Data(contentsOf: paths.state))
    precondition(refreshed.percentage == 65)
    precondition(refreshed.pending == true)
    precondition(ProcessInfo.processInfo.systemUptime - refreshed.updatedAt < 0.5)
    precondition(!brightnessOperationIsRunning(displayID: 42, cache: cache))
    let fd = try acquireBrightnessLock(at: cache.appendingPathComponent("brightness-42.lock").path)
    precondition(brightnessOperationIsRunning(displayID: 42, cache: cache))
    close(fd)
    precondition(!brightnessOperationIsRunning(displayID: 42, cache: cache))
    print("toast activity passed")
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
