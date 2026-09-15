import Foundation

/// The two things every store shared between processes needs.
///
/// The menu bar app, every `portnanny` command, and every `portnanny mcp`
/// server an agent keeps running all read and write the same preference
/// domain. UserDefaults is not transactional across processes, so a
/// read-modify-write needs a lock the other processes also take, and the
/// stored JSON has to survive one entry nobody can read.
public enum SharedStore {

    /// An advisory `flock` on a file every process of this user can see.
    ///
    /// `NSTemporaryDirectory()` resolves to the per-user temporary folder
    /// and ignores a `TMPDIR` the caller set, so an agent running with its
    /// own `TMPDIR` still takes the same lock. The kernel drops the lock
    /// when its holder exits, so a process that crashes mid-write cannot
    /// wedge everyone else.
    public struct Lock {
        let path: String

        /// `name` identifies what is being guarded, in which domain: two
        /// stores in one domain get separate locks so neither waits on the
        /// other's writes.
        public init(name: String) {
            let safeName = name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
            path = (NSTemporaryDirectory() as NSString).appendingPathComponent("portnanny-\(String(safeName)).lock")
        }

        public func withLock<T>(_ body: () throws -> T) rethrows -> T {
            let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            // A lock file that cannot be opened means the temporary folder is
            // gone or unwritable. Writing without exclusion risks losing an
            // entry to a racing process; refusing to write would lose it for
            // certain. The rarer loss is the better one.
            guard descriptor >= 0 else { return try body() }
            defer { close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                // Only a signal interrupts a blocking flock; anything else
                // means the lock cannot be had, and the same reasoning applies.
                guard errno == EINTR else { return try body() }
            }
            defer { flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    /// Decodes a JSON array one element at a time, keeping the ones that decode.
    ///
    /// Decoding `[T]` in one step fails the whole array when a single element
    /// is damaged. The stores then saw nothing at all, and the next write
    /// saved that empty list over every good entry: one lease with a mangled
    /// date made every lease vanish, let another agent take a leased port,
    /// and erased the rest on the next reservation.
    ///
    /// Returns `nil` only when the data is not a JSON array at all, so a caller
    /// can tell "nothing stored" from "stored, but some of it unreadable".
    public static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data) -> [T]? {
        guard let elements = try? JSONDecoder().decode([Salvaged<T>].self, from: data) else { return nil }
        return elements.compactMap(\.value)
    }

    /// One array element, or nothing if it does not decode.
    private struct Salvaged<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}
