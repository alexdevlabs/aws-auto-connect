# Security

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** (Security ▸ Advisories) on this repository rather than
a public issue. Include steps to reproduce and the version or commit.

## What runs as root

The VPN needs root to create the tunnel and set DNS. The VPN tab's **Install Helper…** (macOS admin
prompt) installs:

| Path | What |
|---|---|
| `/usr/local/libexec/aws-autoconnect/` | `openvpn`, `dns-relay`, `vpn-helper`, `dns.sh`, owned by root |
| `/usr/local/etc/aws-autoconnect/` | the sanitised VPN profile, endpoint, profile name |
| `/etc/sudoers.d/aws-autoconnect` | lets your user run only `vpn-helper` without a password |

`vpn-helper` accepts only `connect <ipv4> <port> <udp\|tcp> <file>`, `disconnect`, `status` and
`dns-config <file>`. It validates each argument, and reads the credentials and allowlist files as
your user (`sudo -u`), not as root, so it can't be used to read root-only files.

The installed profile keeps only plain client directives and inline certificates. Anything that can
run code (`up`, `down`, `plugin`, `script-security`, …) is dropped. openvpn's `--up`/`--down` point
only at the root-owned `dns.sh`.

Anyone who can run commands as your user can start or stop the tunnel and change the DNS allowlist.
They can't run other commands as root through the helper.

**Uninstall Helper…** in the VPN tab removes all of it.

## What the app keeps

- The sign-in provider's cookies live in the app's WebKit store (like a browser profile).
  **Clear Browser Session** in the SSO tab deletes them.
- The SAML assertion is written to a 0600 temp file for the helper and deleted right after.
- AWS and gcx tokens stay where those CLIs keep them. The app only reads the AWS token's expiry.
- DNS learning keeps only names that needed the VPN, in
  `~/Library/Application Support/AWSAutoConnect/vpn-domains.json`.
- Logs (`~/Library/Logs/AWSAutoConnect.log`) record hosts and paths, never query strings, which can
  carry SAML data.

## The hidden browser

It only clicks what the current flow allows: the provider's account chooser, and buttons matching the
connector's approval rules on the connector's own hosts. It never types into fields. When a page
needs you (password, 2-step), it shows a notification instead.
