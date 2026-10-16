#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 [--dry-run|-n] "commit message"

This script always prefixes the commit message with a timestamp in the format
  [YYYY-MM-DD HH:MM:SS]
If no commit message is provided, defaults to "[YYYY-MM-DD HH:MM:SS] work_backup".
If there are unstaged changes, they will be staged and committed. If no changes,
an empty commit will be created.

Before pushing, the script rewrites the current branch history so that only
commits created today remain. Commits from prior dates are discarded, and the
push is forced.
EOF
}

rewrite_branch_history() {
  local branch="$1"
  local temp_branch="history-reset-${branch//\//-}-$$"
  local today_start
  local first_commit
  local first_message
  local commit
  local today_commits=()
  local merge_commits=()

  today_start="$(date '+%Y-%m-%d 00:00:00')"

  while IFS= read -r commit; do
    if [ -n "$commit" ]; then
      today_commits+=("$commit")
    fi
  done < <(git rev-list --first-parent --reverse --since="$today_start" "$branch")

  while IFS= read -r commit; do
    if [ -n "$commit" ]; then
      merge_commits+=("$commit")
    fi
  done < <(git rev-list --first-parent --min-parents=2 --since="$today_start" "$branch")

  # Filter out empty commits (commits that change no files) from today's list
  filtered_commits=()
  for commit in "${today_commits[@]:-}"; do
    if [ -n "$(git show --pretty=format: --name-only "$commit")" ]; then
      filtered_commits+=("$commit")
    else
      echo "(rewrite) skipping empty commit $commit" >&2
    fi
  done
  today_commits=("${filtered_commits[@]:-}")

  if [ "${#today_commits[@]}" -eq 0 ]; then
    echo "No non-empty commits found for today; skipping history rewrite." >&2
    return 0
  fi

  if [ "${#merge_commits[@]}" -gt 0 ]; then
    echo "Error: today's history contains merge commits. Automatic pruning only supports linear history." >&2
    exit 1
  fi

  echo "Rewriting branch history to keep only today's ${#today_commits[@]} commit(s)..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: git checkout --orphan $temp_branch"
    echo "DRY RUN: git rm -rf ."
    echo "DRY RUN: git checkout ${today_commits[0]} -- ."
    echo "DRY RUN: git commit --allow-empty -m \"$(git log -1 --format=%s "${today_commits[0]}")\""
    if [ "${#today_commits[@]}" -gt 1 ]; then
      echo "DRY RUN: git cherry-pick ${today_commits[*]:1}"
    fi
    echo "DRY RUN: git branch -M $branch"
    return 0
  fi

  first_commit="${today_commits[0]}"
  first_message="$(git log -1 --format=%B "$first_commit")"

  git checkout --orphan "$temp_branch"
  git rm -rf . >/dev/null 2>&1 || true
  git checkout "$first_commit" -- .
  git add -A
  git commit --allow-empty -m "$first_message"
  if [ "${#today_commits[@]}" -gt 1 ]; then
    git cherry-pick "${today_commits[@]:1}"
  fi
  git branch -M "$branch"
}

DRY_RUN=0
if [ "$#" -ge 1 ]; then
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

TS="$(date '+%Y-%m-%d %H:%M:%S')"
if [ "$#" -ge 1 ]; then
  # Join all remaining args into the message (preserves embedded newlines when quoted)
  MSG_CONTENT="$*"
else
  MSG_CONTENT="work_backup"
fi
# Always prefix the message with a timestamp
MSG="[$TS] $MSG_CONTENT"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: not a git repository (or no .git directory found)" >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [ "$BRANCH" = "HEAD" ]; then
  echo "Error: detached HEAD. Please checkout a branch before running this script." >&2
  exit 1
fi

UPSTREAM_REMOTE="origin"
UPSTREAM_BRANCH="$BRANCH"
if UPSTREAM_REF="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)"; then
  UPSTREAM_REMOTE="${UPSTREAM_REF%%/*}"
  UPSTREAM_BRANCH="${UPSTREAM_REF#*/}"
fi

echo "Branch: $BRANCH"
echo "Commit message:"
echo "$MSG"

PORCELAIN="$(git status --porcelain)"
if [ -n "$PORCELAIN" ]; then
  echo "Staging changes..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: git add -A"
  else
    git add -A
  fi
  echo "Committing..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: git commit -m \"$MSG\""
  else
    git commit -m "$MSG"
  fi
else
  echo "No changes to commit. Skipping commit creation." 
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: (would skip creating empty commit)"
  fi
fi

rewrite_branch_history "$BRANCH"

echo "Pushing to remote..."
if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: git push --force --set-upstream $UPSTREAM_REMOTE $BRANCH:$UPSTREAM_BRANCH"
  exit 0
fi

git push --force --set-upstream "$UPSTREAM_REMOTE" "$BRANCH:$UPSTREAM_BRANCH"

echo "Push complete."
