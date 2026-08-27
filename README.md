# Transcribator

Transcribator is a native macOS menu-bar app that records system audio and microphone input, then sends the result to the official OpenAI Transcriptions API. Optional Telegram and Discord integrations are included in the same repository.

## Features

- Native macOS menu-bar app: no virtual audio driver, Docker, Python, or ffmpeg required.
- Records system audio and microphone input; the microphone can be muted and both levels can be changed during recording.
- Saves transcripts as TXT and, optionally, recordings as M4A.
- Supports `gpt-transcribe`, `gpt-4o-transcribe-diarize`, and `whisper-1`.
- Splits long audio automatically and cleans up working files.

## Quick start on macOS

Requirements: macOS 15 or later and your own OpenAI API key.

1. Download the Universal DMG from [Releases](../../releases).
2. Drag **Transcribator** to **Applications**.
3. Open it; the app appears in the menu bar, not in the Dock.
4. Open **Settings**, save the OpenAI API key, and choose output folders.
5. Allow **Microphone** and **Screen & System Audio Recording** when macOS asks, then restart the app.

The API key is stored in macOS Keychain. Audio is sent to `https://api.openai.com/v1/audio/transcriptions`; it is not uploaded anywhere else by the macOS app.

### First launch of an unsigned build

The current public build is ad-hoc signed because the project does not yet have an Apple Developer ID certificate. macOS may block the first launch:

1. Try to open `/Applications/Transcribator.app` once.
2. Open **System Settings → Privacy & Security**.
3. Find the blocked Transcribator message and click **Open Anyway**.

Verify `SHA256SUMS` from the release before bypassing the warning. Do not disable Gatekeeper globally. A Developer ID signing and notarization workflow is already supported by the build scripts; details are in [macos/README.md](macos/README.md).

## Optional Telegram and Discord integrations

Requirements: Docker Compose, an OpenAI API key, Telegram bot credentials, and/or a Discord bot token.

```bash
cp .env.example .env
openssl rand -hex 32
# Put the generated value and the required bot credentials into .env
docker compose up -d --build
```

Important settings:

- `TELEGRAM_ALLOWED_USERS` — comma-separated Telegram user IDs allowed to use the bot.
- `DISCORD_CHANNEL_ID` — the only Discord text channel where uploads and recording commands are accepted.
- `INTERNAL_API_TOKEN` — a random secret used only between the containers.

In Discord, `!record <voice_channel_id>` starts recording and `!stop` stops it. Record conversations only with the consent of every participant. Files handled through Telegram, Discord, and OpenAI are also subject to those services' privacy policies.

## Development

```bash
# Python
python -m pip install -r requirements-dev.txt
ruff format --check . && ruff check .
python -m unittest discover -s tests -v
pip-audit -r requirements.txt

# Node.js
cd recorder && npm ci && node --check index.js && npm audit --omit=dev

# macOS
swift run --package-path macos TranscribatorCoreChecks
macos/Scripts/package-distribution.sh
```

More macOS build, recovery, signing, and notarization details are in [macos/README.md](macos/README.md). Third-party notices are in [macos/THIRD_PARTY_NOTICES.md](macos/THIRD_PARTY_NOTICES.md) and are also bundled with the application.

## License

[MIT](LICENSE)
