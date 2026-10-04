import ServiceManagement
import SwiftUI

// Settings sections shown inside the menu bar panel.

struct GeneralSettings: View {
    let model: AppModel
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

            Section("Connectors") {
                ForEach(ConnectorRegistry.types.map(ObjectIdentifier.init), id: \.self) { id in
                    let type = ConnectorRegistry.types.first { ObjectIdentifier($0) == id }!
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
