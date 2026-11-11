import Darwin
import Foundation

@main
struct InstanceLockChecks {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3 {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            let lock = try MacInstanceLock.acquire(in: directory)
            if args[1] == "hold", let lock {
                try Data().write(to: directory.appendingPathComponent("ready"))
                withExtendedLifetime(lock) { _ = sleep(30) }
            }
            exit(lock == nil ? 73 : 0)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("musike-lock-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock = try MacInstanceLock.acquire(in: directory)
        guard lock != nil else { fatalError("first instance could not acquire lock") }
        func probe() throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["probe", directory.path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        guard try probe() == 73 else { fatalError("second process was not excluded") }
        lock = nil
        guard try probe() == 0 else { fatalError("lock was not released after exit") }
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        holder.arguments = ["hold", directory.path]
        try holder.run()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) { usleep(50_000) }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) else { holder.terminate(); fatalError("child failed to acquire lock") }
        guard try probe() == 73 else { holder.terminate(); fatalError("child did not hold the lock") }
        holder.terminate()
        holder.waitUntilExit()
        guard try probe() == 0 else { fatalError("lock remained held after process termination") }
        print("Single-instance lock excludes a second process and releases on exit.")
    }
}
