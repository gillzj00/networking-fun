# Slice 1 security audit — findings

**Audit date:** 2026-05-25
**Audit scope:** read-only review of live AWS state in mgmt `111111111111` and dev `222222222222` after Slice 1 (PR #15) landed the multi-account landing zone, cross-checked against `bootstrap/`, `docs/account-setup/policies/`, and the runbook.
**Audit method:** AWS CLI under `default` (mgmt admin) + `networking-fun-dev-ro` (dev read-only) SSO profiles. No resources modified.

Findings are grouped by severity. Each is identified `F-NN`. Tracked in GitHub via the `security` label.

## Current status (as of 2026-05-26)

**10 of 16 resolved.** The 6 still-open findings are tracked in **GitHub issue #17** (baseline hardening, M2 cycle).

| ID | Severity | Title | Status |
|---|---|---|---|
| F-01 | HIGH | `gha-terraform` OIDC trust wildcard | ✅ RESOLVED — PR #18, applied to live IAM 2026-05-26 |
| F-02 | HIGH | CloudTrail bucket allows non-TLS access | ✅ RESOLVED — PR #19, live policy 2026-05-25 |
| F-03 | MEDIUM | CloudTrail bucket has no Object Lock / MFA-delete | 🔲 OPEN — #17 |
| F-04 | MEDIUM | `OrganizationAccountAccessRole` trust lacks MFA | 🔲 OPEN — #17 |
| F-05 | MEDIUM | Default VPC + IGW + public subnets intact in dev | 🔲 OPEN — #17 |
| F-06 | MEDIUM | EBS encryption-by-default off in dev | ✅ Fixed in audit (see below) |
| F-07 | MEDIUM | No IAM Access Analyzer in either account | ✅ Fixed in audit (see below) |
| F-08 | MEDIUM | tfstate bucket has no bucket policy | ✅ RESOLVED — PR #19, applied 2026-05-26 |
| F-09 | MEDIUM | SCP `DenyDisablingCloudTrail` doesn't cover Lake | ✅ RESOLVED — PR #20, live SCP 2026-05-25 |
| F-10 | LOW | No IAM password policy in either account | ✅ Fixed in audit (see below) |
| F-11 | LOW | CloudTrail bucket has no lifecycle policy | 🔲 OPEN — #17 |
| F-12 | LOW | Hardcoded dev account ID in `bootstrap/main.tf` | ✅ RESOLVED — PR #21 |
| F-13 | LOW | Tag policy `enforced_for` misses networking resources | ✅ RESOLVED — PR #20, live policy 2026-05-25 |
| F-14 | LOW | Budget alarms are single-channel email | 🔲 OPEN — #17 |
| F-15 | LOW | IDC permission sets have no permissions boundary | 🔲 OPEN — #17 |
| F-16 | LOW | OIDC provider thumbprint is the stale GitHub one | ✅ RESOLVED — PR #21, applied 2026-05-26 |

**Open work tracker:** GitHub issue #17. **History below is preserved for context** — the per-finding sections retain the original "what / why / fix" narrative even for resolved items.

---

## HIGH

### F-01 [HIGH] `gha-terraform` OIDC trust matches any ref, including PR refs from forks
**Where:** dev `222222222222`, role `gha-terraform`. Trust `Condition.StringLike.token.actions.githubusercontent.com:sub = "repo:gillzj00/networking-fun:*"`.
**What:** The `*` wildcard on the `sub` claim matches every GitHub-issued OIDC token for this repo — `ref:refs/heads/*`, `pull_request`, `environment:*`, `job_workflow_ref:*`. Combined with `AdministratorAccess` (accepted v1.1 risk), any workflow that runs from a PR can assume Admin in the dev account.
**Why it matters:** Public flip was scheduled for M1 (2026-06-08, actually shipped 2026-05-26). Once public, a fork PR-author can propose a workflow change (`pull_request_target` is the classic vector) and pivot to full account control.
**Fix:** Tighten the `sub` condition in `bootstrap/main.tf:90-93`:
```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values   = [
    "repo:${var.github_repo}:ref:refs/heads/main",
    "repo:${var.github_repo}:environment:production",
  ]
}
```
Pair with a GitHub `production` environment (required-reviewer = `@gillzj00`).

### F-02 [HIGH] CloudTrail S3 bucket allows non-TLS access
**Where:** mgmt `111111111111`, bucket `aws-cloudtrail-org-111111111111-us-east-2`.
**What:** Bucket policy has only the 3 CloudTrail Allow statements — no `Deny … aws:SecureTransport=false`. PAB is on, so no exposure today, but CIS 2.1.2 / FSBP `S3.5` failure.
**Fix:** Append to `docs/account-setup/policies/cloudtrail-bucket-policy.json` and re-apply via `aws s3api put-bucket-policy`:
```json
{
  "Sid": "DenyInsecureTransport",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": [
    "arn:aws:s3:::aws-cloudtrail-org-111111111111-us-east-2",
    "arn:aws:s3:::aws-cloudtrail-org-111111111111-us-east-2/*"
  ],
  "Condition": { "Bool": { "aws:SecureTransport": "false" } }
}
```

---

## MEDIUM

### F-03 [MEDIUM] CloudTrail bucket has no Object Lock and no MFA-delete
**Where:** mgmt CloudTrail bucket; `get-object-lock-configuration` → `ObjectLockConfigurationNotFoundError`; versioning Enabled but MFA-delete off.
**What:** SCP `DenyDisablingCloudTrail` blocks trail-level tampering but not S3-level log purging by anyone with `s3:DeleteObjectVersion`.
**Fix:** Object Lock cannot be enabled retroactively without an AWS support ticket. Options:
- Recreate the bucket with `--object-lock-enabled-for-bucket` + Governance mode, 90d retention. Migration window = log gap.
- Enable MFA-delete via `aws s3api put-bucket-versioning --mfa "<serial> <code>" --versioning-configuration Status=Enabled,MFADelete=Enabled`. Requires root user.

### F-04 [MEDIUM] `OrganizationAccountAccessRole` trust lacks MFA condition
**Where:** dev `222222222222`, role `OrganizationAccountAccessRole`, trust = `arn:aws:iam::111111111111:root`, `AdministratorAccess`, `MaxSessionDuration=3600`.
**What:** Permanent backdoor that bypasses IDC. Any mgmt-side IAM principal with `sts:AssumeRole` becomes Admin in dev with no MFA. Today there are zero IAM users in mgmt, so effective callers = SSO Admin only.
**Fix:** Either delete or add MFA condition:
```json
"Condition": { "Bool": { "aws:MultiFactorAuthPresent": "true" } }
```
If deleting, document the recovery path (re-invite from mgmt) first.

### F-05 [MEDIUM] Default VPC, IGW, public subnets intact in dev us-east-2
**Where:** dev us-east-2: `vpc-0e208115bf6b01798` (default), `igw-0b7a04ca56bc1f62d`, 3 default subnets all `MapPublicIpOnLaunch=true`, `BlockPublicAccessStates.InternetGatewayBlockMode=off`.
**What:** Any EC2 launched without explicit subnet selection lands in a public subnet with a public IP.
**Fix:**
```bash
# Option A: delete default VPC entirely (preferred for portfolio signal)
aws ec2 detach-internet-gateway --internet-gateway-id igw-0b7a04ca56bc1f62d --vpc-id vpc-0e208115bf6b01798 --region us-east-2 --profile networking-fun-dev
aws ec2 delete-internet-gateway --internet-gateway-id igw-0b7a04ca56bc1f62d --region us-east-2 --profile networking-fun-dev
# delete each subnet, then delete-vpc

# Option B: block IGW attach at VPC level (less destructive)
aws ec2 modify-vpc-block-public-access-options --internet-gateway-block-mode block-bidirectional --region us-east-2 --profile networking-fun-dev
```

### F-06 [MEDIUM] EBS encryption-by-default OFF in dev us-east-2 — **FIXED IN AUDIT**
**Where:** `get-ebs-encryption-by-default` → `EbsEncryptionByDefault: false`.
**Fix applied:** `aws ec2 enable-ebs-encryption-by-default --region us-east-2 --profile networking-fun-dev` (2026-05-25). Verify with the same command (`true`).
**Follow-up:** add as a resource (`aws_ebs_encryption_by_default`) in a future `account-baseline/` Terraform layer so it survives a destroy/recreate.

### F-07 [MEDIUM] No IAM Access Analyzer in either account — **FIXED IN AUDIT**
**Where:** `list-analyzers` returned empty in both accounts (us-east-2).
**Fix applied:** Org-level analyzer in mgmt and account-level analyzer in dev created 2026-05-25.
```bash
aws accessanalyzer create-analyzer --analyzer-name org-analyzer --type ORGANIZATION --region us-east-2 --profile default
aws accessanalyzer create-analyzer --analyzer-name dev-analyzer --type ACCOUNT --region us-east-2 --profile networking-fun-dev
```
**Follow-up:** add to a future `account-baseline/` Terraform layer.

### F-08 [MEDIUM] Terraform state bucket has no bucket policy
**Where:** dev bucket `tfstate-networking-fun-222222222222`; `get-bucket-policy` → `NoSuchBucketPolicy`.
**What:** Private by PAB + SSE-S3 + `BucketOwnerEnforced`, but no explicit TLS deny.
**Fix:** Add to `bootstrap/main.tf`:
```hcl
resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
```

### F-09 [MEDIUM] SCP `DenyDisablingCloudTrail` doesn't cover CloudTrail Lake
**Where:** `docs/account-setup/policies/scp-workloads-baseline.json:11-20`.
**What:** Blocks v1 trail actions only. Lake equivalents are unprotected.
**Fix:** Append:
```json
"cloudtrail:DeleteEventDataStore",
"cloudtrail:UpdateEventDataStore",
"cloudtrail:DeleteChannel",
"cloudtrail:DeleteResourcePolicy",
"cloudtrail:PutResourcePolicy",
"cloudtrail:DisableFederation"
```
Re-version via `aws organizations update-policy --policy-id p-XXXXXXXX --content file://...`.

---

## LOW

### F-10 [LOW] No IAM password policy — **FIXED IN AUDIT**
**Where:** mgmt + dev: `get-account-password-policy` → `NoSuchEntity`.
**Fix applied:** Both accounts received a CIS-compliant password policy on 2026-05-25 (length 14, all character classes, max age 90d, reuse prevention 24). Zero IAM users today so effective impact is hygiene/audit.

### F-11 [LOW] CloudTrail bucket has no lifecycle policy
**Where:** mgmt CloudTrail bucket; `get-bucket-lifecycle-configuration` → `NoSuchLifecycleConfiguration`.
**Fix:** Add lifecycle: Standard → IA at 30d → Glacier Instant at 90d → Glacier Deep at 365d → expire at 7y.

### F-12 [LOW] Hardcoded dev account ID in tracked `bootstrap/main.tf`
**Where:** `bootstrap/main.tf:3` — `bucket = "tfstate-networking-fun-222222222222"`. **Not** on the runbook's pre-public-flip redact list at `docs/account-setup/README.md:35-39`.
**Fix:** Convert to backend-config injection:
```hcl
# bootstrap/main.tf
terraform { backend "s3" {} }
```
```bash
terraform init -backend-config="bucket=tfstate-networking-fun-${ACCOUNT_ID}" \
               -backend-config="key=bootstrap/terraform.tfstate" \
               -backend-config="region=us-east-2" \
               -backend-config="use_lockfile=true" \
               -backend-config="encrypt=true"
```
Then add to the runbook redact-TODO list.

### F-13 [LOW] Tag policy `enforced_for` misses networking resources
**Where:** `docs/account-setup/policies/tag-policy.json:11-21`.
**What:** Missing `ec2:network-acl`, `ec2:route-table`, `ec2:internet-gateway`, `ec2:nat-gateway`, `ec2:transit-gateway`, `ec2:vpc-endpoint`, `ec2:elastic-ip`, `ec2:network-interface`, `ec2:transit-gateway-attachment`, `iam:role`, `iam:policy`, `kms:key`.
**Fix:** Extend list, re-version via `aws organizations update-policy --policy-id p-XXXXXXXXXX --content file://...`.

### F-14 [LOW] Budget alarms single-channel email
**Where:** `networking-fun-dev-25usd` — all 4 subscribers EMAIL to `5639243+gillzj00@users.noreply.github.com`.
**What:** Single point of failure. No >100% catch-up threshold (150%/200%).
**Fix:** Move to SNS topic with multiple endpoints (email + SMS); add 150% + 200% ACTUAL thresholds.

### F-15 [LOW] IDC permission sets have no permissions boundary
**Where:** both PS in `arn:aws:sso:::instance/ssoins-XXXXXXXXXXXXXXXX`.
**What:** `NetworkingFunDevAdmin` carries Admin with no boundary cap.
**Fix:** Define a customer-managed `IDPLitePermissionsBoundary` denying the tamper-proofing actions in F-09, then attach via `put-permissions-boundary-to-permission-set`.

### F-16 [LOW] OIDC provider thumbprint is the stale GitHub one
**Where:** `bootstrap/main.tf:69` — `6938fd4d98bab03faadb97b34396831e3780aea1`.
**What:** AWS validates `token.actions.githubusercontent.com` JWKS automatically (thumbprint effectively ignored), but some frameworks flag staleness.
**Fix:** Either compute via `aws_iam_openid_connect_provider` data source pattern, or include both current GitHub thumbprints (`6938fd4d98bab03faadb97b34396831e3780aea1`, `1c58a3a8518e8759bf075b76b750d4f2df264fcd`).

---

## Audited, no findings

- **Org-trail integrity** — `IsLogging=true`, `LatestDeliveryAttemptSucceeded=2026-05-26T01:58:51Z`, `LogFileValidationEnabled=true`, multi-region, organization trail.
- **CloudTrail bucket PAB/versioning/SSE/ownership** — all four PAB flags true, versioning Enabled, SSE-S3, `BucketOwnerEnforced`.
- **CloudTrail bucket policy principal scoping** — `aws:SourceArn` correctly pins each Allow to the `org-trail` ARN.
- **SCP region-lock NotAction list** — audited; covers IAM/STS/Orgs/Route53/CloudFront/ACM/Support/Billing/CE/Budgets/Health. Nothing missing for this workload.
- **SCP `DenyRootAccountUsage`** — `StringLike aws:PrincipalArn` pattern correct.
- **SCP `DenyExpensiveServices`** — covers EKS, RDS, ElastiCache, Redshift, OpenSearch, SageMaker, Transfer, Direct Connect.
- **mgmt account root user** — password + MFA enabled, zero access keys, last used 2026-02-12.
- **tfstate bucket** — versioned, SSE-S3, PAB on, 90d non-current expiration, 7d abort-multipart, `BucketOwnerEnforced`.
- **Tag policy effective on dev** — `describe-effective-policy --policy-type TAG_POLICY` merges correctly.
- **Dev IAM** — zero IAM users, zero access keys, only SSO-reserved + service-linked + `gha-terraform` + `OrganizationAccountAccessRole`.

## Accepted risks (per PRD / runbook)

- `gha-terraform` carries `AdministratorAccess` — v1.1 tightening line item.
- GuardDuty, Security Hub, AWS Config — deferred per PRD cost rationale.
- CloudTrail bucket SSE-S3 not KMS — intentional v1 trade-off.
- 90d tfstate non-current expiration — accepted retention trade-off.
- IDC instance in us-west-2 — predates project, intentional.
- mgmt account `111111111111` lives at root, outside Workloads SCP — by design; mgmt has 9 pre-existing buckets + default VPC + IGW that are not covered by project guardrails.
- Runbook contains account IDs / org ID / OU ID — tracked redact TODO at `docs/account-setup/README.md:35-39`.
