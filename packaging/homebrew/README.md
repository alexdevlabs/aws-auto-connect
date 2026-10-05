# Homebrew tap

`aws-autoconnect.rb` is the formula for the `alexdevlabs/homebrew-tap` repository. It builds the app
from source on the user's Mac (needs only the Command Line Tools), so there's no Gatekeeper warning and no Developer ID
signature is needed.

```bash
brew install alexdevlabs/tap/aws-autoconnect          # latest release
brew install --HEAD alexdevlabs/tap/aws-autoconnect   # main branch
```

## Setting up the tap (once)

1. Create the GitHub repository `alexdevlabs/homebrew-tap`.
2. Copy `aws-autoconnect.rb` to `Formula/aws-autoconnect.rb` in it.

## Releasing a version

In this order, so nobody is offered an update Homebrew can't install yet:

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit and push.
2. Tag and push: `git tag -s vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`.
3. Get the tarball's checksum:
   `curl -fsSL https://github.com/alexdevlabs/aws-auto-connect/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`
4. Update `url` and `sha256` here and in the tap's `Formula/aws-autoconnect.rb`, run
   `brew audit --strict alexdevlabs/tap/aws-autoconnect`, then commit and push both.
5. Check it: `brew upgrade aws-autoconnect` (or `brew install`) and `brew test aws-autoconnect`.
6. Publish a GitHub release for the tag with generated notes (web UI, or
   `gh release create vX.Y.Z --generate-notes`). The app's update check reads the latest release,
   so this is what offers the update.

Keep `CFBundleShortVersionString` in `Resources/Info.plist` in step with the tag.
