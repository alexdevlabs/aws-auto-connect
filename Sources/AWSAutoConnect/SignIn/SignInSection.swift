import SwiftUI

/// The hidden browser's settings: which sign-in provider to expect, signing in by hand, clearing cookies.
struct SignInSection: View {
    let context: ConnectorContext
    @AppStorage(Prefs.Key.signInProvider.rawValue) private var providerID = ProviderRegistry.defaultID
    @State private var providers: [IdentityProvider] = []

    var body: some View {
        Section {
            Picker("Provider", selection: $providerID) {
                ForEach(providers) { Text($0.name).tag($0.id) }
            }
            Button("Sign in to \(context.providers.provider(id: providerID).name)…") { context.showSignIn() }
            Button("Clear Browser Session", role: .destructive) {
                Task { await context.browser.clearSession() }
            }
        } header: {
            Text("Browser")
        } footer: {
            HStack(spacing: 4) {
                Text("Add providers as JSON files in the")
                Button("providers folder") { openFolder() }.buttonStyle(.link)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            context.providers.reload()
            providers = context.providers.all
        }
    }

    private func openFolder() {
        let folder = ProviderRegistry.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
