# Murmur / voice-app

An offline iOS 16.4+ prototype for live captions and recorded notes. Open `VoiceApp.xcodeproj` and use the `voice-app` scheme. The home-screen name is Murmur. Git `origin` is `https://github.com/mcv-s/voice-app.git`.

## What it does

- Three bottom tabs: **Record**, **Recordings**, **Settings**. Bottom tabs are always shown.
- Large live captions and a compact microphone meter. Appearance settings contain a text-size slider with preview, Automatic/Light/Dark green themes, font choices, bold, and italic. The appearance preview is shown first, followed by text size and theme/font controls. Every session saves audio. Stop, Pause/Resume, and Mute are separate controls: pause excludes time/audio; mute keeps time and records silence.
- Conversation and Ambient listening are available on Record and in Settings. Ambient uses gentle input gain for quieter room speech and requests an omnidirectional built-in microphone when supported. Neither mode enables voice processing; distant/noisy speech still needs real-device evaluation.
- A selectable fast recognizer plus optional **concurrent Whisper corrections**, off by default. Whisper is experimental: it can lag and make correct wording worse. Selecting or downloading a model does not enable automatic correction. Completed phrases are corrected once while the next phrase continues. Paragraph IDs stay stable, corrected paragraphs do not shrink, and corrections do not trigger auto-scroll. Original wording is preserved. This is live correction, not only an after-Stop pass.
- Saved recordings open full navigation pages with audio playback, editable transcripts, rename, and optional local titles/summaries.
- Copy is a top-right icon and briefly becomes a checkmark. Export opens a full page from the transcript or the recording’s long-press menu. Its Audio section offers **M4A** and the original **CAF**, followed by a Subtitles section with **WebVTT**, **TXT**, and **Markdown**. Tap to share/Save to Files, or hold and drag an actual file.
- TXT contains transcript text; Markdown includes the title and summary. VTT uses caption-phrase timings. Earlier or manually edited/reprocessed transcripts without compatible timing export as one whole-recording cue, labeled in the menu. These are phrase timings, not forced-aligned word timestamps.

First launch and reset show setup: readable text size with preview, a choice of FastConformer Transducer, Moonshine Tiny, or the full model library, theme and listening choices, optional automatic titles/summaries, followed by a Record walkthrough. Record’s paintbrush opens Appearance; the top-right ellipsis opens the same Transcription settings page available from Settings, within Record’s navigation stack.

Recording controls are Pause/Resume, Mute, then Stop on the right. Recordings support long-press and swipe deletion. Deleted metadata and audio are kept for recovery; shake to confirm undo, or use Undo delete in the list. Reset app has two confirmations and permanently erases recordings, model files and preferences before restarting setup. It is blocked during recording, finalization or a model download.

## Recording Live Activity

A WidgetKit extension shows recording status, elapsed time, pause/mute state and final saved status on the Lock Screen, with compact/expanded Dynamic Island layouts on supported devices. It contains no transcript text. Tapping opens Record via `voiceapp://record`. Enable or disable it in Transcription settings; iOS Live Activity permissions are respected and recording remains available when an activity cannot start. Activities are updated on state changes, use a system timer, end after save, and orphaned activities are cleared on relaunch. This works with the existing iOS 16.4 minimum, including the iPhone X Lock Screen.

The extension needs its own provisioning App ID (`com.suitbound.game.RecordingActivity`). If Apple reports the free-team limit of ten new App IDs per seven days, Simulator and unsigned device builds still work, but installation must wait for quota availability or another authorized signing team. Keep the existing app identifier to preserve its data.

## Offline models and storage

Settings → Models groups choices by purpose: recommended live voice models, other live models, live Whisper correction, summaries, speaker detection, and extra saved-text processing. The correction switch only appears in Transcription settings, not Models. A single Use action assigns the model to its supported purpose. Manage Data lists only downloaded models, largest first, with swipe-to-remove. Removing the last downloaded live model is blocked with an explanation; removing a selected model selects an available replacement. Apple speech files are system-managed.

Recommended setup:

| Purpose | Default choice | Optional model storage |
|---|---|---:|
| Default recommendation | FastConformer Transducer | 136.9 MB |
| Accuracy/speaker alternative | Moonshine Tiny Streaming | 45.4 MB |
| Faster alternative | Moonshine Tiny Streaming | 45.4 MB |
| Larger streaming alternative | Moonshine Medium Streaming | 269.3 MB |
| Live correction | Whisper Base English Q5 | 59.7 MB |
| Titles and summaries | SmolLM2 360M Instruct Q4 | 270.6 MB |

Only download choices you want. Downloads show retained sizes, support cancellation, verify every file against a pinned SHA-256 or CRC32C, and become installed atomically. Partial files never count as installed. Models are excluded from backups, removable, and released from memory when their job ends. No speech weights are bundled. FastConformer Transducer is the default recommendation, chosen in setup rather than automatically downloaded; Zipformer is an optional removable download. The previous optional full-size Whisper Base download is migrated without duplicating it.

Other implemented choices include Zipformer Kroko, FastConformer CTC/transducer, Nemotron streaming, Parakeet EOU 120M, Parakeet CTC 110M, Parakeet TDT v2/v3/Redux, SenseVoice, Qwen3-ASR 0.6B, Whisper Tiny/Base/Small/Medium/Turbo, and Distil-Whisper Small. Batch engines are for an optional extra saved-text pass. The catalog includes 22 downloadable speech choices, three local language models, and an optional 8.6 MB speaker-identification model, plus bundled Zipformer and system Apple Speech. Automatic titles and automatic summaries are separate switches in Settings → Beta, both off. The shared selected language model is independent of these switches. Speaker detection and the extra saved-text pass are in Transcription settings; all three default off. Speaker colors currently require Moonshine and the optional speaker assets.

The current Parakeet EOU conversion requires iOS 17+, so it is unavailable on iPhone X. Other native CPU engines target iOS 16.4, which iPhone X can run. This establishes deployment compatibility, not real-time performance on X. Large models are experimental on older phones; they may not keep up or fit available memory. Vosk, Qwen 1.7B, and every possible historical checkpoint were not integrated. Legacy Moonshine CDN entries that returned 403 were removed in favor of the working streaming models.

**No inference service is used.** Apple Speech is forced to on-device recognition and has no server opt-in. It can fail when the installed language/device does not support offline speech. Initial optional weight downloads require connectivity; thereafter audio, transcription, correction, titles, and summaries stay local.

## Processing order

1. Capture 16-kHz mono audio and feed the chosen streaming recognizer off the UI/audio threads.
2. If live correction is explicitly enabled, as phrases complete, spool their audio into a serial Whisper correction queue. The microphone and first-pass captions continue independently. Stop drains captured audio and pending corrections.
3. Save the recording and corrected transcript, retaining original text and phrase timing.
4. If enabled, run an additional selected batch model after Stop; this is off by default. Both Whisper refinement and the saved-text pass can instead be run manually from a recording’s Process recording menu.
5. Only after speech processing finishes, generate whichever automatic notes features are enabled: titles and/or summaries. The recording’s Process recording menu can generate either manually without enabling automation. Long transcripts are summarized in bounded chunks. JSON grammar constrains the output format; a source-based check restores omitted explicit schedules and numbers. Summaries can still omit or misinterpret information and remain reviewable alongside the transcript.

Starting another recording cancels outstanding notes AI and unfinished extra batch refinement before allocating the live engines. Pending notes AI can resume after a later recording. Edits/deletion are protected against stale asynchronous results. Optional notes alternatives are Qwen2.5 0.5B Q4 (about 398 MB) and 1.5B Q4 (about 1 GB). Both use the native CPU runtime and the same constrained JSON prompt. The 1.5B option is experimental and may exceed iPhone X performance/memory limits; the 0.5B option also needs real iPhone X evaluation. No better accuracy is guaranteed. Parakeet Unified Streaming 0.6B was retired and its previous download is removed during migration.

Active microphone recording uses the iOS audio background mode, so it can continue while locked. Stopping requests limited background time to finish saving. Optional post-recording model work may need the app foregrounded if iOS suspends it.

All recording audio is retained as CAF independently of recognition throughput and exported as compressed M4A on request. History is checkpointed during capture and interrupted recordings are recovered on launch. Recoverable legacy temporary CAFs are preserved rather than discarded; already deleted audio cannot be reconstructed. There is no fixed one-hour cap. Audio interruptions stop and save capture. Recording can continue while the screen is locked or another app is open, using the iOS audio background mode. If live decoding falls over two seconds behind, it resumes near the latest audio, keeps prior text stable, and queues the gap’s saved audio for Whisper correction. The full recording is retained even when first-pass recognition skips ahead.

## Fresh checkout

This workspace already contains the ignored native frameworks. To reproduce them:

```sh
./scripts/setup-sherpa.sh
./scripts/setup-whisper.sh
./scripts/setup-moonshine.sh
./scripts/setup-llama.sh
open VoiceApp.xcodeproj
```

Xcode 16+ is needed for the project format. `setup-llama.sh` installs pinned build tools only under `build/tools`, then builds CPU device/Simulator slices from pinned llama.cpp source. Downloads, build products, and model test caches stay under ignored `build/`. They are not part of the app bundle.

Runtime isolation matters: Moonshine embeds ONNX Runtime 1.23 while sherpa uses 1.28. Moonshine is wrapped in a dynamic framework exporting only its speech C API to prevent ABI collisions. llama.cpp similarly exports only its C API; its C++ implementation and ggml headers stay separate from Whisper through `NotesLLM.mm` and a small C-only bridge.

- sherpa-onnx 2.0.1 / ONNX Runtime 1.28.2
- Moonshine Swift binary 0.1.6, isolated native C API
- whisper.cpp 1.9.2
- llama.cpp b12387, CPU native runtime

Simulator builds need no Apple Developer App ID registration. The project retains the existing development team and bundle identifier used by the paired iPhone to avoid another free provisioning registration. Physical installation requires the device to be reachable; launching may additionally require unlocking it.

On Mac, select the attached microphone as Device Hub/Simulator input. Both the iOS app and the macOS simulator helper need microphone permission. The meter shows actual input; a moving meter with no captions indicates a later recognition issue.

## Validation

Integration checks decode a known 16-kHz recording, exercise repeated sessions, two turns separated by silence, final flushing, and silence. All implemented downloadable speech engines were decoded in Simulator; this is functional coverage, not an accuracy benchmark. Apple Speech remains dependent on installed system language support.

Physical iPhone 11 checks for Moonshine Small and Tiny passed the two-turn/silence/flush checks. On the 6.625-second clean sample, Small took about 3.4 seconds total decoding and Tiny about 0.7 seconds. These are throughput measurements, not word-to-screen latency or sustained thermal/battery measurements.

The paced live correction test uses the production consume/apply/Whisper queue. It confirmed correction **before Stop**, two corrected paragraphs, stable IDs, and preserved original text. Notes tests exercise real local model generation, important scheduled/numeric facts, legacy JSON decoding, metadata persistence, valid VTT text, Markdown generation, and playable AAC/M4A export. Final UI review includes bottom tabs, model grouping, transcript navigation, top-right copy/checkmark and export controls.

Current automated speech fixtures use a neutral synthesized passage about a community garden meeting, replacing the earlier literary excerpt. Historical throughput measurements above refer to the previous sample.

Debug-only launch arguments:

- `--streaming-smoke-test` for original streaming/audio-conversion checks.
- `--model-test moonshineSmall,parakeetEOU` for selected engines; `--download-models` optionally installs missing weights.
- `--live-correction-test --paced` for concurrent streaming correction.
- `--notes-feature-test` for local titles/summaries and exports.
- `--record-fixes-test` for continuous audio during decoding stalls, pause/mute/ambient, real model downloads and selection while busy, and Whisper recovery of skipped speech.
- `--speaker-test` for native speaker labels from two distinct voice fixtures.
- `--live-activity-test --microphone-fixture` in the isolated QA app checks real ActivityKit start/pause/mute/resume/end and saved audio. Fixture-only tests do not request microphone access. `--live-activity-preview --microphone-fixture` leaves a recording running for widget visual review.
- `--preferences-test` in the isolated QA build verifies off-by-default processing, separate title-only/summary-only persistence, and real Qwen 0.5B generation.
- `--management-test` in the isolated `com.voiceapp.setupqa` Debug build tests model removal/last-model protection, audio-preserving delete/undo, and reset without automatic downloads.
- `--microphone-fixture` feeds test audio at microphone speed through the real Record controls without host microphone hardware.

These read `Documents/streaming-fixture.wav` and write JSON reports in Documents without recording the microphone. Release builds omit the test harnesses. `scripts/cache-models.py <model IDs>` is an optional developer cache helper. `scripts/update-model-catalog.py` refreshes pinned manifests.

No recognizer guarantees zero missed or incorrect words. Real conversational recordings, soft speech, accents, background noise, and prolonged physical-device sessions still need evaluation before relying on this prototype for accessibility.

## Sources and licenses

See `VoiceApp/Licenses`, model-source links in the app, and the pinned `ModelCatalog.json`. Runtime sources: https://github.com/k2-fsa/sherpa-onnx, https://github.com/moonshine-ai/moonshine, https://github.com/ggml-org/whisper.cpp, https://github.com/ggml-org/llama.cpp. The small Parakeet CTC conversion is from VocaHQ; SmolLM2 quantized weights are from Bartowski/HuggingFaceTB. Export/demo test artifacts are not user recordings.
