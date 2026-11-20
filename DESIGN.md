# Design: Column Rules

The Mac app's visual system (v0.30+). Taste references and reasons are in PRODUCT.md.

## Layout
- The library window is the whole app. It is four equal columns divided by full-height 1px rules (`Paper.border`).
  - **Main area** (columns 1–2, wider when a side column is folded): library home, a section, or an open pane.
  - **Today** (column 3) and **Tablet** (column 4): each folds into a 30px rail with its name running vertically.
    The fold state is remembered separately for the library (`homeShowToday/Tablet`, default open) and for an open
    document or meeting (`paneShowToday/Tablet`, default folded).
- Documents and meetings open as **panes** in the main area (`AppModel.panes`, `activePane`), never in their own
  windows. A pane can be minimised (Esc) to a rail on the left, or closed (⌘W). A meeting that is still recording only
  minimises. Settings is the only other window.
- Content in the main area snaps to the column unit (`\.columnUnit`, `\.mainUnits`): covers two to a column, lists one
  to a column, with `InnerRules` carrying the column lines through.
- Every column starts with a 40px header row (`ColumnHeader`): a mono label, then the column's options.
  The top band under it is 200px in every column so the lists below line up.

## Type
- Funnel Display (`Font.display`) for titles and large text: never bold, slight negative tracking.
- Geist Mono (`Font.mono`) for labels, lists, facts and controls: 12–13pt.
- The app's own labels are lowercase; user content (titles, notes) is shown as written.
- Long-form reading (AI answers, notes, transcripts) stays in the system font for readability.

## Colour
- White `#FFFFFF` or near-black `#0B0B0C` grounds; ink `#0A0A0A` / `#F1F1EE`; muted text passes 4.5:1.
- One accent, pink (`Paper.accent`, `#E0006B` light / `#FF4D94` dark): only the primary action on a screen
  (`AccentButtonStyle`) and reading progress. Red is reserved for "recording".

## Components
- `RuledRow` / `RuledList`: index lists, full-ink hairline above each row, title left, tabular fact right.
- `Chip`: a text tab; the selected one is ink and underlined. `MonoButtonStyle`: quiet text actions.
- `RuledField`: a text field on a single ink rule. `ProgressLine`: 3px, accent fill.
- No rounded cards, shadows, gradients or materials.
