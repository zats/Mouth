---
summary: "Mouth macOS release pipeline: build, sign, notarize, package (zip + dmg), and publish to GitHub Releases."
---

# Releasing Mouth (macOS)

This repo follows a CodexBar-style release flow:

1. Build an `xcarchive` and export a signed `.app` (Developer ID).
2. Notarize and staple the app.
3. Package artifacts:
   - `Mouth-<version>.zip` (stapled app, zipped with `ditto`)
   - `Mouth-<version>.dmg` (app + `/Applications` symlink)
   - `Mouth-<version>.dSYM.zip` (if present in the archive)
4. Create a GitHub Release and upload assets.

## Prereqs

- Xcode installed (the scripts call `xcodebuild`, `notarytool`, `stapler` via `xcrun`).
- `trash` installed (scripts avoid `rm` and use `trash` for cleanup).
- GitHub CLI installed and authenticated:
  - `gh auth status`
- Git remote `origin` configured to the GitHub repo you want to publish releases to.
- A Developer ID Application certificate available in your keychain.
- Notarization credentials (choose one):
  - Preferred: App Store Connect API key via environment variables (see below)
  - Alternative: a `notarytool` keychain profile (see below)

## Versioning

The scripts read version/build from Xcode build settings:

- `MARKETING_VERSION` (shown as the release version)
- `CURRENT_PROJECT_VERSION` (build number)

View what the scripts will use:

```bash
./Scripts/version.sh
```

## Notarization Auth

### Option A: App Store Connect API key (recommended for automation)

Set these environment variables:

- `APP_STORE_CONNECT_API_KEY_P8`: the entire `.p8` file content, with literal `\n` sequences between lines
- `APP_STORE_CONNECT_KEY_ID`: the key id
- `APP_STORE_CONNECT_ISSUER_ID`: the issuer id

### Option B: notarytool keychain profile

If you already have a keychain profile configured:

- `NOTARYTOOL_KEYCHAIN_PROFILE`: profile name to pass to `notarytool`

## Build + Notarize + Package (no GitHub release)

```bash
./Scripts/sign-and-notarize.sh
```

This writes a helper env file at:

- `/tmp/mouth-last-release-outputs.env`

## Publish to GitHub Releases

```bash
./Scripts/release.sh
```

This will:

- tag `v<MARKETING_VERSION>` and push it to `origin`
- create a GitHub release with auto-generated notes
- upload the `.zip`, `.dmg`, and optional `.dSYM.zip`

## Customization knobs

- `APP_NAME` (default `Mouth`)
- `PROJECT` (default `Mouth.xcodeproj`)
- `SCHEME` (default `Mouth`)
- `CONFIGURATION` (default `Release`)
- `TAG_PREFIX` (default `v`)
- `NOTARIZE_DMG` (default `1`)
- `SKIP_NOTARIZATION=1` (optional; runs archive/export/packaging but skips notarytool and stapling)
- `DMG_SIGN_IDENTITY` (optional; if set, the DMG is `codesign`ed before notarization)
- `CLEANUP_RELEASE_DIR=1` (optional; trash the temp release dir at the end)
