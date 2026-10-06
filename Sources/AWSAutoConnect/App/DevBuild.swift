/// `make dev` builds with `-DDEV`, so a test copy is easy to tell from the installed app (orange menu
/// bar mark, DEV label in the panel). Release builds, the Homebrew formula and `make install` don't
/// set it, so none of this is compiled in there.
enum DevBuild {
    #if DEV
    static let isDev = true
    #else
    static let isDev = false
    #endif
}
