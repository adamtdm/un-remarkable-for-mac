# Feature parity: web app vs Mac app

Compared against the web app (`adamtdm/Un-remarkable`, main @ 7eeada4: every REST route, MCP tool and settings
section) on 16 Nov 2026, updated 18 Nov 2026 (v0.27: no ❌ or 🟡 rows left). ✅ done · 🟡 partial · ❌ missing · — not applicable. "Plan" is the Mac version that adds it.

## Sync and library

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| sync15 cloud sync, change detection, blob store | ✅ | ✅ | |
| Live sync monitor with activity log | ✅ | ✅ | Mac: popover; no transfer-rate figure |
| Folders, breadcrumbs, grid/list, sort | ✅ | ✅ | |
| Type filters (Folders / Notebooks / PDFs / EPUBs) | ✅ | ✅ | v0.19 chips |
| "Excluded" filter | ✅ | ✅ | v0.20 |
| Continue Reading shelf | ✅ | ✅ | v0.19 |
| Create folder, move (drag), rename, delete to Trash | ✅ | ✅ | |
| Bulk import PDFs/EPUBs (drop) | ✅ | ✅ | |
| Thumbnails | ✅ | ✅ | v0.27: tablet thumbnails, else EPUB covers and short PDFs are fetched (setting) |
| Snapshots (point-in-time versions from the blob store) | ✅ | ✅ | v0.27: recorded per sync, history in System & Diagnostics |
| App password / auth for remote access | ✅ | — | Mac is local; MCP gets a token (v0.22) |

## Reader

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| Notebook + PDF ink rendering, highlights, typed text | ✅ | ✅ | Mac fixed PDF ink scale (v0.15) |
| Dark mode (perceptual) with artwork detection, per-doc override | ✅ | ✅ | Mac: quick toggle in reader (v0.19) |
| Two-page spreads, cover alone, RTL manga | ✅ | ✅ | |
| Page jump, scrubber, keyboard | ✅ | ✅ | |
| Table of contents | ✅ | ✅ | |
| Bookmarks | ✅ | ✅ | v0.27: B key, toolbar, sidebar panel, ribbon on the page |
| Fullscreen HUD with edge tap zones | ✅ | ✅ | v0.27: page bar fades in full screen |
| Page-turn mode setting (swipe / tap / both) | ✅ | ✅ | v0.27: trackpad swipe, edge clicks or both |
| EPUB reader | ✅ | ✅ | v0.24 position synced both ways (proportional chapter ↔ page) |
| Highlights per book, export Markdown | ✅ | ✅ | |
| Highlights across the library | ✅ | ✅ | v0.27: Highlights section, filter, Markdown export |
| Type Folio drawer: edit a page's typed text | ✅ | ✅ | v0.27: reader › Edit typed text |

## Search

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| FTS5 over titles, tags, typed text, PDF text | ✅ | ✅ | |
| Handwriting OCR into search (vision) | ✅ | ✅ | v0.27: Server › Read handwriting into search (Gemini/OpenAI/Ollama) |
| Handwriting conversion with reMarkable's service (no AI needed) | ❌ | ✅ | v0.29: default OCR engine, reader "Convert to text", MCP `convert_handwriting` |
| Companion server results in search | — | ✅ | v0.29: Settings › Search › Companion server |
| Search filter (Notes only / All documents) | ✅ | ✅ | v0.20 |
| Exclude folder (recursive) / document from search & OCR | ✅ | ✅ | v0.20 |
| Per-document indexing toggle | ✅ | ✅ | the web toggle is its exclusion switch; Mac: Exclude from Search & Tasks |
| Ask questions of your notes (answer + source) | ❌ | ✅ | v0.21, Apple Intelligence on device |

## Writing to the tablet

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| New typed notebook, multi-page via `---` | ✅ | ✅ | Mac adds paragraph styles |
| Markdown import | ✅ | ✅ | |
| Quick capture (note / task) | ✅ | ✅ | Mac: menu bar |
| Edit a page's typed text in place | ✅ | ✅ | v0.27 in the reader; also MCP update_page_text |
| Appending keeps text IDs (handwriting anchors stable) | ❌ | ✅ | v0.24 CRDT append (validated with rmscene) |

## Tasks

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| Typed task rules, checkboxes, TODO | ✅ | ✅ | Mac: bullet-aware |
| Handwritten `*` tasks via vision | ✅ | 🟡 | Mac: built, needs a vision provider |
| Consolidated Tasks notebook, ticks read back | ✅ | ✅ | Mac reads ticks from the tablet |
| Complete all | ✅ | ✅ | v0.20 |
| Meeting action items as tasks | — | ✅ | Mac only |

## Export

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| Annotated PDF export | ✅ | ✅ | Mac: vector |
| Folder ZIP export | ✅ | ✅ | v0.27: right-click › Export as ZIP |

## Converter and device profiles

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| 5-stop quality optimiser for PDF / EPUB / CBZ | ✅ | ✅ | v0.25 (EPUB: image-based) |
| Device profiles (Paper Pro, Paper Pro Move, RM2, RM1) | ✅ | ✅ | v0.24–v0.25 |
| Double-spread splitting | ✅ | ✅ | v0.25, with manga order |
| Convert an existing document | ✅ | ✅ | v0.25 (right-click › Optimise for Tablet) |

## Daily delivery

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| Newspaper from RSS (full articles, Wikipedia, weather, images, tappable index) | ✅ | ✅ | v0.26 |
| RSS catalog, discovery, validation | ✅ | ✅ | v0.27: catalogue, presets, categories, find a site's feed |
| Guardian quick/cryptic crosswords, sudoku | ✅ | ✅ | v0.26 |
| Scheduled delivery + manual trigger, on/off | ✅ | ✅ | v0.26 (checked after each sync) |

## AI and integrations

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| Providers: Gemini / OpenAI / Ollama | ✅ | ✅ | Mac adds Apple Intelligence |
| MCP server (17 tools) on the network + stdio | ✅ | ✅ | v0.22: same 17 + ask_notes, list_meetings, get_meeting, convert_handwriting (v0.29) |
| Calendar: meeting prompts, attendees, notes on the tablet's meeting page | — | ✅ | v0.23 |
| Meeting recording, transcript, AI notes | — | ✅ | Mac only |
| Separate voices within "Them", named per voice | — | ✅ | v0.29 |

## Settings

| Feature | Web | Mac | Notes / plan |
|---|---|---|---|
| Appearance | ✅ | ✅ | |
| Settings page with sections | ✅ | ✅ | v0.27: sidebar window like System Settings |
| Update the app from inside the app | — | ✅ | v0.27: checksum + same-certificate check, swap and relaunch |
| Reading & navigation | ✅ | ✅ | v0.27 |
| AI / vision settings + test | ✅ | ✅ | |
| MCP settings (token, URL, copy config) | ✅ | ✅ | v0.22 |
| Sync settings | ✅ | ✅ | |
| Delivery settings | ✅ | ✅ | v0.26, Server tab |
| "Operate as a server" switch (MCP, delivery, indexing, Tasks notebook) | — | ✅ | v0.26; off = plain sync client |
| Diagnostics & storage, clear thumbnails, rescan | ✅ | ✅ | v0.27: stats, task scan, storage, sync history, rescan |
