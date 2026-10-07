/// The toast at the top of the panel: the overall state in a few words, and when something needs you,
/// what and the one button that fixes it.
struct StatusSummary: Equatable {
    struct Row {
        /// "AWS Client VPN"
        let name: String
        /// "VPN"
        let short: String
        let status: ConnectorStatus
        let isTunnel: Bool
        var notice: String?
    }

    enum Fix: Equatable {
        case signIn
        /// The first action of the connector at this index.
        case action(Int)
        /// The notice's action of the connector at this index.
        case notice(Int)
    }

    var health: ConnectorStatus.Health
    var title: String
    var detail: String?
    var fix: Fix?

    /// Nil when there are no connectors. `signInProvider` is set while a flow waits on a sign-in page.
    static func make(_ rows: [Row], signInProvider: String?) -> StatusSummary? {
        if let provider = signInProvider {
            return .init(health: .attention, title: "\(provider) wants you to sign in",
                         detail: "Connections are waiting on it", fix: .signIn)
        }
        if let i = rows.firstIndex(where: { $0.status.health == .attention }) {
            return .init(health: .attention, title: rows[i].status.summary, detail: rows[i].name, fix: .action(i))
        }
        if let busy = rows.first(where: { $0.status.health == .busy }) {
            return .init(health: .busy, title: busy.status.summary)
        }
        if let i = rows.firstIndex(where: { $0.notice != nil }) {
            return .init(health: .busy, title: rows[i].notice!, detail: rows[i].name, fix: .notice(i))
        }
        if let tunnel = rows.first(where: { $0.isTunnel && $0.status.health == .idle }) {
            return .init(health: .idle, title: "\(tunnel.short) off")
        }
        if rows.contains(where: { $0.status.health == .ok }) {
            return .init(health: .ok, title: "All connected")
        }
        return rows.isEmpty ? nil : .init(health: .idle, title: "Waiting")
    }
}
