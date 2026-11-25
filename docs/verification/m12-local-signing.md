# M12 personal macOS signing

The personal local-signing workflow packages the native Release through the existing unsigned build, then applies the owner’s persistent login Keychain identity. The separate unsigned CI jobs remain the repository build checks. Public distribution uses a separate release decision.

## Build and verify

Use the named identity **Mock Interview Local Signing**, created in the login Keychain as **Self Signed Root** with **Code Signing** usage. Keep the certificate and private key in that Keychain. Certificate Assistant is the macOS tool for creating the identity. [Apple Certificate Assistant](https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac)

From the repository root:

```bash
./scripts/build.sh
./scripts/test.sh
./scripts/package-local-signed.sh .build/macos-local-signed
```

Use a fresh output directory for each build. The script produces the app, ZIP, ZIP checksum and a signing verification report. Future local releases use the same SHA-256 certificate fingerprint pinned at `~/Library/Application Support/MockInterview Local Signing/certificate.sha256`. Certificate replacement creates a new macOS identity and may require renewed permissions. The pin records a public digest and has no role in app data storage.

The app uses bundle ID `com.mockinterview.desktop` and a designated requirement that combines the bundle ID with the exact leaf certificate. The requirement language represents the leaf pin as SHA-1. The script checks the certificate independently by SHA-256. It verifies both executable slices, macOS 14.2 deployment, Hardened Runtime, Audio Input entitlement and signature integrity before and after ZIP extraction. [Apple code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/) · [Apple Audio Input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)

For another local version or an upgrade test using the same identity:

```bash
./scripts/package-local-signed.sh .build/macos-local-upgrade 12.2.1
```

The optional number updates the staged app’s build number before signing. Compare the two reports for certificate and requirement equality before installing the second app. Compare macOS behavior separately. Signature compatibility alone does not prove preserved privacy or Keychain authorization.

## Installation and upgrade

1. Verify the ZIP checksum from its output directory using `shasum -a 256 -c MockInterview-1.0.0-local-signed.zip.sha256`. Extract and verify the app with `codesign --verify --deep --strict --all-architectures MockInterview.app`.
2. Quit Mock Interview. If there is already a `/Applications/MockInterview.app`, copy it to a distinct backup directory before replacing it. Keep the backup until the new build has launched and existing settings are visible.
3. Copy the verified app to `/Applications/MockInterview.app` and open it from Finder. Complete any macOS requests for System Audio Recording, Microphone or Keychain access locally. macOS applies its own trust and launch policy to a locally signed bundle. [Apple code-signing certificates](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)
4. Confirm profiles and preferences, and use a synthetic input in OpenAI’s existing Connection Tests. Use Test Audio with controlled playback and the selected candidate microphone, then repeat after installing a second version with the same certificate.
5. To restore the saved bundle, quit the installed app and replace it with the backed-up copy. The existing application data directory and Keychain item remain outside the app bundle.

## Verification record

Reviewed application source `03cd472e8ec392b2604d2fdcd566f1d2a3357209`. Record the local package fingerprint, exact requirement, checksum, installed path and runtime evidence here and in PR #4 once verified.
