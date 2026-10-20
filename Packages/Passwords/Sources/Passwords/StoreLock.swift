import Foundation

/// A cross-process advisory lock (`flock`) on `<database>.lock`, next to the database.
///
/// Every open `PasswordStore` holds it shared for as long as it's open, in any process (the app,
/// the iSmith Agent). Moving the database aside, which is the only thing that replaces the file
/// under its path, needs it exclusively and doesn't wait for it: if another store has the file
/// open, nothing is moved. `flock` locks belong to the open file description, so two stores in one
/// process are separate holders, as two processes are; the lock goes away when its descriptor is
/// closed, including when a process exits or crashes.
///
/// The lock file is owner-only and empty; it is never moved or deleted.
final class StoreLock: @unchecked Sendable {
    static func url(for database: URL) -> URL { URL(fileURLWithPath: database.path + ".lock") }

    private let mutex = NSLock()
    private var fd: Int32

    /// Opens the lock file (creating it, 0600, when `create`) and takes the lock shared, waiting
    /// up to `PasswordStore.busyTimeout` for a move aside in progress elsewhere to finish.
    /// Without `create`, a missing lock file means the app hasn't opened the database yet.
    init(for database: URL, create: Bool) throws {
        let path = Self.url(for: database).path
        let fd = create ? open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600) : open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT, !create { throw PasswordStoreError.notSetUp }
            throw PasswordStoreError.databaseUnavailable("the passwords lock file couldn't be opened (errno \(errno))")
        }
        if create, fchmod(fd, 0o600) != 0 {
            close(fd)
            throw PasswordStoreError.databaseUnavailable("the passwords lock file couldn't be limited to the owner (errno \(errno))")
        }
        self.fd = fd
        let deadline = Date().addingTimeInterval(PasswordStore.busyTimeout)
        while flock(fd, LOCK_SH | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                close(fd)
                self.fd = -1
                throw PasswordStoreError.databaseUnavailable("another process is replacing the passwords file")
            }
            usleep(20_000)
        }
    }

    deinit { unlock() }

    /// Exclusive, without waiting: false when any other holder has it. `flock` doesn't convert a
    /// shared lock atomically (another holder may lock in between), so this lets go first and
    /// says so: whatever was judged under the shared lock must be judged again. The store throws
    /// away this lock when this fails.
    func lockExclusively(between: (() -> Void)? = nil) -> Bool {
        mutex.withLock {
            guard fd >= 0 else { return false }
            flock(fd, LOCK_UN)
            between?()
            return flock(fd, LOCK_EX | LOCK_NB) == 0
        }
    }

    /// Back to shared, after an exclusive hold. Waits for the shared lock if another holder
    /// slipped in while converting.
    func lockShared() {
        mutex.withLock {
            guard fd >= 0 else { return }
            while flock(fd, LOCK_SH) != 0 && errno == EINTR {}
        }
    }

    /// Lets go (closing the descriptor). Safe to call more than once.
    func unlock() {
        mutex.withLock {
            guard fd >= 0 else { return }
            close(fd)
            fd = -1
        }
    }
}
