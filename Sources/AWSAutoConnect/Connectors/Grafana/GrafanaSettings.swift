import SwiftUI

struct GrafanaSettings: View {
    @Bindable var connector: GrafanaConnector

    var body: some View {
        Form {
            Toggle("Sign in automatically", isOn: $connector.autoRefresh)
            Stepper("Check every \(connector.checkMinutes) min", value: $connector.checkMinutes, in: 1...60)
            Toggle("Only while the VPN is connected", isOn: $connector.onlyWithVPN)

            Section {
                TextField("Context", text: $connector.contextName, prompt: Text("current"))
                TextField("Stack", text: $connector.stackHost, prompt: Text("myorg.grafana.net"))
                TextField("Login arguments", text: $connector.loginArguments, prompt: Text("none"))
            } header: {
                Text("gcx")
            } footer: {
                Text("Checks with `gcx api /api/user` and signs in with `gcx auth login`, pressing OK on Grafana's page in the hidden browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
