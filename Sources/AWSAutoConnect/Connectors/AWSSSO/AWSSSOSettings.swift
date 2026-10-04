import SwiftUI

struct AWSSSOSettings: View {
    @Bindable var connector: AWSSSOConnector
    let context: ConnectorContext
    @State private var sessions = AWSConfig.ssoSessions()

    var body: some View {
        Form {
            Toggle("Refresh automatically", isOn: $connector.autoRefresh)
            if sessions.isEmpty {
                LabeledContent("Session", value: "None in ~/.aws/config")
            } else {
                Picker("Session", selection: $connector.sessionName) {
                    ForEach(sessions) { Text($0.name).tag($0.name) }
                }
            }
            Section {
                Stepper("\(connector.leadMinutes) min before expiry", value: $connector.leadMinutes, in: 5...120, step: 5)
            } footer: {
                Text("≤ 10 min uses the CLI's silent refresh. More approves a new login in the hidden browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            SignInSection(context: context)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            sessions = AWSConfig.ssoSessions()
            if !sessions.contains(where: { $0.name == connector.sessionName }), let first = sessions.first {
                connector.sessionName = first.name
            }
        }
    }
}
