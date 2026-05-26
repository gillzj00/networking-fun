# bootstrap/

The smallest layer of the IaC pyramid. Creates the things that the higher layers
(`platform/`, `labs/runtime/`) need to exist before they can be applied:

- S3 bucket for Terraform state (with versioning, SSE, public access block)
- GitHub OIDC provider
- IAM role `gha-terraform` for GitHub Actions to assume

**Applied manually**, deliberately, from your SSO-authenticated CLI. Not via GitHub
Actions — see the [PRD blast-radius safety rail](../PRD.md#blast-radius-safety-rail).

## Prerequisites

1. `networking-fun-dev` member account exists (see
   [`docs/account-setup/`](../docs/account-setup/)).
2. You have an SSO profile targeting it.
3. Terraform ≥ 1.10 (required for S3 native state locking).

## First apply (local state)

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to confirm owner_email and github_repo

export AWS_PROFILE=networking-fun-dev.NetworkingFunDevAdmin
terraform init        # initializes with local state
terraform plan -out=tfplan
terraform apply tfplan
```

Outputs to capture:

- `tfstate_bucket` — pass to `platform/` and `labs/runtime/` as their backend bucket
- `gha_role_arn` — paste into `.github/workflows/*.yml` under `role-to-assume`
- `oidc_provider_arn` — informational

## Migrate state to S3 (one-time, after first apply)

Uncomment the `backend "s3"` block at the top of `main.tf`, fill in the dev account ID,
then:

```bash
terraform init -migrate-state
# Type "yes" when prompted. Local state file becomes the S3 object.
```

After migration the local `terraform.tfstate` is just a backup — delete it once you've
confirmed S3 access works.

## Subsequent applies

```bash
export AWS_PROFILE=networking-fun-dev.NetworkingFunDevAdmin
terraform plan
terraform apply
```

## Destroy

This layer is intentionally hard to destroy:

- S3 bucket is versioned. `terraform destroy` will fail until you empty it.
- The OIDC provider and role are referenced from GitHub workflows; destroying breaks CI.

If you really mean it:

```bash
aws s3api delete-objects --bucket "$(terraform output -raw tfstate_bucket)" \
  --delete "$(aws s3api list-object-versions --bucket "$(terraform output -raw tfstate_bucket)" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}')"
terraform destroy
```

But realistically the only reason to destroy bootstrap is account closure, and at that
point you're closing the whole account from Organizations.
