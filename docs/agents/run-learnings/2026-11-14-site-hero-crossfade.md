# 2026-11-14 — Site hero: one slot crossfading the Console and the dictation clip

- **Worked:** two figures in one grid cell with `grid-template-rows: subgrid`
  (picture row, caption row), a CSS keyframe crossfade with the second figure
  at `animation-delay: -6s`, and no script. Captions get their own keyframes
  that reach 0 before the other comes in, so mid-fade text never mixes.
- **Worked:** a preview clip without a screen recorder: a throwaway
  `playwright-core` script outside the repo collects CDP
  `Page.startScreencast` JPEG frames in real time (an animated WebP keeps its
  own pace, so seeking frame by frame would not), then pipes them at a fixed
  frame rate into the ffmpeg Playwright ships
  (`~/.cache/ms-playwright/ffmpeg-*/ffmpeg-linux`: VP8 only, JPEG in through
  `-f image2pipe -c:v mjpeg -i pipe:0`; `-i -` fails with "Protocol not
  found"). Pin the cycle for stills with `document.getAnimations()`,
  `pause()` and `currentTime`.
- **Broke:** a shorthand `animation` on `.slide` after `.talk {
  animation-delay }` in the same block reset the delay: both figures ran in
  step. Put longhands after the shorthand.
- **Broke:** hiding the clip for reduced motion collapsed the Console, whose
  height came from the clip, and let the `auto` stage column shrink so the
  left column widened. Give the Console its own height (`--clip-w` and the
  clip's aspect from the still's metadata) and the stage an explicit width.
- **Watch out:** the hero's `.stage` class also exists in other sections;
  scope page scripts to `.hero .stage`.
