// dns-relay: the DNS server macOS uses while the tunnel is up (127.0.0.1:53, root, run by `dns.sh watch`).
//
// Each lookup goes to the VPN's resolver and to your network's resolver at the same time.
// - Allowlist off: answers come from the VPN resolver (like the AWS client); your network's answer
//   is only used when the VPN resolver fails or is slow.
// - Allowlist on: allowlisted names (and reverse lookups of VPN addresses) use the VPN resolver,
//   everything else your network's. The other one is the fallback.
// Either way, names that need the VPN are appended to dns-learned.log for the app:
// the VPN resolver returns an address inside the VPN routes, or only the VPN resolver knows the name.
//
//   dns-relay <run-dir>   reads <run-dir>/dns-relay.conf and <run-dir>/dns-allowlist, reloading on change.
import Darwin
import Dispatch

// MARK: Config

struct Route {
    let net: UInt32, mask: UInt32
    func contains(_ ip: UInt32) -> Bool { ip & mask == net & mask }
}

struct Config {
    /// dns-relay.conf: `vpn <ip>`, `upstream <ip>`, `route <network> <netmask>` lines.
    var vpn: [String] = []
    var upstream: [String] = []
    var routes: [Route] = []
    /// dns-allowlist: first line `on` or `off`, then one domain per line (matches it and its subdomains).
    var allowlistOn = false
    var allowlist: [String] = []

    func inRoutes(_ ip: UInt32) -> Bool { routes.contains { $0.contains(ip) } }

    func allowlisted(_ name: String) -> Bool {
        allowlist.contains { name == $0 || name.hasSuffix("." + $0) }
    }
}

let runDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/var/run/aws-autoconnect"
let confPath = runDir + "/dns-relay.conf"
let allowPath = runDir + "/dns-allowlist"
let learnedPath = runDir + "/dns-learned.log"
/// DNS_RELAY_PORT overrides the port, for testing without root.
let listenPort = getenv("DNS_RELAY_PORT").flatMap { UInt16(String(cString: $0)) } ?? 53

final class Store: @unchecked Sendable {
    private var lock = pthread_mutex_t()
    private var config = Config()
    private var stamps: (Int, Int) = (-1, -1)
    private var checkedAt: UInt64 = 0
    private var lastLogged: [String: UInt64] = [:]

    init() { pthread_mutex_init(&lock, nil) }

    /// Current config, reloading the files at most once a second when they changed.
    func current() -> Config {
        pthread_mutex_lock(&lock); defer { pthread_mutex_unlock(&lock) }
        let now = uptimeMs()
        if now - checkedAt > 1000 || checkedAt == 0 {
            checkedAt = now
            let s = (mtime(confPath), mtime(allowPath))
            if s != stamps {
                stamps = s
                config = load()
            }
        }
        return config
    }

    private func load() -> Config {
        var c = Config()
        for line in readLines(confPath) {
            let f = line.split(separator: " ").map(String.init)
            switch (f.first, f.count) {
            case ("vpn", 2): c.vpn.append(f[1])
            case ("upstream", 2) where !f[1].hasPrefix("127."): c.upstream.append(f[1])
            case ("route", 3):
                if let n = ipv4(f[1]), let m = ipv4(f[2]) { c.routes.append(Route(net: n, mask: m)) }
            default: break
            }
        }
        let allow = readLines(allowPath)
        c.allowlistOn = allow.first == "on"
        c.allowlist = allow.dropFirst().map(normalize).filter { !$0.isEmpty }
        return c
    }

    /// Appends `<epoch>\t<name>\t<reason>`, at most once a minute per name.
    func learned(_ name: String, _ reason: String) {
        pthread_mutex_lock(&lock); defer { pthread_mutex_unlock(&lock) }
        let now = uptimeMs()
        if let last = lastLogged[name], now - last < 60_000 { return }
        lastLogged[name] = now
        var st = stat()
        if stat(learnedPath, &st) == 0, st.st_size > 1 << 20 { unlink(learnedPath) }  // the app notices and starts over
        let fd = open(learnedPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let line = Array("\(time(nil))\t\(name)\t\(reason)\n".utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}

let store = Store()

// MARK: Resolving

enum Via { case vpn, upstream }

/// Answers one query through `reply` (called at most once). Over UDP both resolvers are asked at
/// once, which also feeds learning; over TCP (large answers) they are tried one after the other.
func resolve(_ query: [UInt8], tcp: Bool, reply: ([UInt8]) -> Void) {
    guard let q = Question(query) else { return }
    let c = store.current()
    let primary: Via = !c.allowlistOn || c.allowlisted(q.name) || reverseInRoutes(q.name, c) ? .vpn : .upstream
    let servers: (Via) -> [String] = { $0 == .vpn ? c.vpn : c.upstream }

    if tcp {
        for via in [primary, primary == .vpn ? .upstream : .vpn] {
            for s in servers(via).prefix(2) {
                if let r = exchangeTCP(query, server: s), usable(r) { return reply(r) }
            }
        }
        return
    }

    var socks: [(fd: Int32, via: Via)] = []
    for via in [Via.vpn, .upstream] {
        if let s = servers(via).first, let fd = udpSocket(to: s) { socks.append((fd, via)) }
    }
    defer { socks.forEach { close($0.fd) } }
    for s in socks { _ = query.withUnsafeBytes { send(s.fd, $0.baseAddress, $0.count, 0) } }

    var replies: [Via: [UInt8]] = [:]
    var answered: [UInt8]?
    let start = uptimeMs()
    let primaryWait: UInt64 = 1500, giveUp: UInt64 = 4000
    var pending = socks
    while !pending.isEmpty {
        let elapsed = uptimeMs() - start
        if elapsed >= giveUp { break }
        var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
        // Wake up at the primary deadline to consider the fallback answer.
        let wake = answered == nil && elapsed < primaryWait ? primaryWait - elapsed : giveUp - elapsed
        if poll(&fds, nfds_t(fds.count), Int32(wake)) < 0 { break }
        for (i, p) in fds.enumerated() where p.revents != 0 {
            var buf = [UInt8](repeating: 0, count: 65535)
            let n = recv(p.fd, &buf, buf.count, 0)
            if n >= 12, buf[0] == query[0], buf[1] == query[1], buf[2] & 0x80 != 0 {
                replies[pending[i].via] = Array(buf[0..<n])
            }
            pending[i].fd = -1
        }
        pending.removeAll { $0.fd == -1 }

        if answered == nil {
            let fallback: Via = primary == .vpn ? .upstream : .vpn
            if let r = replies[primary], usable(r) || replies[fallback] == nil && pending.isEmpty {
                answered = r
            } else if let f = replies[fallback], usable(f),
                      replies[primary] != nil || uptimeMs() - start >= primaryWait || pending.isEmpty {
                answered = f
            }
            if let a = answered { reply(a) }
        }
        // Keep listening briefly after answering so both replies can be compared.
        if answered != nil, uptimeMs() - start > 2500 { break }
    }
    if answered == nil, let r = replies[primary] ?? replies.values.first { reply(r) }
    learn(q, vpn: replies[.vpn], upstream: replies[.upstream], config: c)
}

func usable(_ reply: [UInt8]) -> Bool {
    let rcode = reply[3] & 0x0f
    return rcode == 0 || rcode == 3  // NOERROR or NXDOMAIN; SERVFAIL/REFUSED fall back
}

func learn(_ q: Question, vpn: [UInt8]?, upstream: [UInt8]?, config c: Config) {
    guard let vpn, !q.name.hasSuffix(".arpa"), !q.name.hasSuffix(".local"), q.name.contains(".") else { return }
    let answers = Answers(vpn)
    if let ip = answers.ipv4.first(where: c.inRoutes) {
        store.learned(q.name, formatIPv4(ip))
    } else if answers.rcode == 0, answers.count > 0, let upstream {
        let up = Answers(upstream)
        if up.rcode == 3 || (up.rcode == 0 && up.count == 0) { store.learned(q.name, "only on VPN DNS") }
    }
}

/// `4.3.2.10.in-addr.arpa` for an address inside the VPN routes.
func reverseInRoutes(_ name: String, _ c: Config) -> Bool {
    guard name.hasSuffix(".in-addr.arpa") else { return false }
    let parts = name.dropLast(".in-addr.arpa".count).split(separator: ".")
    guard parts.count == 4, let ip = ipv4(parts.reversed().joined(separator: ".")) else { return false }
    return c.inRoutes(ip)
}

// MARK: DNS messages

struct Question {
    let name: String
    init?(_ msg: [UInt8]) {
        guard msg.count >= 12, msg[4] == 0, msg[5] >= 1 else { return nil }
        var off = 12
        guard let n = readName(msg, &off), off + 4 <= msg.count else { return nil }
        name = n
    }
}

struct Answers {
    var rcode: UInt8 = 2
    var count = 0
    var ipv4: [UInt32] = []

    init(_ msg: [UInt8]) {
        guard msg.count >= 12 else { return }
        rcode = msg[3] & 0x0f
        let qd = Int(msg[4]) << 8 | Int(msg[5])
        count = Int(msg[6]) << 8 | Int(msg[7])
        var off = 12
        for _ in 0..<qd {
            guard readName(msg, &off) != nil, off + 4 <= msg.count else { return }
            off += 4
        }
        for _ in 0..<count {
            guard readName(msg, &off) != nil, off + 10 <= msg.count else { return }
            let type = Int(msg[off]) << 8 | Int(msg[off + 1])
            let len = Int(msg[off + 8]) << 8 | Int(msg[off + 9])
            off += 10
            guard off + len <= msg.count else { return }
            if type == 1, len == 4 {
                ipv4.append(UInt32(msg[off]) << 24 | UInt32(msg[off + 1]) << 16 | UInt32(msg[off + 2]) << 8 | UInt32(msg[off + 3]))
            }
            off += len
        }
    }
}

/// Reads a (possibly compressed) name at `off`, leaving `off` just past it. Lowercased, no trailing dot.
func readName(_ msg: [UInt8], _ off: inout Int) -> String? {
    var labels: [String] = []
    var pos = off, jumped = false, hops = 0
    while true {
        guard pos < msg.count else { return nil }
        let len = Int(msg[pos])
        if len == 0 { pos += 1; break }
        if len & 0xc0 == 0xc0 {
            guard pos + 1 < msg.count, hops < 32 else { return nil }
            if !jumped { off = pos + 2 }
            jumped = true
            hops += 1
            pos = (len & 0x3f) << 8 | Int(msg[pos + 1])
            continue
        }
        guard len < 64, pos + 1 + len <= msg.count else { return nil }
        labels.append(String(decoding: msg[(pos + 1)..<(pos + 1 + len)], as: UTF8.self).lowercased())
        pos += 1 + len
    }
    if !jumped { off = pos }
    return labels.joined(separator: ".")
}

// MARK: Sockets

func sockaddr(for host: String, port: UInt16) -> (sockaddr_storage, socklen_t, Int32)? {
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(res) }
    var ss = sockaddr_storage()
    memcpy(&ss, ai.pointee.ai_addr, Int(ai.pointee.ai_addrlen))
    return (ss, ai.pointee.ai_addrlen, ai.pointee.ai_family)
}

func udpSocket(to server: String) -> Int32? {
    guard let (addr, len, family) = sockaddr(for: server, port: 53) else { return nil }
    var ss = addr
    let fd = socket(family, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    let ok = withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
    if ok != 0 { close(fd); return nil }
    return fd
}

func exchangeTCP(_ query: [UInt8], server: String) -> [UInt8]? {
    guard let (addr, len, family) = sockaddr(for: server, port: 53) else { return nil }
    var ss = addr
    let fd = socket(family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let r = withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
    if r != 0 {
        guard errno == EINPROGRESS else { return nil }
        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var err: Int32 = 0, errLen = socklen_t(4)
        guard poll(&p, 1, 3000) == 1, getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen) == 0, err == 0 else { return nil }
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    setTimeout(fd, seconds: 4)
    guard writeAll(fd, [UInt8(query.count >> 8), UInt8(query.count & 0xff)] + query) else { return nil }
    return readMessage(fd)
}

func readMessage(_ fd: Int32) -> [UInt8]? {
    guard let head = readExactly(fd, 2) else { return nil }
    return readExactly(fd, Int(head[0]) << 8 | Int(head[1]))
}

func readExactly(_ fd: Int32, _ n: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: n), got = 0
    while got < n {
        let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
        if r <= 0 { return nil }
        got += r
    }
    return buf
}

func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
    var sent = 0
    while sent < data.count {
        let r = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
        if r <= 0 { return false }
        sent += r
    }
    return true
}

func setTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func listener(_ type: Int32) -> Int32 {
    let fd = socket(AF_INET, type, 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
    var sa = sockaddr_in()
    sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sa.sin_family = sa_family_t(AF_INET)
    sa.sin_port = in_port_t(listenPort).bigEndian
    sa.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &sa) {
        $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if fd < 0 || ok != 0 { fail("cannot listen on 127.0.0.1:\(listenPort): \(String(cString: strerror(errno)))") }
    if type == SOCK_STREAM { listen(fd, 16) }
    return fd
}

// MARK: Helpers

func uptimeMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

func mtime(_ path: String) -> Int {
    var st = stat()
    return stat(path, &st) == 0 ? st.st_mtimespec.tv_sec * 1_000_000_000 + st.st_mtimespec.tv_nsec : -1
}

func readLines(_ path: String) -> [String] {
    guard let f = fopen(path, "r") else { return [] }
    defer { fclose(f) }
    var lines: [String] = []
    var buf: UnsafeMutablePointer<CChar>?
    var cap = 0
    while getline(&buf, &cap, f) > 0, let b = buf, lines.count < 10_000 {
        let line = String(cString: b).trimmingWhitespace()
        if !line.isEmpty { lines.append(line) }
    }
    free(buf)
    return lines
}

func normalize(_ domain: String) -> String {
    var d = domain.lowercased()
    while d.hasPrefix("*.") || d.hasPrefix(".") { d.removeFirst(d.hasPrefix("*.") ? 2 : 1) }
    while d.hasSuffix(".") { d.removeLast() }
    return d
}

func ipv4(_ s: String) -> UInt32? {
    var a = in_addr()
    return inet_pton(AF_INET, s, &a) == 1 ? UInt32(bigEndian: a.s_addr) : nil
}

func formatIPv4(_ ip: UInt32) -> String {
    "\(ip >> 24).\(ip >> 16 & 0xff).\(ip >> 8 & 0xff).\(ip & 0xff)"
}

extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let c = s.first, c.isWhitespace { s.removeFirst() }
        while let c = s.last, c.isWhitespace { s.removeLast() }
        return String(s)
    }
}

func fail(_ msg: String) -> Never {
    fputs("dns-relay: \(msg)\n", stderr)
    exit(1)
}

// MARK: Main

signal(SIGPIPE, SIG_IGN)
let udp = listener(SOCK_DGRAM)
let tcp = listener(SOCK_STREAM)
_ = store.current()
// dns.sh waits for this before pointing macOS at the relay.
let ready = open(runDir + "/dns-relay.ready", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
if ready >= 0 { let pid = Array("\(getpid())\n".utf8); _ = pid.withUnsafeBytes { write(ready, $0.baseAddress, $0.count) }; close(ready) }
print("dns-relay: listening on 127.0.0.1:\(listenPort)")
fflush(stdout)

DispatchQueue(label: "tcp").async {
    while true {
        let conn = accept(tcp, nil, nil)
        guard conn >= 0 else { continue }
        DispatchQueue.global().async {
            defer { close(conn) }
            setTimeout(conn, seconds: 10)
            while let q = readMessage(conn) {
                var ok = false
                resolve(q, tcp: true) { r in ok = writeAll(conn, [UInt8(r.count >> 8), UInt8(r.count & 0xff)] + r) }
                if !ok { return }
            }
        }
    }
}

while true {
    var buf = [UInt8](repeating: 0, count: 4096)
    var from = sockaddr_storage()
    var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let n = withUnsafeMutablePointer(to: &from) {
        $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { recvfrom(udp, &buf, buf.count, 0, $0, &fromLen) }
    }
    guard n >= 12 else { continue }
    let query = Array(buf[0..<n])
    let client = from, clientLen = fromLen
    DispatchQueue.global().async {
        var to = client
        resolve(query, tcp: false) { r in
            _ = withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { p in
                    r.withUnsafeBytes { sendto(udp, $0.baseAddress, $0.count, 0, p, clientLen) }
                }
            }
        }
    }
}
