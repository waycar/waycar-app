# 2026-11-19 — Direct Input keyboard flake: the simulator lost its keyboard

- **Broke:** the flake hunt failed
  `terminalKeyboardTakesMessageAgentsVisibleKeyboardWithoutReloading` once
  in 16 passes (loaded job, pass 1): the inset read 0 right after the
  Terminal Keyboard tap. Not an app bug: that pass alone logged the
  simulator's keyboard process (InputUI) going away, the keyboard and the
  Composer's focus went with it, and the inset rightly followed. The test
  took its height at the first landing and accepted any steady inset as
  settled, so it tapped anyway.
- **Worked:** `grep -c` of system lines across every pass log: only the
  failing pass had `_UIRemoteKeyboards` errors, in the same seconds. Then a
  throwaway test that `SIGKILL`s its own simulator's `InputUI` right after
  the keyboard lands gave the same four issues 2 of 2; with the fix, every
  kill that dropped the keyboard (4 of 4) recovered and passed.
- **Broke:** my first fix passed review by eye and failed a clean
  `-test-iterations 3` run 1 and 2 of 3 times: it checked the live inset
  against display-frame samples still stable at 0, so it went on in the
  instant the keyboard landed, before the Toolbar moved.
- **Watch out:** the flake hunt's artifacts hold the pass logs only (no
  xcresult; `Waycar*.ips` only on a crash). `NSLog` lines with a unique
  prefix in a throwaway commit show up in the `mac_run` full log.
