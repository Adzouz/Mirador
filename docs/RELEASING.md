# Releasing

Releases are built by GitHub Actions ([`.github/workflows/release.yml`](../.github/workflows/release.yml)) when a
`v*` tag is pushed. The workflow runs the tests, builds a universal DMG with `scripts/make-dmg.sh`, and publishes a
GitHub release named **Mirador vX.Y.Z** with:

- install instructions, followed by GitHub's generated "What's Changed" notes (merged PRs since the previous tag);
- `Mirador-X.Y.Z.dmg` and its `.sha256`.

## Cut a release

```sh
git checkout main && git pull
echo "0.2.0" > VERSION            # optional: CI writes VERSION from the tag anyway
git commit -am "chore: release 0.2.0"
git tag v0.2.0
git push origin main v0.2.0
```

Follow the run under **Actions → Release**; the release appears under **Releases** when it is green.
To rebuild the assets of an existing tag: **Actions → Release → Run workflow** with that tag.

## One-time setup

### 1. Auto-updates (Sparkle)

Installed copies update themselves from the `appcast.xml` attached to the latest release. Each update is signed
with an EdDSA key; the public half is committed in [`Resources/sparkle-public-key`](../Resources/sparkle-public-key),
the private half must only exist in the maintainer's Keychain and in one repository secret.

```sh
swift package resolve
# Creates the key in your login Keychain (or prints the existing public key):
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mirador
# Export the private key once, store it as a secret, delete the file:
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account mirador -x sparkle-private-key.txt
gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key.txt && rm sparkle-private-key.txt
```

If you ever regenerate the key, commit the new public key in `Resources/sparkle-public-key`; apps built with the old
one will not accept updates signed with the new one (users reinstall once from the DMG).

Without `SPARKLE_PRIVATE_KEY`, releases still publish a DMG but no `appcast.xml`, and the workflow warns.

### 2. Developer ID signing and notarization (recommended)

Distribution outside the Mac App Store uses a **Developer ID Application** certificate (any paid Apple Developer
account) plus notarization, an automated Apple malware scan: no store listing, no review. Without it the app is
ad-hoc signed and users open it the first time with right-click → Open.

1. Xcode → Settings → Accounts → your team → **Manage Certificates…** → **+** → **Developer ID Application**.
2. Keychain Access → My Certificates → right-click the "Developer ID Application: …" certificate → **Export** as
   `.p12` with a password.
3. Create an app-specific password at [account.apple.com](https://account.apple.com) → Sign-In and Security.
4. Add the repository secrets:

```sh
gh secret set MACOS_SIGN_IDENTITY --body "Developer ID Application: Your Name (TEAMID)"
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12
gh secret set MACOS_CERTIFICATE_PASSWORD --body "<p12 password>"
gh secret set NOTARY_APPLE_ID --body "<apple id email>"
gh secret set NOTARY_TEAM_ID --body "TEAMID"
gh secret set NOTARY_PASSWORD --body "<app-specific password>"
```

The workflow then signs Sparkle's helpers, the CLI and the app with the hardened runtime, signs and notarizes the DMG
and staples the ticket. Locally, the same variables (`SIGN_IDENTITY`, `NOTARY_*`) work with `./scripts/make-dmg.sh`.

**Changing the signing later:** Sparkle refuses an update signed by a different Developer ID team than the
installed app. Going from ad-hoc to Developer ID is fine; switching teams afterwards is not.
