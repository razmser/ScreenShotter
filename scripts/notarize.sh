#!/usr/bin/env bash
# Notarizes build/ScreenShotter.app and staples the ticket to it. The app must
# be signed with a "Developer ID Application" identity:
#
#   SIGN_IDENTITY="Developer ID Application" ./scripts/build-app.sh
#
# Credentials, one of:
#   NOTARY_PROFILE  profile saved with `xcrun notarytool store-credentials`
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER
#                   App Store Connect API key: path to the .p8 file, its key ID,
#                   and the issuer ID (leave NOTARY_ISSUER unset for an
#                   individual key)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/ScreenShotter.app"
ZIP="build/ScreenShotter-notarize.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    auth=(--keychain-profile "$NOTARY_PROFILE")
else
    auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID")
    if [[ -n "${NOTARY_ISSUER:-}" ]]; then
        auth+=(--issuer "$NOTARY_ISSUER")
    fi
fi

# The notary service only accepts archives, but the ticket is stapled to the
# app itself, so this zip is thrown away afterwards.
ditto -c -k --keepParent "$APP" "$ZIP"
submission="$(xcrun notarytool submit "$ZIP" "${auth[@]}" --output-format json)" || true
rm -f "$ZIP"
id="$(plutil -extract id raw -o - - <<<"$submission" 2>/dev/null || true)"
if [[ -z "$id" ]]; then
    echo "Upload failed: $submission" >&2
    exit 1
fi
# Printed up front so a slow submission can be followed with
# `xcrun notarytool info <id>` even if the wait below is interrupted.
echo "Submitted $id, waiting for Apple's verdict"
result="$(xcrun notarytool wait "$id" "${auth[@]}" --output-format json)" || true

# notarytool can exit 0 for a rejected submission, so check the status.
status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
if [[ "$status" != "Accepted" ]]; then
    echo "Notarization of $id failed (status: ${status:-unknown}): $result" >&2
    xcrun notarytool log "$id" "${auth[@]}" >&2
    exit 1
fi

xcrun stapler staple "$APP"
# Gatekeeper's verdict, as for a downloaded copy: expect "Notarized Developer ID".
spctl --assess --type execute --verbose=2 "$APP"
