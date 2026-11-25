# Mac release readiness

**Hold release.** OpenAI is the primary production qualification scope. Mandatory product, hardware and performance gates remain open.

- OpenAI question precision, recall, duplicate and premature-response rates on independently attributed channels. Shared audio without reliable separation remains manual. [Defect register](verification/m11-defect-register.md) · [Benchmark](verification/m11-performance-benchmark.md)
- Independently measured speech-end to first useful displayed text and completion, plus the actual 90-minute remote run. No remote endpoint is currently available. [Acceptance report](verification/m11-final-acceptance.md)
- Native **Test Audio** startup stalled inside Core Audio while the OS requested a new authorization for the unsigned identity. The bounded failure path was exercised. Twenty successful dual-source cycles, physical overlap and hardware recovery remain unqualified. [Audio compatibility](verification/m11-audio-compatibility.md)
- Live OpenAI configuration, grounding, context continuity, interruption recovery and native Chat View performance. [Provider qualification](verification/m11-provider-qualification.md)
- Signed installation and clean-host upgrade require separately authorized release work. The unsigned build is complete. [Draft PR #3 exact-commit evidence](https://github.com/Tekie79/Mock-interview/pull/3)

## Signing and distribution procedure

1. Check out the exact reviewed commit and run the Linux and both macOS regression jobs. Retain the test counts, logs, bundle identity and source revision.
2. Use the confirmed release bundle identifier and version with a valid Developer ID Application certificate. For an authorized signed build, enable hardened runtime and choose a release signing configuration consistent with the supported macOS permissions. Verify the signed app and inspect the signed entitlements.
3. Package the signed app for the selected distribution method. Submit the artifact with `xcrun notarytool submit <archive> --keychain-profile <profile> --wait`. Review the result, then staple and validate the ticket for the distributed package type.
4. Verify with the appropriate strict signing check and Gatekeeper assessment, such as `codesign --verify --deep --strict <app>` and `spctl --assess --type execute <app>`. Archive the exact package checksum and the notarization record.
5. Exercise clean installation and upgrade from a quarantined download on representative Macs. Confirm settings, Keychain access, SQLite data and expected privacy prompts. Repeat critical source, Start/Stop and answer flows against the signed artifact.

No signing credentials were used. The M11 builds are unsigned and local. Publication and distribution require the owner's explicit authorization. [Apple Developer ID](https://developer.apple.com/developer-id/) · [Apple notarization procedure](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Provider release boundaries

The owner approved deferral of live ElevenLabs, Deepgram and Anthropic qualification. ElevenLabs graceful drain and performance are outside the mandatory release gate. Retain the optional adapters and deterministic tests. ChatGPT sign-in remains gated until the owner documents official eligibility for the exact distribution and completes any required OpenAI approval. [Provider qualification](verification/m11-provider-qualification.md)

## M12 release decision

**HOLD for production distribution.** M12 is a native UI review candidate. [M12 validation](verification/m12-ui-validation.md) records the redesign’s exact build and test evidence. The OpenAI production scope still needs physical dual-source cycles, an independent holdout and observed display latency, curated live grounding, a sustained Chat run, 90 minutes over a controlled remote endpoint, and clean supported-system installation and upgrade qualification. Optional-provider qualification is outside the primary release decision.
