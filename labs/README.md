# `labs/` — per-PR lab environments

This layer owns the ephemeral AWS networking labs that a PR provisions when
its branch carries a `.platform/manifest.yaml`. The `platform/` layer must
already be applied — labs consume the OIDC role, state bucket, and janitor
Lambda from the platform layer.

## Layout

```
labs/
├── modules/
│   ├── layered-reachability/   # Lab #1: private VPC + SSM-attached EC2
│   └── probe/                  # Lambda probe shared by all labs
└── runtime/                    # Per-PR root module (state at labs/<pr>/terraform.tfstate)
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

| field | required | enum (v1) | notes |
|---|---|---|---|
| `lab` | yes | `layered-reachability` | Slice 11 adds `three-tier-segmentation`. |
| `scenario` | yes | `happy-path`, `nacl-deny-egress`, `missing-vpc-endpoint`, `dns-disabled` | One baseline + three fault scenarios. The probe matrix is the success criterion: a fault scenario "passes" when each check matches its scenario-specific expectation. |
| `ttl` | no (default `4h`) | `<int><s\|m\|h>` | Capped at 4h. Janitor Lambda destroys on `AutoDelete=<ttl-iso>`. |
| `notes` | no | free text | Rendered in the PR comment. |

The validator (`.github/scripts/validate-manifest.py`) runs in CI before any
AWS call. Bad lab, bad scenario, missing field, or `ttl > 4h` fail the PR
before Terraform is invoked.

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

#### Scenarios

The same four probes run for every scenario; the `expected` column in the
PR-comment matrix flips per scenario, so a fault scenario "passes" when
each check's actual result matches its scenario-specific expectation. A
`*` next to the probe name marks rows where actual disagreed with
expected.

##### `happy-path`

The baseline: every layer works. SSM endpoints are in place, the default
NACL allows everything, VPC DNS is on. The instance registers with SSM
within ~90 s; all four probes pass. **Lesson:** a private subnet can
manage instances over SSM without any internet egress, as long as DNS,
endpoints, SGs, and NACLs all cooperate.

| check | expected |
|---|---|
| `dns_ssm_endpoint` | pass |
| `dns_public_hostname` | pass |
| `ssm_api_reachable` | pass |
| `instance_registered_with_ssm` | pass |

##### `nacl-deny-egress`

Adds a custom Network ACL on the private subnet that allows everything
inbound but denies everything outbound. The instance and probe SGs
(stateful) still authorize egress to the SSM endpoint SG, but NACLs
(stateless) evaluate every packet independently and drop outbound
traffic regardless. The VPC DNS resolver sits inside the subnet, so name
resolution still works; anything that has to leave the subnet over
TCP/443 fails. **Lesson:** NACLs are stateless and operate independently
of security groups. An SG rule that "allows" a session is not enough
when a NACL drops the matching outbound or return packet.

| check | expected | why |
|---|---|---|
| `dns_ssm_endpoint` | pass | VPC resolver is intra-subnet, NACL doesn't see it |
| `dns_public_hostname` | pass | same |
| `ssm_api_reachable` | fail | TCP/443 to the endpoint ENI is dropped at the subnet boundary |
| `instance_registered_with_ssm` | fail | SSM agent can't reach the control plane |

##### `missing-vpc-endpoint`

Drops the `ssm` interface endpoint (the control plane one); the
`ssmmessages` and `ec2messages` endpoints stay so the failure is pinned
to a single missing piece. The regional SSM hostname falls through to
public DNS — it resolves to a public IP — but the private subnet has no
IGW or NAT, so nothing can route to it. **Lesson:** SSM needs all three
of the `ssm`, `ssmmessages`, and `ec2messages` endpoints in a
no-internet VPC, and DNS resolution succeeding is not the same thing as
reachability.

| check | expected | why |
|---|---|---|
| `dns_ssm_endpoint` | pass | public DNS returns the public service IP |
| `dns_public_hostname` | pass | same |
| `ssm_api_reachable` | fail | no route from the private subnet to the public IP |
| `instance_registered_with_ssm` | fail | agent can't reach the control plane |

##### `dns-disabled`

Sets `enable_dns_support = false` (and `enable_dns_hostnames = false`)
on the VPC. The endpoints stay but `private_dns_enabled` is flipped off
because that AWS-side feature requires VPC DNS to be enabled. The
Amazon-provided resolver returns nothing, so every name lookup inside
the VPC fails. **Lesson:** VPC DNS is a per-VPC toggle that quietly
breaks both name resolution and the private-DNS overlay that lets
interface endpoints work as drop-in replacements for public service
hostnames.

| check | expected | why |
|---|---|---|
| `dns_ssm_endpoint` | fail | VPC resolver returns nothing |
| `dns_public_hostname` | fail | same |
| `ssm_api_reachable` | fail | boto3 can't resolve the endpoint hostname |
| `instance_registered_with_ssm` | fail | same |

### Lab #2: `three-tier-segmentation` — slice 11 (#12)

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
