# Contributing

Thanks for helping. Bug reports, new sign-in providers and new connectors are all welcome.

## Build and test

```bash
make install   # builds the patched openvpn (first time), the app, copies to /Applications
swift test     # unit tests, including the page rules run in WebKit
```

Needs Xcode 16+ and Homebrew `openssl@3`. Logs: `~/Library/Logs/AWSAutoConnect.log`.

Debug aids: `--show-panel --tab=<title>` opens the panel and saves a snapshot to `~/Library/Logs`;
`--debug-browser` logs and snapshots every page the hidden browser loads. The hidden browser is
inspectable from Safari ▸ Develop.

## How it fits together

```
Sources/AWSAutoConnect/
  Core/        Connector protocol, ConnectorStore (saved settings), Shell, Log, Prefs
  SignIn/      HeadlessBrowser (page rules engine), IdentityProvider, CLILogin, FormPostListener
  Connectors/  AWSSSO/, AWSVPN/ (+ DNS learning), Grafana/, ConnectorRegistry
  App/         menu bar, panel, General settings
Sources/DNSRelay/   the root DNS relay used while the VPN is up
helper/             root helper scripts (installed by the VPN tab)
```

- A **sign-in provider** (Google, Okta, …) is data: which hosts its pages are on, which elements
  mean "needs you", what may be clicked, and which pages only pass through.
- A **connector** (AWS SSO, AWS Client VPN, Grafana) is something kept signed in or connected. It
  reports a status, offers actions, adds settings tabs, and is ticked every minute.
- The hidden browser knows neither. Each flow hands it a `BrowserJob`: the provider's rules plus the
  connector's `ApprovalRules` (the buttons it may click on its own pages).

## Adding a sign-in provider

Most providers need no Swift. Save a JSON file in
`~/Library/Application Support/AWSAutoConnect/providers/` (the SSO tab links to the folder):

```json
{
  "id": "okta",
  "name": "Okta",
  "hosts": ["okta.com"],
  "signInURL": "https://yourorg.okta.com/",
  "needsUser": ["input[type=password]", "input[name=identifier]"],
  "pick": [],
  "passThrough": ["^/app/.*/sso/saml"],
  "otherPagesNeedUser": false,
  "serviceButton": "^(sign in|log in) with okta$"
}
```

| Field | Meaning |
|---|---|
| `hosts` | Hosts of its sign-in pages; subdomains match too. |
| `needsUser` | CSS selectors; a visible match shows the sign-in window (notification, red dot). |
| `pick` | Choosers: exactly one visible match is clicked, more than one needs you. |
| `passThrough` | Path regexes of redirect pages that never need you. |
| `otherPagesNeedUser` | Any other page on these hosts needs you (2-step, passkeys). |
| `serviceButton` | Button on a service's own login page that signs in with this provider. |

To ship it built in, add it next to `IdentityProvider.google` in `SignIn/IdentityProvider.swift` and
add tests to `Tests/AWSAutoConnectTests/PageScriptTests.swift` with trimmed copies of its real pages
(sign-in, account chooser, 2-step, redirect). We can't test providers we don't use, so the tests are
what keeps it working.

## Adding a connector

1. Create `Sources/AWSAutoConnect/Connectors/<Name>/` with an `@Observable` class conforming to
   `Connector` (or `TunnelConnector`). Keep its settings in `config` via the typed helpers
   (`config.bool("key", default:)`, `config.set(...)`).
2. For CLI logins that print or open a URL (`<tool> login`), use `CLILogin`: it runs the command,
   catches the URL (from the output, or by standing in for `open` / `$BROWSER`), and lets the hidden
   browser click your `ApprovalRules`. See `GrafanaConnector` (~200 lines) for a complete example.
3. Add a SwiftUI settings view and return it from `settingsTabs`.
4. List the type in `ConnectorRegistry.types`. It appears in General ▸ Connectors.
5. Add unit tests for any output parsing.

`type` strings are stored in users' settings: never rename one after release.

Anything that needs root goes through `helper/vpn-helper`, which only accepts a fixed set of
commands. A new tunnel type adds its own named commands there, with the same care as the existing ones
(validate every argument, read user files as the user). No general "run this as root".

## Pull requests

- Keep changes focused; run `swift build` and `swift test`.
- Match the surrounding style: short doc comments that say why, no dead code.
- Describe how you tested, especially for provider rules and anything touching the helper.
