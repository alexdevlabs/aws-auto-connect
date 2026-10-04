# AWS AutoConnect

Menu bar app that keeps your CLI logins fresh and your VPN connected, without clicking through browser
pages: AWS SSO, AWS Client VPN (SAML), and Grafana's `gcx`. Sign-in goes through your identity provider
(Google by default) in a hidden browser that only shows itself when you really need to sign in.

- Native Swift, ~5 MB, no runtime dependencies. Uses the system WebKit as the hidden browser.
- Lives only in the menu bar: click the tunnel icon for status, actions and all settings. The dot is
  green OK, yellow working, red needs you.
- Pluggable: sign-in providers are JSON, connectors are small Swift adapters
  ([CONTRIBUTING.md](CONTRIBUTING.md)).

## Install

With Homebrew (builds from source; needs Xcode):

```bash
brew install alexdevlabs/tap/aws-autoconnect
ln -sf "$(brew --prefix aws-autoconnect)/AWS AutoConnect.app" ~/Applications/
open ~/Applications/"AWS AutoConnect.app"
```

Or from a clone:

```bash
make install   # builds patched openvpn (first time), the app, copies to ~/Applications
open ~/Applications/"AWS AutoConnect.app"
```

Needs macOS 14+, Xcode 16+ and Homebrew `openssl@3`.

## First-time setup

1. **SSO** tab ▸ **Browser**: pick your provider, then **Sign in to …** once. Cookies are kept in the
   app's WebKit store.
2. **VPN** tab ▸ pick the AWS VPN Client profile ▸ **Install Helper…** (asks for your admin password once).
3. **Status** tab ▸ **Connect**.
4. Optional: **General** ▸ **Connectors** ▸ turn on **Grafana (gcx)**, then set it up in its tab.

## Connectors

| Connector | Keeps | How |
|---|---|---|
| **AWS SSO** | an `sso-session` from `~/.aws/config` | Every minute it reads the CLI's token cache. Near expiry it runs `aws configure export-credentials` (silent refresh). If that isn't enough, it runs `aws sso login` and the hidden browser clicks "Confirm and continue" / "Allow access". |
| **AWS Client VPN** | a tunnel from an AWS VPN Client profile | SAML sign-in in the hidden browser, then the root helper starts the patched openvpn. Optional reconnect after drops and wake. Owns the DNS relay below. |
| **Grafana (gcx)** | the `gcx` CLI login | Every few minutes it runs `gcx api /api/user`. When that's rejected it runs `gcx auth login` and presses OK on Grafana's page. Can wait for the VPN if your stack is behind it. |

Connectors are stored as a list (`ConnectorStore`), so several of a type are possible later. The panel
shows the first enabled one of each.

## Sign-in providers

Google is built in. **Other (generic)** works with any provider without clicking anything on its
pages: a visible password box means you need to sign in. Add your own (Okta, Microsoft Entra,
Keycloak, …) as JSON files in `~/Library/Application Support/AWSAutoConnect/providers/`; see
[CONTRIBUTING.md](CONTRIBUTING.md#adding-a-sign-in-provider).

When the provider wants you (signed out, 2-step, passkey, "Verify it's you"), you get a notification,
the dot turns red, and the Status tab shows **Sign-in needed** with an **Open** button. The flow waits up
to 10 minutes, then carries on and the window hides again.

## How the VPN works

AWS Client VPN is OpenVPN with a SAML extension.
1. openvpn (as you) connects with `ACS::35001` and gets `AUTH_FAILED,CRV1:…:<sid>:…:<saml url>`.
2. The hidden browser opens the URL; the provider posts `SAMLResponse` to `127.0.0.1:35001`, where the app listens.
3. `sudo -n vpn-helper connect …` starts openvpn as root with `CRV1::<sid>::<SAMLResponse>`.

**DNS**: while the tunnel is up, macOS uses `dns-relay` on 127.0.0.1 (root, from the helper). It sends
every lookup to the VPN's resolver and to your network's at the same time:
- **Allowlist only off** (default): answers come from the VPN's resolver, like the AWS client. Your
  network's answer is only used if the VPN's resolver fails or takes over 1.5 s.
- **Allowlist only on**: allowlisted domains (and their subdomains) use the VPN's resolver, everything
  else your network's.
- Either way it records names that need the VPN: the VPN's resolver returned an address inside the
  pushed routes, or only it knows the name. The **DNS** tab lists them (with Allow / Allow `*.parent`),
  and **Scan Config Files** looks up the hosts in `~/.ssh/config`, `~/.kube/config` and
  `~/.aws/config` while connected. Stored in `~/Library/Application Support/AWSAutoConnect/vpn-domains.json`;
  only names that needed the VPN, never other lookups.
- `dns.sh watch` restarts the relay if it exits, puts DNS back when DHCP or a network switch
  overwrites it, and restores your DNS if openvpn dies. Without the relay, DNS points straight at the
  VPN's resolver.

openvpn 2.6.12 + the AWS SAML patch from [aws-vpn-client/aws-vpn-client](https://github.com/aws-vpn-client/aws-vpn-client)
(the maintained home of the archived samm-git/aws-vpn-client), downloaded by `scripts/build-openvpn.sh`
at a pinned commit and SHA-256. On top of it, `vendor/openvpn-aws-size-macros.patch` wraps the patch's
size macros in parentheses (without it openvpn exits with "fatal buffer size error"). OpenSSL is linked
statically.

## What the helper installs (root)

| Path | What |
|---|---|
| `/usr/local/libexec/aws-autoconnect/` | `openvpn`, `dns-relay`, `vpn-helper`, `dns.sh` |
| `/usr/local/etc/aws-autoconnect/` | sanitised profile (no `up`/`down`/scripts), endpoint, profile name |
| `/etc/sudoers.d/aws-autoconnect` | `<you> ALL=(root) NOPASSWD: …/vpn-helper` |
| `/var/log/aws-autoconnect.log`, `aws-autoconnect-dns.log` | openvpn log, DNS relay log |
| `/var/run/aws-autoconnect/` | pid, relay config, allowlist, `dns-learned.log` (gone after reboot) |

`vpn-helper` only accepts `connect <ipv4> <port> <udp|tcp> <file>`, `disconnect`, `status` and
`dns-config <file>`, and reads the credentials and allowlist files as you, not as root. The VPN tab's
**Uninstall Helper…** removes all of it. More in [SECURITY.md](SECURITY.md).

## Logs

- App: `~/Library/Logs/AWSAutoConnect.log` (a sign-in that gives up logs the page it was stuck on and
  saves `AWSAutoConnect-stuck.png` next to it)
- Tunnel: `/var/log/aws-autoconnect.log`
- DNS relay: `/var/log/aws-autoconnect-dns.log`

## License

MIT, see [LICENSE](LICENSE). The bundled openvpn is GPLv2; it's downloaded and built at install time,
not stored in this repository.
