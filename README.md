# NIGHTVOICE v0.5 — Codemagic build package

Unverified SwiftUI iOS source and Codemagic unsigned IPA workflow. This is **not yet a compiled IPA**.

## Codemagic setup
1. Extract ZIP; preserve the top-level `codemagic.yaml`, `project.yml`, `NIGHTVOICE/`, and `server/`.
2. In Codemagic, use your existing repository-connected app or a repository Codemagic can access. Upload/commit these files to the repository root (not inside an extra folder). Codemagic generally builds from a connected repository; the ZIP is not itself an installable app.
3. Select **NIGHTVOICE - unsigned IPA for Sideloadly**, then **Start new build**.
4. If successful, download the `NIGHTVOICE-unsigned.ipa` artifact and use Sideloadly to sign/install it on your iPhone.
5. Grant microphone and speech-recognition permission. Use the app in the foreground.

## Current limitations
- Build and on-device operation have not been verified.
- The offline engine uses rules, not a local AI model.
- Cloud AI requires a separately hosted, secured HTTPS endpoint; the sample server is a development example, not production-hardened.
- Voice output is synthesized without radio effects; session history is not persistent.
- The interface does not show an AI label, but source metadata is retained in logs. Responses are simulated, not evidence of spirits.
- Codemagic plan/build-minute availability and Sideloadly signing requirements may apply.


## v0.6 build fixes
- Simplified the waveform expression in NIGHTVOICE/ContentView.swift to avoid SwiftUI type-check timeout.
- Removed invalid empty publishing.email configuration from codemagic.yaml.
- This source has not been compiled on macOS; further compiler errors may appear.
