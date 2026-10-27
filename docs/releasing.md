# Release a Mac build

Install Xcode command line tools and a Developer ID Application certificate. Save Apple notarization credentials in Keychain with `xcrun notarytool store-credentials`.

```sh
DAYBOOK_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
DAYBOOK_NOTARY_PROFILE="your-keychain-profile" ./release.sh
```

The script signs the app and helper, submits the app and DMG to Apple, staples both tickets, and verifies the result. Files are written to `.build/release/`. Without these settings, the script builds an ad-hoc signed, unnotarized DMG for local testing.

Publish the DMG, `Daybook-Helper.zip`, and `SHA256SUMS.txt` under a GitHub release tag matching the app version (for example `v0.3.0`). Keep the helper ZIP from the same build: the app verifies its bundled SHA-256 before installing a download. A bundled helper is also available offline.

Never commit credentials, pairing files, activity databases, or signing keys.

## Use an existing Xcode account

Xcode Organizer can notarize a signed macOS app archive through **Distribute App → Direct Distribution**, using the developer account already configured in Xcode. Wait for **Ready to distribute**, then choose **Export Notarized App**. Verify the export with `xcrun stapler validate` and `spctl --assess --type execute` before packaging it as a ZIP.

Version 0.3.0 uses this flow. Its app ZIP contains an attached Apple ticket; it does not ship the earlier unnotarized DMG. Local builds remain unnotarized unless you complete either release workflow.
