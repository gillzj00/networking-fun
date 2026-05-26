# platform/

Long-lived, account-wide resources for `networking-fun`: anything the labs
consume but that itself outlives any individual PR. Today this layer owns:

- A trivial CloudWatch log group (`/networking-fun/platform/demo`) — only
  there to prove the GitOps loop end-to-end; will be removed once real
  platform resources have displaced it.
- A delegated Route53 zone for `labs.gillzhub.com` — vanity URLs for the
  ephemeral lab envs (`pr-<N>.labs.gillzhub.com`).
- A wildcard ACM cert for `*.labs.gillzhub.com` (us-east-2, DNS-validated).

Future slices add the Janitor Lambda, Budgets alarm, and the lab module
registry (see [PRD §6](../PRD.md#6-architecture--three-layers)).

## Trigger model

This layer is GitOps. You do **not** run `terraform apply` from your laptop —
GitHub Actions does it, authenticated via OIDC.

| Event | Workflow | Effect |
|---|---|---|
| PR opened / pushed, touches `platform/**` | [`.github/workflows/platform-plan.yml`](../.github/workflows/platform-plan.yml) | `fmt -check`, `tflint`, `checkov`, `terraform plan`; plan posted as a sticky PR comment; blast-radius check fails the PR if it touches bootstrap-owned resources |
| Push to `main` touches `platform/**` | [`.github/workflows/platform-apply.yml`](../.github/workflows/platform-apply.yml) | `terraform apply -auto-approve` |

Both workflows assume the `gha-terraform` role (created by [`bootstrap/`](../bootstrap/)) via OIDC.

### Why the plan workflow needs an environment approval

The `gha-terraform` trust policy is restricted (F-01) to two GitHub OIDC
subject patterns: `ref:refs/heads/main` and `environment:<protected env>`.
That keeps fork PRs from silently obtaining Admin in the dev account.

To allow PR plans to read state, the plan workflow targets a dedicated
GitHub environment named `terraform-plan`. The environment is configured
with **required-reviewer = @gillzj00**, so every PR plan run waits for one
explicit approval click in the GH UI before the role is assumed. This is
the same gate F-01 applies to production applies, just on a per-plan basis.

Required prerequisite (one-time, per fork):

1. Repo settings → Environments → create `terraform-plan` with
   required-reviewer `@gillzj00` and "all branches" deployment policy.
2. Re-apply `bootstrap/` so the trust policy picks up the new
   `environment:terraform-plan` subject.

Required GitHub Actions variables (`Settings → Secrets and variables → Actions → Variables`):

| Variable | Value |
|---|---|
| `AWS_REGION` | `us-east-2` |
| `AWS_ROLE_ARN` | output `gha_role_arn` from `bootstrap/` |
| `TFSTATE_BUCKET` | output `tfstate_bucket` from `bootstrap/` |

## Blast-radius safety rail

The plan workflow runs `terraform show -json tfplan` and fails the PR if
any `resource_change` touches resources that belong to `bootstrap/`:

- `aws_s3_bucket.tfstate` and its sub-resources (the state bucket)
- `aws_iam_openid_connect_provider.github`
- `aws_iam_role.gha_terraform` and its policy attachments

These resources can only be changed by re-running `bootstrap/` manually
from a privileged IDC session. Catching the attempt in CI prevents a
platform-layer PR from accidentally hosing the credential surface that CI
itself depends on.

## DNS delegation and wildcard ACM

The lab vanity-URL pattern is `pr-<N>.labs.gillzhub.com`. To make that
resolve, `labs.gillzhub.com` is delegated from the parent `gillzhub.com`
zone (in the management account) to a child Route53 zone in this dev
sub-account, and a wildcard ACM cert is issued for `*.labs.gillzhub.com`.

The child zone and cert are managed here in `platform/`. The parent-zone
NS record is a **one-time manual step** in the management account — see
the [parent-zone NS delegation
runbook](../docs/account-setup/README.md#phase-9--delegate-labsgillzhubcom-to-the-dev-sub-account).
Cross-account Terraform for that one record was judged too much trust
surface for a single 4-line resource; see the rationale in the runbook.

### Order of operations

1. Merge the platform-layer change that introduces the zone + cert.
   Apply runs in the dev sub-account; the cert is created in
   `PENDING_VALIDATION` because the validation CNAME can't yet resolve
   publicly.
2. Read the `labs_zone_name_servers` Terraform output.
3. Run the parent-zone runbook (one-time, manual) to add the NS record in
   `gillzhub.com`. Verify with `dig labs.gillzhub.com NS`.
4. Flip `enable_acm_validation = true` in `terraform.tfvars` and open a
   follow-up PR. The apply will block on `aws_acm_certificate_validation`
   until ACM sees the validation record, then the cert reaches `ISSUED`.

Until step 3 is done, the cert is harmless dead weight in
`PENDING_VALIDATION`; nothing else in `platform/` or `labs/` depends on
it being issued yet.

## Escape hatch

GitOps is the normal path. The IDC SSO admin role retains permission to
run `terraform apply` from a laptop in genuine emergencies — see the PRD
for the policy. Manual applies are an incident, not a workflow.

## Local development

You should rarely need to run Terraform locally for this layer, but for
debugging:

```bash
cp backend.hcl.example backend.hcl
# Fill in your dev account ID

cp terraform.tfvars.example terraform.tfvars
# Adjust if needed

export AWS_PROFILE=networking-fun-dev.NetworkingFunDevAdmin
terraform init -backend-config=backend.hcl
terraform plan
```

Do not `terraform apply` from your laptop — let the workflow do it.
