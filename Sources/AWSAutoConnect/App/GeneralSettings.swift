import ServiceManagement
import SwiftUI

// The General tab of Settings.

struct GeneralSettings: View {
    let model: AppModel
    @AppStorage(Prefs.Key.notifications.rawValue) private var notifications = true
    @AppStorage(Prefs.Key.quietEnabled.rawValue) private var quietEnabled = false
    @AppStorage(Prefs.Key.quietFrom.rawValue) private var quietFrom = 19
    @AppStorage(Prefs.Key.quietTo.rawValue) private var quietTo = 8
    @AppStorage(Prefs.Key.quietWeekends.rawValue) private var quietWeekends = false
    @AppStorage(Prefs.Key.checkForUpdates.rawValue) private var checkForUpdates = true
    @AppStorage(Prefs.Key.autoInstallUpdates.rawValue) private var autoInstallUpdates = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @State private var logSize: Int?
    @State private var savingLogs = false
    @State private var confirmingClear = false

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

            Section("Connectors") {
                ForEach(model.offeredTypes.map(ConnectorToggle.init)) { item in
                    let type = item.type
                    Toggle(type.displayName, isOn: Binding(get: { model.isEnabled(type) },
                                                           set: { model.setEnabled(type, $0) }))
                }
            }

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

            Section {
                Toggle("Check daily", isOn: $checkForUpdates)
                if model.updater.homebrewApp != nil {
                    Toggle("Install automatically when the VPN is off", isOn: $autoInstallUpdates)
                        .disabled(!checkForUpdates)
                }
                HStack {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { Task { await model.updater.check() } }
                        .disabled(model.updater.state == .checking || model.updater.isUpdating)
                    // Same as the Status tab's button, so you needn't go looking for it after Check Now.
                    if let release = model.updater.release, model.updater.homebrewApp != nil, !model.updater.isUpdating {
                        Button("Update") { Task { await model.updater.install(release) } }
                    }
                }
            } header: {
                Text("Updates")
            }

            Section {
                HStack {
                    Text("Logs")
                    if let logSize {
                        Text("· \(logSize.formatted(.byteCount(style: .file)))").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button("Save as Zip…") { Task { await saveLogs() } }.disabled(savingLogs).fixedSize()
                    Menu {
                        Button("Show in Finder") { revealLog() }
                        Button("Open in Console") { openInConsole() }
                        Divider()
                        Button("Clear Logs…", role: .destructive) { confirmingClear = true }.disabled(logSize == 0)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Something not working? Save the logs and send the zip with your report. Tokens, codes and email addresses are masked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task { await refreshLogSize() }
            .confirmationDialog("Clear the logs?", isPresented: $confirmingClear) {
                Button("Clear", role: .destructive) {
                    Task {
                        await LogFiles.clear()
                        await refreshLogSize()
                    }
                }
            } message: {
                Text("Deletes the app's log files and sign-in snapshots. The tunnel and DNS logs start over on every connect.")
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var updateStatus: String {
        switch model.updater.state {
        case .idle: return "v\(Updater.current)"
        case .checking: return "Checking…"
        case .upToDate: return "v\(Updater.current) is the latest"
        case .available(let r): return "v\(r.version) is available"
        case .updating(let r, let step): return "Updating to v\(r.version): \(step)…"
        case .failed(_, let message): return message
        }
    }

    private func revealLog() {
        let files = LogFiles.appFiles()
        NSWorkspace.shared.activateFileViewerSelecting(files.isEmpty ? [LogFiles.folder] : files)
    }

    private func openInConsole() {
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([AppLog.fileURL], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    private func saveLogs() async {
        savingLogs = true
        defer { savingLogs = false }
        do {
            let zip = try await LogFiles.archive()
            error = nil
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        } catch let e {
            error = e.localizedDescription
        }
        await refreshLogSize()
    }

    private func refreshLogSize() async {
        logSize = await LogFiles.size()
    }

    private var hours: some View {
        ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
    }
}

@MainActor
private struct ConnectorToggle: Identifiable {
    let type: any Connector.Type
    let id: String
    init(_ type: any Connector.Type) { self.type = type; id = type.type }
}
