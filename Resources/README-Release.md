# Release builds

OpenInTerminal 2.3.10 targets macOS 12 or later and builds both `arm64` and `x86_64` with Xcode 27. The main app, Finder extension, and login helper use this fork's `noxluna.app` identifiers. Shared preferences use the extension's Application Scripts directory; older file preferences are migrated on launch.

Install a Developer ID Application certificate with its private key in the login keychain. Sign in to the corresponding paid Apple Developer account in Xcode Settings → Accounts, then run from the repository root:

```sh
bash build-signed.sh OpenInTerminal
```

The script uses a valid `OpenInTerminal-notary` keychain profile when available. Otherwise it uses the developer account already signed in to Xcode to upload and export a notarized app. An explicit Xcode invocation is:

```sh
NOTARY_METHOD=xcode EXPORT_DIR=export/2.3.10 bash build-signed.sh OpenInTerminal
```

Output includes `OpenInTerminal.app`, `OpenInTerminal.zip`, and `OpenInTerminal.zip.sha256`. The app includes the project and ShortcutRecorder licenses. Distribution archives and matching debug symbols remain under `build/release/`.

Verify before uploading:

```sh
codesign --verify --deep --strict export/2.3.10/OpenInTerminal.app
xcrun stapler validate export/2.3.10/OpenInTerminal.app
spctl -a -t exec -vv export/2.3.10/OpenInTerminal.app
cd export/2.3.10 && shasum -a 256 -c OpenInTerminal.zip.sha256
```

Gatekeeper must report `accepted` and `source=Notarized Developer ID`. Upload the ZIP and checksum to the GitHub release, then download and verify the uploaded ZIP again. `SKIP_NOTARIZE=1` produces a signed testing artifact that must not be used for the public release.

Keep certificates, private keys, and notarization credentials in the local keychain or a secure backup outside the repository. This fork does not update the upstream Homebrew cask.
