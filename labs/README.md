# `labs/` — per-PR lab environments

Ephemeral container labs provisioned by a PR carrying a
`.platform/manifest.yaml`. The `platform/` layer must already be applied —
labs consume its OIDC role, state bucket, janitor Lambda, and (since
Amendment A1) its static lab VPC, shared ECS cluster, and `hello` ECR image.

## Layout

```
labs/
├── modules/
│   ├── container-lab/             # Per-PR Fargate lab — see module README
│   ├── layered-reachability/      # Lab #1 (VPC era) — reference only
│   ├── three-tier-segmentation/   # Lab #2 (VPC era) — reference only
│   └── probe/                     # Lambda/SSM probe (VPC era) — reference only
└── runtime/                       # Per-PR root module (state at labs/<pr>/terraform.tfstate)
```

The `labs/runtime/` root is the only thing the workflows apply. Since the
container pivot (PRD Amendment A1) it composes exactly one module:
`container-lab`. The VPC-era modules stay in the tree as reference material
but are no longer wired into the loop — a manifest naming them fails
validation.

## Manifest

Schema: [`.platform/manifest.schema.json`](../.platform/manifest.schema.json).
Example: [`.platform/manifest.yaml.example`](../.platform/manifest.yaml.example).

```yaml
lab: hello-fargate
scenario: sg-port-mismatch
ttl: 2h
notes: "Why can't I reach my service?"
```

| field | required | enum | notes |
|---|---|---|---|
| `lab` | yes | `hello-fargate` | Per-PR Fargate service on the shared lab cluster. |
| `scenario` | yes | per-lab whitelist | A fault scenario "passes" when probe results match scenario-specific expectations. |
| `ttl` | no (default `4h`) | `<int><s\|m\|h>` | Capped at 4h. Janitor destroys on `AutoDelete=<ttl-iso>`. |
| `notes` | no | free text | Rendered in the PR comment. |

Scenarios (one deliberate fault each — details in
[`modules/container-lab/`](./modules/container-lab/README.md)):

`happy-path` · `sg-port-mismatch` · `broken-task-execution-role` ·
`bad-image-tag` · `failing-health-check` · `misconfigured-task-definition`

The validator runs in CI before any AWS call — bad lab, mismatched scenario,
missing field, or `ttl > 4h` all fail the PR before Terraform is invoked.

## PR lifecycle

| Event | Workflow | Effect |
|---|---|---|
| PR opened / synchronised with manifest | `lab-provision.yml` | Validate → `terraform apply` → HTTP probe from the runner → sticky PR comment (public endpoint + curl, probe matrix, log links, TTL). |
| PR closed (merged or not) | `lab-destroy.yml` | `terraform destroy` → update sticky comment. |
| `/lab destroy` PR comment | `lab-destroy.yml` | Force-destroy escape hatch. |
| `AutoDelete` tag in the past | `platform-janitor` Lambda | Scanner-only in v1 (slice 5); destroy path tracked on issue #6. |

Only `@gillzj00` (the PR or comment actor) triggers labs — any other actor is
refused at the guard step. While a lab is up, anyone with the PR comment's
endpoint URL can interact with it: the task has a public IP and the security
group admits the app port from anywhere (except when the scenario's fault is
exactly that it doesn't).

## Probe

`.github/scripts/probe-container-lab.py` runs on the workflow runner after
apply. It waits for the per-PR service to converge or definitively fail
(deployment circuit breaker, `UNHEALTHY` task, deadline), curls the task's
public endpoint, and emits a check matrix with per-scenario expectations —
fault scenarios *expect* their checks to fail, and the probe only reports a
mismatch when reality disagrees with the scenario.

## Integration tests

[`tests/`](../tests/README.md) covers the VPC-era modules end-to-end. The
`terratest` schedule has been disabled since the pause (the VpcLimitExceeded
incident); the suite and its fixtures remain valid against the reference
modules. Container-lab test coverage is a follow-up.

## Prerequisites for live runs

Workflows reuse the slice-3 GitOps plumbing:

1. Bootstrap re-applied so the OIDC trust policy includes the
   `environment:lab` subject (see `bootstrap/main.tf`).
2. A `lab` GitHub environment exists on the repo. Required reviewer is
   per-owner judgement — open keeps the IDP loop frictionless, required
   gates every provision.
3. `terraform-plan` environment and Actions variables (`AWS_REGION`,
   `AWS_ROLE_ARN`, `TFSTATE_BUCKET`) from PR #24 in place.
4. `platform/` applied through PR #62 (lab VPC, ECS cluster, ECR image).

## Local validation

Live applies go through CI. For local lint/validate only:

```bash
terraform -chdir=labs/runtime fmt -check -recursive
terraform -chdir=labs/runtime init -backend=false
terraform -chdir=labs/runtime validate
tflint --chdir=labs --recursive
checkov --directory labs --framework terraform

pip install pyyaml jsonschema
python3 .github/scripts/validate-manifest.py --manifest .platform/manifest.yaml
```
