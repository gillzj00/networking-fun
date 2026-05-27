# networking-fun

An ephemeral-environment Internal Developer Platform (IDP-lite) for AWS
networking labs. A developer opens a PR with a YAML manifest declaring which
lab and which fault scenario; GitHub Actions provisions an isolated VPC,
posts a connectivity probe matrix back as a PR comment, and tears the lab
down when the PR closes or a 4-hour TTL elapses.

A **portfolio project** demonstrating platform engineering, multi-account
AWS, GitOps, and cost engineering — and the author's own AWS-networking
sandbox.

## Status

| Milestone | Status |
|---|---|
| **M1** Bootstrap, multi-account org baseline, repo public | ✅ Shipped 2026-05-26 |
| **M2** Lab #1 (Layered Reachability) + IDP loop live | 🚧 Target 2026-06-22 |
| **M3** Lab #2 (Three-Tier Segmentation) + Terratest suite | ⏳ Target 2026-07-06 |

No live demo yet. A Loom walkthrough lands with M2.

## Architecture

Three layers, with deliberately different apply paths so the credential
surface CI itself depends on can't be changed by CI:

| Layer | Apply | Purpose |
|---|---|---|
| [`bootstrap/`](./bootstrap/) | Manual `terraform apply` from an IDC SSO session | S3 state bucket, GitHub OIDC provider, `gha-terraform` CI role. |
| [`platform/`](./platform/) | GitHub Actions via OIDC, merge to `main` | Janitor Lambda, AWS Budgets, Route53 zone, wildcard ACM. |
| [`labs/runtime/`](./labs/) | GitHub Actions per-PR, auto-destroy on close | Per-PR VPC, EC2, probe Lambda for one lab + scenario. |

A blast-radius safety rail fails any `platform/` PR whose plan touches
bootstrap-owned resources. Full table in [PRD §6](./PRD.md#6-architecture--three-layers).

## Repo map

```
bootstrap/         # Layer 1 — manual TF; OIDC, state bucket, CI role
platform/          # Layer 2 — GitOps TF; janitor, budgets, DNS, ACM
labs/
  modules/         #   Lab modules (per-module README has scenario detail)
  runtime/         #   Per-PR root composing one lab + probe module
tests/             # Terratest harness (Go) + janitor unit test (Python)
.platform/         # Manifest schema + example
.github/           # Workflows + scripts (manifest validator, blast-radius)
docs/
  account-setup/   # Manual AWS Org bootstrap runbook (9 phases)
  security/        # Slice 1 audit findings; open work in issue #17
  branch-protection.md
PRD.md             # Full product spec, lab catalog, roadmap
```

All AWS/org identifiers in checked-in docs are placeholders. Real values
were stripped from git history via `git-filter-repo` before the public flip.
