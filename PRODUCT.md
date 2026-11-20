# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Native macOS app (Swift 6, SwiftUI with some AppKit), not iOS. Impeccable has no macOS value, so `ios` is the nearest
Apple-native setting. Apply the macOS conventions: pointer and hover, menu bar commands, keyboard shortcuts, sidebar and
toolbar windows, Settings window. Touch-target and phone layout rules don't apply.

## Users

Built for its author first: one person with a reMarkable Paper Pro who reads comics, books, magazines and PDFs on it,
writes notebooks, and takes work meetings at a Mac. It should then feel right for other reMarkable owners it is shared
with, so it can't depend on knowing the author's library or setup.

## Product Purpose

A desktop home for everything on a reMarkable tablet, without the tablet in hand. It syncs the library straight from
the reMarkable cloud and lets you:
- read anything on the Mac with the tablet's ink and highlights;
- record meetings and turn the transcript, typed notes and handwriting into notes sent back to the tablet;
- find anything across the library: search, Ask, tasks and highlights;
- receive daily deliveries on the tablet (newspaper, puzzles).

Success: it's the place you go on the Mac to pick up, find or add to anything that lives on the tablet.

## Positioning

The official reMarkable desktop app is a file manager for the tablet. This app treats the library as material to
read, search, ask and act on. It also brings two things to the Mac that the tablet can't do alone: meeting capture
(Granola-style, with handwriting from the tablet merged into the notes), and daily deliveries back to the tablet.
It talks to the reMarkable cloud directly: no server, no jailbreak.

## Operating Context

- Used at a desk on a Mac, alongside the tablet. Sessions are short (find a page, check a task, open a meeting) or long (reading a comic or book, a meeting being recorded).
- The library is large and mixed: comics and magazines with full-colour covers, text-heavy PDFs, handwritten notebooks, typed notebooks, daily newspapers and puzzles.
- Content arrives from the tablet and from the app itself (deliveries, meeting notes, the Tasks notebook).
- Main jobs, all in regular use: reading; notes and meetings; finding things; daily deliveries.

## Capabilities and Constraints

- Library sections: My files, Continue Reading, Favourites, Recent, Meetings, Tasks, Ask, Highlights; kinds (Notebooks, PDFs, Books); folders and tags; Trash.
- Reader for notebooks, PDFs and EPUBs with ink, highlights, spreads and dark mode; typed-text editing and handwriting conversion.
- Meeting window with live transcript, voices, AI notes and sending to the tablet.
- Settings window with a sidebar of panes; menu bar extra for quick capture and recording.
- Light and dark appearance both supported.
- Built with only the Command Line Tools (no Xcode), so no asset catalogs edited in Xcode; everything is in code.
- Optional "Operate as a server" mode adds MCP, indexing, Tasks notebook and deliveries.

## Brand Commitments

- Name: Un-remarkable (a play on reMarkable; independent, not affiliated).
- Existing app icon in the repo; voice in the UI is plain British English, short and direct.
- Must not imitate reMarkable's own branding or app; the user explicitly wants it to be better than the official app's look.
- Taste references (binding, given 2026-11-20): Martin Foucaut, Haikoo Studio, Type Darkroom, ISTD Awards, Gil Huybrecht,
  Maximilian Kaspar (all via SiteInspire), plus Awwwards, Httpster and Dribbble web-design inspiration. Shared traits:
  monochrome grounds (black or stark white) with at most one loud accent; a visible grid (hairline-bordered cells,
  full-height column rules); index lists with tiny thumbnails and right-aligned tabular facts instead of cards;
  large grotesk display type (often lowercase) with small mono labels and superscript annotations; ambient live
  details (local time, status) in edge rails; no rounded cards, shadows or decorative gradients.

## Evidence on Hand

- The real library (covers and thumbnails rendered from the user's documents) is the content every screen is built on.
- No testimonials, users or metrics exist; don't invent them.

## Product Principles

1. The library is the interface: covers, pages and ink are the content, chrome stays out of their way.
2. Pick up where you left off: the most recent reading, meeting or note is always one step away.
3. Everything is findable: anything on the tablet, typed or handwritten, can be searched, asked or acted on.
4. Respect the Mac: native windows, menus, keyboard and system appearance before custom invention.
5. Work for a stranger's library too: no layout that only works with the author's folders.

## Accessibility & Inclusion

Keyboard-complete operation, VoiceOver labels on icon-only controls, and contrast that holds in both light and dark appearance.
