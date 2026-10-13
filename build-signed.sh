#!/bin/bash
#
# Build, Developer-ID sign, NOTARIZE and staple OpenInTerminal for distribution
# outside the Mac App Store. Pass Lite scheme names to package those separately.
#
# Unlike build-unsigned.sh (ad-hoc "Sign to Run Locally"), this produces artifacts
# that pass Gatekeeper and satisfy Homebrew/cask's "signed AND notarized" rule.
#
# Strategy: build each app with signing turned off (so Xcode never demands a
# provisioning profile for the app-groups / sandbox capabilities), then re-sign
# the finished bundles with a "Developer ID Application" certificate, enabling the
# hardened runtime (--options runtime) and a secure timestamp (--timestamp) — both
# mandatory for notarization. The bundle is then zipped, submitted to Apple's
# notary service, and the resulting ticket is stapled into the .app.
#
# For the full OpenInTerminal app the login-item helper is embedded into
# Contents/Library/LoginItems and signed too, so "Launch at Login" works.
#
# Output: ./export/<App>.app  (stapled)  and  ./export/<App>.zip  (ready to upload)
#
# ---------------------------------------------------------------------------
# Prerequisites (all tied to your paid Apple Developer account):
#
#   1. A "Developer ID Application" certificate installed in your login keychain.
#         security find-identity -v -p codesigning | grep "Developer ID Application"
#      Create it at https://developer.apple.com/account/resources/certificates
#      (or via Xcode > Settings > Accounts > Manage Certificates > +).
#
#   2. Sign in to your developer account in Xcode, or store notary credentials
#      as a keychain profile:
#         xcrun notarytool store-credentials "OpenInTerminal-notary" \
#           --apple-id "you@example.com" \
#           --team-id  "XXXXXXXXXX" \
#           --password "app-specific-password"      # appleid.apple.com > App-Specific Passwords
#      ...or with an App Store Connect API key:
#         xcrun notarytool store-credentials "OpenInTerminal-notary" \
#           --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#
# Configuration (override via environment):
#   SIGN_ID         signing identity; default: auto-detected Developer ID Application
#   NOTARY_PROFILE  notarytool keychain profile name; default: OpenInTerminal-notary
#   NOTARY_METHOD   auto (default), notarytool, or xcode; auto uses Xcode if the
#                   keychain profile is unavailable
#   SKIP_NOTARIZE   set to 1 to sign only (no notarization/stapling) — for testing
#   DERIVED         build directory; default: build/release
#   EXPORT_DIR      output directory; default: export
# Pass scheme names to build selected apps: bash build-signed.sh OpenInTerminal
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")"

WORKSPACE="OpenInTerminal.xcworkspace"
CONFIG="Release"
DERIVED="${DERIVED:-build/release}"
EXPORT_DIR="${EXPORT_DIR:-export}"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"
EXT_ENT="OpenInTerminalFinderExtension/OpenInTerminalFinderExtension.entitlements"
HELPER="OpenInTerminalHelper.app"
HELPER_ENT="OpenInTerminalHelper/OpenInTerminalHelper.entitlements"

NOTARY_PROFILE="${NOTARY_PROFILE:-OpenInTerminal-notary}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
NOTARY_METHOD="${NOTARY_METHOD:-auto}"

# scheme:app-entitlements pairs
TARGETS=(
  "OpenInTerminal:OpenInTerminal/OpenInTerminal.entitlements"
)

if [[ "$#" -gt 0 ]]; then
  TARGETS=()
  for scheme in "$@"; do
    case "$scheme" in
      OpenInTerminal) TARGETS+=("$scheme:OpenInTerminal/OpenInTerminal.entitlements") ;;
      OpenInTerminal-Lite) TARGETS+=("$scheme:OpenInTerminal-Lite/OpenInTerminal-Lite/OpenInTerminal-Lite.entitlements") ;;
      OpenInEditor-Lite) TARGETS+=("$scheme:OpenInEditor-Lite/OpenInEditor-Lite/OpenInEditor-Lite.entitlements") ;;
      *) echo "Unknown scheme: $scheme" >&2; exit 1 ;;
    esac
  done
fi

# --- Resolve the signing identity ------------------------------------------
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n1)"
fi
if [[ -z "${SIGN_ID:-}" ]]; then
  echo "!! No 'Developer ID Application' identity found in the keychain." >&2
  echo "   Install one from your Apple Developer account, or set SIGN_ID explicitly." >&2
  echo "   Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi
echo "==> Signing identity: $SIGN_ID"

# --- Verify notary credentials up front (fail fast, before the long build) --
if [[ "$SKIP_NOTARIZE" != "1" ]]; then
  if [[ "$NOTARY_METHOD" == "auto" ]]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      NOTARY_METHOD="notarytool"
    else
      NOTARY_METHOD="xcode"
    fi
  fi
  if [[ "$NOTARY_METHOD" != "xcode" && "$NOTARY_METHOD" != "notarytool" ]]; then
    echo "!! NOTARY_METHOD must be auto, xcode, or notarytool" >&2
    exit 1
  fi
  if [[ "$NOTARY_METHOD" == "notarytool" ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "!! Notary keychain profile '$NOTARY_PROFILE' is missing or invalid." >&2
    echo "   Create it with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" ..." >&2
    echo "   (see the header of this script), or run with SKIP_NOTARIZE=1 to sign only." >&2
    exit 1
  fi
  echo "==> Notarization method: $NOTARY_METHOD"
fi

# Developer-ID sign an .app bundle strictly leaf-first so every inner signature
# is sealed before the bundle that contains it:
#   dylibs -> frameworks -> app extensions -> nested (helper) apps -> the app
# Every signature uses the hardened runtime (--options runtime) and a secure
# timestamp (--timestamp); both are required by the notary service.
sign() {  # $1 = .app bundle, $2 = app entitlements
  local app="$1" ent="$2"
  local common=(--force --options runtime --timestamp --sign "$SIGN_ID")
  find "$app" -type f -name "*.dylib" -print0 | while IFS= read -r -d '' d; do
    codesign "${common[@]}" "$d"
  done
  find "$app" -depth -type d -name "*.framework" -print0 | while IFS= read -r -d '' fw; do
    codesign "${common[@]}" "$fw"
  done
  find "$app" -depth -type d -name "*.appex" -print0 | while IFS= read -r -d '' ext; do
    codesign "${common[@]}" --entitlements "$EXT_ENT" "$ext"
  done
  # nested apps (e.g. the login-item helper)
  find "$app" -depth -mindepth 1 -type d -name "*.app" -print0 | while IFS= read -r -d '' sub; do
    codesign "${common[@]}" --entitlements "$HELPER_ENT" "$sub"
  done
  codesign "${common[@]}" --entitlements "$ent" "$app"
}

mkdir -p "$EXPORT_DIR"

for pair in "${TARGETS[@]}"; do
  scheme="${pair%%:*}"
  ent="${pair#*:}"
  echo "==> Building $scheme (unsigned)"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$scheme" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination 'generic/platform=macOS' \
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=12.0 \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

  app="$PRODUCTS/$scheme.app"

  # Embed the login-item helper into the full app so "Launch at Login" works.
  if [[ "$scheme" == "OpenInTerminal" ]]; then
    if [[ -d "$PRODUCTS/$HELPER" ]]; then
      echo "==> Embedding $HELPER into LoginItems"
      mkdir -p "$app/Contents/Library/LoginItems"
      rm -rf "$app/Contents/Library/LoginItems/$HELPER"
      cp -R "$PRODUCTS/$HELPER" "$app/Contents/Library/LoginItems/"
    else
      echo "!! $HELPER not found in products; refusing an incomplete release" >&2
      exit 1
    fi
  fi

  out="$EXPORT_DIR/$scheme.app"
  rm -rf "$out"
  ditto "$app" "$out"
  mkdir -p "$out/Contents/Resources"
  cp LICENSE "$out/Contents/Resources/LICENSE"
  shortcut_license="$DERIVED/SourcePackages/checkouts/ShortcutRecorder/LICENSE.txt"
  if [[ -f "$shortcut_license" ]]; then
    cp "$shortcut_license" "$out/Contents/Resources/ShortcutRecorder-LICENSE.txt"
  fi
  echo "==> Developer-ID signing $scheme.app"
  sign "$out" "$ent"
  codesign --verify --deep --strict --verbose=2 "$out"

  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "==> SKIP_NOTARIZE=1 — zipping signed (not notarized) $scheme"
    ditto -c -k --sequesterRsrc --keepParent "$out" "$EXPORT_DIR/$scheme.zip"
    echo "==> Exported $EXPORT_DIR/$scheme.zip (signed, NOT notarized)"
    continue
  fi

  # --- Notarize -------------------------------------------------------------
  if [[ "$NOTARY_METHOD" == "xcode" ]]; then
    archive="$DERIVED/$scheme-distribution.xcarchive"
    notarized="$DERIVED/$scheme-notarized"
    rm -rf "$archive" "$notarized"
    # Wrap the already-signed build with its matching dSYMs. Keeping the symbols
    # from this build avoids UUID mismatches with a separately compiled archive.
    python3 - "$out" "$archive" "$PRODUCTS" "$scheme" <<'PY'
import datetime, pathlib, plistlib, shutil, subprocess, sys
app, archive, products = map(pathlib.Path, sys.argv[1:4])
scheme = sys.argv[4]
destination = archive / 'Products/Applications' / app.name
destination.parent.mkdir(parents=True)
subprocess.run(['ditto', str(app), str(destination)], check=True)
(archive / 'dSYMs').mkdir()
for symbols in products.glob('*.dSYM'):
    shutil.copytree(symbols, archive / 'dSYMs' / symbols.name, symlinks=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
signature = subprocess.run(['codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True, check=True).stderr.splitlines()
team = next(line.split('=', 1)[1] for line in signature if line.startswith('TeamIdentifier='))
identity = next(line.split('=', 1)[1] for line in signature if line.startswith('Authority='))
metadata = {'ArchiveVersion': 2, 'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Name': scheme, 'SchemeName': scheme,
            'ApplicationProperties': {'ApplicationPath': 'Applications/' + app.name, 'Architectures': ['arm64', 'x86_64'],
                                      'CFBundleIdentifier': info['CFBundleIdentifier'], 'CFBundleShortVersionString': info['CFBundleShortVersionString'],
                                      'CFBundleVersion': info['CFBundleVersion'], 'SigningIdentity': identity, 'Team': team}}
(archive / 'Info.plist').write_bytes(plistlib.dumps(metadata))
(archive.parent / (scheme + '-DeveloperIDUpload.plist')).write_bytes(plistlib.dumps({
    'method': 'developer-id', 'destination': 'upload', 'teamID': team,
    'signingStyle': 'manual', 'signingCertificate': identity, 'manageAppVersionAndBuildNumber': False}))
PY
    xcodebuild -exportArchive -archivePath "$archive" \
      -exportOptionsPlist "$DERIVED/$scheme-DeveloperIDUpload.plist" \
      -exportPath "$DERIVED/$scheme-notary-upload" -allowProvisioningUpdates
    attempt=0
    notary_log="$DERIVED/$scheme-notarized-export.log"
    until xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$notarized" > "$notary_log" 2>&1; do
      attempt=$((attempt + 1))
      if [[ "$attempt" -ge 20 ]] || ! /usr/bin/grep -Fq 'is processing and not ready for distribution' "$notary_log"; then
        cat "$notary_log" >&2
        exit 1
      fi
      echo "==> Apple is processing the notarization request; waiting 15 seconds ($attempt/20)"
      sleep 15
    done
    cat "$notary_log"
    rm -rf "$out"
    ditto "$notarized/$scheme.app" "$out"
  else
  # notarytool takes a zip (or dmg/pkg). Zip the signed .app, submit, wait.
  submit_zip="$EXPORT_DIR/$scheme-notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$out" "$submit_zip"
  echo "==> Submitting $scheme to the notary service (this can take a few minutes)"
  result="$EXPORT_DIR/$scheme-notary-result.json"
  xcrun notarytool submit "$submit_zip" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$result"
  status="$(/usr/bin/plutil -extract status raw -o - "$result")"
  if [[ "$status" != "Accepted" ]]; then
    submission_id="$(/usr/bin/plutil -extract id raw -o - "$result")"
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" \
      "$EXPORT_DIR/$scheme-notary-log.json"
    echo "!! Notarization status: $status. See $EXPORT_DIR/$scheme-notary-log.json" >&2
    exit 1
  fi
  rm -f "$submit_zip"

  # Staple the ticket into the .app so Gatekeeper works offline.
  echo "==> Stapling $scheme.app"
  xcrun stapler staple "$out"
  fi
  xcrun stapler validate "$out"
  codesign --verify --deep --strict "$out"
  spctl -a -t exec -vv "$out" 2>&1 | sed 's/^/    /'

  # Final distributable zip (contains the stapled app).
  ditto -c -k --sequesterRsrc --keepParent "$out" "$EXPORT_DIR/$scheme.zip"
  (cd "$EXPORT_DIR" && shasum -a 256 "$scheme.zip" > "$scheme.zip.sha256")
  echo "==> Exported $EXPORT_DIR/$scheme.zip (signed + notarized + stapled)"
done

echo
echo "Done. Artifacts are in ./$EXPORT_DIR :"
ls -1 "$EXPORT_DIR"
