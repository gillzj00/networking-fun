#!/usr/bin/env bash
# Manage the sticky "platform/ drift detected" issue.
#
# Usage:
#   drift-issue.sh open  <plan-text-file>   # drift detected; open new or update existing
#   drift-issue.sh close                    # no drift; close any open drift issue
#
# Env:
#   GH_TOKEN  - required, repo scope
#   RUN_URL   - optional, link to the workflow run that produced this output
#
# The script identifies the sticky issue by a hidden HTML marker embedded in
# the body, so multiple drift events collapse into a single open issue.

set -euo pipefail

MARKER='<!-- drift-detect:platform -->'
TITLE_PREFIX='platform/ drift detected'
PLAN_LIMIT=55000

action="${1:-}"
case "$action" in
  open|close) ;;
  *)
    echo "usage: drift-issue.sh open <plan-text-file> | close" >&2
    exit 2
    ;;
esac

repo="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
run_url="${RUN_URL:-}"

find_existing() {
  # Lists open issues whose body contains the marker. Print the first issue
  # number, or empty if none. The --search narrows the candidate set; jq
  # confirms the marker is actually present.
  gh issue list \
    --repo "$repo" \
    --state open \
    --search "$TITLE_PREFIX in:title" \
    --json number,body \
    --jq "[.[] | select(.body | contains(\"$MARKER\"))] | .[0].number // empty"
}

if [[ "$action" == "open" ]]; then
  plan_file="${2:-}"
  if [[ -z "$plan_file" || ! -f "$plan_file" ]]; then
    echo "drift-issue.sh open: plan file '$plan_file' not found" >&2
    exit 2
  fi

  today="$(date -u +%Y-%m-%d)"
  title="$TITLE_PREFIX on $today"

  plan_bytes=$(wc -c < "$plan_file" | tr -d ' ')
  plan_excerpt=$(head -c "$PLAN_LIMIT" "$plan_file")
  truncation_note=""
  if (( plan_bytes > PLAN_LIMIT )); then
    truncation_note=$'\n... (truncated, '"$plan_bytes"$' bytes total — full plan available in workflow logs)'
  fi

  body_file=$(mktemp)
  trap 'rm -f "$body_file"' EXIT
  {
    echo "$MARKER"
    echo
    echo "\`terraform plan\` for \`platform/\` reported drift on $today (UTC)."
    echo
    if [[ -n "$run_url" ]]; then
      echo "_Workflow run: ${run_url}_"
      echo
    fi
    echo "<details>"
    echo "<summary>Plan output (click to expand)</summary>"
    echo
    echo '```hcl'
    printf '%s' "$plan_excerpt"
    if [[ -n "$truncation_note" ]]; then
      printf '%s' "$truncation_note"
    fi
    echo
    echo '```'
    echo "</details>"
    echo
    echo "This issue auto-updates on each drift-detect run. It will be closed automatically when a subsequent run reports no drift."
  } > "$body_file"

  existing=$(find_existing || true)
  if [[ -n "$existing" ]]; then
    echo "updating existing drift issue #$existing"
    gh issue edit "$existing" \
      --repo "$repo" \
      --title "$title" \
      --body-file "$body_file"
  else
    echo "opening new drift issue"
    gh issue create \
      --repo "$repo" \
      --title "$title" \
      --body-file "$body_file"
  fi
  exit 0
fi

# action == close
existing=$(find_existing || true)
if [[ -z "$existing" ]]; then
  echo "no open drift issue; nothing to close"
  exit 0
fi

echo "closing drift issue #$existing — plan is clean"
comment="Drift resolved — latest \`drift-detect\` run reported no changes."
if [[ -n "$run_url" ]]; then
  comment="$comment

_Workflow run: ${run_url}_"
fi
gh issue close "$existing" \
  --repo "$repo" \
  --reason completed \
  --comment "$comment"
