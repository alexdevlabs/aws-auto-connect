import Foundation
import Observation

/// Domains that needed the VPN (learned by dns-relay while the tunnel is up) and the DNS allowlist
/// the relay follows when it's turned on.
@MainActor
@Observable
final class VPNDomains {
    struct Entry: Codable, Identifiable {
        let name: String
        /// The VPN address it resolved to, or "only on VPN DNS".
        var reason: String
        var count: Int
        var first: Date
        var last: Date
        var id: String { name }
    }

    /// Newest first.
    private(set) var learned: [Entry] = []
    var allowlistOn: Bool {
        didSet { onChange?(allowlistOn, allowlist); push() }
    }
    private(set) var allowlist: [String] {
        didSet { onChange?(allowlistOn, allowlist); push() }
    }
    /// Saves the toggle and list (the connector keeps them in its settings).
    @ObservationIgnored var onChange: ((Bool, [String]) -> Void)?
    private(set) var scanStatus: String?

    static let logPath = "/var/run/aws-autoconnect/dns-learned.log"
    static var relayInstalled: Bool { FileManager.default.isExecutableFile(atPath: VPNHelper.dir + "/dns-relay") }

    @ObservationIgnored private let log = AppLog("dns")
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var inode: UInt64 = 0
    @ObservationIgnored private var storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AWSAutoConnect/vpn-domains.json")

    private struct Stored: Codable {
        var offset: UInt64
        var inode: UInt64
        var entries: [Entry]
    }

    /// False for a test instance (one with its own `storeURL`), so tests never change the relay.
    @ObservationIgnored private let sendsToRelay: Bool

    init(allowlistOn: Bool, allowlist: [String], storeURL: URL? = nil) {
        self.allowlistOn = allowlistOn
        self.allowlist = allowlist
        sendsToRelay = storeURL == nil
        if let storeURL { self.storeURL = storeURL }
        if let data = try? Data(contentsOf: self.storeURL), let s = try? JSONDecoder().decode(Stored.self, from: data) {
            offset = s.offset
            inode = s.inode
            learned = s.entries.sorted { $0.last > $1.last }
        }
    }

    // MARK: Allowlist

    func isAllowed(_ name: String) -> Bool {
        allowlist.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    /// Adds a domain (covers its subdomains too). Accepts "*.foo.com" and ".foo.com".
    func allow(_ raw: String) {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while d.hasPrefix("*.") || d.hasPrefix(".") { d.removeFirst(d.hasPrefix("*.") ? 2 : 1) }
        while d.hasSuffix(".") { d.removeLast() }
        guard d.contains("."), d.range(of: #"^[a-z0-9_.-]+$"#, options: .regularExpression) != nil,
              !allowlist.contains(d) else { return }
        allowlist = (allowlist.filter { $0 != d && !$0.hasSuffix("." + d) } + [d]).sorted()
    }

    func remove(_ domain: String) { allowlist.removeAll { $0 == domain } }

    /// Stops allowing these names: takes out every entry that covers one of them, i.e. the name
    /// itself or a parent domain (which also stops allowing that parent's other names).
    func disallow(_ names: [String]) { allowlist = Self.allowlist(allowlist, without: names) }

    static func allowlist(_ list: [String], without names: [String]) -> [String] {
        let names = names.map { $0.lowercased() }
        return list.filter { d in !names.contains { $0 == d || $0.hasSuffix("." + d) } }
    }

    func disallowAll() { allowlist = [] }

    func allowAllLearned() {
        for e in learned where !isAllowed(e.name) { allow(e.name) }
    }

    /// Like the row's "*.parent" choice, for every learned name not yet allowed.
    func allowAllLearnedSubdomains() {
        for d in Self.subdomainWildcards(for: learned.map(\.name).filter { !isAllowed($0) }) { allow(d) }
    }

    /// The parent of each name ("api.svc.corp.com" → "svc.corp.com"), or the name itself when the
    /// parent would be too broad; without duplicates or entries another one already covers.
    static func subdomainWildcards(for names: [String]) -> [String] {
        let wanted = Set(names.map { parent(of: $0.lowercased()) ?? $0.lowercased() })
        return wanted.filter { d in !wanted.contains { d.hasSuffix("." + $0) } }.sorted()
    }

    /// "api.svc.corp.com" → "svc.corp.com"; nil when that would be too broad.
    static func parent(of name: String) -> String? {
        let labels = name.split(separator: ".")
        return labels.count >= 3 ? labels.dropFirst().joined(separator: ".") : nil
    }

    /// The domain a learned name is listed under in Settings, whose "Allow" covers the whole group:
    /// the last two labels ("api.svc.corp.com" → "corp.com"). Under a domain many companies share
    /// (amazonaws.com, co.uk) that would be far too broad, so those group by their parent instead.
    static func group(of name: String) -> String {
        let labels = name.lowercased().split(separator: ".")
        guard labels.count > 2 else { return name.lowercased() }
        let base = labels.suffix(2).joined(separator: ".")
        guard sharedDomains.contains(base) else { return base }
        return labels.count > 3 ? labels.dropFirst().joined(separator: ".") : name.lowercased()
    }

    private static let sharedDomains: Set<String> = [
        "amazonaws.com", "cloudfront.net", "azurewebsites.net", "cloudapp.net",
        "googleapis.com", "appspot.com", "herokuapp.com",
        "co.uk", "org.uk", "com.au", "co.jp", "co.nz", "com.br", "co.in",
    ]

    private func push() { Task { await sync() } }

    @ObservationIgnored private var syncing: Task<Void, Never>?
    /// What the relay has, or is being sent, as `send()` writes it.
    @ObservationIgnored private var sent: String?
    private var current: String { (allowlistOn ? "on" : "off") + "\n" + allowlist.map { $0 + "\n" }.joined() }

    /// Sends the toggle and list to the relay, which reloads them within a second. Also run before connecting.
    /// One send at a time, so an older list can't land after a newer one; changes made during a
    /// send go out right after it.
    func sync() async {
        if let syncing { return await syncing.value }
        let task = Task {
            repeat { await send(current) } while sent != current
            syncing = nil
        }
        syncing = task
        await task.value
    }

    private func send(_ text: String) async {
        sent = text
        guard sendsToRelay, VPNHelper.isInstalled, Self.relayInstalled else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aws-autoconnect-allowlist-\(UUID().uuidString)")
        try? Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let r = await Shell.run("/usr/bin/sudo", ["-n", VPNHelper.helper, "dns-config", file.path], timeout: 15)
        if r.status != 0 { log.error("dns-config failed: \(r.lastLine)") }
    }

    // MARK: Learned

    /// Reads what the relay appended since last time (`<epoch>\t<name>\t<reason>` lines).
    func ingest() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: Self.logPath),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let node = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { return }
        if node != inode || size < offset { inode = node; offset = 0 }  // rotated or a new boot
        guard size > offset, let h = FileHandle(forReadingAtPath: Self.logPath) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)

        var byName = Dictionary(uniqueKeysWithValues: learned.map { ($0.name, $0) })
        for line in String(decoding: complete, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard f.count == 3, let epoch = TimeInterval(f[0]) else { continue }
            let when = Date(timeIntervalSince1970: epoch)
            if var e = byName[f[1]] {
                e.count += 1
                e.reason = f[2]
                e.last = max(e.last, when)
                byName[f[1]] = e
            } else {
                byName[f[1]] = Entry(name: f[1], reason: f[2], count: 1, first: when, last: when)
            }
        }
        learned = byName.values.sorted { $0.last > $1.last }
        save()
    }

    func forget(_ name: String) {
        learned.removeAll { $0.name == name }
        save()
    }

    func clearLearned() {
        learned = []
        save()
    }

    private func save() {
        let s = Stored(offset: offset, inode: inode, entries: learned)
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: storeURL, options: .atomic)
    }

    // MARK: Config scan

    /// Looks up the hostnames in ~/.ssh/config, ~/.kube/config and ~/.aws/config through the relay,
    /// which records the ones that need the VPN. Needs the tunnel up.
    func scanConfigFiles() async {
        let hosts = Self.configHostnames()
        guard !hosts.isEmpty else { scanStatus = "No hostnames found in the config files"; return }
        let before = learned.count
        scanStatus = "Checking \(hosts.count) hostnames…"
        await withTaskGroup(of: Void.self) { group in
            for host in hosts {
                group.addTask { _ = await Shell.run("/usr/bin/dig", ["+time=2", "+tries=1", "@127.0.0.1", host, "A"], timeout: 5) }
            }
        }
        try? await Task.sleep(for: .seconds(3))  // the relay waits for both resolvers before recording
        ingest()
        scanStatus = "Checked \(hosts.count) hostnames, \(learned.count - before) new"
    }

    nonisolated static func configHostnames() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func read(_ path: String) -> String { (try? String(contentsOf: home.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        var found = Set<String>()
        for line in read(".ssh/config").split(separator: "\n") {
            let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let key = f.first?.lowercased(), key == "hostname" || key == "host" else { continue }
            found.formUnion(f.dropFirst())
        }
        let urlPattern = #"(?:server|endpoint_url)\s*[:=]\s*\S*?://([A-Za-z0-9.-]+)"#
        for text in [read(".kube/config"), read(".aws/config")] {
            let regex = try! NSRegularExpression(pattern: urlPattern)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { found.insert(String(text[r])) }
            }
        }
        return found.map { $0.lowercased() }
            .filter { $0.contains(".") && !$0.contains("*") && !$0.contains("?") && $0.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil }
            .sorted()
    }
}
