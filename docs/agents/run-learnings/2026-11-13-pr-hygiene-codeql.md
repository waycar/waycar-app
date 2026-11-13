# 2026-11-13 — PR hygiene for outside contributors: lint, CodeQL, Dependabot

- **Worked:** a draft PR from the branch ran every hardened workflow before landing, so the permission, SHA pin and `persist-credentials` changes were proven on GitHub, not only by actionlint and zizmor.
- **Broke:** CodeQL cannot scan the app's Swift. Its Swift extractor traces the build, and on the `xcode-27` runner the tracer fails with `posix_spawn … Bad CPU type in executable` while SwiftPM loads manifests. GitHub says Xcode 27 / Swift 6.4 is unsupported until a new extractor ships (github/codeql#22742). Xcode 26 cannot build the iOS 27 SDK project, so no workaround exists; #3 tracks it.
- **Watch out:** a workflow change runs every workflow whose path filter names its own file. One PR that touches all of them queues every macOS job at once (ci.yml's three plus any new one), and the org's Free plan allows five.
- **Watch out:** the plugin-version guard only reads tags from the public origin, so its checkouts need no persisted credentials. A zizmor `artipacked` finding there is fixed with `persist-credentials: false`, not an ignore.
