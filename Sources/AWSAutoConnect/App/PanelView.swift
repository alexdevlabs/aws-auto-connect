import SwiftUI

/// Everything the app has, in the menu bar dropdown: status, actions and settings.
struct PanelView: View {
    let model: AppModel
    // --tab=<title> opens a given tab, e.g. --tab=DNS (debug aid with --show-panel).
    @State private var tab: String = CommandLine.arguments.lazy
        .compactMap { $0.hasPrefix("--tab=") ? String($0.dropFirst(6)) : nil }
        .first ?? "Status"
    /// Which way the content slides: forward (to a tab on the right) comes in from the right.
    @State private var forward = true

    /// Status, then each enabled connector's tabs (first one of each type), then General.
    private var tabs: [SettingsTab] {
        var seen = Set<String>()
        let connectorTabs = model.connectors
            .filter { seen.insert(type(of: $0).type).inserted }
            .flatMap(\.settingsTabs)
        return [SettingsTab("Status", height: 0) { StatusSection(model: model) }]
            + connectorTabs
            + [SettingsTab("General", height: 400) { GeneralSettings(model: model) }]
    }

    private var tabSelection: Binding<String> {
        Binding(get: { tab }, set: { new in
            let order = tabs.map(\.title)
            forward = (order.firstIndex(of: new) ?? 0) > (order.firstIndex(of: tab) ?? 0)
            withAnimation(.snappy(duration: 0.3)) { tab = new }
        })
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                    removal: .move(edge: forward ? .leading : .trailing))
    }

    var body: some View {
        let tabs = tabs
        let current = tabs.first { $0.title == tab } ?? tabs[0]
        // Wider when a connector adds a sixth tab, so the labels still fit.
        let width: CGFloat = tabs.count > 5 ? 400 : 340
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("AWS AutoConnect").font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], 14)

            Picker("", selection: tabSelection) {
                ForEach(tabs) { Text($0.title).tag($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Old and new content overlap in a ZStack while sliding, clipped to the panel's width.
            ZStack(alignment: .top) {
                Group {
                    if current.height == 0 {
                        current.view.padding(.horizontal, 14).padding(.bottom, 12)
                    } else {
                        current.view.frame(height: current.height)
                    }
                }
                .frame(width: width)
                .id(current.title)
                .transition(slide)
            }
            .clipped()

            Divider()
            HStack {
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: width)
    }
}

private struct StatusSection: View {
    let model: AppModel

    var body: some View {
        // Re-render periodically so "time left" stays current while open.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 8) {
                if model.signInNeeded {
                    StatusRow(icon: "exclamationmark.triangle.fill", tint: .red, title: "Sign-in needed",
                              detail: "\(model.browser.waitingProvider ?? "Your provider") wants you to sign in again") {
                        Button("Open") { model.showSignIn() }
                    }
                }
                UpdateRow(updater: model.updater)
                if model.connectors.isEmpty {
                    Text("Nothing to keep connected. Turn on a connector in General.")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(model.connectors, id: \.config.id) { c in
                    StatusRow(icon: c.symbol, tint: Self.tint(c.status.health), title: c.title, detail: c.status.summary) {
                        HStack(spacing: 6) {
                            ForEach(c.actions) { action in
                                Button(action.title) { Task { await action.run() } }.disabled(!action.enabled)
                            }
                        }
                    }
                }
            }
        }
    }

    static func tint(_ health: ConnectorStatus.Health) -> Color {
        switch health {
        case .ok: return .green
        case .busy: return .yellow
        case .attention: return .red
        case .idle: return .secondary
        }
    }
}

/// Shown while there's an update to offer, it's installing, or installing failed.
private struct UpdateRow: View {
    let updater: Updater

    var body: some View {
        if let release = updater.release {
            StatusRow(icon: "arrow.down.circle.fill", tint: tint, title: title(release), detail: detail(release)) {
                HStack(spacing: 6) {
                    Button("Notes") { updater.openNotes() }
                    if updater.homebrewApp != nil, !updater.isUpdating {
                        Button(isFailed ? "Retry" : "Update") { Task { await updater.install(release) } }
                    }
                }
            }
        }
    }

    private var isFailed: Bool { if case .failed = updater.state { return true } else { return false } }
    private var tint: Color { isFailed ? .red : updater.isUpdating ? .yellow : .accentColor }

    private func title(_ r: Updater.Release) -> String {
        updater.isUpdating ? "Updating to v\(r.version)" : "Update available: v\(r.version)"
    }

    private func detail(_ r: Updater.Release) -> String {
        switch updater.state {
        case .updating(_, let step): return step + "…"
        case .failed(_, let message): return message
        default:
            return updater.homebrewApp != nil
                ? "You have v\(Updater.current). The VPN reconnects after the restart."
                : "You have v\(Updater.current). Update with \(updater.manualHint)."
        }
    }
}

private struct StatusRow<Action: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            action().controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
