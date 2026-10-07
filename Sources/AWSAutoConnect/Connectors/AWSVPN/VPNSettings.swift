import SwiftUI

struct VPNSettings: View {
    @Bindable var connector: AWSVPNConnector
    @State private var profiles = VPNProfile.all()
    @State private var installed = VPNHelper.installedProfileName
    @State private var error: String?

    var body: some View {
        Form {
            if profiles.isEmpty {
                LabeledContent("Profile", value: "No AWS VPN Client profiles")
            } else {
                Picker("Profile", selection: $connector.profileName) {
                    ForEach(profiles) { Text($0.name).tag($0.name) }
                }
            }
            Toggle("Connect when the app starts", isOn: $connector.connectAtLaunch)
            Toggle("Reconnect if dropped or after wake", isOn: $connector.reconnect)

            Section {
                LabeledContent("Helper", value: connector.installingHelper ? "Working…"
                               : installed.map { "Installed · \($0)" } ?? "Not installed")
                if connector.helperOutdated {
                    Label {
                        Text("This app comes with a newer helper. Update it, then reconnect to use it.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
                HStack {
                    Button(installed == nil ? "Install Helper…" : connector.helperOutdated ? "Update Helper…" : "Reinstall…") { install() }
                        .disabled(selectedProfile == nil || connector.installingHelper)
                        .help(installed == nil ? "Install the helper for the selected profile" : "Reinstall the helper for the selected profile")
                    Spacer()
                    if installed != nil {
                        Button("Uninstall…", role: .destructive) { uninstall() }
                            .disabled(connector.installingHelper)
                    }
                }
            } header: {
                Text("Tunnel helper")
            } footer: {
                Text("Asks for your admin password once. Installs openvpn and a root helper with a sudoers rule for only that helper.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            profiles = VPNProfile.all()
            installed = VPNHelper.installedProfileName
            if !profiles.contains(where: { $0.name == connector.profileName }), let first = profiles.first {
                connector.profileName = first.name
            }
        }
    }

    private var selectedProfile: VPNProfile? { profiles.first { $0.name == connector.profileName } }

    private func install() {
        guard let profile = selectedProfile else { return }
        run { try await connector.installHelper(profile) }
    }

    private func uninstall() {
        run { try await connector.uninstallHelper() }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                error = nil
            } catch is CancellationError {
            } catch let e {
                error = e.localizedDescription
            }
            installed = VPNHelper.installedProfileName
        }
    }
}
