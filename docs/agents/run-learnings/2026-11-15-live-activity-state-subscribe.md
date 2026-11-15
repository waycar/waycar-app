# 2026-11-15 — Live Activity end lost before the coordinator subscribed

- **Broke:** `anExpiredActivityIsDismissedNotLeftBesideItsReplacement` hit
  its 30 s wait on hosted CI: its poll resumed before the coordinator's
  watch tasks, which made the state stream only when they first ran, so
  the fake's `.ended` reached no subscriber and no replacement started.
  Now a Known trap (a stream made inside `Task {}`).
- **Worked:** a deterministic red without load: a fake hook
  (`onNextRequest`) starts a main-actor task inside `request`, which runs
  ahead of every task the caller starts after it, the order a busy main
  thread gives by chance.
