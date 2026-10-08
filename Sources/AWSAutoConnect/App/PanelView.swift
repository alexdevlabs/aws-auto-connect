import SwiftUI

/// The menu bar dropdown: the overall state and one row per connector. Settings slides in from the
/// right, with a tab per page.
struct PanelView: View {
    let model: AppModel

    var body: some View {
        let settings = model.showingSettings
        VStack(spacing: 0) {
            // Old and new content overlap in a ZStack while sliding, clipped to the panel's width.
            ZStack(alignment: .top) {
                if settings {
                    SettingsPane(model: model)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                } else {
                    StatusPane(model: model)
                        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
                }
            }
            .frame(width: 380)
            .clipped()

            Divider()
            HStack {
                if settings {
                    Text("AWS Auto Connect \(version)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Settings") { model.openSettings(nil) }
                        .keyboardShortcut(",")
                    Text(version).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 380)
    }

    private var version: String {
        "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
    }
}

private struct StatusPane: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("AWS Auto Connect").font(.headline)
                DevBadge()
                Spacer()
            }
            .padding([.horizontal, .top], 14)

            StatusSection(model: model)
                .padding(14)
        }
    }
}

/// Settings: a back button, a tab per page, and the open tab's page.
private struct SettingsPane: View {
    let model: AppModel
    @AppStorage(Prefs.Key.settingsPage.rawValue) private var selection = "general"

    var body: some View {
        let pages = model.settingsPages
        let current = pages.first { $0.id == selection } ?? pages[0]
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.closeSettings() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(",")
                .help("Back (Esc)")
                Text("Settings").font(.headline)
                DevBadge()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            SegmentedControl(items: pages.map { .init(id: $0.id, label: $0.title, detail: $0.badge) },
                             selection: Binding(get: { current.id }, set: { selection = $0 }))
                .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                if let connector = model.connector(forPage: current.id) {
                    ConnectorHeader(connector: connector)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }
                current.view
            }
            .frame(height: current.height)
            .id(current.id)
        }
    }
}

/// The top of a connector's tab: the same status and actions as its row on the status view.
private struct ConnectorHeader: View {
    let connector: any Connector

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            HStack(spacing: 10) {
                ConnectorTile(symbol: connector.symbol, health: connector.status.health)
                VStack(alignment: .leading, spacing: 1) {
                    Text(type(of: connector).displayName).font(.subheadline.weight(.semibold))
                    Text(connector.status.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                ForEach(connector.actions) { action in
                    Button(action.title) { Task { await action.run() } }.disabled(!action.enabled)
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct DevBadge: View {
    var body: some View {
        #if DEV
        Text("DEV")
            .font(.caption2.weight(.medium)).foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.orange.opacity(0.15), in: Capsule())
            .help("Built with make dev")
        #endif
    }
}

private struct StatusSection: View {
    let model: AppModel

    var body: some View {
        // Re-render periodically so "time left" stays current while open.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 10) {
                if let summary = model.summary {
                    Toast(summary: summary, fix: fix(for: summary))
                } else {
                    Text("Nothing to keep connected. Turn on a connector in Settings.")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if !model.online { OfflineStrip() }
                UpdateStrip(updater: model.updater)
                if !model.connectors.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(model.connectors.enumerated()), id: \.element.config.id) { i, c in
                            if i > 0 { Divider().padding(.leading, 46) }
                            ConnectorRow(connector: c) {
                                model.openSettings(c.settingsPages.first?.id)
                            }
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    private func fix(for summary: StatusSummary) -> ConnectorAction? {
        switch summary.fix {
        case .signIn: return ConnectorAction(title: "Sign In…") { model.showSignIn() }
        case .action(let i): return model.connectors.indices.contains(i) ? model.connectors[i].actions.first : nil
        case .notice(let i): return model.connectors.indices.contains(i) ? model.connectors[i].notice?.action : nil
        case nil: return nil
        }
    }
}

/// Colours shared by the toast, the rows and the connector tabs (and the menu bar dot).
extension ConnectorStatus.Health {
    var tint: Color {
        switch self {
        case .ok: return .green
        case .busy: return .yellow
        case .attention: return .red
        case .idle: return .gray
        }
    }
}

private struct Toast: View {
    let summary: StatusSummary
    let fix: ConnectorAction?

    var body: some View {
        let tint = summary.health.tint
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)
                .background(Circle().fill(tint.opacity(0.25)).frame(width: 16, height: 16))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.title).font(.system(size: 14)).lineLimit(2)
                if let detail = summary.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let fix {
                Button(fix.title) { Task { await fix.run() } }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(!fix.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(summary.health == .idle ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(tint.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

/// Shown while there's an update to offer, it's installing, or installing failed.
/// Shown while the Mac has no network: checks and reconnects wait for it instead of failing.
private struct OfflineStrip: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash").foregroundStyle(.secondary)
            Text("Offline. Checks will resume when the network is back.").font(.caption).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UpdateStrip: View {
    let updater: Updater

    var body: some View {
        if let release = updater.release {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(isFailed ? Color.red : Color.accentColor)
                Text(text(release)).font(.caption).lineLimit(2)
                    .help(updater.homebrewApp == nil ? "Update with \(updater.manualHint)." : "")
                Spacer(minLength: 6)
                Button("Notes") { updater.openNotes() }.buttonStyle(.borderless).font(.caption)
                if updater.homebrewApp != nil, !updater.isUpdating {
                    Button(isFailed ? "Retry" : "Update") { Task { await updater.install(release) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var isFailed: Bool { if case .failed = updater.state { return true } else { return false } }

    private func text(_ r: Updater.Release) -> String {
        switch updater.state {
        case .updating(_, let step): return "Updating to v\(r.version): \(step)…"
        case .failed(_, let message): return message
        default: return "v\(r.version) is ready"
        }
    }
}

/// A rounded tile with the connector's symbol, filled with its health colour.
struct ConnectorTile: View {
    let symbol: String
    let health: ConnectorStatus.Health?
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(health.map { $0 == .idle ? Color.gray.opacity(0.6) : $0.tint } ?? .accentColor)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
    }
}

private struct ConnectorRow: View {
    let connector: any Connector
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ConnectorTile(symbol: connector.symbol, health: connector.status.health)
            VStack(alignment: .leading, spacing: 1) {
                Text(type(of: connector).displayName).font(.subheadline.weight(.semibold))
                Text(connector.status.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(connector.actions) { action in
                    Button(action.title) { Task { await action.run() } }.disabled(!action.enabled)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help("Open its settings")
    }
}
