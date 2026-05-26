#!/usr/bin/env bash
# Fails when a terraform plan for the platform/ layer attempts to modify any
# resource that belongs to bootstrap/ (the S3 state bucket, the GitHub OIDC
# provider, or the gha-terraform role). Those resources can only be changed
# by re-running bootstrap/ manually from a privileged IDC session.
#
# Usage: blast-radius-check.sh <path-to-terraform-show-json-output>

set -euo pipefail

PLAN_JSON="${1:-tfplan.json}"

if [[ ! -f "$PLAN_JSON" ]]; then
  echo "blast-radius-check: $PLAN_JSON not found" >&2
  exit 2
fi

violations=$(jq -r '
  .resource_changes // []
  | .[]
  | select(
      ((.change.actions // []) | any(. != "no-op" and . != "read"))
      and
      (
        (
          .type == "aws_s3_bucket"
          and ((.change.after.bucket // .change.before.bucket // "") | startswith("tfstate-networking-fun-"))
        )
        or
        (
          (.type | startswith("aws_s3_bucket_"))
          and ((.change.after.bucket // .change.before.bucket // "") | startswith("tfstate-networking-fun-"))
        )
        or
        (
          .type == "aws_iam_openid_connect_provider"
          and ((.change.after.url // .change.before.url // "") | contains("token.actions.githubusercontent.com"))
        )
        or
        (
          .type == "aws_iam_role"
          and ((.change.after.name // .change.before.name // "") == "gha-terraform")
        )
        or
        (
          ((.type == "aws_iam_role_policy_attachment") or (.type == "aws_iam_role_policy"))
          and ((.change.after.role // .change.before.role // "") == "gha-terraform")
        )
      )
    )
  | "  - \(.address) [\(.type)] actions=\((.change.actions // []) | join(","))"
' "$PLAN_JSON")

if [[ -n "$violations" ]]; then
  cat >&2 <<EOF
BLAST-RADIUS CHECK FAILED

The plan would modify resources owned by bootstrap/:
$violations

These resources can only be changed by re-running bootstrap/ manually
from a privileged IDC session. See platform/README.md for the safety
rail rationale.
EOF
  exit 1
fi

echo "blast-radius-check: ok"
