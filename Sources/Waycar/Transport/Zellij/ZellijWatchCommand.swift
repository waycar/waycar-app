import Foundation

/// POSIX sh inventory feed (BSD/GNU sed), run in sshd's private exec process group.
/// Stdin EOF terminates that group, including an in-flight Zellij read, not just the poll loop.
enum ZellijWatchCommand {
    static func script(zellij: String, stateDirectory: String) -> String {
        let body = #"""
            Z=\#(ShellWord.quoted(zellij)); D=\#(ShellWord.quoted(stateDirectory)); LC_ALL=C; export LC_ALL
            (
              tick=
              trap '[ -z "$tick" ] || { kill "$tick" 2>/dev/null; wait "$tick" 2>/dev/null; }; exit 0' TERM INT
              prev=
              while :; do
                ls=$("$Z" ls -n 2>/dev/null | grep -v '[[:cntrl:]]' | grep -v '^-' | sed -n \
                  -e 's/^\(.*\) \[Created [^]][^]]* ago\] (current) *$/\1 [Created] (current)/p' \
                  -e 's/^\(.*\) \[Created [^]][^]]* ago\] (EXITED - attach to resurrect) *$/\1 [Created] (EXITED - attach to resurrect)/p' \
                  -e 's/^\(.*\) \[Created [^]][^]]* ago\] *$/\1 [Created]/p')
                live=$(printf '%s\n' "$ls" | grep -v ' \[Created\] (EXITED - attach to resurrect) *$' | sed 's/ \[Created\]\( (current)\)\{0,1\} *$//' | grep -v '^$')
                count=$(printf '%s\n' "$live" | grep -c .)
                out=$(printf '%s\n' "$ls"; printf '\036P\n'
                  printf '%s\n' "$live" | while IFS= read -r s; do
                    [ -n "$s" ] || continue
                    printf '\036S%s\n' "$s"
                    "$Z" -s "$s" action list-panes -j 2>/dev/null | tr -d '\012\015' | sed \
                      -e 's/,[[:space:]]*"cursor_coordinates_in_pane":[[:space:]]*null//g' \
                      -e 's/,[[:space:]]*"cursor_coordinates_in_pane":[[:space:]]*\[[[:space:]]*[0-9]*,[[:space:]]*[0-9]*[[:space:]]*\]//g' \
                      -e 's/"cursor_coordinates_in_pane":[[:space:]]*null,[[:space:]]*//g' \
                      -e 's/"cursor_coordinates_in_pane":[[:space:]]*\[[[:space:]]*[0-9]*,[[:space:]]*[0-9]*[[:space:]]*\],[[:space:]]*//g'
                    printf '\n'
                  done
                  printf '\036H\n'
                  for f in "$D"/*.json; do [ ! -f "$f" ] || { cat "$f"; printf '\n'; }; done)
                if [ "$out" != "$prev" ]; then
                  printf '\036B\n%s\n\036E\n' "$out"; prev=$out
                else
                  printf '\n'
                fi
                delay=1; [ "$count" -le 4 ] || delay=2
                sleep "$delay" </dev/null >/dev/null 2>&1 & tick=$!
                wait "$tick"; tick=
              done
            ) </dev/null &
            cat >/dev/null
            kill 0
            """#
        return "/bin/sh -c " + ShellWord.quoted(body)
    }
}
