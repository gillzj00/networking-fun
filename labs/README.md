# `labs/` — per-PR lab environments

Ephemeral AWS networking labs provisioned by a PR carrying a
`.platform/manifest.yaml`. The `platform/` layer must already be applied —
labs consume its OIDC role, state bucket, and janitor Lambda.

## Layout

```
labs/
├── modules/
│   ├── layered-reachability/      # Lab #1 — see module README
│   ├── three-tier-segmentation/   # Lab #2 — see module README
│   └── probe/                     # Lambda probe shared by all labs
└── runtime/                       # Per-PR root module (state at labs/<pr>/terraform.tfstate)
```

The `labs/runtime/` root is the only thing the workflows apply. It composes
one lab module and one probe module, parameterised by the manifest.

## Manifest

Schema: [`.platform/manifest.schema.json`](../.platform/manifest.schema.json).
Example: [`.platform/manifest.yaml.example`](../.platform/manifest.yaml.example).

```yaml
lab: layered-reachability
scenario: happy-path
ttl: 2h
notes: "Smoke test for Lab #1 happy path"
```

| field | required | enum | notes |
|---|---|---|---|
| `lab` | yes | `layered-reachability`, `three-tier-segmentation` | Drives module dispatch in `labs/runtime/`. |
| `scenario` | yes | per-lab whitelist | A fault scenario "passes" when probe results match scenario-specific expectations. |
| `ttl` | no (default `4h`) | `<int><s\|m\|h>` | Capped at 4h. Janitor destroys on `AutoDelete=<ttl-iso>`. |
| `notes` | no | free text | Rendered in the PR comment. |

Scenario whitelist enforced by `.github/scripts/validate-manifest.py`:

| lab | scenarios |
|---|---|
| `layered-reachability` | `happy-path`, `nacl-deny-egress`, `missing-vpc-endpoint`, `dns-disabled` |
| `three-tier-segmentation` | `happy-path`, `cidr-instead-of-sg`, `nacl-stateless-return`, `missing-chain-link` |

The validator runs in CI before any AWS call — bad lab, mismatched scenario,
missing field, or `ttl > 4h` all fail the PR before Terraform is invoked.

## PR lifecycle

| Event | Workflow | Effect |
|---|---|---|
| PR opened / synchronised with manifest | `lab-provision.yml` | Validate → `terraform apply` → probe → sticky PR comment (instance IDs, probe matrix, log links, TTL). |
| PR closed (merged or not) | `lab-destroy.yml` | `terraform destroy` → update sticky comment. |
| `/lab destroy` PR comment | `lab-destroy.yml` | Force-destroy escape hatch. |
| `AutoDelete` tag in the past | `platform-janitor` Lambda | Scanner-only in v1 (slice 5); destroy path tracked on issue #6. |

Only `@gillzj00` (the PR or comment actor) triggers labs — any other actor is
refused at the guard step. Replace-on-change for `lab`/`scenario` edits on a
branch is a v1.1 enhancement; `ttl` and `notes` updates use the normal
Terraform diff/apply.

## Lab catalog

| Lab | Module README | Topology | Scenarios |
|---|---|---|---|
| **#1 Layered Reachability** | [`modules/layered-reachability/`](./modules/layered-reachability/README.md) | 1× t4g.nano in a private subnet, SSM via 3 interface endpoints. | happy-path · nacl-deny-egress · missing-vpc-endpoint · dns-disabled |
| **#2 Three-Tier Segmentation** | [`modules/three-tier-segmentation/`](./modules/three-tier-segmentation/README.md) | 3× t4g.nano (web/app/db), SGs chained by reference. 3×3 probe matrix. | happy-path · cidr-instead-of-sg · nacl-stateless-return · missing-chain-link |

## Integration tests

[`tests/`](../tests/README.md) covers both modules end-to-end:

| Test | Asserts | Cost | Runtime |
|---|---|---|---|
| `tests/vpc/` | `layered-reachability` static shape (no IGW, 3 endpoints, instance state). | ~$0.01 | ~5 min |
| `tests/lab1/` | Lab #1 happy-path + `nacl-deny-egress` matrices. | ~$0.04 | ~20 min |
| `tests/lab2/` | Lab #2 happy-path + `nacl-stateless-return` 3×3 matrices. | ~$0.06 | ~20 min |

All test resources are tagged `Workload=terratest` ($5 budget) and
`AutoDelete=<now+1h>` (janitor-swept on failure).

## Prerequisites for live runs

Workflows reuse the slice-3 GitOps plumbing:

1. Bootstrap re-applied so the OIDC trust policy includes the
   `environment:lab` subject (see `bootstrap/main.tf`).
2. A `lab` GitHub environment exists on the repo. Required reviewer is
   per-owner judgement — open keeps the IDP loop frictionless, required
   gates every provision.
3. `terraform-plan` environment and Actions variables (`AWS_REGION`,
   `AWS_ROLE_ARN`, `TFSTATE_BUCKET`) from PR #24 in place.

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
