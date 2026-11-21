# NIGHTVOICE v1.0 — Haunted Voices

Codemagic + Sideloadly source update based on the working v0.9 PAUSE project.

## What's new
- Automatically selects an available English-language masculine or feminine iOS speech voice for each response. This is a random character choice, not a paranormal or gender detection mechanism.
- Sends synthesized PCM speech through AVAudioEngine + AVAudioUnitReverb using a large-hall preset.
- Adds Settings > Haunted voice > Automatic / Male / Female and Reverb (0–85%).
- Keeps PAUSE / RESUME, ARM / DISARM, 3–15-second randomized reply delay, and online/offline response handling.
- Keeps response source labels off the main response display.

## Upload
Unzip. Replace your repository's corresponding files with the files in this package, preserving `NIGHTVOICE/` folder structure. Commit, then build using Codemagic. Download unsigned IPA from artifacts and install using Sideloadly.

## Testing
1. Arm, ask a question, allow reply.
2. Ask a second question and verify listening resumes.
3. Open Settings and switch between AUTO / MALE / FEMALE; test reverb at 0% and 65%.
4. Pause and verify no response occurs while paused.

## Caveats
This package has not been compiled with Apple's iOS SDK or tested on an iPhone here. If Codemagic reports an error, share the first specific `error:` line. Available voices vary by installed iOS voices. Apple's synthesizer may not provide gender-tagged voices for every language. Audio effects are theatrical; the app simulates responses and cannot establish paranormal communication.
