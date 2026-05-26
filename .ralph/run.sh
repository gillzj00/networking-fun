#!/usr/bin/env bash
# Ralph Wiggum: a dumb loop that asks Claude to ship one issue, then again, then again.
#
# Usage:
#   ./.ralph/run.sh                          # run until no eligible issues remain (or MAX_ITERS)
#   MAX_ITERS=3 ./.ralph/run.sh              # cap iterations
#   YOLO=1 ./.ralph/run.sh                   # skip permission prompts (true Ralph mode)
#   AWS_PROFILE=networking-fun-dev ./.ralph/run.sh
#
# Stop with Ctrl-C. Each iteration starts a fresh Claude session — no shared
# memory between iterations except what's committed to the repo and GitHub.

set -u
cd "$(dirname "$0")/.."

MAX_ITERS="${MAX_ITERS:-25}"
YOLO="${YOLO:-0}"
LABEL_FILTER="${LABEL_FILTER:-}"
AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_PROFILE

# pipx installs to ~/.local/bin which may not be on PATH in non-login shells.
export PATH="$HOME/.local/bin:$PATH"

CLAUDE_FLAGS=( -p --model claude-opus-4-7 )
if [ "$YOLO" = "1" ]; then
  CLAUDE_FLAGS+=( --dangerously-skip-permissions )
fi

prompt="$(cat .ralph/PROMPT.md)"

require_sso() {
  if ! aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
    echo "AWS session for profile '$AWS_PROFILE' is expired or missing."
    echo "Refresh with:  aws sso login --profile $AWS_PROFILE"
    return 1
  fi
}

# Preflight once before entering the loop so we fail fast.
require_sso || exit 1

for i in $(seq 1 "$MAX_ITERS"); do
  echo "=============================="
  echo "  Ralph iteration $i / $MAX_ITERS  (profile: $AWS_PROFILE)"
  echo "=============================="

  # Re-check creds each iteration in case the session expired mid-run.
  if ! require_sso; then
    echo "Stopping — refresh creds and re-run."
    exit 1
  fi

  # Bail early if there's nothing left to grab.
  if [ -n "$LABEL_FILTER" ]; then
    remaining=$(gh issue list --state open --label "$LABEL_FILTER" --json number --jq 'length')
  else
    remaining=$(gh issue list --state open --json number --jq 'length')
  fi
  if [ "$remaining" -eq 0 ]; then
    echo "No open issues. Ralph goes home."
    exit 0
  fi
  echo "$remaining open issue(s) remaining."

  if ! claude "${CLAUDE_FLAGS[@]}" "$prompt"; then
    echo "Iteration $i failed. Sleeping 10s before retry."
    sleep 10
  fi

  # Tiny gap so a Ctrl-C is easy to land.
  sleep 2
done

echo "Hit MAX_ITERS=$MAX_ITERS. Stopping."
