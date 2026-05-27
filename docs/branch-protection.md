# Branch protection on `main`

`main` is protected by GitHub branch protection rules. This file is the
canonical list of required status checks and the exact command used to
apply them — when a workflow's check name changes, update both the
workflow and this file in the same PR.

## Required status checks

GitHub matches required-check contexts against the **job name** of a
workflow run (the `name:` field of the job, not the workflow file name
or job id). The list below is the set of check contexts that must
report green before a PR can merge to `main`.

| Check context | Source workflow | Job |
| --- | --- | --- |
| `Analyze (actions)` | CodeQL | (default CodeQL matrix) |
| `Analyze (go)` | CodeQL | (default CodeQL matrix) |
| `Analyze (python)` | CodeQL | (default CodeQL matrix) |
| `fmt / validate / tflint / checkov` | `platform-pipeline` | `lint` |
| `terraform plan` | `platform-pipeline` | `plan` |
| `terraform apply` | `platform-pipeline` | `apply` |
| `janitor unit test (Python)` | `terratest` | `janitor` |
| `VPC module integration test (Terratest)` | `terratest` | `vpc` |
| `lab1-happy-path` | `terratest` | `scenario` (matrix) |
| `lab1-nacl-deny-egress` | `terratest` | `scenario` (matrix) |
| `lab1-missing-vpc-endpoint` | `terratest` | `scenario` (matrix) |
| `lab1-dns-disabled` | `terratest` | `scenario` (matrix) |
| `lab2-happy-path` | `terratest` | `scenario` (matrix) |
| `lab2-nacl-stateless-return` | `terratest` | `scenario` (matrix) |

### Skipped-as-success contract

Both `platform-pipeline` and `terratest` run on **every** pull request,
not just PRs that touch their respective code paths. Each workflow has
an internal `changes` job (using `dorny/paths-filter`) that gates
downstream jobs. When a PR doesn't touch the relevant paths the
downstream jobs are skipped — GitHub reports them with
`conclusion: skipped`, which satisfies a required-check rule.

This is the mechanism that lets docs-only PRs (and other unrelated
changes) merge cleanly while still requiring the checks to pass on PRs
that do touch the code.

## Other protection rules

The following non-check rules are also enabled on `main`:

- **Require branches to be up to date before merging** (`strict: true`)
  — forces a rebase + re-plan when `main` moves under a PR, which closes
  the stale-plan race between concurrent platform PRs.
- **Require linear history** — squash- or rebase-merge only.
- **Require conversation resolution before merging**.
- **Include administrators** (`enforce_admins: true`) — the rules apply
  to repo admins too.

## Applying the rules

Branch protection is configured out-of-band, not in Terraform. To apply
or update the required-check list, run:

```bash
gh api \
  --method PATCH \
  -H 'Accept: application/vnd.github+json' \
  /repos/gillzj00/networking-fun/branches/main/protection/required_status_checks \
  -f strict=true \
  -f 'contexts[]=Analyze (actions)' \
  -f 'contexts[]=Analyze (go)' \
  -f 'contexts[]=Analyze (python)' \
  -f 'contexts[]=fmt / validate / tflint / checkov' \
  -f 'contexts[]=terraform plan' \
  -f 'contexts[]=terraform apply' \
  -f 'contexts[]=janitor unit test (Python)' \
  -f 'contexts[]=VPC module integration test (Terratest)' \
  -f 'contexts[]=lab1-happy-path' \
  -f 'contexts[]=lab1-nacl-deny-egress' \
  -f 'contexts[]=lab1-missing-vpc-endpoint' \
  -f 'contexts[]=lab1-dns-disabled' \
  -f 'contexts[]=lab2-happy-path' \
  -f 'contexts[]=lab2-nacl-stateless-return'
```

To verify the current state:

```bash
gh api /repos/gillzj00/networking-fun/branches/main/protection \
  --jq '{strict: .required_status_checks.strict,
         contexts: .required_status_checks.contexts,
         enforce_admins: .enforce_admins.enabled,
         linear: .required_linear_history.enabled,
         conversation: .required_conversation_resolution.enabled}'
```

## Acceptance verification

After applying the rules, the following should hold:

1. A PR with a failing `terraform apply` check cannot be merged — the
   GitHub UI shows the required check as the blocker.
2. A PR that is behind `main` cannot be merged until the "Update
   branch" button is clicked.
3. A docs-only PR (touching only `docs/**` or `README.md`) sees every
   `terratest` and `platform-pipeline` check report as `skipped`, and
   the PR is mergeable.
4. The check list above matches the actual config returned by the
   verify command in the previous section.
