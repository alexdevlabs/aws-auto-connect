import ServiceManagement
import SwiftUI

// Settings sections shown inside the menu bar panel.

struct GeneralSettings: View {
    @AppStorage(Prefs.Key.notifications.rawValue) private var notifications = true
    @AppStorage(Prefs.Key.quietEnabled.rawValue) private var quietEnabled = false
    @AppStorage(Prefs.Key.quietFrom.rawValue) private var quietFrom = 19
    @AppStorage(Prefs.Key.quietTo.rawValue) private var quietTo = 8
    @AppStorage(Prefs.Key.quietWeekends.rawValue) private var quietWeekends = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch let e {
                        error = e.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Notifications", isOn: $notifications)

            Section {
                Toggle("Pause every day", isOn: $quietEnabled)
                if quietEnabled {
                    Picker("From", selection: $quietFrom) { hours }
                    Picker("To", selection: $quietTo) { hours }
                }
                Toggle("Pause on weekends", isOn: $quietWeekends)
            } header: {
                Text("Quiet hours")
            } footer: {
                Text("No automatic refresh or reconnect.").font(.caption).foregroundStyle(.secondary)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var hours: some View {
        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
    }
}

struct SSOSettings: View {
    let model: AppModel
    @AppStorage(Prefs.Key.autoRefreshSSO.rawValue) private var autoRefresh = true
    @AppStorage(Prefs.Key.ssoSession.rawValue) private var sessionName = ""
    @AppStorage(Prefs.Key.refreshLeadMinutes.rawValue) private var lead = 10
    @State private var sessions = AWSConfig.ssoSessions()

    var body: some View {
        Form {
            Toggle("Refresh automatically", isOn: $autoRefresh)
            if sessions.isEmpty {
                LabeledContent("Session", value: "None in ~/.aws/config")
            } else {
                Picker("Session", selection: $sessionName) {
                    ForEach(sessions) { Text($0.name).tag($0.name) }
                }
            }
            Section {
                Stepper("\(lead) min before expiry", value: $lead, in: 5...120, step: 5)
            } footer: {
                Text("≤ 10 min uses the CLI's silent refresh. More approves a new login in the hidden browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Browser") {
                Button("Sign in to Google…") { model.showSignIn() }
                Button("Clear Browser Session", role: .destructive) {
                    Task { await model.clearBrowserSession() }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            sessions = AWSConfig.ssoSessions()
            if !sessions.contains(where: { $0.name == sessionName }), let first = sessions.first {
                sessionName = first.name
            }
        }
    }
}

struct VPNSettings: View {
    @AppStorage(Prefs.Key.vpnProfile.rawValue) private var profileName = ""
    @AppStorage(Prefs.Key.vpnConnectAtLaunch.rawValue) private var connectAtLaunch = false
    @AppStorage(Prefs.Key.vpnReconnect.rawValue) private var reconnect = false
    @State private var profiles = VPNProfile.all()
    @State private var installed = VPNHelper.installedProfileName
    @State private var error: String?

    var body: some View {
        Form {
            if profiles.isEmpty {
                LabeledContent("Profile", value: "No AWS VPN Client profiles")
            } else {
                Picker("Profile", selection: $profileName) {
                    ForEach(profiles) { Text($0.name).tag($0.name) }
                }
            }
            Toggle("Connect when the app starts", isOn: $connectAtLaunch)
            Toggle("Reconnect if dropped or after wake", isOn: $reconnect)

            Section {
                LabeledContent("Helper", value: installed.map { "Installed · \($0)" } ?? "Not installed")
                Button(installed == nil ? "Install Helper…" : "Reinstall for Selected Profile…") { install() }
                    .disabled(selectedProfile == nil)
                if installed != nil {
                    Button("Uninstall Helper…", role: .destructive) { uninstall() }
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
            if !profiles.contains(where: { $0.name == profileName }), let first = profiles.first {
                profileName = first.name
            }
        }
    }

    private var selectedProfile: VPNProfile? { profiles.first { $0.name == profileName } }

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
    let model: AppModel
    @State private var newDomain = ""
    @State private var scanning = false

    private var domains: VPNDomains { model.domains }

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
                            .disabled(scanning || model.vpn.state != .connected || !VPNDomains.relayInstalled)
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
