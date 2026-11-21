# NIGHTVOICE v0.8 — Recovery Patch

This is the complete v0.7 project with a watchdog-based recovery patch in `NIGHTVOICE/SpeechController.swift`.

## Changes
- Recovery timer releases the response lock if speech completion is not received within 8 seconds.
- Independent monitor checks every 4 seconds and restarts recognition when unexpectedly idle.
- Keeps random 3–15 second question-to-response delay.
- Stops recovery timers when disarmed; session identifiers prevent stale callbacks from restarting a new session.

## Installation
Replace the corresponding project files in your repository, commit to `main`, and rebuild with Codemagic. If the app still stops, note the status text displayed on the app immediately after its first response. That status will help distinguish microphone permission, speech recognition, and audio-session failures.

Not compiled or device-tested in this environment. This patch is a reliability improvement, not a guarantee of uninterrupted recognition. Speech recognition may still be unavailable during interruptions or background execution.


## v0.9: Pause listening

A PAUSE LISTENING button suspends microphone recognition, cancels any pending 3–15 second response, stops speaking, and prevents automatic restarts. RESUME LISTENING begins a fresh recognition session without disarming. DISARM still ends the session. Replace the complete source package in your repository, retaining the `NIGHTVOICE/` directory and root-level `codemagic.yaml` and `project.yml`. This package has not been compiled on macOS.
