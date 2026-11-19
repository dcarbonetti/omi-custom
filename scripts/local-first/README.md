# Omi, local-first

Run the Omi desktop app with everything on your Mac: transcription, AI, database and login.
The only thing that leaves the machine is the Google Drive backup you turn on yourself.

| What | Where it runs |
|---|---|
| Transcription | Parakeet on the Apple Neural Engine (`LocalTranscriptionService`). No cloud fallback. |
| Summaries, memories, tasks | Apple Intelligence or your Ollama / LM Studio model, on the Mac and in the local backend. |
| Chat | AI Provider → **Local**: the agent talks straight to your local model. |
| Database, login, search | Firestore + Auth emulators, Redis and Typesense, all on `127.0.0.1`. |
| Analytics / telemetry | Off unless you turn on *Share usage data*. |
| Backup | Your own Google Drive, `drive.file` scope only. |

Each AI feature can also be switched to **Omi Cloud** or **My own cloud account** in
**Settings → Local-first**.

## 1. Install the prerequisites

On an Apple Silicon Mac with macOS 14 or later:

```bash
xcode-select --install
```

```bash
brew install uv node redis openjdk@21 ollama typesense/tap/typesense-server
```

- **Xcode** (full, from the App Store). The app is a Swift package built with `xcrun swift build`.
- **A code-signing identity.** A free Apple ID added in Xcode → Settings → Accounts is enough. See
  `desktop/macos/docs/local-code-signing.md`. Do not use ad-hoc signing: macOS drops the Screen
  Recording permission for it.
- Make Java 21 the one on your `PATH` (the Firebase emulators refuse older versions):
  `export PATH="$(brew --prefix openjdk@21)/bin:$PATH"`.

## 2. Pick and pull a local model

```bash
ollama serve
```

```bash
ollama pull qwen3:8b
```

The model needs tool calling and JSON-schema output. `qwen3:8b` suits 16 GB. On 32 GB or more,
a 14B–32B instruct model gives better summaries. Avoid "thinking" variants here: they are much slower.
LM Studio works too (Developer tab → Start server, base URL `http://127.0.0.1:1234/v1`).

## 3. Start the local stack

From the repository root:

```bash
scripts/local-first/omi-local up
```

The first run creates `scripts/local-first/omi-local.env` from the example and stops. Edit the model name
and URL there, then run:

```bash
scripts/local-first/omi-local setup
```

`setup` installs the backend's Python 3.11 environment and the Firebase emulator tools. It ends by
asking for "your four API keys": ignore that, because local-AI mode uses none.

```bash
scripts/local-first/omi-local up
```

`up` checks that your model server answers and starts the emulators, Redis, Typesense, the LLM gateway
and both backends. It also creates your personal account in the local Auth emulator. No cloud API key is
needed or used: `OMI_LOCAL_LLM_BASE_URL` puts the gateway in local-AI mode
(`backend/llm_gateway/gateway/local_mode.py`). There, every AI lane goes to your server. A lane your
server can't serve (web search, Anthropic-only lanes, and embeddings unless you set
`OMI_LOCAL_EMBEDDING_MODEL`) fails closed instead of reaching a cloud provider.

## 4. Build and open the app

```bash
scripts/local-first/omi-local app
```

This builds `/Applications/omi-local.app` (bundle `com.omi.omi-local`). It sits beside the official Omi
app without touching it. It signs in to the local emulator as your personal account and starts with:
AI Provider → Local, transcription and summaries on this Mac, and analytics off. Open
**Settings → Local-first** to check the status panel. Every row should show a checkmark.

Grant Microphone and Screen Recording when macOS asks. The first recording downloads the Parakeet model
once (about 600 MB) from Hugging Face.

## 5. Stop it cleanly

```bash
scripts/local-first/omi-local down
```

The emulators write your database to disk **when they shut down cleanly**
(`~/Library/Application Support/OmiLocal/harness/personal/services/firebase-export`). Run `down` before
restarting or shutting down the Mac, and keep the Drive backup on as a safety net.

## Google Drive backup

You need your own OAuth client, because Omi's own Google credentials can't be used by a custom build.
Setup takes about five minutes and is free:

1. Open <https://console.cloud.google.com/> and create a project, for example "Omi Backup".
2. **APIs & Services → Library**: enable the **Google Drive API**.
3. **APIs & Services → OAuth consent screen**: choose *External*, fill in the app name and your email,
   and add the scopes `.../auth/drive.file`, `openid` and `email`. All three are non-sensitive.
4. **Publish the app** (Audience → *Publish app* → *In production*). While it is in *Testing*, Google
   expires refresh tokens after 7 days and the backup stops. Non-sensitive scopes need no verification.
   You'll see an "unverified app" notice once at sign-in; continue through it.
5. **Credentials → Create credentials → OAuth client ID → Application type: Desktop app**. Copy the client
   ID and client secret.
6. In the app: **Settings → Local-first → Google Drive backup**. Paste both, click **Sign in with Google**,
   and approve in the browser.

The backup runs every 30 minutes and on **Back up now**. It writes to **My Drive → Omi Backup**:

```
Omi Backup/
  Memories.md   memories.json
  Tasks.md      tasks.json
  Conversations/
    2026-11-19 0930 Weekly planning (abc12345).md
    2026-11-19 0930 Weekly planning (abc12345).json
```

Only changed conversations are fetched and uploaded again. If you delete a file in Drive, the next run
puts it back. The `drive.file` scope means Omi can see only the files it created, never the rest of your
Drive. The refresh token is kept in the macOS Keychain.

## What still uses the internet

- **One-time downloads:** the Parakeet speech model and your Ollama/LM Studio models.
- **Google Drive backup**, when you turn it on.
- **Integrations you connect yourself** (Google Calendar, Gmail, Notion, MCP servers, …).
- **Cloud-assisted features**, only if you turn them on in Settings → Local-first.
- **Push-to-talk voice answers.** With transcription on this Mac, push-to-talk types on-device and keeps
  voice questions for you to send, because the voice assistant (Gemini Live) is cloud-only. Typed chat
  goes to your local model.

The named `omi-local` bundle does not auto-update (Sparkle is off for named development bundles).

## Your existing Omi Cloud data

This stack starts empty. Conversations already in Omi Cloud stay there. Export them from the official
app (it exports conversations as JSON) if you want a copy. Delete them, or your account, from the
official app if you want them gone from Omi's servers. Your on-Mac screen history (Rewind) can be copied
into the new bundle on first launch; set `OMI_SKIP_REWIND_SEED=1` before `omi-local app` to start empty.

## Troubleshooting

- `omi-local status` and `omi-local logs` show the services and their logs.
- If summaries come back as a bare "minimum" note, the local model failed or timed out. Check
  `ollama ps` and the gateway log. Raise `OMI_LOCAL_LLM_TIMEOUT_MS` for big models on smaller Macs.
- Transcription refusing to start with an alert means your language has no on-device model. Pick a
  supported one, or set Transcription to Omi Cloud.

## Notes for maintainers

These changes were written without a Mac to compile them on. Expect to fix a few compile errors on
the first `omi-local app`. The Python side (gateway local-AI mode and harness) has tests:
`backend/tests/unit/test_llm_gateway_local_mode.py` and `scripts/dev-harness/tests/test_env_stage.py`.
