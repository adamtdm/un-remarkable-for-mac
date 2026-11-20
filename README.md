# Un-remarkable for Mac

A native macOS companion for reMarkable tablets (Paper Pro, reMarkable 2, reMarkable 1), built in Swift and SwiftUI.
It merges the [web app](https://github.com/adamtdm/Un-remarkable) and the [Android app](https://github.com/adamtdm/un-remarkable-android)
into one desktop app, with a Granola-style meeting mode.

It talks to the reMarkable cloud (`sync15`) directly, like the Android app: no Docker, no server, no jailbreak.

## Get started

You need an Apple silicon Mac with macOS 15 or later (meeting recording needs macOS 26), a reMarkable account with
cloud sync on, and Xcode or just the Command Line Tools (`xcode-select --install`).

```sh
git clone <this repository> un-remarkable-mac && cd un-remarkable-mac
scripts/setup-signing.sh      # once: a local signing identity, so macOS remembers mic/calendar permissions
scripts/build-app.sh          # builds dist/Unremarkable.app
cp -R dist/Unremarkable.app /Applications/ && open /Applications/Unremarkable.app
```

Then connect your tablet. That's the only thing you have to add:

1. Open <https://my.remarkable.com/device/desktop/connect> (the app links to it), sign in and copy the one-time code.
2. Type the 8-character code into the app and press **connect**. Your library syncs straight away.

The token is stored only on your Mac (see [Data and privacy](#data-and-privacy)). Everything else is optional and
lives in Settings (⌘,):

- **AI Providers**: for meeting notes, Ask and handwritten tasks. Apple Intelligence works on-device with no key;
  or paste a Gemini or OpenAI API key, or point it at a local Ollama.
- **Meetings**: connect your calendars to be reminded to record, with titles and attendees filled in.
- **Server**: "Operate as a server" adds the MCP server, search indexing, the Tasks notebook and daily deliveries.
- **Search**: an optional [companion web app](https://github.com/adamtdm/Un-remarkable) server to search as well.

### Share builds and get in-app updates (optional)

To install on other Macs with one command and get updates from inside the app, publish your builds to any web
server you can reach over SSH:

1. `cp config.example.env config.local.env` and fill in `DOWNLOAD_URL` (the public address of the folder),
   `PAGES_HOST` and `PAGES_DIR`. `config.local.env` is git-ignored.
2. `scripts/publish.sh` builds the app with that address as its update feed, then uploads `Un-remarkable-mac.zip`,
   `mac-version.json` and `install-mac.sh` (and updates a `<!--mac-meta-->…<!--/mac-meta-->` version line in the
   folder's `index.html`, if there is one).
3. On any Mac: `curl -fsSL <DOWNLOAD_URL>/install-mac.sh | zsh`. Run the same command to update; it replaces the
   copy you already have, asking for an administrator password if another account installed it.

Builds made without `DOWNLOAD_URL` have in-app updates switched off (you can still enter a feed in Settings › Updates).
Updates must be signed by the same certificate as the running copy, so keep the identity from `scripts/setup-signing.sh`.

## Meeting mode (v0.11)

- **Record** from the Meetings section, the menu bar (waveform icon) or ⇧⌘M. Your microphone is transcribed as "Me"
  and system audio (Zoom, Meet, Teams…) as "Them", using a Core Audio process tap. Audio is saved per speaker.
- **Live on-device transcript** with Apple's SpeechAnalyzer (macOS 26). Nothing is sent anywhere while recording.
- **Type rough notes** while the transcript runs, Granola style.
- **AI notes** after the meeting: your notes are the outline, filled in from the transcript, plus decisions, action items
  and open questions. Handwriting from a linked tablet notebook is read too (the notebook you wrote in during the
  meeting is suggested automatically). Providers: Gemini, OpenAI, Ollama, or Apple Intelligence on-device
  (free and private; it fills a structured schema, so the notes are reliable even from a small model, but it can't
  read handwriting images).
- **Send to tablet**: the notes and transcript go to your "Meeting Notes" folder as a PDF with space to write.
- Copy as Markdown, search across meetings, resume a recording.

## Writing to the tablet and organising (v0.14–v0.15)

- **Typed notebooks**: ⌘N writes a notebook in Markdown with a live preview of the tablet page. Headings, bold,
  bullets and checkboxes become native reMarkable paragraph styles; `---` starts a new page. The `.rm` v6 writer is
  byte-identical to rmscene (what the web app uses).
- **Import Markdown**: from the + menu, or drop `.md` files on the library.
- **Quick notes** from the menu bar, appended with a timestamp to a "Quick Notes" notebook (handwriting on it is kept).
- **New folders** (⇧⌘N).
- **Organise**: rename, move (menu or drag onto a folder in the grid or sidebar), favourites, move to Trash and put back.
- **Export** any document or folder: vector PDFs with your ink, highlights and typed text (original pages for PDFs),
  EPUBs as the original file, folders as folders.
- **Meeting notes as a typed notebook** (default) or PDF; sending again updates the same notebook.

## Tasks (v0.16)

- **Tasks section** in the library: everything to do across your notebooks, grouped by where it came from, with
  tick-off, add, and jump to the source page.
- Found in typed text (`* task`, `[ ]`/`[x]`, `TODO:` and native checkboxes; pasted Markdown bullets are ignored),
  handwritten `*` tasks (reMarkable's handwriting conversion, or a vision AI), and your "Me" action items from meeting notes.
- Only pages changed since the last scan are read; handwriting OCR is capped per scan.
- **Tasks notebook** on the tablet (on by default, adopts an existing "Tasks" notebook), rebuilt in place; ticking a
  box in it on the tablet completes the task. If the web server is also running, untick *Keep Tasks notebook on
  tablet* there (or set `RMC_TASKS_NOTEBOOK_SYNC=false`) so they don't overwrite each other.
- Quick capture: the menu bar field has Note and Task modes.

## Operate as a server (v0.26)

Settings › Server has one switch for the web server's background features. Off (the default for new installs), the app is
a plain reMarkable sync client: the reader, meetings, writing to the tablet, quick capture, title search and Ask all work.
On, each feature has its own toggle:
- **MCP server** for AI assistants (details in the MCP tab).
- **Notebook text indexing** for full-text search and Ask.
- **Tasks notebook** on the tablet.
- **Daily newspaper**: *The Morning Chronicle*, built from your RSS feeds with full article text, Wikipedia's featured
  article, weather and optional images. It has a tappable index and "Back to index" links. Delivered to a folder after a set time.
- **Daily puzzles**: the Guardian quick and cryptic crosswords (cropped to fill the screen) and a seeded sudoku with its solution.

Deliveries are sized for the tablet chosen in Reader › My tablet, and run at the first sync after the set time.
"Deliver Now" sends one straight away. If the web server also delivers, switch its delivery off to avoid getting two copies.

## Everything in the columns (v0.31)

- **The whole app uses the column style**: folders, search, meetings, tasks, Ask, highlights, the reader and meeting
  notes all live in the main window's columns, with mono index lists, ruled rows and one pink action per screen.
- **No more extra windows.** Documents and meeting notes open in the main area. **Minimise** one (Esc) and it folds to a
  rail on the left, where you click to bring it back; **close** it with ⌘W. A meeting that's still recording only
  minimises. While something is open, the today and tablet columns fold to rails to give it room.
- The reader's controls (pages, contents, bookmarks, two-page view, fit) sit in a slim bar at the top of its pane.
- Search lives in the toolbar (⌘F, handwriting too); ⌘1–⌘5 switch between library, meetings, tasks, ask and highlights.
- Tasks, highlights and folders lay out across the columns; meetings show up next and recorded meetings as an index.

## New look: Column Rules (v0.30)

- **A new library home**: four columns divided by hairline rules. The first two hold what you were last in (its cover,
  progress and a pink Continue) and then the whole library as covers, scrolling down, with notebook / PDF / book filters
  and sort at the top. The third column is today (meetings, open tasks you can tick off, what changed); the fourth is the
  tablet (sync, folders, kinds, favourites, tags, trash).
- **Hide a column** with the arrow in its header; it folds into a thin rail you click to bring it back, and the library
  takes the space.
- Sections are tabs in the toolbar (library, meetings, tasks, ask, highlights); the sidebar is hidden by default and
  still one click away.
- Type is Funnel Display and Geist Mono (bundled, SIL Open Font License); white or near-black with one pink accent,
  square corners, no shadows.

## Handwriting, voices and companion search (v0.29)

- **Convert handwriting to text** in the reader (the text-viewfinder button): reMarkable's own handwriting conversion,
  as "Convert to text" on the tablet, for one page or the whole notebook, in 15 languages. Copy the text or save it as a
  typed notebook. It needs no AI provider, so it works with Apple Intelligence.
- **Handwriting in search, Ask and Tasks** (Server › Read handwriting into search) uses the same conversion by
  default, or a vision AI if you prefer. Handwritten `*` tasks are found the same way. Meeting notes written with
  Apple Intelligence now include the linked notebook's handwriting as converted text.
- **Voices on calls**: when a recording stops, "Them" is split into the separate voices on the call (Them 1, Them 2…)
  from the recorded system audio. Name each voice (attendees are offered); the names go into the transcript and
  the AI notes. It works on voice characteristics (cepstra and pitch) without a speaker model: distinct voices
  separate reliably, very similar voices may be split in two (give both the same name) or merged.
- **Companion server search** (Settings › Search): adds results from the self-hosted web app to search.
- **MCP**: `convert_handwriting` reads a notebook page's handwriting as text.

## Settings and updates (v0.27)

Settings is a sidebar window, like System Settings and laid out like the web app's settings page. Its sections:
- Appearance
- Account & Sync
- Reading & Gestures
- Updates
- Meetings
- Tasks
- Search
- AI Providers
- Server
- MCP Server
- News & Puzzles (feed catalogue, presets and discovery)
- System & Diagnostics (library stats, storage, sync history)

**Updates** checks the download page's `mac-version.json` every 6 hours (or use *Check for Updates…* in the app
menu). Before installing, it checks the download's SHA-256 and that it's signed with the same certificate as the
running copy. It then swaps the app bundle and relaunches. `scripts/publish.sh` writes the manifest.

Reader: bookmarks (B), trackpad swipe and/or edge clicks to turn pages, a page bar that fades in full screen, and
*Edit typed text* for notebook pages. The library has a **Highlights** section covering every book.

## Library and reader (v0.1)

- **Pairing** with an 8-character one-time code. This Mac registers as a desktop app on your account.
- **Sync**: pulls the whole library tree (metadata only), checks for changes every 2 minutes by default, and downloads page files on demand into a content-addressed blob store.
- **Library**: folders, Continue Reading, Favourites, Recent, Notebooks / PDFs / Books, tags and Trash. Grid or list view, sorting, breadcrumbs, thumbnails.
- **Search**: SQLite FTS5 over titles, tags, typed notebook text and the text of PDFs you have opened, with highlighted snippets.
- **Command palette** (⌘K): fuzzy jump to any document, folder or command.
- **Reader** for notebooks and PDFs:
  - Native `.rm` v6 vector rendering (pressure-aware brushes, colours, highlights, typed text). Legacy v3/v5 files are supported too.
  - Ink overlaid on PDFs using the tablet's coordinate mapping. Inserted note pages work.
  - Dark mode that darkens text pages but leaves comics and artwork alone, with a per-document override.
  - Two-page spreads (optionally with the cover alone), right-to-left manga mode, fit page or width.
  - Keyboard paging (←/→, space, Page Up/Down, Home/End, G to jump), click-zone paging, and a page scrubber.
  - Sidebar with page thumbnails, PDF table of contents, and tablet highlights you can copy as Markdown.
  - Settings are remembered per book. Your page position syncs back to the tablet.
- **EPUB reader**: chapter list, light/dark reading styles, font size.
- **Upload**: drop PDFs or EPUBs on the library window to send them to your tablet.
- **AI provider settings**: Gemini, OpenAI or Ollama, the same providers as the web app, with a connection test.

## Develop

```sh
scripts/build-app.sh debug    # debug app bundle in dist/
scripts/test.sh               # unit tests (Swift Testing; works with only the Command Line Tools)
```

CLAUDE.md lists the development hooks (snapshots of the running app, fake audio for meetings, live cloud tests).

Versions: v0.1 library and reader, v0.11 meeting mode, then +0.01 per commit (the `VERSION` file).

`scripts/env.sh` pins a compatible SDK when only the Command Line Tools are installed.

## Layout

```
Sources/RMKit/          Platform core, no UI
  Cloud/                Auth (pairing, token refresh), sync15 client, SyncEngine, secret storage
  Model/                .docSchema index entries, document metadata (.metadata/.content, cPages)
  Store/                Blob store, SQLite + FTS5 library, text indexer, search providers
  Render/               .rm parser, scene model, palettes, CoreGraphics page renderer
  Intelligence/         Gemini / OpenAI / Ollama client
Sources/Unremarkable/   SwiftUI app: library, reader, EPUB, settings, command palette
Tests/RMKitTests/       Parser fixtures (shared with the web app), sync model, database, renderer
```

## Data and privacy

- Library index and downloaded files: `~/Library/Application Support/Unremarkable/`.
- Thumbnails and unpacked EPUBs: `~/Library/Caches/Unremarkable/`.
- The reMarkable token and AI keys are in `secrets.json` in the Application Support folder, readable only by your user (mode 0600).
  The Keychain isn't used yet: ad-hoc signed builds change signature on every rebuild, which would trigger a Keychain prompt each time. Switch back once the app is Developer ID signed.

## Roadmap

Done: calendar meetings (v0.23), typed-notebook meeting notes (v0.14), handwriting conversion, voice separation
and companion search (v0.29).

1. **Screen Share** (needs someone at the tablet to develop and test): the official app's screen share is WebRTC.
   The tablet sends a notification, SDP is exchanged over HTTP (`/screenshare/v1`, `application/sdp`), and a data
   channel carries an RFB (VNC-style) stream. A Mac version could use WebKit's WebRTC for the data channel. The broker
   messages and the RFB encoding still have to be reverse engineered from live sessions, which means starting a share
   on the tablet each time.

## Credits and licence

- Un-remarkable is released under the MIT licence (see `LICENSE`).
- Funnel Display and Geist Mono are bundled under the SIL Open Font License (`Resources/Fonts`).
- The `.rm` test fixtures come from [rmscene](https://github.com/ricklupton/rmscene) (MIT).
- Not affiliated with or endorsed by reMarkable AS. "reMarkable" is their trademark. The app uses the same cloud
  endpoints as reMarkable's own apps, which can change without notice.
