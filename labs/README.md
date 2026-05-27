# `labs/` — per-PR lab environments

This layer owns the ephemeral AWS networking labs that a PR provisions when
its branch carries a `.platform/manifest.yaml`. The `platform/` layer must
already be applied — labs consume the OIDC role, state bucket, and janitor
Lambda from the platform layer.

## Layout

```
labs/
├── modules/
│   ├── layered-reachability/      # Lab #1: private VPC + SSM-attached EC2
│   ├── three-tier-segmentation/   # Lab #2: web/app/db chained SGs
│   └── probe/                     # Lambda probe shared by all labs
└── runtime/                       # Per-PR root module (state at labs/<pr>/terraform.tfstate)
```

The `labs/runtime/` root is the only thing the workflows apply. It composes
one lab module and one probe module, parameterised by the manifest.

## Manifest

The schema lives at [`.platform/manifest.schema.json`](../.platform/manifest.schema.json)
and an example is at [`.platform/manifest.yaml.example`](../.platform/manifest.yaml.example).
Drop a real manifest at `.platform/manifest.yaml` on your PR branch:

```yaml
lab: layered-reachability
scenario: happy-path
ttl: 2h
notes: "Smoke test for Lab #1 happy path"
```

The fields:

| field | required | enum | notes |
|---|---|---|---|
| `lab` | yes | `layered-reachability`, `three-tier-segmentation` | Drives module dispatch in `labs/runtime/`. |
| `scenario` | yes | see per-lab whitelist below | Validator rejects scenarios not in the chosen lab's whitelist. |
| `ttl` | no (default `4h`) | `<int><s\|m\|h>` | Capped at 4h. Janitor Lambda destroys on `AutoDelete=<ttl-iso>`. |
| `notes` | no | free text | Rendered in the PR comment. |

Per-lab scenario whitelist (enforced by `.github/scripts/validate-manifest.py`):

| lab | allowed scenarios |
|---|---|
| `layered-reachability` | `happy-path` |
| `three-tier-segmentation` | `happy-path`, `cidr-instead-of-sg`, `nacl-stateless-return`, `missing-chain-link` |

The validator runs in CI before any AWS call. Bad lab, scenario not valid
for the lab, missing field, or `ttl > 4h` all fail the PR before Terraform
is invoked.

## PR lifecycle

| Event | Workflow | Effect |
|---|---|---|
| PR opened / synchronised with manifest present | `lab-provision.yml` | Validates manifest → `terraform apply` → invokes probe → posts sticky PR comment with instance ID, probe matrix, log links, TTL. |
| PR closed (merged or not) | `lab-destroy.yml` | `terraform destroy` → updates sticky comment. |
| `/lab destroy` PR comment | `lab-destroy.yml` | Force-destroy escape hatch. |
| `AutoDelete` tag in the past | `platform-janitor` Lambda | Scanner-only in v1 (slice 5); the destroy path is the follow-up tracked on issue #6. |

Only `@gillzj00` (the actor on the PR or comment) triggers labs. Any other
actor is refused at the guard step.

Replace-on-change (`destroy + provision` when the manifest's `lab` or
`scenario` value changes on the PR branch) is a v1.1 enhancement; v1 ships
with only one valid `lab`/`scenario` value so there is nothing to switch
between. Terraform's normal diff/apply handles `ttl` and `notes` updates.

## Lab catalog

### Lab #1: `layered-reachability` (this slice)

Private-only VPC with one `t4g.nano` Amazon Linux 2023 (arm64) instance,
SSM-attached, reachable through three VPC interface endpoints (`ssm`,
`ssmmessages`, `ec2messages`). VPC Flow Logs to CloudWatch (1-day
retention). No IGW, no NAT — the happy-path lesson is "you don't need
internet to manage instances if you have SSM endpoints."

Probe matrix (happy path expects all pass):

| check | what it tests |
|---|---|
| `dns_ssm_endpoint` | VPC DNS resolves the regional SSM endpoint. |
| `dns_public_hostname` | VPC DNS resolves a public hostname (DNS works without egress). |
| `ssm_api_reachable` | Probe Lambda can call `ssm:DescribeInstanceInformation` through the endpoint. |
| `instance_registered_with_ssm` | Lab instance has checked in (`PingStatus=Online`). |

### Lab #2: `three-tier-segmentation`

Three private subnets — `web`, `app`, `db` — each with one SSM-attached
`t4g.nano`. The three SGs are chained by reference:

- `web-sg` accepts `tcp/443` from `0.0.0.0/0` (simulated ALB ingress).
- `app-sg` accepts `tcp/8080` from `web-sg` (chained).
- `db-sg` accepts `tcp/5432` from `app-sg` (chained).

Every tier SG has egress to the SSM endpoint SG on 443 (so the agent
works) and to every other tier SG on the destination tier's service
port (so failures in the probe matrix never reflect a same-side egress
restriction). All three subnets share one route table; no IGW, no NAT;
three SSM family interface endpoints provide control-plane reachability.

The probe Lambda calls `ssm:SendCommand` against each tier's instance
to run `nc -zv -w 5 <peer-ip> <peer-port>`. The result is a 3×3
connectivity matrix (web/app/db each as source × destination). The PR
comment renders the matrix as a grid, with `*` marking any cell whose
actual result didn't match the per-scenario expectation.

#### Scenarios

| scenario | what it changes | the lesson |
|---|---|---|
| `happy-path` | nothing — baseline | Chained SG references confine traffic to web→app→db. |
| `cidr-instead-of-sg` | `db-sg` allows the VPC CIDR on `5432` instead of `app-sg`. | Reaching for CIDR-based SG rules widens blast radius; web now also reaches db. |
| `nacl-stateless-return` | Custom NACL on the db subnet: ingress allow-all, egress allows 443/5432/8080 but DENIES tcp 32768–60999. | NACLs are stateless: SG approves `app→db:5432` (SYN reaches db), NACL drops the return SYN-ACK to app's ephemeral port. |
| `missing-chain-link` | `app-sg` omits the 8080 ingress rule from `web-sg`. | One missing hop breaks the chain; web can't reach app even though every other piece is right. |

Expected probe matrix (passing cells in **bold**):

| scenario | web→app | web→db | app→web | app→db | db→web | db→app |
|---|---|---|---|---|---|---|
| `happy-path` | **pass** | fail | **pass** | **pass** | **pass** | fail |
| `cidr-instead-of-sg` | **pass** | **pass** | **pass** | **pass** | **pass** | fail |
| `nacl-stateless-return` | **pass** | fail | **pass** | fail | **pass** | fail |
| `missing-chain-link` | fail | fail | **pass** | **pass** | **pass** | fail |

The `app→web` and `db→web` rows pass in every scenario because `web-sg`
allows `tcp/443` from `0.0.0.0/0` — the takeaway is that an overly
broad inbound rule on the web tier swallows what would otherwise be
useful negative signal.

## Running locally

Ralph runs Terraform locally only with `-backend=false` for validation. Live
applies happen in CI via the OIDC role; running `terraform apply` from a
laptop would create real resources without going through the PR lifecycle.

```bash
# Lint + validate
terraform -chdir=labs/runtime fmt -check -recursive
terraform -chdir=labs/runtime init -backend=false
terraform -chdir=labs/runtime validate
tflint --chdir=labs --recursive
checkov --directory labs --framework terraform

# Manifest validator
pip install pyyaml jsonschema
python3 .github/scripts/validate-manifest.py --manifest .platform/manifest.yaml
```

## Prerequisites for live runs

The workflows reuse the slice-3 GitOps plumbing. Before the lab workflows can
do anything in AWS:

1. The bootstrap layer must be re-applied so the OIDC trust policy includes
   the new `environment:lab` subject. The change is in
   `bootstrap/main.tf:124`.
2. A `lab` GitHub environment must exist on the repo. Whether to enable
   required reviewers on it is a per-owner call — leaving it open keeps the
   IDP loop frictionless; requiring a reviewer gates every provision.
3. The `terraform-plan` environment and repo Actions variables
   (`AWS_REGION`, `AWS_ROLE_ARN`, `TFSTATE_BUCKET`) from PR #24 must be in
   place; the lab workflows reuse all three.
