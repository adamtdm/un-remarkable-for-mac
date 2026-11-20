# Un-remarkable for Mac

Native macOS reMarkable companion (Swift 6, SwiftUI, SwiftPM). See README.md for features and roadmap.

## Commands
- Build app bundle: `scripts/build-app.sh` → `dist/Unremarkable.app`
- Publish to your download page: `scripts/publish.sh`, configured by `config.local.env` (git-ignored; template in
  `config.example.env`: DOWNLOAD_URL, PAGES_HOST, PAGES_DIR). `scripts/install.sh` is published as `install-mac.sh`
  with `__DOWNLOAD_URL__` filled in; the page's version lines are `<!--mac-meta-->` markers.
- Build-time settings from `config.local.env` go into Info.plist: `UnremarkableUpdateFeed` (DOWNLOAD_URL) and
  `UnremarkableCompanionURL` (COMPANION_URL). Never hard-code personal servers, names or accounts in tracked files.
- Public releases: `scripts/publish.sh` ends by running `scripts/release-public.sh` when PUBLIC_REPO is set. It copies the current commit to PUBLIC_REPO as one squashed commit
  (this repo's history stays private) and refuses if any config.local.env value appears in the files.
- Tests: `scripts/test.sh` (Swift Testing; works with only the Command Line Tools)
- Debug build: `source scripts/env.sh && swift build`
- Visual check of the running app without Screen Recording permission: run the binary with
  `UNREMARKABLE_SNAPSHOT_DIR=<dir>`; it writes a PNG of each window every 2s.
- Dev launch hooks (env vars on the binary): `UNREMARKABLE_OPEN=<docID,…>` opens readers;
  `UNREMARKABLE_MEETING=record|<meetingID>` starts/opens a meeting; `UNREMARKABLE_STOP_AFTER=<s>` stops it;
  `UNREMARKABLE_WRITE_NOTES=1` writes AI notes for the opened meeting; `UNREMARKABLE_FAKE_ME` /
  `UNREMARKABLE_FAKE_THEM=<audio file>` replace the microphone / system audio (no permission prompts).
- More dev hooks: `UNREMARKABLE_SETTINGS_TAB=<pane>` opens Settings on a pane (general, sync, reading, server, delivery,
  updates, system…). `UNREMARKABLE_SECTION=highlights|ask|tasks|meetings|folder:<id>|search:<text>` opens a library section.
  Snapshot PNGs are named after the window title (the open document, meeting or section).
  `UNREMARKABLE_UPDATE=install` with `-updateFeedURL <url>` checks and installs from a test feed.
  Pass `-serverMode NO` on dev runs so they never write to the tablet (Tasks notebook, deliveries).
- Updater: `publish.sh` uploads `mac-version.json` (version, sha256, notes) after the zip. The app refuses a bundle
  that doesn't satisfy its own designated requirement (same signing cert), so keep `scripts/setup-signing.sh`'s identity.
- Live Apple Intelligence notes tests (needs it switched on): `RMKIT_APPLE_AI=1 scripts/test.sh --filter AppleIntelligenceTests`.
  Its context is 4,096 tokens: keep prompts within `AIProviderKind.apple.promptBudget` and cap response tokens.
- Live cloud write test (creates two test notebooks, verifies, trashes them): `RMKIT_LIVE_CLOUD=1 scripts/test.sh --filter LiveCloudTests`.
  Before changing index/root writing, check `RMKIT_ROOT_INDEX=<root blob> scripts/test.sh --filter realRootIndex` stays byte-identical.
- Live handwriting conversion (reads one real page, writes nothing): `RMKIT_LIVE_CONVERT=1 scripts/test.sh --filter LiveConversionTests`.
  The endpoint is `POST /convert/v1/handwriting` (MyScript batch JSON, `Accept: application/vnd.myscript.jiix`).
- Voice separation: `VoiceTests` builds fake calls with `say`. `RMKIT_VOICE_CALL=<file.m4a>` writes a two-voice call
  to use as `UNREMARKABLE_FAKE_THEM`; `RMKIT_MEETING_DIR=<meeting folder>` re-runs separation on a recording;
  `RMKIT_VOICE_DEBUG=1` prints voice-print distances (threshold calibration).
- Render fixtures to PNG: `RMKIT_RENDER_DIR=<dir> scripts/test.sh --filter renderFixtures`

## Design
- DESIGN.md is the visual system (Column Rules); PRODUCT.md holds the brief and taste references. Everything opens in
  the library window as panes (`AppModel.show/minimise/close`); don't add new windows.

## Notes
- This machine has no full Xcode. The CLT's macOS 27 SDK needs a SwiftUI macro plugin that isn't shipped,
  so `scripts/env.sh` pins `MacOSX26.5.sdk`. Always build through the scripts or source env.sh first.
- Signing: `scripts/setup-signing.sh` creates a self-signed identity in its own keychain (in Application
  Support/Unremarkable/signing) so TCC permissions survive rebuilds; build-app.sh uses it, else ad-hoc.
  Secrets still live in `Secrets` (0600 file), not the Keychain.
- Meeting mode needs macOS 26 (SpeechAnalyzer). Real mic/system-audio capture shows TCC prompts only the user
  can answer; use the FAKE_ hooks for automated runs.
- Audio capture lessons (macOS 26): mic and system-audio tap must share ONE aggregate device
  (`SystemAudioSource.microphone`); a separate mic capture (AVAudioEngine or HAL) alongside the tap stalls it,
  and voice processing (echo cancellation) breaks the tap. Echo is removed in the transcript instead
  (`Meeting.appendSegment`). Launch real-capture tests with `open --env …` (not the binary) or TCC checks the
  terminal's permissions. Never SIGKILL the app mid-capture: it can wedge coreaudiod (fix: `sudo killall coreaudiod`).
  `UNREMARKABLE_AUDIO_DEBUG=1` logs formats, levels and tap callbacks to stderr.
- Versioning: `VERSION` file (0.11 = meeting mode); bump +0.01 and tag `vX.YY` with each commit.
- Reference sources live in `_ref/` (web, android, rea clones) and `reMarkable.app/`, both gitignored.
  Port behaviour from `_ref/android/core` and `_ref/web/src/rmcompanion` before inventing new logic.
- sync15: root via `GET /sync/v4/root`, blobs via `/sync/v3/files/<hash>`, root update via `PUT /sync/v3/root`
  (412 = generation moved; rebuild and retry). Schema-4 doc hashes are sha256 of the serialized `.docSchema`.
