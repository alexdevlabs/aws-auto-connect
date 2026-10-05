import AppKit

Prefs.migrateOldDomain()
if AppInstaller.relaunchFromApplicationsIfNeeded() { exit(0) }

let delegate = MainActor.assumeIsolated { AppDelegate() }
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
