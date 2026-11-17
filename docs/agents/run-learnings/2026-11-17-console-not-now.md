# 2026-11-17 — One Not now for every hideable Console row

- **Worked:** one throwaway screenshot run captured both layouts (buttons
  beside the words, and under them) on iPhone and iPad, so the layout
  call took one Mac round, not two.
- **Broke:** two buttons beside a Console row's words fit the iPhone but
  not the iPad sidebar (about 380 pt): the message truncated and "Start
  Herdr Core" wrapped. Rows with two buttons now put them under the words.
- **Watch out:** `make publish` moves `[Unreleased]` into a release file, so
  a change to a shipped-but-unsubmitted release cannot reword its old
  CHANGELOG line: write a new `[Unreleased]` entry; App Store What's New is
  where the single reworded line goes.
