import Foundation

/// Asks the kernel about a port with real sockets, then closes them.
///
/// The listener table cannot see sockets owned by another user: Postgres
/// running as `_postgres`, anything started with `sudo`, a system daemon.
/// Without this, `portnanny free 5432` reported a port as free that no
/// server could then bind.
///
/// Measured on macOS, which is why every probe sets `SO_REUSEADDR` and tries
/// four addresses:
/// - Without `SO_REUSEADDR`, a port left in TIME_WAIT by a closed connection
///   fails to bind, so a usable port read as taken.
/// - A listener on `127.0.0.1` alone is only visible to a `127.0.0.1` probe
///   once `SO_REUSEADDR` is set; the same holds for `::1`.
/// - A privileged port answers `EACCES` rather than `EADDRINUSE` on a
///   loopback address even when it is free, so only `EADDRINUSE` means held.
///
/// One known blind spot, also measured: another user's listener bound to a
/// single LAN address (say `192.168.0.83` alone) reads as free, because
/// `SO_REUSEADDR` lets a wildcard bind share the port with it.
enum PortProbe {

    /// True when something is listening on the port, whoever owns it.
    static func isHeld(_ port: Int) -> Bool {
        guard let port = in_port_t(exactly: port), port > 0 else { return false }
        return addresses.contains { bind(port, family: $0.family, address: $0.address) == EADDRINUSE }
    }

    /// True when a server started now could take the port: nothing holds it,
    /// and this user may bind it at all.
    static func canBind(_ port: Int) -> Bool {
        guard let number = in_port_t(exactly: port), number > 0, !isHeld(port) else { return false }
        return bind(number, family: AF_INET, address: "0.0.0.0") == 0
    }

    private static let addresses: [(family: Int32, address: String)] = [
        (AF_INET, "0.0.0.0"), (AF_INET, "127.0.0.1"), (AF_INET6, "::"), (AF_INET6, "::1"),
    ]

    /// 0 when the bind succeeded, otherwise its errno. A socket that could not
    /// be created at all reports EMFILE-style errors rather than EADDRINUSE,
    /// so running out of descriptors never makes a free port look held.
    private static func bind(_ port: in_port_t, family: Int32, address: String) -> Int32 {
        let socketFD = socket(family, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return errno }
        defer { close(socketFD) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let result: Int32
        if family == AF_INET {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = port.bigEndian
            inet_pton(AF_INET, address, &sin.sin_addr)
            result = withUnsafePointer(to: &sin) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = port.bigEndian
            inet_pton(AF_INET6, address, &sin6.sin6_addr)
            // Without this an IPv6 wildcard also claims IPv4, and would report
            // an IPv4-only listener twice over.
            var v6only: Int32 = 1
            setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))
            result = withUnsafePointer(to: &sin6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        return result == 0 ? 0 : errno
    }
}
