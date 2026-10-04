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
                LabeledContent("Helper", value: installed.map { "Installed · \($0)" } ?? "Not installed")
                HStack {
                    Button(installed == nil ? "Install Helper…" : "Reinstall…") { install() }
                        .disabled(selectedProfile == nil)
                        .help(installed == nil ? "Install the helper for the selected profile" : "Reinstall the helper for the selected profile")
                    Spacer()
                    if installed != nil {
                        Button("Uninstall…", role: .destructive) { uninstall() }
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
        run { try VPNHelper.install(profile) }
    }

    private func uninstall() {
        run { try VPNHelper.uninstall() }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch let e {
            error = e.localizedDescription
        }
        installed = VPNHelper.installedProfileName
    }
}

struct DNSSettings: View {
    let connector: AWSVPNConnector
    @State private var newDomain = ""
    @State private var scanning = false

    private var domains: VPNDomains { connector.domains }

    var body: some View {
        @Bindable var domains = domains
        Form {
            if !VPNDomains.relayInstalled {
                Text("Reinstall the helper (VPN tab) to turn this on.")
                    .font(.caption).foregroundStyle(.orange)
            }

            Section {
                Toggle("Allowlist only", isOn: $domains.allowlistOn)
            } footer: {
                Text(domains.allowlistOn
                     ? (domains.allowlist.isEmpty
                        ? "The allowlist is empty, so nothing uses the VPN's DNS."
                        : "Only these domains use the VPN's DNS. Everything else uses your network's.")
                     : "All lookups use the VPN's DNS, like the AWS client.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Allowlist") {
                ForEach(domains.allowlist, id: \.self) { d in
                    HStack {
                        Text(d).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { domains.remove(d) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Remove")
                    }
                }
                HStack {
                    TextField("", text: $newDomain, prompt: Text("corp.example.com"))
                        .labelsHidden()
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                if domains.learned.isEmpty {
                    Text("Nothing yet. Domains show up here as you use the VPN.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(domains.learned) { e in LearnedRow(entry: e, domains: domains) }
            } header: {
                HStack {
                    Text("Needed the VPN (\(domains.learned.count))")
                    Spacer()
                    Menu {
                        Button("Allow All") { domains.allowAllLearned() }.disabled(domains.learned.isEmpty)
                        Button("Scan Config Files") { scan() }
                            .disabled(scanning || !connector.isConnected || !VPNDomains.relayInstalled)
                        Divider()
                        Button("Clear List", role: .destructive) { domains.clearLearned() }.disabled(domains.learned.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let status = domains.scanStatus { Text(status) }
                    Text("Learned while connected: the VPN's DNS answered with an address in the VPN's routes, or only it knew the name. Kept on this Mac.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            // Pick up new names every few seconds while the tab is open.
            while !Task.isCancelled {
                domains.ingest()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func add() {
        domains.allow(newDomain)
        newDomain = ""
    }

    private func scan() {
        scanning = true
        Task {
            await domains.scanConfigFiles()
            scanning = false
        }
    }
}

private struct LearnedRow: View {
    let entry: VPNDomains.Entry
    let domains: VPNDomains

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text("\(entry.reason) · \(entry.count)× · \(entry.last.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if domains.isAllowed(entry.name) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("In the allowlist")
            } else {
                Menu("Allow") {
                    Button(entry.name) { domains.allow(entry.name) }
                    if let parent = VPNDomains.parent(of: entry.name) {
                        Button("*.\(parent)") { domains.allow(parent) }
                    }
                } primaryAction: {
                    domains.allow(entry.name)
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }
        }
        .contextMenu {
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.name, forType: .string)
            }
            Button("Forget", role: .destructive) { domains.forget(entry.name) }
        }
    }
}
