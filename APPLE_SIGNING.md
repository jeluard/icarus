# Apple Code Signing Setup

This repo already has the Tauri wiring for macOS release signing in `.github/workflows/release.yml` and `src-tauri/tauri.conf.json`. The missing part is supplying the Apple credentials in GitHub Actions.

## What This Repo Requires

Keep the setup narrow:

1. A paid Apple Developer account.
2. A Mac.
3. A `Developer ID Application` certificate installed in Keychain.
4. A `.p12` export of that certificate.
5. Apple notarization credentials.

If `security find-identity -v -p codesigning` only shows `Apple Development`, stop there. That is not enough for the GitHub macOS release flow used here.

## Local Development

Local builds use ad-hoc signing by default:

```bash
make build
```

That is fine for local testing. It is not the release path.

## Release Path

For GitHub releases, this repo follows the Tauri macOS distribution path:

1. Sign with `Developer ID Application`.
2. Notarize with Apple ID credentials.
3. Upload the DMG from GitHub Actions.

The workflow currently expects these GitHub Actions secrets:

| Secret | Source |
|--------|--------|
| `APPLE_SIGNING_IDENTITY` | Keychain identity name, for example `Developer ID Application: Name (TEAMID)` |
| `APPLE_CERTIFICATE` | Base64 of the exported `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_PASSWORD` | Apple app-specific password |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

## Simplest Setup

### 1. Create the correct certificate

In the Apple Developer portal, create a `Developer ID Application` certificate from a CSR generated on your Mac. Install the downloaded `.cer` on that same Mac.

After that, this should show the correct identity:

```bash
security find-identity -v -p codesigning
```

### 2. Export it as `.p12`

In Keychain Access, open `My Certificates`, find `Developer ID Application: ...`, then export it as a `.p12` file.

The easiest location for this repo is:

```bash
./certificate.p12
```

### 3. Create the notarization password

Create an Apple app-specific password at:

https://appleid.apple.com

### 4. Populate GitHub secrets

Run:

```bash
make apple-secrets
```

The script in `scripts/setup-gh-apple-secrets.sh` now keeps prompts to the minimum needed for this repo:

- repo: auto-detected from `origin`
- signing identity: auto-detected from Keychain or the `.p12` when possible
- team id: derived when possible
- certificate path: defaults to `./certificate.p12` when present
- user prompts: only for values the script cannot infer and for the notarization credentials required by this release flow

## Notes

- This repo currently uses Apple ID notarization in GitHub Actions, not the App Store Connect API variant.
- Tauri supports ad-hoc signing with `-` for local builds, which is what `make build` uses when no Apple identity is set.
- For an external macOS release signed with `Developer ID Application`, treat notarization as part of the required setup.
