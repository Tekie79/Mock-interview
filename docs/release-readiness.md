# Mac release readiness

**Hold release.** M11 has runtime and provider smoke evidence and an open final acceptance gate. The baseline held-out text run missed the precision target. Independently measured displayed-answer latency, the actual 90-minute remote test, representative hardware recovery and signed installation are still required. [M11 acceptance](verification/m11-final-acceptance.md) · [Benchmark](verification/m11-performance-benchmark.md)

## Signing and distribution procedure

1. Check out the exact reviewed commit and run the Linux and both macOS regression jobs. Retain the test counts, logs, bundle identity and source revision.
2. Use the confirmed release bundle identifier and version with a valid Developer ID Application certificate. For an authorized signed build, enable hardened runtime and choose a release signing configuration consistent with the supported macOS permissions. Verify the signed app and inspect the signed entitlements.
3. Package the signed app for the selected distribution method. Submit the artifact with `xcrun notarytool submit <archive> --keychain-profile <profile> --wait`. Review the result, then staple and validate the ticket for the distributed package type.
4. Verify with the appropriate strict signing check and Gatekeeper assessment, such as `codesign --verify --deep --strict <app>` and `spctl --assess --type execute <app>`. Archive the exact package checksum and the notarization record.
5. Exercise clean installation and upgrade from a quarantined download on representative Macs. Confirm settings, Keychain access, SQLite data and expected privacy prompts. Repeat critical source, Start/Stop and answer flows against the signed artifact.

No signing credentials were used. The M11 builds are unsigned and local. Publication and distribution require the owner's explicit authorization. [Apple Developer ID](https://developer.apple.com/developer-id/) · [Apple notarization procedure](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Provider release boundaries

Live OpenAI and ElevenLabs smoke results apply to the account models and configurations listed in the qualification report. Deepgram and Anthropic need separate test credentials. ChatGPT sign-in remains gated until the owner can document official eligibility for the exact distribution and complete any required OpenAI approval. Subscription use and explicitly selected API billing stay separate. [Provider qualification](verification/m11-provider-qualification.md)
