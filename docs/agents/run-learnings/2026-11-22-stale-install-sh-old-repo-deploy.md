# 2026-11-22 — waycar.dev served plugin 2.6.0: the retired private repo deployed over main

- **Worked:** reading the Worker's deployments with the Cloudflare API
  (`/workers/scripts/waycar-web/deployments` and `/versions`). Two deploys a
  few seconds apart after each daily schedule pointed to a second deployer.
  `gh run list --workflow web.yml` in the old repository then showed its
  scheduled runs at those exact times, deploying its frozen 2026-11-13
  snapshot. Its versions have no `author_email`, while this repo's show the
  owner's.
- **Worked:** checking a file only the new deploy has. The 2.6.4 tarball
  answered 404 while the 2.6.0 one answered 200, which ruled out a cache
  before any cache theory was tested.
- **Broke:** the old repo's `Web` workflow stayed active after the go-day
  split; only its sweeper and uptime check were disabled. Its daily deploy
  won whenever it finished last: three minutes on 11-20 and 11-21, then from
  20:57 on 11-22 until a rollback at 21:19. No customer package download
  fell inside those windows (PostHog).
- **Broke:** "serves 2.6.4" was true when #255029 checked at 20:14 and false
  at 20:57. A single check after a deploy proves nothing later.
- **Broke:** a manual `web.yml` dispatch was cancelled mid-build through the
  shared GitHub login, by someone outside this run. Dispatch again and
  watch the run to the end.
- **Watch out:** `cf-cache-status: HIT` on a Workers asset is not stale
  content. The rollback showed 2.6.4 within 5 s, still a HIT.
- **Watch out:** release-asset tarballs and the site's tarballs have different
  checksums, since each build stamps new mtimes. Their unpacked trees are
  byte-identical (`bin/waycar` included), so compare contents, not tarball
  hashes.
