# Demo terminal frames

The terminal every Agent pane shows under `--demo-screenshots` (and so in the
README and marketing screenshots) is an OMP-styled session, drawn with omp's
default `dark` theme colors. `make_omp_frames.py` builds one frame per pane
width the screenshots capture:

| Frame       | Columns | Pane                                          |
|-------------|---------|-----------------------------------------------|
| `iphone`    | 68      | iPhone 17 Pro Max Agent                        |
| `ipadSplit` | 150     | iPad Pro 13-inch landscape, beside the sidebar |
| `ipadFull`  | 210     | iPad Pro 13-inch landscape, sidebar hidden     |

Every frame is `ROWS` (80) rows tall, more than any captured pane. Painting
one scrolls the surplus history into scrollback, so the omp prompt lands on
the pane's bottom row whatever height the Agent view's chrome leaves the
terminal; a frame shorter than its pane would leave a blank band under the
prompt.

It writes them as Swift string literals to
`Sources/Waycar/Demo/DemoTerminalFrames.swift`, which compiles only into DEBUG
simulator builds alongside `DemoScreenshotMode.swift`. Like a real TUI, the
demo transport paints on attach and again on every resize, choosing the widest
frame that fits the pane's columns.

To change the frames, edit the script, then:

```sh
scripts/demo-terminal/make_omp_frames.py --ans-dir /tmp/omp-frames
cat /tmp/omp-frames/omp-ipadFull.ans   # preview in a 210-column terminal
make screenshots
```

`make screenshots` always reruns this script before capturing, so the
committed script is the single source of the demo terminal, and it copies the
agent, console, hosts and new-agent shots into `apps/web/src/assets/screens/`
for waycar.dev. `make_omp_frames.py --check` fails if the committed Swift
file has drifted from the script; the codegen-drift job in
`.github/workflows/ci-node.yml` runs it.

Never edit the generated Swift file or the PNGs by hand. The script asserts
every row fits its width and that the earlier scrolled-back turns fill each
frame to its top row; add history to `earlier_turns` if the current turn
shrinks or `ROWS` grows. If the terminal font or side chrome changes,
remeasure the columns, and raise `ROWS` if a pane could exceed it: a DEBUG
build logs each pane's `resize AxB->CxD` to `Documents/stream-*.bin` in the
simulator app's data container. That log comes from `TerminalStreamCapture`,
a diagnostic marked for removal; once it is gone, read the size from
`request.cols`/`request.rows` in `DemoScreenshotTransport.attachTerminal`
and from each `.resize` it receives.
