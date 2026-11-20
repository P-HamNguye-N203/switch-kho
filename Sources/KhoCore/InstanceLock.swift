import Darwin
import Foundation

/// An exclusive `flock` held for the life of the process, so only one Switch Kho touches
/// the ledger.
public final class InstanceLock: Sendable {
    let fd: Int32

    init(fd: Int32) { self.fd = fd }

    public static func acquire(at url: URL) -> InstanceLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return InstanceLock(fd: fd)
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
