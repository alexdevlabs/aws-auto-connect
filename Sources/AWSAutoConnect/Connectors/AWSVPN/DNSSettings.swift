import SwiftUI

struct DNSSettings: View {
    let connector: AWSVPNConnector
    @State private var scanning = false
    @State private var query = ""
    @State private var filter = Filter.toReview
    /// Groups start collapsed; these are the ones opened.
    @State private var expanded: Set<String> = []
    @State private var newHost = ""
    @FocusState private var addFocused: Bool
    /// Edit as Text… swaps the tab for a text area.
    @State private var editingText = false

    private enum Filter: String { case toReview, allowed }

    private var domains: VPNDomains { connector.domains }

    var body: some View {
        if editingText {
            AllowlistText(domains: domains) { editingText = false }
        } else {
            list
        }
    }

    @ViewBuilder private var list: some View {
        @Bindable var domains = domains
        let toReview = domains.learned.filter { !domains.isAllowed($0.name) }.count
        let byHand = byHand
        let allowed = domains.learned.count - toReview + byHand.count
        let groups = groups
        let typed = query.trimmingCharacters(in: .whitespaces)
        Form {
            if !VPNDomains.relayInstalled {
                Text("Reinstall the helper (VPN tab) to turn this on.")
                    .font(.caption).foregroundStyle(.orange)
            } else if connector.helperOutdated {
                Label {
                    Text("Update the helper (VPN tab): with Allowlist only on, the older one still sends every name to the VPN's DNS.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }

            Section {
                Toggle("Allowlist only", isOn: $domains.allowlistOn)
            } footer: {
                Text(domains.allowlistOn
                     ? (domains.allowlist.isEmpty
                        ? "Nothing allowed yet. Everything uses your normal DNS first."
                        : "Allowed domains use the VPN's DNS. The rest use your normal DNS first.")
                     : "Every lookup uses the VPN's DNS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("", text: $query, prompt: Text("Filter hostnames")).labelsHidden()
                }
                SegmentedControl(items: [.init(id: Filter.toReview.rawValue, label: "To review", detail: "\(toReview)"),
                                         .init(id: Filter.allowed.rawValue, label: "Allowed", detail: "\(allowed)")],
                                 selection: Binding(get: { filter.rawValue },
                                                    set: { filter = Filter(rawValue: $0) ?? .toReview }))
                if filter == .allowed {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        TextField("", text: $newHost, prompt: Text("Add a hostname, e.g. git.corp.example")).labelsHidden()
                            .focused($addFocused)
                            .onSubmit(addHost)
                        Button("Add", action: addHost).controlSize(.small).disabled(!canAdd)
                            .help("Also covers its subdomains. *.corp.example works too.")
                    }
                    ForEach(byHand.filter { typed.isEmpty || $0.contains(typed.lowercased()) }, id: \.self) { d in
                        ByHandRow(domain: d) { domains.remove(d) }
                    }
                }
                ForEach(groups, id: \.domain) { group in
                    // A filter shows every match, so groups open while one is typed.
                    let open = expanded.contains(group.domain) || !typed.isEmpty
                    let allAllowed = group.entries.allSatisfy { domains.isAllowed($0.name) }
                    GroupHeader(domain: group.domain, count: group.entries.count, open: open, allAllowed: allAllowed,
                                toggle: { expanded.formSymmetricDifference([group.domain]) },
                                allow: { domains.allow(group.domain) },
                                remove: { domains.disallow(group.entries.map(\.name)) })
                    if open {
                        ForEach(group.entries) { e in
                            LearnedRow(entry: e, group: group.domain, domains: domains).padding(.leading, 20)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Learned while connected")
                    Spacer()
                    Menu {
                        Button("Allow Each Name") { domains.allowAllLearned() }.disabled(toReview == 0)
                        Button("Allow Each Parent Domain") { domains.allowAllLearnedSubdomains() }
                            .disabled(toReview == 0)
                            .help("Adds *.parent for each name, e.g. *.svc.corp.com for api.svc.corp.com")
                        Button("Add Hostname…") {
                            filter = .allowed
                            addFocused = true
                        }
                        Button("Edit as Text…") { editingText = true }
                        Button("Remove All Allowed", role: .destructive) { domains.disallowAll() }
                            .disabled(domains.allowlist.isEmpty)
                        Divider()
                        Button("Scan Config Files") { scan() }
                            .disabled(scanning || !connector.isConnected || !VPNDomains.relayInstalled)
                        Button("Clear List", role: .destructive) { domains.clearLearned() }.disabled(domains.learned.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let status = domains.scanStatus { Text(status) }
                    if domains.learned.isEmpty, byHand.isEmpty {
                        Text("Nothing yet. Domains show up here as you use the VPN.")
                    } else if groups.isEmpty, filter == .toReview || byHand.isEmpty {
                        Text(!typed.isEmpty ? "Nothing matches “\(typed)”."
                             : filter == .toReview ? "All caught up: nothing left to review." : "Nothing allowed yet.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            // Pick up new names every few seconds while the page is open.
            while !Task.isCancelled {
                domains.ingest()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Learned names that pass the filter, grouped by domain; groups in order of their newest name.
    private var groups: [(domain: String, entries: [VPNDomains.Entry])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = domains.learned.filter { e in
            guard q.isEmpty || e.name.contains(q) else { return false }
            switch filter {
            case .toReview: return !domains.isAllowed(e.name)
            case .allowed: return domains.isAllowed(e.name)
            }
        }
        var order: [String] = []
        var byGroup: [String: [VPNDomains.Entry]] = [:]
        for e in shown {
            let g = VPNDomains.group(of: e.name)
            if byGroup[g] == nil { order.append(g) }
            byGroup[g, default: []].append(e)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    /// Allowed domains that no learned name falls under (typed in, or the names were cleared).
    private var byHand: [String] {
        domains.allowlist.filter { d in !domains.learned.contains { $0.name == d || $0.name.hasSuffix("." + d) } }
    }

    /// The add field holds a hostname that isn't allowed yet.
    private var canAdd: Bool {
        VPNDomains.normalized(newHost).map { !domains.isAllowed($0) } ?? false
    }

    private func addHost() {
        guard canAdd else { return }
        domains.allow(newHost)
        newHost = ""
    }

    private func scan() {
        scanning = true
        Task {
            await domains.scanConfigFiles()
            scanning = false
        }
    }
}

/// Edit as Text…: the allowed list, one domain per line. Save replaces the list with what's there.
private struct AllowlistText: View {
    let domains: VPNDomains
    let done: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(domains: VPNDomains, done: @escaping () -> Void) {
        self.domains = domains
        self.done = done
        _text = State(initialValue: domains.allowlist.map { $0 + "\n" }.joined())
    }

    var body: some View {
        let edited = VPNDomains.allowlist([], adding: VPNDomains.importable(text))
        let added = edited.filter { !domains.allowlist.contains($0) }.count
        let removed = domains.allowlist.filter { !edited.contains($0) }.count
        VStack(alignment: .leading, spacing: 10) {
            Text("One domain per line; each covers its subdomains. Paste to add, delete a line to remove, or copy it to share.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .focused($focused)
            HStack {
                Text([added > 0 ? "+\(added)" : nil, removed > 0 ? "−\(removed)" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    domains.replaceAllowlist(with: edited)
                    done()
                }
                .buttonStyle(.borderedProminent).disabled(added == 0 && removed == 0)
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }
}

/// An allowed domain no learned name falls under.
private struct ByHandRow: View {
    let domain: String
    let remove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain).lineLimit(1).truncationMode(.middle)
                Text("Added by you · covers its subdomains").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button("Remove", action: remove).controlSize(.small)
        }
    }
}

/// A group's row: opens and closes it, and allows (or removes) the whole group.
private struct GroupHeader: View {
    let domain: String
    let count: Int
    let open: Bool
    /// Every name shown in the group is allowed.
    let allAllowed: Bool
    let toggle: () -> Void
    let allow: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text(domain).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if allAllowed {
                Button("Remove All", action: remove).controlSize(.small).fixedSize()
                    .help("Stops allowing every name in \(domain)")
            } else {
                Button("Allow All", action: allow).controlSize(.small).fixedSize()
                    .help("Adds *.\(domain), which covers all of its subdomains")
            }
        }
    }
}

private struct LearnedRow: View {
    let entry: VPNDomains.Entry
    let group: String
    let domains: VPNDomains

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                name.lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if domains.isAllowed(entry.name) {
                Button("Remove") { domains.disallow([entry.name]) }.controlSize(.small)
                    .help(via.map { "Removes *.\($0), which also covers other names" } ?? "Stops allowing this name")
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

    /// The allowed parent domain this name falls under, if it isn't allowed by its own name.
    private var via: String? {
        domains.allowlist.first { entry.name.hasSuffix("." + $0) }
    }

    private var detail: String {
        let seen = "\(entry.reason) · \(entry.count)× · \(entry.last.formatted(.relative(presentation: .named)))"
        return via.map { "Allowed by *.\($0) · " + seen } ?? seen
    }

    /// The part before the group's domain, with the domain dimmed: "grafana.tools" + ".corp.example".
    private var name: Text {
        guard entry.name.hasSuffix("." + group) else { return Text(entry.name) }
        return Text(entry.name.dropLast(group.count + 1)) + Text("." + group).foregroundColor(.secondary)
    }
}
