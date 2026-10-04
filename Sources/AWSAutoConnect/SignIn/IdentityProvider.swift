import Foundation

/// Who you sign in with (Google, Okta, …): how the hidden browser recognises its pages. Built-ins are
/// below; more can be added as JSON files in `ProviderRegistry.folder`, using these field names.
struct IdentityProvider: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Hosts of its sign-in pages; each also matches its subdomains. "*" matches any host and is
    /// checked last, after the connector's own pages.
    var hosts: [String]
    /// Where "Sign in to <name>…" goes when no connector has a page that leads here.
    var signInURL: URL?
    /// CSS selectors; a visible match means the page needs you (email or password box, …).
    var needsUser: [String]
    /// CSS selectors for a chooser (e.g. Google's account picker): exactly one visible match is
    /// clicked, more than one needs you.
    var pick: [String]?
    /// Regexes on the URL path of pages that only pass through, like an auto-posting SAML form.
    var passThrough: [String]?
    /// Whether any other page on these hosts needs you (2-step prompts, passkeys, "Verify it's you").
    var otherPagesNeedUser: Bool?
    /// Regex for the button on a service's own login page that signs in with this provider
    /// (e.g. "Sign in with Google"); clicked on the connector's pages.
    var serviceButton: String?

    func matches(host: String) -> Bool {
        hosts.contains { $0 == "*" || host == $0 || host.hasSuffix("." + $0) }
    }
}

extension IdentityProvider {
    static let google = IdentityProvider(
        id: "google",
        name: "Google",
        hosts: ["accounts.google.com"],
        signInURL: URL(string: "https://accounts.google.com/"),
        needsUser: ["input[type=password]:not([aria-hidden=true])", "input[type=email]"],
        pick: ["[data-identifier]"],
        passThrough: ["^/o/saml2/"],
        otherPagesNeedUser: true,
        serviceButton: "^(sign in|log in|login|continue) with google$"
    )

    /// Works with any provider, without clicking anything on its pages: a visible password box anywhere
    /// means you need to sign in. Always checked last, whichever provider is chosen.
    static let generic = IdentityProvider(
        id: "generic",
        name: "Other (generic)",
        hosts: ["*"],
        signInURL: nil,
        needsUser: ["input[type=password]"],
        otherPagesNeedUser: false
    )
}

/// Built-in providers plus the user's JSON files.
@MainActor
final class ProviderRegistry {
    nonisolated static let defaultID = IdentityProvider.google.id
    nonisolated static let builtIn: [IdentityProvider] = [.google, .generic]
    nonisolated static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AWSAutoConnect/providers")
    }

    private let log = AppLog("providers")
    private let folder: URL?
    private(set) var all: [IdentityProvider] = ProviderRegistry.builtIn

    /// `folder: nil` uses only the built-ins (tests).
    init(folder: URL? = ProviderRegistry.folder) {
        self.folder = folder
        reload()
    }

    func reload() {
        var list = Self.builtIn
        for p in loadFolder() {
            if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
        }
        all = list
    }

    /// Unknown ids fall back to the default.
    func provider(id: String) -> IdentityProvider {
        all.first { $0.id == id } ?? all.first { $0.id == Self.defaultID } ?? .google
    }

    private func loadFolder() -> [IdentityProvider] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { file in
            do {
                return try JSONDecoder().decode(IdentityProvider.self, from: Data(contentsOf: file))
            } catch {
                log.error("skipping \(file.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }
    }
}
