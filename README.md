# networking-fun

An ephemeral-environment Internal Developer Platform (IDP-lite) for AWS networking
labs. A developer opens a PR with a YAML manifest declaring which lab and which fault
scenario; GitHub Actions provisions an isolated VPC, posts a connectivity probe matrix
back as a PR comment, and tears the lab down when the PR closes or a 4-hour TTL
elapses.

This is a **portfolio project** demonstrating platform-engineering, multi-account AWS,
GitOps, and cost engineering. It is also the author's own AWS-networking sandbox.

## Status — under construction

| Milestone | Status |
|---|---|
| **M1** Bootstrap, multi-account org baseline, repo public | ✅ Shipped 2026-05-26 |
| **M2** Lab #1 (Layered Reachability) + IDP loop live | 🚧 In progress, target 2026-06-22 |
| **M3** Lab #2 (Three-Tier Segmentation) + Terratest suite | ⏳ Target 2026-07-06 |

There is no live demo yet. A Loom walkthrough will land with M2.

## Where to read more

- [`PRD.md`](./PRD.md) — product requirements, architecture, lab catalog, roadmap.
- [`docs/account-setup/`](./docs/account-setup/) — the manual AWS bootstrap runbook
  (org, IDC, OIDC, S3 state). Reproducible if you fork.
- [`docs/security/`](./docs/security/) — security audit findings and remediations.
  Live tracker for open hardening work is **GitHub issue #17**.
- [`bootstrap/`](./bootstrap/) — Terraform layer applied manually from an IDC SSO
  session. Creates the S3 state bucket, GitHub OIDC provider, and CI role.

## Architecture (one-paragraph version)

Three layers: `bootstrap/` (manual `terraform apply`, intentionally outside CI),
`platform/` (GitOps via GitHub Actions OIDC on merge to `main`), and `labs/runtime/`
(per-PR, auto-provisioned and auto-destroyed). A blast-radius safety rail fails any
PR whose plan touches bootstrap-owned resources. See PRD §6 for the full table.

## Operating notes

All identifiers in checked-in docs (account IDs, org IDs, OU IDs, SCP IDs, etc.) are
placeholders — real values were redacted from git history before the public flip via
`git-filter-repo`. Fork-and-substitute is supported but not actively marketed.
