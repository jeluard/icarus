# Apple Code Signing Setup

## Overview

This project is configured for GitHub Actions-based Apple code signing. Desktop builds for release are signed automatically when tags are pushed.

## Local Development

For local builds, the project uses **ad-hoc code signing** (`-` identity) by default, which is sufficient for development and local testing.

```bash
make build  # Uses ad-hoc signing if APPLE_SIGNING_IDENTITY not set
```

## Release Signing (GitHub Actions)

When you push a version tag (e.g., `v0.3.14`), the release workflow builds and signs the app using credentials from GitHub Secrets.

### Required GitHub Secrets

Set these in your repository settings under **Settings > Secrets and variables > Actions**:

| Secret | Description |
|--------|-------------|
| `APPLE_SIGNING_IDENTITY` | Certificate common name (e.g., `"Developer ID Application: Company Name (ABC123XYZ)"`) |
| `APPLE_CERTIFICATE` | Base64-encoded .p12 certificate file |
| `APPLE_CERTIFICATE_PASSWORD` | Password for the .p12 file |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_PASSWORD` | App-specific password for `APPLE_ID` |
| `APPLE_TEAM_ID` | Team ID for notarization (e.g., `ABC123XYZ`) |

### Prepare Your Certificate

```bash
# Convert .cer to .p12
openssl pkcs12 -export -in certificate.cer -inkey private_key.key -out certificate.p12 -name "Developer ID Application: Company Name (ABC123XYZ)"

# Encode to base64 for GitHub
base64 < certificate.p12 | pbcopy
```

Then paste into `APPLE_CERTIFICATE` secret.

### Notarization Notes

- **Apple ID** and **App Password** enable automatic notarization (optional but recommended for distribution)
- App-specific passwords can be created at https://appleid.apple.com
- Without notarization credentials, builds still sign but won't be notarized

## Configuration Files

- **tauri.conf.json**: `signingIdentity` uses `${APPLE_SIGNING_IDENTITY:-}` env var (ad-hoc fallback)
- **.github/workflows/release.yml**: Passes secrets to build environment
- **Makefile**: `make build` sets `APPLE_SIGNING_IDENTITY` to `"-"` if not provided

## Testing

To test ad-hoc signing locally:

```bash
# Build with local ad-hoc signing
make build

# Mount and verify the DMG
hdiutil mount src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/*.dmg
codesign -v /Volumes/Icarus/Icarus.app/Contents/MacOS/icarus
```

Should see: `valid on disk` (not `adhoc`)
