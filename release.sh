#!/usr/bin/env bash
# release.sh — atomic version bump + commit + annotated tag + zip whose
# contents are sourced from the tag (via `git archive`), so the distributed
# archive is byte-for-byte what `git show vX.Y.Z` shows.
#
# Usage: ./release.sh X.Y.Z [--force-branch]
#
# Adding a new runtime file later? Append it to RUNTIME_FILES below.

set -euo pipefail

VERSION="${1:-}"
shift || true

FORCE_BRANCH=0
for arg in "$@"; do
    case "$arg" in
        --force-branch) FORCE_BRANCH=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "usage: $0 X.Y.Z [--force-branch]" >&2
    exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "version must be plain semver X.Y.Z without leading 'v' (got: '$VERSION')" >&2
    exit 2
fi

TAG="v${VERSION}"

cd "$(dirname "$0")"

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "tag ${TAG} already exists" >&2
    exit 2
fi

# Preflight: clean tree, on main unless overridden. We refuse a dirty tree
# so the version-bump commit never accidentally absorbs unrelated work.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "working tree is dirty — commit or stash unrelated changes first" >&2
    exit 2
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" && "$FORCE_BRANCH" -eq 0 ]]; then
    echo "current branch is '${branch}', not 'main'. Pass --force-branch to override." >&2
    exit 2
fi

# Files that ship inside the addon zip. Append here when you add a new
# runtime asset; nothing else in the script should need to change. Anchored
# up here (rather than next to `git archive`) so the cross-check below can
# bail before any destructive operation.
RUNTIME_FILES=(
    DeathReplay.mod
    DeathReplay.lua
    DeathReplay_GUI.xml
    DeathReplay_GUI.lua
    DeathReplay_Indicator.xml
    DeathReplay_Indicator.lua
    skull.tga
)

# Cross-check: every <File name="..."/> in the .mod manifest must also appear
# in RUNTIME_FILES, or the zip will ship without a file the game tries to load.
declare -A _in_runtime=()
for f in "${RUNTIME_FILES[@]}"; do _in_runtime["$f"]=1; done
missing=()
while IFS= read -r f; do
    [[ -n "${_in_runtime[$f]:-}" ]] || missing+=("$f")
done < <(grep -oE '<File name="[^"]+"' DeathReplay.mod | sed -E 's/.*name="([^"]+)"/\1/')
if (( ${#missing[@]} > 0 )); then
    echo "RUNTIME_FILES is missing files declared in DeathReplay.mod <Files>:" >&2
    printf '    %s\n' "${missing[@]}" >&2
    echo "Add them to the RUNTIME_FILES array in release.sh and retry." >&2
    exit 1
fi

# Capture the *current* version from the .mod file (canonical source) so the
# sed patterns don't carry a hardcoded previous version. If this regex ever
# stops matching, we abort loudly rather than silently no-op'ing the bumps.
current_version="$(grep -oE 'name="DeathReplay" version="[0-9]+\.[0-9]+\.[0-9]+"' DeathReplay.mod \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [[ -z "$current_version" ]]; then
    echo "could not locate current version in DeathReplay.mod" >&2
    exit 1
fi

if [[ "$current_version" == "$VERSION" ]]; then
    echo "DeathReplay.mod already at ${VERSION} — nothing to bump" >&2
    exit 2
fi

# Today's date in the M/D/YYYY style the .mod file already uses (no leading zeros).
# Avoid GNU `%-m` which BSD date may not honor; force-decimal via 10# prefix.
mm="$(date +%m)"; dd="$(date +%d)"; yyyy="$(date +%Y)"
today="$((10#$mm))/$((10#$dd))/${yyyy}"

# Escape regex metacharacters in the captured current version (just `.`, really).
esc_re() { printf '%s' "$1" | sed 's/[][\/.*^$]/\\&/g'; }
cur_re="$(esc_re "$current_version")"

# Rollback guard: if anything fails between the first sed and a successful
# `git commit`, restore the original .mod and .lua so the working tree is
# never left half-bumped.
ROLLBACK_NEEDED=0
_rollback_on_exit() {
    if [[ "$ROLLBACK_NEEDED" -eq 1 ]]; then
        echo "release.sh: aborting, reverting sed edits to .mod and .lua" >&2
        git checkout -- DeathReplay.mod DeathReplay.lua 2>/dev/null || true
    fi
}
trap _rollback_on_exit EXIT

ROLLBACK_NEEDED=1

# Three edits, each anchored to its surrounding context so we don't catch
# any incidental occurrences of the old version string elsewhere.
sed -i '' -E "s/(name=\"DeathReplay\" version=\")${cur_re}(\")/\1${VERSION}\2/" DeathReplay.mod
sed -i '' -E "s|(date=\")[0-9]+/[0-9]+/[0-9]+(\")|\1${today}\2|" DeathReplay.mod
sed -i '' -E "s/^(-- DeathReplay v)${cur_re}( —)/\1${VERSION}\2/" DeathReplay.lua
sed -i '' -E "s/(L\"DeathReplay v)${cur_re}( loaded\.\")/\1${VERSION}\2/" DeathReplay.lua

# Each file must show a diff now; if not, a sed pattern drifted and we'd
# release a half-bumped version. Trap will roll back on exit.
for f in DeathReplay.mod DeathReplay.lua; do
    if git diff --quiet -- "$f"; then
        echo "sed produced no change in $f — pattern drifted." >&2
        exit 1
    fi
done

# Belt-and-braces: confirm the new version string is present in all three spots.
grep -q "name=\"DeathReplay\" version=\"${VERSION}\"" DeathReplay.mod \
    || { echo "mod version line missing after bump" >&2; exit 1; }
grep -q "^-- DeathReplay v${VERSION} —" DeathReplay.lua \
    || { echo "lua header missing after bump" >&2; exit 1; }
grep -q "L\"DeathReplay v${VERSION} loaded\\.\"" DeathReplay.lua \
    || { echo "lua chat line missing after bump" >&2; exit 1; }

# Commit only the version-bumped files. Any pre-commit hook (e.g. `bd export`
# sweeping .beads/issues.jsonl) is welcome to add its own files alongside.
git commit -m "DeathReplay v${VERSION}" -- DeathReplay.mod DeathReplay.lua
# Past this point the bump is captured in a commit; no rollback needed.
ROLLBACK_NEEDED=0

git tag -a "${TAG}" -m "DeathReplay v${VERSION}"

ZIP="DeathReplay_v${VERSION}.zip"
rm -f "${ZIP}"
git archive --format=zip --prefix=DeathReplay/ -o "${ZIP}" "${TAG}" -- "${RUNTIME_FILES[@]}"

size="$(du -h "${ZIP}" | awk '{print $1}')"

echo
echo "Built ${ZIP} (${size}) from ${TAG}"
echo
unzip -l "${ZIP}"
echo
echo "Tag and commit are local only. Push when ready:"
echo "    git push --follow-tags"
