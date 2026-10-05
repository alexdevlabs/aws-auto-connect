import AppKit

Prefs.migrateOldDomain()
if AppInstaller.relaunchFromApplicationsIfNeeded() { exit(0) }
Shell.warmUp()

let delegate = MainActor.assumeIsolated { AppDelegate() }
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
