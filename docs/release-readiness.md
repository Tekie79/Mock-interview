# Mac release readiness

**Hold release.** Local tests and unsigned packaging passed for the M11 correction. Release gates remain open:

- Live shared-feed question precision and recall, duplicate and premature answers, and Scribe v3 Live same-audio strategy comparison. The human Q&A diagnostic still let two ambiguous turns reach classification. [Defect register](verification/m11-defect-register.md) · [Benchmark](verification/m11-performance-benchmark.md)
- Independently measured speech-end to first useful displayed text and completion, plus the actual 90-minute remote run. No remote endpoint is currently available. [Acceptance report](verification/m11-final-acceptance.md)
- Intermittent native **Test Audio** reproduction, physical candidate microphone, overlap, isolation, permission and hardware recovery. Both stacks captured 20/20 timed loop starts at the adapter layer. [Audio compatibility](verification/m11-audio-compatibility.md)
- Remaining live model/effort, alternate provider, grounding and interruption checks. [Provider qualification](verification/m11-provider-qualification.md)
- Signed installation and clean-host upgrade require separately authorized release work. The unsigned build is complete. [Draft PR #3 exact-commit evidence](https://github.com/Tekie79/Mock-interview/pull/3)

## Signing and distribution procedure

1. Check out the exact reviewed commit and run the Linux and both macOS regression jobs. Retain the test counts, logs, bundle identity and source revision.
2. Use the confirmed release bundle identifier and version with a valid Developer ID Application certificate. For an authorized signed build, enable hardened runtime and choose a release signing configuration consistent with the supported macOS permissions. Verify the signed app and inspect the signed entitlements.
3. Package the signed app for the selected distribution method. Submit the artifact with `xcrun notarytool submit <archive> --keychain-profile <profile> --wait`. Review the result, then staple and validate the ticket for the distributed package type.
4. Verify with the appropriate strict signing check and Gatekeeper assessment, such as `codesign --verify --deep --strict <app>` and `spctl --assess --type execute <app>`. Archive the exact package checksum and the notarization record.
5. Exercise clean installation and upgrade from a quarantined download on representative Macs. Confirm settings, Keychain access, SQLite data and expected privacy prompts. Repeat critical source, Start/Stop and answer flows against the signed artifact.

No signing credentials were used. The M11 builds are unsigned and local. Publication and distribution require the owner's explicit authorization. [Apple Developer ID](https://developer.apple.com/developer-id/) · [Apple notarization procedure](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Provider release boundaries

Live OpenAI and ElevenLabs smoke results apply to the account models and configurations listed in the qualification report. Deepgram and Anthropic need separate test credentials. ChatGPT sign-in remains gated until the owner can document official eligibility for the exact distribution and complete any required OpenAI approval. Subscription use and explicitly selected API billing stay separate. [Provider qualification](verification/m11-provider-qualification.md)
