import SwiftUI

/// Everything the app has, in the menu bar dropdown: status, actions and settings.
struct PanelView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case status = "Status", sso = "SSO", vpn = "VPN", dns = "DNS", general = "General"
        var id: String { rawValue }
    }

    let model: AppModel
    // --tab=<Status|SSO|VPN|DNS|General> opens a given tab (debug aid with --show-panel).
    @State private var tab: Tab = CommandLine.arguments.lazy
        .compactMap { $0.hasPrefix("--tab=") ? Tab(rawValue: String($0.dropFirst(6))) : nil }
        .first ?? .status
    /// Which way the content slides: forward (to a tab on the right) comes in from the right.
    @State private var forward = true

    private var tabSelection: Binding<Tab> {
        Binding(get: { tab }, set: { new in
            let order = Tab.allCases
            forward = order.firstIndex(of: new)! > order.firstIndex(of: tab)!
            withAnimation(.snappy(duration: 0.3)) { tab = new }
        })
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: forward ? .trailing : .leading),
                    removal: .move(edge: forward ? .leading : .trailing))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("AWS AutoConnect").font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], 14)

            Picker("", selection: tabSelection) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Old and new content overlap in a ZStack while sliding, clipped to the panel's width.
            ZStack(alignment: .top) {
                Group {
                    switch tab {
                    case .status: StatusSection(model: model).padding(.horizontal, 14).padding(.bottom, 12)
                    case .sso: SSOSettings(model: model).frame(height: 330)
                    case .vpn: VPNSettings().frame(height: 340)
                    case .dns: DNSSettings(model: model).frame(height: 420)
                    case .general: GeneralSettings().frame(height: 330)
                    }
                }
                .frame(width: 340)
                .id(tab)
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
        .frame(width: 340)
    }
}

private struct StatusSection: View {
    let model: AppModel

    var body: some View {
        // Re-render periodically so "time left" stays current while open.
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 8) {
                if model.signInNeeded {
                    StatusRow(icon: "exclamationmark.triangle.fill", tint: .red,
                              title: "Sign-in needed", detail: "Google wants you to sign in again") {
                        Button("Open") { model.showSignIn() }
                    }
                }

                StatusRow(icon: "key.fill", tint: ssoTint, title: "SSO", detail: model.ssoSummary) {
                    Button("Refresh") { Task { await model.refreshSSO(manual: true) } }
                        .disabled(model.sso == .refreshing)
                }

                StatusRow(icon: "network", tint: vpnTint, title: "VPN", detail: model.vpn.summary) {
                    if model.vpn.state == .connected || model.vpn.isBusy {
                        Button("Disconnect") { Task { await model.vpn.disconnect() } }
                    } else {
                        Button("Connect") { Task { await model.vpn.connect() } }
                            .disabled(!VPNHelper.isInstalled)
                    }
                }
            }
        }
    }

    private var ssoTint: Color {
        switch model.sso {
        case .valid: return .green
        case .refreshing: return .yellow
        case .failed, .expired: return .red
        default: return .secondary
        }
    }

    private var vpnTint: Color {
        switch model.vpn.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .secondary
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
