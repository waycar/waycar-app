#!/usr/bin/env bash
#
# Cut a release. Driven by `make publish`; see docs/guides/releasing.md.
#
# CHANGELOG.md is the source. Its [Unreleased] section names what ships and
# becomes the release notes verbatim; the cut moves that body into
# apps/web/src/content/changelog/<version>.md, one file per release, whose
# front matter is the record of released versions. Every version string
# elsewhere is derived from the version this script resolves.
#
# Publish mode: local build. The archive is signed with the developer's Apple
# credentials and uploaded to App Store Connect, neither of which exists on a
# CI runner, so a tag-triggered workflow cannot produce the artifact. The
# GitHub release therefore carries the notes and the tag only; the build ships
# through TestFlight.
#
# Options arrive as environment variables because make consumes flags of its
# own (--dry-run is make's -n) and rejects unknown long options, so a flag
# never reaches the recipe.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CHANGELOG="CHANGELOG.md"
RELEASES_DIR="apps/web/src/content/changelog"
PROJECT_YML="project.yml"
XCODEPROJ="Waycar.xcodeproj"
DEFAULT_BRANCH="main"
REMOTE="origin"

VERSION="${VERSION:-}"
DRY_RUN="${DRY_RUN:-}"
YES="${YES:-}"

die() { printf 'publish: %s\n' "$*" >&2; exit 1; }

# Tracks how far we got, so a failure can name the right recovery. Anything
# before `mutating` leaves the working tree untouched.
stage="preflight"
notes_file=""
tag=""
release_file=""
release_commit=""

on_exit() {
    local code=$?
    if [ -n "$notes_file" ]; then rm -f "$notes_file"; fi
    if [ "$code" -eq 0 ]; then return 0; fi
    case "$stage" in
        mutating)
            printf '\npublish: failed before anything was pushed. Undo the local edits (staged or not) with:\n'
            printf '  git restore --source=HEAD --staged --worktree -- %s %s %s\n' "$CHANGELOG" "$PROJECT_YML" "$XCODEPROJ"
            printf '  git rm -q --cached -f %s 2>/dev/null; rm -f %s\n' "$release_file" "$release_file"
            ;;
        committed)
            printf '\npublish: release commit %s is on local %s but untagged, and may not be pushed — do NOT re-run publish.\n' \
                "$release_commit" "$DEFAULT_BRANCH"
            printf 'Retry the push (a no-op if it went through), then tag, release and distribute:\n'
            printf '  git push %s %s\n' "$REMOTE" "$DEFAULT_BRANCH"
            printf '  git rev-parse -q --verify refs/tags/%s >/dev/null || git tag -a %s -m %s %s\n' \
                "$tag" "$tag" "$tag" "$release_commit"
            printf '  git push %s %s\n' "$REMOTE" "$tag"
            printf '  gh release create %s --title %s --notes "<the body of %s, without its front matter>"\n' \
                "$tag" "$tag" "$release_file"
            printf '  scripts/asc-distribute-build.py %s\n' "$next_build"
            ;;
        tagged)
            printf '\npublish: %s is already pushed — do NOT re-run publish.\n' "$tag"
            printf 'Check whether the release exists, and whether it is a draft:\n'
            printf '  gh release view %s --json isDraft,url\n' "$tag"
            printf 'If it is a draft, publish it:\n'
            printf '  gh release edit %s --draft=false\n' "$tag"
            printf 'If there is none, create it against the existing tag:\n'
            printf '  gh release create %s --title %s --notes "<the body of %s, without its front matter>"\n' \
                "$tag" "$tag" "$release_file"
            printf 'then add build %s to Waycar Testers:\n' "$next_build"
            printf '  scripts/asc-distribute-build.py %s\n' "$next_build"
            ;;
        distributing)
            printf '\npublish: %s is released, but build %s did not reach Waycar Testers — do NOT re-run publish.\n' \
                "$tag" "$next_build"
            printf 'Once App Store Connect shows the build, add it with:\n'
            printf '  scripts/asc-distribute-build.py %s\n' "$next_build"
            ;;
    esac
    return 0
}
trap on_exit EXIT

# --- Preflight ---------------------------------------------------------------

for tool in git gh xcodegen xcodebuild awk sed python3 openssl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

# make distribute needs the App Store Connect API key, and make upload uses it
# when present but falls back to the Xcode account silently, so without this
# check a release would ship and only then fail to reach Waycar Testers.
[ -n "${ASC_API_KEY_ID:-}" ] && [ -n "${ASC_API_ISSUER_ID:-}" ] \
    || die "ASC_API_KEY_ID and ASC_API_ISSUER_ID must be set (make distribute needs the App Store Connect API key)"
asc_key="$HOME/.appstoreconnect/private/AuthKey_${ASC_API_KEY_ID}.p8"
[ -f "$asc_key" ] || die "App Store Connect API key not found at $asc_key"

[ -z "$(git status --porcelain)" ] || die "working tree is not clean"

branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "$DEFAULT_BRANCH" ] || die "on branch '$branch', expected '$DEFAULT_BRANCH'"

git rev-parse --verify --quiet "refs/heads/$DEFAULT_BRANCH" >/dev/null || die "no $DEFAULT_BRANCH branch"
git fetch --quiet --tags "$REMOTE"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$REMOTE/$DEFAULT_BRANCH")" ] \
    || die "$DEFAULT_BRANCH differs from $REMOTE/$DEFAULT_BRANCH; pull or push first"

grep -q '^## \[Unreleased\]' "$CHANGELOG" || die "$CHANGELOG has no '## [Unreleased]' heading"

# The cut keeps CHANGELOG.md only up to [Unreleased], so any other section
# (or a second [Unreleased]) would be deleted with it.
headings="$(grep '^## ' "$CHANGELOG" || true)"
[ "$headings" = "## [Unreleased]" ] \
    || die "$CHANGELOG may have one '## ' heading, '## [Unreleased]', but has: $(printf '%s' "$headings" | tr '\n' '|') — released versions belong in $RELEASES_DIR/"

# The [Unreleased] body: everything up to the next '## ' heading.
notes="$(awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
' "$CHANGELOG")"
[ -n "$(printf '%s' "$notes" | tr -d '[:space:]')" ] \
    || die "[Unreleased] is empty — there is nothing to release. Entries belong there as they merge."

# Drop the blank line that follows the heading; $( ) already ate the trailing ones.
notes="$(printf '%s\n' "$notes" | awk 'NF == 0 && !seen { next } { seen = 1; print }')"

# --- Version resolution ------------------------------------------------------

# Released versions are the `version` front matter of the release files, one
# per file, named after it. Prints one version per line.
release_versions() {
    local file found
    for file in "$RELEASES_DIR"/*.md; do
        [ -e "$file" ] || continue
        found="$(awk '
            NR == 1 { if ($0 != "---") exit; next }
            $0 == "---" { exit }
            /^version:/ { sub(/^version:[ \t]*/, ""); print; exit }
        ' "$file")"
        [[ "$found" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || die "$file has no X.Y.Z 'version' in its front matter"
        [ "$file" = "$RELEASES_DIR/$found.md" ] || die "$file says version $found; it must be named $found.md"
        printf '%s\n' "$found"
    done
}

# Compared numerically: 1.10.0 is newer than 1.9.0.
released_versions="$(release_versions)"
released_version="$(printf '%s\n' "$released_versions" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"

# The newest released version and the newest tag must agree: if they disagree
# one of them is lying, and guessing which is how a release gets cut from the
# wrong base.
latest_tag="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -1)"

# The public repository starts from one snapshot commit, and tagging it with
# an old version would point that tag at code that is not that release. Until
# its first release is tagged, scripts/release-baseline names the newest
# version released before the cut and stands in for the tag; it is read only
# while there is no v* tag at all, so afterwards the rule above holds again.
RELEASE_BASELINE="scripts/release-baseline"
if [ -n "$released_version" ] && [ -z "$(git tag --list 'v*')" ] && [ -f "$RELEASE_BASELINE" ]; then
    baseline="$(grep -v '^[[:space:]]*#' "$RELEASE_BASELINE" | tr -d '[:space:]')"
    [[ "$baseline" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$RELEASE_BASELINE has no X.Y.Z version"
    [ "$baseline" = "$released_version" ] \
        || die "$RELEASE_BASELINE says $baseline but the newest release file is $released_version"
    echo "==> No v* tag yet: $RELEASE_BASELINE stands in for v$baseline"
    latest_tag="v$baseline"
fi

if [ -n "$released_version" ] || [ -n "$latest_tag" ]; then
    [ -n "$released_version" ] || die "git has tag $latest_tag but $RELEASES_DIR has no release file"
    [ -n "$latest_tag" ] || die "$RELEASES_DIR has $released_version but there is no matching git tag"
    [ "v$released_version" = "$latest_tag" ] \
        || die "the newest release file ($released_version) disagrees with the newest tag $latest_tag"
fi

if [ -n "$VERSION" ]; then
    version="${VERSION#v}"
    bump_reason="explicit"
elif [ -n "$released_version" ]; then
    IFS=. read -r major minor patch <<<"$released_version"
    version="$major.$minor.$((patch + 1))"
    bump_reason="patch bump from $released_version"
else
    die "no released version to bump from — pass the first version explicitly, e.g. make publish VERSION=0.1.0"
fi

# Prereleases are out of scope for this convention.
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$version' is not X.Y.Z"

release_file="$RELEASES_DIR/$version.md"
[ ! -e "$release_file" ] || die "$release_file already exists"

tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists locally"
fi
# A local-only check passes right up until the push fails, by which time the
# release commit has already landed.
[ -z "$(git ls-remote --tags "$REMOTE" "refs/tags/$tag")" ] || die "tag $tag already exists on $REMOTE"

# --- Version files -----------------------------------------------------------

marketing_lines="$(grep -c '^ *MARKETING_VERSION:' "$PROJECT_YML" || true)"
build_lines="$(grep -c '^ *CURRENT_PROJECT_VERSION:' "$PROJECT_YML" || true)"
[ "$marketing_lines" -gt 0 ] && [ "$marketing_lines" = "$build_lines" ] \
    || die "$PROJECT_YML has $marketing_lines MARKETING_VERSION and $build_lines CURRENT_PROJECT_VERSION entries; they must pair up"

current_marketing="$(awk -F'"' '/^ *MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
current_build="$(awk -F'"' '/^ *CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_YML")"
[[ "$current_build" =~ ^[0-9]+$ ]] || die "CURRENT_PROJECT_VERSION '$current_build' is not an integer"
next_build=$((current_build + 1))

today="$(date +%Y-%m-%d)"

# The demo Host check and the reviewer-device smoke run. Fail before any
# release edits, build or upload; a dry run only lists these checks.
if [ -z "$DRY_RUN" ]; then
    echo "==> Checking the demo Host"
    WAYCAR_REPO="$PWD" "${WAYCAR_OPS_DIR:-$HOME/src/waycar-ops}/scripts/review-host/verify.sh" --release
    # The same for the app: a Release build installed over the last approved
    # release on reviewer-shaped simulators.
    echo "==> Smoke-testing the release on reviewer-shaped simulators"
    make review-smoke
fi

# The release file: front matter, a blank line, then the [Unreleased] body
# (already trimmed of leading and trailing blank lines).
release_file_content() {
    printf -- '---\nversion: %s\ndate: %s\n---\n\n%s\n' "$version" "$today" "$notes"
}

# Moves the [Unreleased] body into the release file and leaves CHANGELOG.md
# as its header and an empty [Unreleased] heading.
cut_changelog() {
    [ ! -e "$release_file" ] || die "$release_file already exists"
    mkdir -p "$RELEASES_DIR"
    release_file_content >"$release_file"
    awk '{ print } /^## \[Unreleased\]/ { exit }' "$CHANGELOG" >"$CHANGELOG.tmp"
    mv "$CHANGELOG.tmp" "$CHANGELOG"
}

# --- Plan --------------------------------------------------------------------

row() { printf '  %-22s %s\n' "$1" "$2"; }

printf '\nPublish %s  (%s)\n\n' "$tag" "$bump_reason"
row "preflight" "${WAYCAR_OPS_DIR:-$HOME/src/waycar-ops}/scripts/review-host/verify.sh --release   (must pass before release edits, build or upload)"
row "preflight" "make review-smoke   (Release build updating the last approved release on review simulators; must pass)"
row "$CHANGELOG" "[Unreleased] body -> $release_file (new, shown below), [Unreleased] left empty"
row "$PROJECT_YML" "MARKETING_VERSION $current_marketing -> $version ($marketing_lines targets, in lockstep)"
row "$PROJECT_YML" "CURRENT_PROJECT_VERSION $current_build -> $next_build (App Store Connect rejects reused build numbers)"
# The backticks are printed for the plan, not executed.
# shellcheck disable=SC2016
row "$XCODEPROJ" 'regenerate via `xcodegen generate`'
echo
row "build" "make archive ADMIN_BUILD=  (Release, signed locally, no admin panel)"
row "upload" "make upload   (App Store Connect / TestFlight)"
row "commit" "chore: release $tag"
row "push" "$REMOTE $DEFAULT_BRANCH"
row "tag" "$tag (annotated) -> $REMOTE"
row "release" "gh release create (notes only; the build ships via TestFlight)"
row "distribute" "make distribute   (wait for processing, add build $next_build to Waycar Testers)"
printf '\n%s (its body is the GitHub release notes):\n' "$release_file"
release_file_content | sed 's/^/  /'
echo

if [ -n "$DRY_RUN" ]; then
    echo "DRY_RUN=1 — nothing was changed."
    exit 0
fi

if [ -z "$YES" ]; then
    [ -e /dev/tty ] || die "no terminal to confirm on; re-run with YES=1 after reviewing DRY_RUN=1"
    printf 'Proceed? [y/N] '
    read -r reply </dev/tty || reply=""
    case "$reply" in
        [yY] | [yY][eE][sS]) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# --- Cut ---------------------------------------------------------------------

stage="mutating"

notes_file="$(mktemp -t waycar-release-notes)"
printf '%s\n' "$notes" >"$notes_file"

cut_changelog

sed -i '' \
    -e "s/^\( *MARKETING_VERSION: \)\".*\"/\1\"$version\"/" \
    -e "s/^\( *CURRENT_PROJECT_VERSION: \)\".*\"/\1\"$next_build\"/" \
    "$PROJECT_YML"
[ "$(grep -c "^ *MARKETING_VERSION: \"$version\"$" "$PROJECT_YML")" = "$marketing_lines" ] \
    || die "MARKETING_VERSION was not rewritten in all $marketing_lines targets"
[ "$(grep -c "^ *CURRENT_PROJECT_VERSION: \"$next_build\"$" "$PROJECT_YML")" = "$build_lines" ] \
    || die "CURRENT_PROJECT_VERSION was not rewritten in all $build_lines targets"

echo "==> Regenerating $XCODEPROJ"
xcodegen generate

echo "==> Building and uploading to TestFlight"
# A release is the build App Review sees: never with the admin panel
# (ADR 0032), whatever ADMIN_BUILD the environment carries.
make archive ADMIN_BUILD=
make upload

# --- Ship --------------------------------------------------------------------

echo "==> Committing and tagging"
git add "$CHANGELOG" "$release_file" "$PROJECT_YML" "$XCODEPROJ"
git commit -m "chore: release $tag"
release_commit="$(git rev-parse --short HEAD)"
stage="committed"

# Straight to the default branch on purpose: the commit is mechanical, was
# reviewed in the plan above, and the tag must point at the exact SHA on that
# branch — a PR merge would change it.
git push "$REMOTE" "$DEFAULT_BRANCH"

# Push the commit first: the tag has to point at a commit reviewers can fetch.
git tag -a "$tag" -m "$tag"
git push "$REMOTE" "$tag"
stage="tagged"

echo "==> Creating the GitHub release"
gh release create "$tag" --title "$tag" --notes-file "$notes_file"

# A pushed tag is not a published release.
gh release view "$tag" --json isDraft,tagName --jq 'select(.isDraft == false) | .tagName' \
    | grep -qx "$tag" || die "gh release view $tag does not show a published release"

stage="done"
printf '\nPublished %s.\n' "$tag"
gh release view "$tag" --json url --jq .url || true

# Last on purpose: it waits for App Store Connect to process the upload (up to
# 45 minutes), and main may move meanwhile, so the release is pushed first. A
# failure here leaves a complete release; on_exit prints the manual command.
stage="distributing"
echo "==> Adding build $next_build to Waycar Testers (waits for App Store Connect processing, up to 45 min)"
make distribute
stage="done"
printf '\nBuild %s is in Waycar Testers.\n' "$next_build"
