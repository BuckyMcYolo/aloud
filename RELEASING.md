# Releasing Aloud

## One-time setup

1. **Notary credentials** — generate an app-specific password at
   [appleid.apple.com](https://account.apple.com/account/manage) (Sign-In and
   Security › App-Specific Passwords), then store it:

   ```
   xcrun notarytool store-credentials aloud \
     --apple-id YOUR_APPLE_ID --team-id 3RR5DSQAVQ
   ```

2. **GitHub repos** — create `aloud` (this repo) and `homebrew-tap`.
   Copy `packaging/Casks/aloud.rb` into the tap as `Casks/aloud.rb`
   and replace `BuckyMcYolo` in both files.

## Each release

```
# 1. bump CFBundleShortVersionString in swift/make_app.sh, commit, tag
git tag v0.2.0 && git push --tags

# 2. build + notarize + staple + DMG (prints the sha256)
./swift/release.sh

# 3. publish
gh release create v0.2.0 swift/build/Aloud-0.2.0.dmg --title "Aloud 0.2.0"

# 4. update the cask in homebrew-tap: bump version, paste sha256, push
```

Users then install with either:

- `brew install --cask BuckyMcYolo/tap/aloud`
- or download the DMG from GitHub Releases and drag to Applications.

First launch downloads the Kokoro model (~310 MB) into
`~/Library/Application Support/Aloud`. The only permission the app asks for
is Accessibility (to read the selection), shown as "Aloud" in System
Settings.
