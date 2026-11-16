# 2026-11-16 — Console status headings, preview first

- **Worked:** a designer put three heading looks behind a DEBUG-only launch
  argument of the demo fixture (`--demo-screenshots`), captured them with a
  throwaway UI test through `mac_run` `screenshots` (the run script narrowed
  to that test in the preview commit), and the owner picked from six images
  on one card. The real build then started from his picks, not a guess.
- **Watch out:** switching a simulator's appearance with `simctl ui` right
  before a UI test made it fail `kAXError -25218` until it had settled for
  about 20 s. Pick light or dark per launch with `-app-appearance light|dark`
  (UserDefaults argument domain) instead.
- **Watch out:** a plain List gives every row at least 44 pt
  (`defaultMinListRowHeight`), so a caption-sized row needs it set to 0; then
  any row that relied on the List for its tap target (the AI Usage button)
  must keep 44 pt itself. A plain List's `Section` header pins while its
  group scrolls and adds tall gaps between groups; an inline row does not.
- **Watch out:** headings over a sorted list must group the rows as placed,
  never re-sort them: the open Agent keeps its place under its held status,
  and an Ultimate lead or a departing row can sit apart from its group, so a
  later run of the same kind needs its own row id.
