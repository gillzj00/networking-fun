# networking-fun — Product Requirements Document

**Status:** Draft v1 — **M1 shipped 2026-05-26 (repo public)**
**Last updated:** 2026-05-26
**Owner:** @gillzj00
**Target ship (v1):** 2026-07-06 (6 weeks)

---

## 1. Overview

`networking-fun` is an **Internal Developer Platform (IDP) lite** for ephemeral AWS networking labs. A developer opens a GitHub PR containing a small YAML manifest declaring which lab and which fault scenario they want. GitHub Actions provisions an isolated VPC-based environment via Terraform, posts the SSM-able instance IDs and a connectivity probe matrix back as a PR comment, and tears the environment down when the PR closes (or after a 4-hour TTL — whichever comes first).

Each lab is a teaching artifact: a deliberately misconfigured (or correctly configured) AWS network topology that the user can poke at to understand a specific networking concept.

The repo is simultaneously:
- A **portfolio piece** demonstrating platform engineering, IaC, multi-account AWS, CI/CD, and cost engineering competence.
- A **personal learning sandbox** for AWS networking.

## 2. Audience & role targeting

**Primary audience:** hiring managers for **platform engineer** roles.
**Secondary audience:** hiring managers for **DevOps engineer** roles.

Design tradeoffs are resolved in favor of platform-engineering signal first (manifest DX, GitOps, ephemeral env primitives), DevOps signal second (IaC quality, CI/CD pipeline, cost guardrails), and networking depth third (the labs themselves).

## 3. Primary surface

The artifact a hiring manager interacts with is, in priority order:

1. **A 3–5 minute Loom walkthrough** embedded in the README. The Loom shows: editing `.platform/manifest.yaml`, opening a PR, the bot posting the env details, SSM'ing in, observing the fault scenario, closing the PR, watching it disappear.
2. **A polished public README** with architecture diagrams, design decisions, and a roadmap.
3. **A forkable repo** that *could* be run by someone else, but the "run it yourself" path is not actively marketed.

## 4. Goals (v1)

- **G1.** Two working labs (`layered-reachability`, `three-tier-segmentation`), each with at least 3 fault scenarios.
- **G2.** PR-driven provision and destroy flow, end-to-end automated, no manual steps after `git push`.
- **G3.** Cost ceiling: ≤ $25/mo AWS spend during active development. Enforced by AWS Budgets alarm + a 4-hour TTL janitor Lambda.
- **G4.** GitOps for the platform itself: changes to `platform/` are applied via GitHub Actions OIDC on merge to `main`.
- **G5.** Integration test coverage via Terratest: VPC module, both labs' happy paths, both labs' canonical fault scenarios, janitor Lambda.
- **G6.** Repo flippable to public at M1 without security or quality embarrassment.

## 5. Non-goals (v1)

Explicitly deferred to v2 or never:

1. Multi-user / RBAC. Only `@gillzj00` triggers labs.
2. Multi-tenancy / multi-account at the lab layer. Single `networking-fun-dev` sub-account hosts all envs.
3. Multi-region. `us-east-2` only.
4. Production-grade reliability. No SLOs, on-call, or incident runbooks.
5. EKS / Kubernetes. *Planned* as the headline v2 lab (K8s Pod Networking — VPC CNI, IRSA, NetworkPolicy, Karpenter).
6. Vanity URLs per env. Pattern is `pr-<num>.labs.gillzhub.com`.
7. Bulletproof forkability. The Loom mentions forking is possible; bootstrap docs assume the operator is the owner.
8. Cross-cloud. AWS-only.
9. Long-running labs. Only bootstrap state bucket, OIDC provider, janitor Lambda, and Route53 zone run 24/7.
10. Real workloads inside labs. Labs are reachability demos; no application logic deployed.
11. Advanced networking (Transit Gateway, PrivateLink, Direct Connect, BGP). VPC primitives only in v1; these become v2 lab candidates.

## 6. Architecture — three layers

| Layer | Contents | Apply method | State |
|---|---|---|---|
| **`bootstrap/`** | S3 state bucket (native locking, Terraform 1.10+), OIDC provider, GH Actions IAM role, base tagging policy | Manual `terraform apply` from IDC SSO session. Documented as "intentionally manual" in README. | `s3://<bucket>/bootstrap/terraform.tfstate` |
| **`platform/`** | Janitor Lambda, Route53 delegated zone for `labs.gillzhub.com`, wildcard ACM cert, AWS Budgets + alarms, CloudWatch log retention, IAM roles consumed by labs, lab module registry | GitHub Actions via OIDC on merge to `main`. `terraform plan` runs on PR open and posts to PR. | `s3://<bucket>/platform/terraform.tfstate` |
| **`labs/runtime/`** | Per-PR VPC, EC2 (t4g.nano Graviton), Lambda probes, VPC Flow Logs, lab-specific SGs/NACLs | GitHub Actions via OIDC on PR open / manifest-change / PR close. | `s3://<bucket>/labs/<pr-number>/terraform.tfstate` |

### Blast-radius safety rail

The `platform/` GitHub Action runs `terraform plan -detailed-exitcode` and **fails the PR** if the plan touches:
- The S3 state bucket
- The OIDC provider
- The GitHub Actions IAM role itself

These changes are forced back through the manual `bootstrap/` flow.

### Escape hatch

- `bootstrap/`: always applicable manually.
- `platform/`: GitOps is the normal path; the IDC SSO role retains permission to apply manually in emergencies, but doing so is treated as an incident and noted in the README.
- `labs/runtime/`: managed by PR lifecycle only; manual destroy via `/lab destroy` PR comment (escape hatch).

## 7. Manifest

**Location:** `.platform/manifest.yaml` at the repo root of the PR branch.
**Format:** YAML.

### Schema (v1)

```yaml
lab: three-tier-segmentation       # required; one of: layered-reachability, three-tier-segmentation
scenario: nacl-stateless-return    # required; must be a valid scenario for the chosen lab
ttl: 2h                            # optional; default 4h, max 4h
notes: "Testing #142 hypothesis"   # optional; free-text shown in PR comment
```

The schema is **designed as if** a future `modules: [...]` array could be added (module registry pattern), but v1 ships with the lab-preset form only. CI validates the manifest with a JSON Schema check before any AWS calls.

## 8. PR lifecycle

| Event | Action |
|---|---|
| PR opened, `.platform/manifest.yaml` present | Provision lab env |
| PR closed or merged | Destroy lab env |
| Push to PR branch, manifest changed | Destroy + provision (replace-on-change) |
| Push to PR branch, manifest unchanged | No-op |
| TTL exceeded (≤ 4h) | Janitor destroys env |
| Comment `/lab destroy` | Force destroy (escape hatch) |

The PR comment bot posts:
- Env status (provisioning / ready / destroyed)
- SSM-able instance IDs
- Probe results matrix (source → destination → pass/fail)
- Links to VPC Flow Logs and Lambda probe log groups
- Teardown ETA (TTL countdown)

## 9. Lab catalog (v1)

### Lab #1: Layered Reachability

**Concept:** Build up a VPC layer by layer (subnet, route table, IGW, SG, NACL, VPC endpoint, VPC DNS); break each layer in turn and observe how reachability changes.

**Fault scenarios (≥3 required):**
- `happy-path` — everything works, baseline.
- `nacl-deny-egress` — NACL on the private subnet denies all outbound; probe to AWS endpoints fails.
- `missing-vpc-endpoint` — SSM VPC endpoint removed; instance becomes unreachable via SSM.
- `dns-disabled` — VPC DNS resolution off; name resolution fails inside instances.

**Compute:** 1× t4g.nano private EC2 (SSM-attached), 1× Lambda probe.

### Lab #2: Three-Tier Segmentation

**Concept:** Canonical web/app/db three-tier architecture with SG chaining by reference (not CIDR). Probe matrix asserts only the intended hops work.

**Fault scenarios (≥3 required):**
- `happy-path` — SG-to-SG references throughout; web→app→db works, no other paths.
- `cidr-instead-of-sg` — db SG allows `10.0.0.0/16` instead of app-SG reference. Probes pass; talking point about operational blast radius.
- `nacl-stateless-return` — db subnet NACL blocks ephemeral return ports. SG (stateful) says yes; NACL (stateless) drops return. Canonical AWS gotcha.
- `missing-chain-link` — app SG forgets to allow from web SG. Probes fail one hop in.
- `overly-permissive` — db SG allows `0.0.0.0/0:5432`. Probes pass; talking point about least privilege.

**Compute:** 3× t4g.nano (web/app/db), 1× Lambda probe.

## 10. Observability

**v1 scope:**
- **VPC Flow Logs** → CloudWatch Logs, per-lab log group, 1-day retention.
- **Lambda probe** logs structured JSON to CloudWatch, 1-day retention.
- **PR comment** includes inline probe matrix + clickable links to Flow Logs and probe log group.

**Deferred to v1.1:**
- Cost-by-lab CloudWatch Dashboard (single panel).

**Deferred to v2:**
- Managed Grafana + AMP (would be the headline change if SRE flavor is added later).

## 11. Cost guardrails

- **AWS Budgets:** $25/mo alarm threshold → email to `OwnerEmail`.
- **TTL janitor:** Lambda scheduled every 15 min; destroys any resource whose `AutoDelete=<ISO timestamp>` tag is in the past.
- **Terratest budget watcher:** alarm if monthly Terratest-driven spend > $5.
- **Default region:** us-east-2 (~10% cheaper than us-east-1, full service catalog).
- **Default instance type:** t4g.nano Graviton (~$0.0042/hr).
- **Tagging:** all resources tagged `Project=networking-fun`, `ManagedBy=terraform`, `Env=<platform|lab-pr-N>`, `OwnerEmail`, `AutoDelete`.

## 12. Testing strategy

**Terratest suite (v1):**
1. VPC module — apply, assert subnets/RT/IGW exist, destroy. (~5 min)
2. Lab #1 happy-path — provision, probe asserts reachability matrix, destroy. (~10 min)
3. Lab #1 fault scenario (`nacl-deny-egress`) — assert expected drops occur. (~10 min)
4. Lab #2 happy-path. (~10 min)
5. Lab #2 fault scenario (`nacl-stateless-return`) — assert stateful/stateless gotcha. (~10 min)
6. Janitor Lambda — unit test with mocked AWS clients, assert expired-tag detection + destroy call. (~30s)

**Triggers:** nightly cron + on PRs touching `modules/**`, `labs/**`, or `platform/janitor/**`. Skipped on docs-only PRs.

**Other CI checks (all PRs):**
- `terraform fmt -check`
- `tflint`
- `checkov` (security scan)
- Manifest JSON Schema validation (when manifest changes)
- `terraform plan` posted as PR comment (platform/ layer only)
- Pre-commit hooks enforce the above locally

## 13. Timeline & milestones

Assumes ~10–15 hrs/week, soft deadline 6 weeks from 2026-05-25.

| Milestone | Target date | Deliverables | Public-flip? |
|---|---|---|---|
| **M1: Bootstrap done** | **SHIPPED 2026-05-26** (target was 2026-06-08) | Org, sub-account, IDC, OIDC, S3 state, baseline SCP + tag policy, CloudTrail org-trail, Budget, security audit + M1-blocker remediation. Branch protection on `main`. `production` GitHub environment locked to required reviewer + main-only deploy. Trunk-on-main. **DNS delegation, ACM, and janitor Lambda are tracked as separate M1-tagged issues (#5, #6) and remain open.** | **Yes — flipped 2026-05-26** |
| **M2: Lab #1 + IDP loop live** | 2026-06-22 | Manifest schema + validator. PR-driven provision/destroy. Lab #1 with ≥3 scenarios. PR comment bot. Loom v1 recorded. | Already public |
| **M3: v1 complete** | 2026-07-06 | Lab #2 with ≥3 scenarios. Terratest suite green. Loom re-recorded with both labs. All G1–G6 satisfied. | Already public |

## 14. Public-flip checklist (gate for M1)

Marks reflect actual state after 2026-05-26 flip.

**Security:**
- [x] No AWS account IDs hardcoded — `git-filter-repo` rewrote history to placeholders pre-flip; `bootstrap/main.tf` backend config injected via gitignored `backend.hcl` (F-12).
- [x] No personal email beyond `OwnerEmail` tag (variable, defaulted to `zachary.gill@hotmail.com`).
- [x] `.gitignore` covers `*.tfstate`, `*.tfvars`, `backend.hcl`, `bootstrap-outputs.json`, `replacements.txt`.
- [x] Manual scan clean on full history (no AWS keys / GH tokens / private keys / sensitive AWS IDs). `gitleaks` not run.
- [x] Branch protection on `main`: PR required, linear history, no force-push, no deletions, conversation resolution required. `enforce_admins=false` (owner can bypass).
- [x] No long-lived AWS keys in GH secrets; OIDC role ARN only (`gha-terraform`, sub-claim restricted to `ref:refs/heads/main` + `environment:production` per F-01).

**Quality:**
- [x] README: brief overview + status + links to PRD / runbook / audit. **Full pitch + architecture diagram + roadmap still pending (Loom-driven, M2 deliverable).**
- [ ] LICENSE (MIT). **Open.**
- [x] Commit messages reviewed; no junk/WIP.
- [ ] Repo description, topics, homepage URL set. **Open.**
- [x] Default branch `main`; `develop` removed.
- [ ] Status badges in README (GH Actions, license). **Deferred — no workflows defined yet (M2).**

**Posture:**
- [ ] CONTRIBUTING.md (short — "portfolio project, PRs welcome but not the goal"). **Open.**
- [ ] CODEOWNERS with `@gillzj00`. **Open — `production` environment required-reviewer already enforces `@gillzj00`.**
- [ ] Issue templates off or minimal. **Default templates, not customized.**

## 15. Roadmap (post-v1)

**v1.1 (polish):**
- Cost-by-lab CloudWatch Dashboard.
- Drift detection (scheduled `terraform plan` on platform infra).
- Tagging policy enforced via SCP.
- Cross-AZ failover lab (Lab #3 candidate).

**v2 (depth):**
- **K8s Pod Networking Lab** — EKS, VPC CNI, IRSA, NetworkPolicy with Cilium, Karpenter. Headline v2 feature.
- Transit Gateway lab (hub-and-spoke).
- VPC endpoint gateway vs. interface lab.
- Managed Grafana + AMP migration writeup.
- Multi-account "ring 2" isolation per lab.

## 16. Open risks

- **R1.** EKS deferral may disappoint cloud-network-engineer-flavored interviewers. Mitigation: explicit v2 callout in README.
- **R2.** Terratest costs could exceed budget if test suite is run too aggressively. Mitigation: $5 alarm + path-filtered triggers.
- **R3.** GitOps-on-platform layer introduces chicken-and-egg complexity. Mitigation: "Why bootstrap is manual" README section turns it into a teaching moment.
- **R4.** 6-week timeline assumes ~10–15 hrs/week; competing demands (job search, current role) could slip M3. Mitigation: M2 is the "resume-able" milestone, not M3.
