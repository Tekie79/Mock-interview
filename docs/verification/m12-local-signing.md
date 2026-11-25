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

Both packages were built from a clean `b0303b846201f9d7d16a1869fc96584369df0e1d` on an Apple Silicon Mac running macOS 26.3.2 and Xcode 26.6. Application code matches the reviewed revision. The repository’s `package-macos.sh` was the available baseline for the local signing script.

- Identity `Mock Interview Local Signing`, RSA 2048, expires November 22, 2036.
- Certificate SHA-256 `E8321C0DA7797F7FACD93A55656B92AF088B883E50DD207346B15FACBA62F3F0`.
- Designated requirement `identifier "com.mockinterview.desktop" and certificate leaf = H"2af453bfb9f6a14ef434a38d95b8384a0ba8a33f"`.
- Installed 1.0.0 (12.2) ZIP SHA-256 `ded6f133f2a5e90d04f9bf1e5aa0ba3cf036b40610ce9c795d19c005e83e2448`.
- Upgrade trial 1.0.0 (12.2.1) ZIP SHA-256 `68a0b20079d636351be1e78843f6c4b746103228c06f987288285fb7be2bdd48`.

| Check | Evidence |
| --- | --- |
| Deterministic regressions | 165 passed locally. Portable build and separate unsigned universal Release passed. |
| Signed bundle and ZIP extraction | Both builds passed strict verification on both executable architectures, minimum macOS 14.2, Hardened Runtime, Audio Input entitlement and fixture exclusion. The extracted app preserved its privacy metadata. |
| Installation | The verified 12.2 bundle was the first at `/Applications/MockInterview.app`. The copied executable matched the release artifact, the installed signature passed and the application launched from that path. |
| Saved profile and settings | The installed app loaded the selected existing profile, profile library, output route, automatic answer and Adaptive preferences. |
| Presentation | The installed app opened Compact and switched Focus, Chat and Answers Only in the idle UI. The test returned the presentation preferences to their original values. |
| First-run OS authorization | The installed signer requested Microphone and System Audio Recording. The first dual-source test timed out awaiting macOS. The signed app detected the existing OpenAI Keychain entry and its synthetic classification check awaited Keychain access. |
| Physical audio, live context and session lifecycle | Require the owner’s macOS authorization on the installed signer. The test does not count the earlier unsigned observations as signed-runtime evidence. |
| Same-certificate upgrade | The signed and extracted upgrade build has the same certificate and designated requirement. Runtime authorization retention still requires successful first-build grants and an installed-upgrade retest. |
