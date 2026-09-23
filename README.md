# mc.Rofone

A small, free, self-hosted call recorder for macOS. It lives in the menu bar, records your calls **without a meeting bot** (your microphone plus the system audio, i.e. what the other people say), transcribes them with the speech-to-text provider you choose, and saves everything in a folder you can find.

- Asks for the call title **when you start**, not after, prefilled from the calendar event happening now. Tags (e.g. project names) with autocomplete.
- Mic and system audio are recorded to **separate tracks**, so the transcript knows who is "Me" and who is "Others".
- **Pause / resume** and **bookmarks** during the call, from the panel or global shortcuts.
- **Crash safe**: audio is written in a format that survives a crash or a forced quit, and is recovered on the next launch.
- **Call detection**: notices when Zoom, Teams, Meet (in the browser), Slack, FaceTime, Webex or Discord start using the microphone and offers to record.
- Pluggable transcription: local whisper.cpp, ElevenLabs Scribe, OpenAI, Groq. Long silences are skipped before upload to save money, with a per-call cost estimate.
- Optional **summary** (decisions, action items) with your own OpenAI, Anthropic or Groq key. Off by default.
- Notification when the transcript is ready (click to open it), optional webhook.
- Recordings library window with search, tag filter, playback with bookmark markers, export (Markdown, TXT, SRT, VTT, DOCX), multi-selection for bulk actions, re-transcribe, rename and delete (to Trash).
- Storage overview and optional automatic cleanup of old audio (transcripts are kept).
- **Mute all microphones** with an Option-click on the menu bar icon: call apps still show you as unmuted but send silence.

Requires macOS 14.2 or later (system audio capture uses Core Audio process taps).

## Build

```sh
./scripts/build-app.sh
open build/mc.Rofone.app
```

The script runs `swift build -c release`, assembles `build/mc.Rofone.app` and signs it ad hoc. Copy the app to `/Applications` if you like. Needs Xcode (or the Command Line Tools) with Swift 6.

Tools used at runtime (install with Homebrew):

```sh
brew install ffmpeg whisper-cpp
```

`ffmpeg` is needed by every provider (format conversion, compression, chunking, mixing). `whisper-cpp` only for local transcription.

Run the unit tests with `swift test`.

## Permissions

On the first recording macOS asks for:

1. **Microphone**: System Settings > Privacy & Security > Microphone.
2. **System audio recording**: System Settings > Privacy & Security > Screen & System Audio Recording > "System Audio Recording Only". If this is denied the system track is silent and the transcript only contains your side.
3. **Notifications**: allow them to get "Transcript ready", "Call detected" and "Recovered call" alerts.
4. **Calendar** (optional): System Settings > Privacy & Security > Calendars. Used only to name recordings after the event happening now and to suggest attendee names. Google and Outlook calendars must first be added to macOS in System Settings > Internet Accounts (or in the Calendar app), otherwise they are not visible to any app.

Call detection needs no permission: it reads which apps are using a microphone from Core Audio, without opening any microphone.

The app is signed ad hoc, so after rebuilding macOS may ask for these permissions (and Keychain access for API keys) again. If a permission seems stuck, remove the app from the list in System Settings and add it again, or run `tccutil reset Microphone com.gabrielepartiti.mcrofone` / `tccutil reset AudioCapture com.gabrielepartiti.mcrofone` / `tccutil reset Calendar com.gabrielepartiti.mcrofone`. The app is not sandboxed and has no hardened runtime, so no entitlements are needed for the calendar.

## Usage

The first launch shows a short welcome guide (permissions, provider, shortcut). Start and stop recordings from the menu bar panel or with the global shortcut (default ⌃⌥⌘R, configurable in Settings > General). The panel shows live levels for your microphone and the call audio, the transcription status and your last calls. **All Recordings** opens the library: search, inline player (click a timestamp to jump there), rename, rename speakers, transcribe again, send the webhook again, delete.

Settings > Transcription can download whisper.cpp models for you and test each provider with a one-second request. "Open at login" works best with the app in /Applications.

1. Click the mic icon in the menu bar > **Start Recording…** (⌘R).
2. Type a title (prefilled with the current calendar event, or `Call YYYY-MM-DD HH:mm`), optionally add tags (Enter or Tab to accept one, ⌫ removes the last, "Last used" adds the previous call's tags in one click) and pick a language for this call, press Enter.
3. The icon turns into a record dot with the recorded time. From the panel:
   - **Pause / Resume** (⌘P in the panel, ⌃⌥⌘P from any app). While paused nothing is written to either track, so the two tracks stay aligned; the menu bar shows a gray pill with a pause symbol and the timer counts recorded time only.
   - **Bookmark** (⌘B in the panel, ⌃⌥⌘B from any app) marks the current moment instantly. Type an optional note next to it in the panel, or label it later in the library.
4. Click **Stop Recording**. The audio is saved, then transcription runs in the background. A notification opens the transcript.

Both extra shortcuts can be changed or turned off in Settings > General.

### Mute all microphones

**Option-click** the menu bar icon to mute every microphone on the Mac at once (no panel opens); Option-click again to unmute. The panel also has a *Mute all microphones* switch, and Settings > Recording has one. Zoom, Meet or Teams keep showing you as unmuted, but they receive silence. The icon shows a crossed-out mic (as a badge on the recording pill while recording), and the panel shows "Microphones muted" with **Unmute**.

How it works: for each input device, mc.Rofone saves its current state, then turns on the device's mute switch, or sets its input volume to 0 if it has no mute switch (or ignores it). It only changes device settings and never opens a device, so a Bluetooth headset does not switch to its call profile. Microphones connected while muted are muted too, and if an app turns the volume back up (automatic gain control), it is muted again immediately; turning off "Automatically adjust microphone volume" in Zoom avoids the tug of war. Devices that allow neither (for example the iPhone Continuity microphone or some virtual devices) are listed in the panel. Unmuting restores every device exactly as it was; this also happens when you quit, and on the next launch if the app crashed while muted. While muted your own track is silent; mute periods are saved in `meta.json` (`muteIntervals`).

The menu bar item is a regular status item (so Option-click can be detected); the panel is the same as before.

If a transcription fails (missing key, network, quota), fix the cause and use **Retry Last Transcription**, or open **Show All Recordings…** and pick *Re-transcribe* with any provider.

## Output layout

Default base folder: `~/Documents/mc.Rofone` (changeable in Settings; the menu always shows the current path).

```
~/Documents/mc.Rofone/
  2026-09-23_1430_weekly-sync/
    meta.json        title, date, duration, language, provider, status, speaker names,
                     tags, pauses, bookmarks, calendar event, estimated cost, output routes,
                     mute intervals
    segments.json    raw timed segments with original speaker labels
    mic.m4a          your microphone
    system.m4a       everything played by the Mac (the other participants)
    mixed.m4a        both tracks mixed, for listening
    transcript.md
    summary.md       only if you use summaries
```

While recording, the tracks are written as `mic.caf` and `system.caf` (uncompressed, about 1 GB per hour for both). They are converted to `.m4a` when you stop, and removed once the `.m4a` files are checked.

`transcript.md` looks like this:

```markdown
# Weekly sync

- **Date:** 2026-09-23 14:30
- **Duration:** 00:42:10
- **Provider:** OpenAI (whisper-1)
- **Language:** auto (detected: italian)
- **Audio:** mic.m4a, system.m4a, mixed.m4a

---

**[00:00:03] Me:** Ciao a tutti, iniziamo?

**[00:00:06] Others:** Sì, ci siamo.

🔖 [00:00:09] Bookmark: Budget question
```

A `- **Tags:**` line is added to the header when the call has tags.

Consecutive lines from the same speaker are merged. The mic track is labelled "Me", the system track "Others" (both configurable). If the provider supports diarization (ElevenLabs, `gpt-4o-transcribe-diarize`) the system track is split into "Speaker 1", "Speaker 2", ...

To give speakers real names, open **Show All Recordings…**, select the call and use **Rename Speakers…**. The mapping is saved in `meta.json` (`speakerNames`) and `transcript.md` is regenerated from `segments.json`, so renaming is lossless and can be changed again.

## Library

- **Search** matches titles, tags and transcript text. The tag bar above the list filters by tag.
- The player shows **bookmark markers** under the scrubber; the Bookmarks list below it jumps to each one and lets you edit or remove labels (the transcript is updated).
- **Copy Transcript** copies the whole transcript with speaker names applied.
- **Export** (toolbar, context menu or the button under the player): Markdown, plain text, SRT and VTT subtitles (each cue starts with the speaker name), or a Word document (.docx, generated without any extra software). The save panel opens in Downloads.
- The header shows the folder size, the estimated transcription cost and the linked calendar event. Tags are edited in place.
- **Multi-selection** (⌘-click, ⇧-click): export all selected calls into a folder, add a tag, transcribe again, send the webhook, move audio or whole calls to the Trash. The detail pane shows the number of calls, total duration and size.
- **Summary** tab: generate a summary for any call with a transcript (see below).

## Crash recovery

Audio is written while recording as CAF files that stay readable even if the app crashes, is force quit or the Mac loses power (at most the last fraction of a second is lost). When the app starts it looks for calls left in the recording or paused state, converts what was recorded to `.m4a`, marks them as *Recovered* and shows a notification and a card in the menu bar panel with **Transcribe**. Quitting the app during a recording works the same way.

## Call detection

Settings > Recording > Call Detection (on by default). Every few seconds mc.Rofone asks Core Audio which processes are using an input device and matches them against known apps (Zoom, Microsoft Teams, Slack, FaceTime, Webex, Discord, and browsers for Google Meet: Chrome, Safari, Arc, Edge, Firefox, Brave, Zen, Vivaldi). It never opens a microphone for this, and ignores itself. Each app can be turned off (for example browsers, if you use the mic for other things).

- A call starting while you are not recording shows "Call detected in Zoom" with **Record** (opens the title window, prefilled) or **Dismiss**. With *Start recording automatically* it starts right away.
- When every meeting app stops using the mic during a recording, you get "Call seems to have ended" with **Stop Recording**. Optionally recording stops by itself after 30 s to 5 min.

## Calendar

Settings > Recording > Calendar. When a recording starts during an event (or within 10 minutes of its start), the title is prefilled with the event title, and the event (title, calendar, attendee names and emails) is saved in `meta.json`. Attendee names are suggested in **Rename Speakers**. You can limit this to some calendars. Google and Outlook calendars must be added in System Settings > Internet Accounts first. Tags are never set automatically.

## Silence trimming

Settings > Transcription > Silence. By default, for cloud providers only, pauses longer than 2 s below -45 dB are cut from a temporary copy of each track before it is sent (a little audio is kept around each cut so words are not clipped). The original files are never changed, and every timestamp is mapped back to the original timeline, so click-to-play, bookmarks and subtitles stay in sync. Mic and call audio are trimmed independently. Threshold and minimum length are configurable, and it can be turned on for whisper.cpp too (faster) or off.

## Cost estimate

Each call stores `transcribedSeconds` (after trimming) and `estimatedCostUSD` (minutes × the model's price). It is an estimate: free tiers, minimum billing per request and plan discounts are not taken into account. Default prices, editable in Settings > Transcription > Cost Estimate (USD per hour of audio, list prices checked September 2026):

| Model | $/hour | Source |
|---|---|---|
| ElevenLabs `scribe_v2` | 0.22 | elevenlabs.io/pricing/api |
| ElevenLabs `scribe_v1` | 0.22 | not listed anymore, assumed equal to v2 |
| OpenAI `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize`, `whisper-1` | 0.36 | developers.openai.com/api/docs/pricing ($0.006/min) |
| OpenAI `gpt-4o-mini-transcribe` | 0.18 | same ($0.003/min) |
| Groq `whisper-large-v3-turbo` | 0.04 | console.groq.com/docs/model/whisper-large-v3-turbo |
| Groq `whisper-large-v3` | 0.111 | console.groq.com/docs/model/whisper-large-v3 |
| whisper.cpp | 0 | local |

## Summary

Off by default. Settings > Transcription > Summary: turn on *Summarize every call after transcription*, or use **Generate Summary** in the library for any call. Providers, all with your own key:

| Provider | Default model | Key |
|---|---|---|
| OpenAI | `gpt-5-mini` | the OpenAI transcription key |
| Anthropic | `claude-sonnet-5` | its own key (Keychain) |
| Groq | `openai/gpt-oss-120b` | the Groq transcription key |

The prompt is editable (`{{title}}` and `{{transcript}}` are filled in). The default asks for a short summary, decisions and action items in the transcript's language. The result is saved as `summary.md` and included in the webhook.

## Storage

Settings > General > Storage shows the space used by all calls. **Clean Up Now…** previews how many calls and how much audio would go to the Trash, and asks before doing it. *Delete old audio automatically* (off by default) does the same at launch and once a day. Only audio of calls that already have a transcript is removed; transcripts, summaries, bookmarks and `meta.json` stay, and the call is marked `audioDeleted`.

## Providers

Pick one in **Settings**. API keys are stored in the macOS Keychain, everything else in UserDefaults.

| Provider | Default model | Notes |
|---|---|---|
| whisper.cpp (local) | model file you choose | Free and offline. Audio is converted to 16 kHz mono WAV. |
| ElevenLabs Scribe | `scribe_v2` | `scribe_v1` also works. Word timestamps, diarization on the system track. Key: elevenlabs.io > API keys. |
| OpenAI | `gpt-4o-transcribe` | See below. Key: platform.openai.com. |
| Groq | `whisper-large-v3-turbo` | OpenAI-compatible, fast and cheap, segment timestamps. Key: console.groq.com. |

OpenAI model behaviour:

- `whisper-1`: `verbose_json`, segment timestamps and detected language.
- `gpt-4o-transcribe` / `gpt-4o-mini-transcribe`: these only return plain text, so audio is sent in 1-minute chunks and each chunk becomes one timestamped block. Pick `whisper-1` or the diarize model if you want finer timing.
- `gpt-4o-transcribe-diarize`: `diarized_json` with `chunking_strategy=auto`, speaker labels on the system track.

For cloud providers audio is compressed to mono 16 kHz 32 kbps MP3 before upload. OpenAI and Groq requests are split into chunks (10 minutes, or 1 minute for text-only models) to stay well under the 25 MB upload limit.

### Language

Default is **Auto-detect** for every provider (no language is sent; whisper.cpp gets `-l auto`). Settings offers Auto, Italian, English or any ISO code, and the title window lets you override it per call. The chosen or detected language is written in `transcript.md`, `meta.json` and the webhook payload. Setting it explicitly helps accuracy when you know the call language.

### whisper.cpp model

Download a ggml model, for example large-v3-turbo (about 1.6 GB, good quality in Italian and English):

```sh
mkdir -p ~/Library/Application\ Support/mc.Rofone/models
curl -L -o ~/Library/Application\ Support/mc.Rofone/models/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
```

That path is the default in Settings. Smaller and faster options: `ggml-small.bin`, `ggml-base.bin`, or the quantized `ggml-large-v3-turbo-q5_0.bin`. Avoid the `.en` models if you speak other languages.

## Webhook

Off by default. Enable it in Settings and configure:

- **URL** and **method** (POST, PUT or PATCH).
- **Headers**, e.g. `Authorization: Bearer <token>` or `X-Api-Key`. Header names are stored in UserDefaults, values in the Keychain.
- **Body**: *Default JSON* (below) or *Custom template*.
- **Send Test** fires the webhook with the last recording (or sample data) and shows the HTTP status and the start of the response.

Failed deliveries are retried up to 3 times (1 s, 2 s, 4 s) on network errors, 429 and 5xx. A final failure shows a notification with the status code. Any call can be sent again from the library with **Resend Webhook**.

Default JSON body:

```json
{
  "title": "Weekly sync",
  "date": "2026-09-23T12:30:00Z",
  "duration_seconds": 2530,
  "language": "it",
  "folder_path": "/Users/me/Documents/mc.Rofone/2026-09-23_1430_weekly-sync",
  "transcript_path": "/Users/me/Documents/mc.Rofone/2026-09-23_1430_weekly-sync/transcript.md",
  "audio_paths": [
    "/Users/me/Documents/mc.Rofone/2026-09-23_1430_weekly-sync/mic.m4a",
    "/Users/me/Documents/mc.Rofone/2026-09-23_1430_weekly-sync/system.m4a",
    "/Users/me/Documents/mc.Rofone/2026-09-23_1430_weekly-sync/mixed.m4a"
  ],
  "provider": "OpenAI (whisper-1)",
  "transcript_markdown": "# Weekly sync\n\n...",
  "segments": [
    { "start": 3.1, "end": 5.8, "speaker": "Me", "text": "Ciao a tutti, iniziamo?" },
    { "start": 6.0, "end": 7.2, "speaker": "Anna", "text": "Sì, ci siamo." }
  ],
  "speaker_names": { "Speaker 1": "Anna" },
  "tags": ["Nova"],
  "bookmarks": [
    { "time": 723.4, "label": "Budget question" }
  ],
  "summary_markdown": "## Summary\n...",
  "estimated_cost_usd": 0.0853
}
```

`language` is the language you chose, or the one detected by the provider when set to auto. `bookmarks[].time` is in seconds of recorded audio. `summary_markdown` and `estimated_cost_usd` are `null` when not available. Segment speakers use the names set with Rename Speakers (`speaker_names` holds the mapping). `transcript_markdown` is always the full transcript.

### Custom template

Write any body and set the Content-Type (default `application/json`). Placeholders:

`{{title}}` `{{date}}` `{{duration_seconds}}` `{{language}}` `{{provider}}` `{{folder_path}}` `{{transcript_path}}` `{{transcript_markdown}}` `{{segments_json}}` `{{audio_paths_json}}` `{{bookmarks_json}}` `{{summary_markdown}}` `{{estimated_cost_usd}}` `{{tags}}` `{{tags_json}}`

When the Content-Type contains `json`, text placeholders are JSON-escaped, so put them inside quotes. `{{segments_json}}`, `{{audio_paths_json}}`, `{{bookmarks_json}}`, `{{tags_json}}`, `{{duration_seconds}}` and `{{estimated_cost_usd}}` (a number or `null`) are inserted as raw JSON values. `{{tags}}` is a comma-separated list:

```json
{
  "name": "{{title}}",
  "minutes": {{duration_seconds}},
  "body": "{{transcript_markdown}}",
  "segments": {{segments_json}}
}
```

## How system audio is captured

A global Core Audio process tap (`CATapDescription` + `AudioHardwareCreateProcessTap`) is attached to a private aggregate device built on the current default output device. Nothing is muted and no virtual audio driver is installed. The microphone is recorded separately with `AVAudioEngine`.

Known limitations:

- Switching outputs mid-call (connecting or removing AirPods, picking the speakers in Control Center) is handled: the tap is rebuilt on the new output about a second later, the short gap is filled with silence so both tracks stay aligned, a different sample rate is converted, and a notification says "Audio output changed". Default devices and sample rates are never touched.
- If the microphone being recorded disappears (a USB mic unplugged, for example), recording switches to the automatic choice (the built-in mic, never a Bluetooth headset) without stopping, fills the gap with silence and notifies you. If the original mic comes back, recording stays on the new one, to keep the call stable. You can also switch microphone from the menu bar panel while recording.
- All system sounds are recorded, including notifications and music.
- If you do not use headphones, the other participants are also picked up by your microphone. mc.Rofone records which output was in use for each part of the call (`outputRoutes` in `meta.json`) and, for the parts on loudspeakers, hides "Me" lines that repeat what the call audio says at the same time (Settings > Recording > *Remove echo when using speakers*, on by default). Hidden lines stay in `segments.json` with `"droppedAsEcho": true`; turn the option off and transcribe again to get them back. Bluetooth and USB outputs count as headphones.
- Tracks are aligned by start time only; drift over long calls is typically well under a second.
- The microphone is chosen in Settings. The default, **Automatic (avoid Bluetooth)**, uses the default input unless it is a Bluetooth headset, in which case it uses the built-in mic. Opening a Bluetooth headset mic switches it to its low-quality call profile, which degrades the call for you and the other participants. You can also pick a specific device, or record system audio only.
- The system audio tap uses a tap-only private aggregate device: it does not open, reconfigure or mute your output device.

## Troubleshooting

- **Show Error Details…** in the menu shows the full last error (component, error domain and code) with a Copy button.
- Logs: `/usr/bin/log show --last 1h --info --predicate 'subsystem == "com.gabrielepartiti.mcrofone"'` (use the full path in zsh, where `log` is a shell builtin).
- Audio self-test from a terminal, records mic and system audio for a few seconds and prints formats, errors and levels:

  ```sh
  build/mc.Rofone.app/Contents/MacOS/McRofone --selftest-audio 3
  ```

  It also prints the default input/output devices with their sample rates before and during capture, to confirm recording does not change them. Permissions in this mode belong to the terminal app, not to mc.Rofone.
- Other headless checks (no windows, no devices unless noted):

  ```sh
  build/mc.Rofone.app/Contents/MacOS/McRofone --selftest-recovery   # kills a writer mid-recording, recovers the audio
  build/mc.Rofone.app/Contents/MacOS/McRofone --selftest-trim       # silence trimming and timestamp mapping
  build/mc.Rofone.app/Contents/MacOS/McRofone --selftest-detect     # apps using a microphone right now
  build/mc.Rofone.app/Contents/MacOS/McRofone --selftest-devicechange  # track alignment across a tap rebuild and mic switch (opens the mic for ~5 s)
  build/mc.Rofone.app/Contents/MacOS/McRofone --selftest-mute       # mutes every mic for a moment, checks, restores (skips if a call app uses a mic)
  ```
- UI snapshots for review: `McRofone --render-snapshots <dir>` renders every screen with sample data in light and dark mode. It briefly shows windows on screen while capturing. `McRofone --render-icon <dir>` regenerates `AppIcon.icns` without showing anything.
