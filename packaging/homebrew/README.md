# Homebrew tap

`aws-autoconnect.rb` is the formula for the `alexdevlabs/homebrew-tap` repository. It builds the app
from source on the user's Mac (needs Xcode), so there's no Gatekeeper warning and no Developer ID
signature is needed.

```bash
brew install alexdevlabs/tap/aws-autoconnect          # latest release
brew install --HEAD alexdevlabs/tap/aws-autoconnect   # main branch
```

## Setting up the tap (once)

1. Create the GitHub repository `alexdevlabs/homebrew-tap`.
2. Copy `aws-autoconnect.rb` to `Formula/aws-autoconnect.rb` in it.

## Releasing a version

1. Tag and push: `git tag -s v1.0.0 -m v1.0.0 && git push origin v1.0.0`.
2. Publish a GitHub release for the tag (the app's update check reads the latest release and links its
   notes): `gh release create v1.0.0 --generate-notes`.
3. Get the tarball's checksum:
   `curl -fsSL https://github.com/alexdevlabs/aws-auto-connect/archive/refs/tags/v1.0.0.tar.gz | shasum -a 256`
4. In the tap, update `url` (the tag) and `sha256`, then commit and push. Do this right after the
   release: until the tap has it, the app's **Update** button reports that Homebrew doesn't have it yet.
5. Check it: `brew install --build-from-source alexdevlabs/tap/aws-autoconnect && brew test aws-autoconnect`.

Keep `CFBundleShortVersionString` in `Resources/Info.plist` in step with the tag.
