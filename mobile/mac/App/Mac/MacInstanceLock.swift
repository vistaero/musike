import Darwin
import Foundation

/// The kernel releases this lock if Musike exits or crashes. The file itself is
/// intentionally left in place so a waiting launch can never lock a new inode.
final class MacInstanceLock {
    static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Musike Native", isDirectory: true)
    }
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    /// Returns nil when another process owns the lock; actual filesystem errors
    /// are reported separately so startup cannot silently violate the limit.
    static func acquire(in directory: URL) throws -> MacInstanceLock? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        return MacInstanceLock(descriptor: fd)
    }
}
