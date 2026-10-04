# AWS AutoConnect

Menu bar app that keeps your AWS CLI SSO session fresh and connects AWS Client VPN (SAML) without clicking through browser pages.

- Native Swift, ~5 MB, no dependencies at runtime. Uses the system WebKit as a hidden browser.
- Lives only in the menu bar: click the tunnel icon for status, actions and all settings. The dot is green OK, yellow working, red needs you.

## Build & install

```bash
make install   # builds patched openvpn (first time), the app, copies to ~/Applications
open ~/Applications/"AWS AutoConnect.app"
```

Needs Xcode and Homebrew `openssl@3`.

## First-time setup

1. Click the menu bar icon ▸ **SSO** tab ▸ **Sign in to Google…** and sign in once. Cookies are kept in the app's WebKit store.
2. **VPN** tab ▸ pick the profile ▸ **Install Helper…** (asks for your admin password once).
3. **Status** tab ▸ **Connect**.

## How it works

**SSO**: every minute it reads `~/.aws/sso/cache/<sha1(session)>.json`. When the token is within the lead time it runs `aws configure export-credentials` (silent refresh via refresh token). If that doesn't extend the token, it runs `aws sso login --no-browser` and the hidden browser clicks "Confirm and continue" / "Allow access". If Google asks for a password, you get a notification instead of a popup.

**VPN**: AWS Client VPN is OpenVPN with a SAML extension.
1. openvpn (as you) connects with `ACS::35001` and gets `AUTH_FAILED,CRV1:…:<sid>:…:<saml url>`.
2. The hidden browser opens the URL; Google posts `SAMLResponse` to `127.0.0.1:35001`, where the app listens.
3. `sudo -n vpn-helper connect …` starts openvpn as root with `CRV1::<sid>::<SAMLResponse>`.

**DNS**: while the tunnel is up, macOS uses `dns-relay` on 127.0.0.1 (root, from the helper). It sends every lookup to the VPN's resolver and to your network's at the same time:
- **Allowlist only off** (default): answers come from the VPN's resolver, like the AWS client. Your network's answer is only used if the VPN's resolver fails or takes over 1.5 s.
- **Allowlist only on**: allowlisted domains (and their subdomains) use the VPN's resolver, everything else your network's.
- Either way it records names that need the VPN: the VPN's resolver returned an address inside the pushed routes, or only it knows the name. The **DNS** tab lists them (with Allow / Allow `*.parent`), and **Scan Config Files** looks up the hosts in `~/.ssh/config`, `~/.kube/config` and `~/.aws/config` while connected. Stored in `~/Library/Application Support/AWSAutoConnect/vpn-domains.json`; only names that needed the VPN, never other lookups.
- `dns.sh watch` restarts the relay if it exits, puts DNS back when DHCP or a network switch overwrites it, and restores your DNS if openvpn dies. Without the relay, DNS points straight at the VPN's resolver.

openvpn 2.6.12 + the AWS SAML patch from [aws-vpn-client/aws-vpn-client](https://github.com/aws-vpn-client/aws-vpn-client) (the maintained home of the archived samm-git/aws-vpn-client), downloaded by `scripts/build-openvpn.sh` at a pinned commit and SHA-256. On top of it, `vendor/openvpn-aws-size-macros.patch` wraps the patch's size macros in parentheses (without it openvpn exits with "fatal buffer size error"). OpenSSL is linked statically.

## What the helper installs (root)

| Path | What |
|---|---|
| `/usr/local/libexec/aws-autoconnect/` | `openvpn`, `dns-relay`, `vpn-helper`, `dns.sh` |
| `/usr/local/etc/aws-autoconnect/` | sanitised profile (no `up`/`down`/scripts), endpoint, profile name |
| `/etc/sudoers.d/aws-autoconnect` | `<you> ALL=(root) NOPASSWD: …/vpn-helper` |
| `/var/log/aws-autoconnect.log`, `aws-autoconnect-dns.log` | openvpn log, DNS relay log |
| `/var/run/aws-autoconnect/` | pid, relay config, allowlist, `dns-learned.log` (gone after reboot) |

`vpn-helper` only accepts `connect <ipv4> <port> <udp|tcp> <file>`, `disconnect`, `status` and `dns-config <file>`, and reads the credentials and allowlist files as you, not as root. The VPN tab's **Uninstall Helper…** removes all of it.

## Icon

Master artwork lives in `Assets/`: `AppIcon.svg` (macOS 1024 grid), `MenuBarIcon.svg` (template glyph, also drawn in `StatusIcon.swift`), `AppIcon-1024.png` (App Store / web) and the full `AppIcon.iconset`. After editing the SVG run `scripts/make-icons.sh` (needs Google Chrome) to regenerate the PNGs and `Resources/AppIcon.icns`.

## Logs

- App: `~/Library/Logs/AWSAutoConnect.log`
- Tunnel: `/var/log/aws-autoconnect.log`
- DNS relay: `/var/log/aws-autoconnect-dns.log`
