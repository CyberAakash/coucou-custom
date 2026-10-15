#!/bin/bash
# Brings the official Coucou changes into this fork: upstream/main → main → every feature/* and chore/* branch.
# Merges only (no rebase, no force push). Stops on the first conflict with the merge left in progress.
#   scripts/custom-sync-upstream.sh            sync and push
#   scripts/custom-sync-upstream.sh --no-push  sync locally only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PUSH=1; [ "${1:-}" = "--no-push" ] && PUSH=0

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream https://github.com/Louis-CFM/coucou
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "Working tree has uncommitted changes; commit or stash them first." >&2; exit 1
fi
START="$(git rev-parse --abbrev-ref HEAD)"

git fetch --quiet upstream
git fetch --quiet origin

merge_into() {  # $1 = branch, $2 = what to merge
  git switch --quiet "$1"
  git merge --ff-only --quiet "origin/$1" 2>/dev/null || true
  if git merge-base --is-ancestor "$2" HEAD; then echo "$1: up to date"; return; fi
  if ! git merge --no-edit --quiet "$2"; then
    echo "Conflict merging $2 into $1. Resolve, build both schemes, commit, then re-run." >&2; exit 1
  fi
  echo "$1: merged $2"
  [ "$PUSH" -eq 1 ] && git push --quiet origin "$1"
}

BEHIND="$(git rev-list --count main..upstream/main)"
echo "upstream/main has $BEHIND new commit(s)"
merge_into main upstream/main

for b in $(git for-each-ref --format='%(refname:strip=3)' 'refs/remotes/origin/feature/*' 'refs/remotes/origin/chore/*'); do
  # Branches already merged into main are finished; leave them alone.
  git merge-base --is-ancestor "origin/$b" main && continue
  git show-ref --quiet "refs/heads/$b" || git branch --quiet --track "$b" "origin/$b"
  merge_into "$b" main
done

git switch --quiet "$START"
echo "Done. Rebuild with scripts/custom-install.sh"
