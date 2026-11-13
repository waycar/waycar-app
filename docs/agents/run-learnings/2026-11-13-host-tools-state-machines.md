# 2026-11-13 — Host Tools lifecycles as state machines (plugin 2.6.1)

- **Worked:** pin tests through the existing functions first, then one
  conversion per commit with `impl StateMachine for`, kept every on-disk
  format and test vector unchanged; `scripts/check-state-machines.py` finds
  the Rust machines the same way as the Swift ones.
- **Worked:** guarded tmux writes as a compare-and-swap inside the server
  (`if-shell -F '#{==:#{@waycar_seq},<read>}' …`, then read the value back);
  a refused write re-reads, decides again from the fresh status and retries
  a bounded number of times, so a late hook never overwrites a newer status
  and a racing one is not lost. Checked against real tmux 3.2a, 3.3a, 3.4
  and 3.7c on private `-L` servers.
- **Broke:** a test whose verdict needs a subprocess to exit before a
  300 ms deadline is a flake waiting for a loaded runner; give the subprocess
  seconds, and keep whatever it leaves behind alive far longer.
- **Watch out:** a value placed in a tmux format (`#{==:…,value}`) must hold
  no `#`, `,`, `}` or control character; anything else takes the old
  unconditional path rather than a format it could break.
