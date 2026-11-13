import Darwin
import Foundation

/// Atomic one-copy claim: an exclusive, non-blocking `flock` on a file in the default data folder.
/// A held lock, or one that cannot be taken, means this copy yields. The kernel drops the lock when the
/// process exits. `flock` locks belong to the open file description, so a second claim in the same
/// process fails too, unlike a POSIX `fcntl` record lock.
final class TNFInstanceLock {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func lockURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(LibrarySessionConfiguration.defaultFolderName, isDirectory: true)
            .appendingPathComponent(".instance.lock", isDirectory: false)
    }

    /// Returns nil when the lock is held, cannot be taken, or the file is not a plain single-name file of
    /// this user. Never follows a symlink at `url`; never creates the folder.
    static func acquire(at url: URL) -> TNFInstanceLock? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        // Only a plain file with no other name, owned by this user, may be locked or chmodded; a hard link
        // could be another app's file.
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid() else {
            close(descriptor)
            return nil
        }
        guard fchmod(descriptor, 0o600) == 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return TNFInstanceLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
