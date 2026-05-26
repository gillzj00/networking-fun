# networking-fun — AWS account setup runbook

**Purpose.** Convert the existing single management account into an enterprise-shaped AWS
Organization with a dedicated `networking-fun-dev` member account, ready to receive the
Terraform in [`bootstrap/`](../../bootstrap/).

**Status:** Phases 0–8 shipped 2026-05-25 (Slice 1, PR #15). Audit-driven remediations
shipped 2026-05-26 (F-01/F-02/F-08/F-12/F-16 — see [`docs/security/`](../security/)).

> **Public-repo note.** All account / org / OU / SCP / SSO / permission-set IDs in this
> file are placeholders (`111111111111`, `o-XXXXXXXXXX`, etc.). The real IDs were
> redacted from git history via `git-filter-repo` before the 2026-05-26 public flip. If
> you're forking this runbook, substitute your own.

**Specific to this setup** (not generic — all values are wired in):

| Field | Value |
|---|---|
| Management account ID | `111111111111` |
| Region | `us-east-2` |
| SSO start URL | `https://zach-gill-2025.awsapps.com/start` |
| SSO region | `us-west-2` (where the Identity Center instance lives) |
| Owner GitHub | `gillzj00` |
| Repo | `gillzj00/networking-fun` |
| Owner contact email | `zachary.gill@hotmail.com` |
| Member account name | `networking-fun-dev` |
| Member account email | `zachary.gill+networking-fun-dev@hotmail.com` (`+` aliasing works on Outlook/Hotmail) |
| Member account ID | `222222222222` (created 2026-05-25) |
| Org ID | `o-XXXXXXXXXX` |
| Root ID | `r-XXXX` |
| Workloads OU ID | `ou-XXXX-XXXXXXXX` |
| Budget cap | `$25` / month |
| Lab TTL | `4h` |

**How to read.** Phases are sequential. Each phase is tagged with one of:

- **YOU** — only you can do this (browser SSO, email verification, console clicks)
- **CLAUDE** — paste the phase header back into Claude and I'll run it
- **DECISION** — Claude pauses and waits for your explicit OK because the action is hard to reverse or has billing impact

Tick the checkbox at the start of each phase as you finish it.

---

## Phase 0 — Refresh SSO and audit current state

- [x] Done (2026-05-25)

**YOU:** Refresh your SSO session (opens a browser).

```bash
aws sso login --profile default
```

> `aws-sso-util` 4.33.0 doesn't parse the `sso-session` block in your `~/.aws/config`,
> so we use the native AWS CLI for login throughout this runbook.

**CLAUDE:** Once logged in, run the audit so I know what already exists:

```bash
aws sts get-caller-identity
aws organizations describe-organization
aws organizations list-roots --query 'Roots[0].[Id,Name,PolicyTypes]' --output table
aws organizations list-organizational-units-for-parent \
  --parent-id "$(aws organizations list-roots --query 'Roots[0].Id' --output text)" \
  --output table
aws organizations list-accounts --output table
aws sso-admin list-instances --region us-west-2
aws cloudtrail list-trails --region us-east-2
```

**Expected result:** Organizations is already enabled (Identity Center requires it). One
account in the org (management). Zero or one OUs. Zero or one CloudTrail trails.

---

## Phase 1 — Organization baseline (OUs + policy types)

- [x] Done (2026-05-25) — SCP + TAG_POLICY enabled on root `r-XXXX`; Workloads OU `ou-XXXX-XXXXXXXX` created

**CLAUDE:**

1. Enable both policy types on the root if not already:

   ```bash
   ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)
   aws organizations enable-policy-type --root-id "$ROOT_ID" --policy-type SERVICE_CONTROL_POLICY || true
   aws organizations enable-policy-type --root-id "$ROOT_ID" --policy-type TAG_POLICY || true
   ```

2. Create the `Workloads` OU (the only OU we need for v1):

   ```bash
   aws organizations create-organizational-unit \
     --parent-id "$ROOT_ID" \
     --name Workloads
   ```

   Capture the returned `Id` — we'll use it in Phases 3 and 4.

**Why only one OU.** AWS best practice splits accounts across `Security`,
`Infrastructure`, `Workloads`, `Sandbox`, etc. For v1 (one member account, $25/mo cap),
that structure is theater. The Workloads OU exists so guardrails attach at the OU level
(not directly to the account), which is the pattern that scales.

---

## Phase 2 — Org-wide CloudTrail

- [x] Done (2026-05-25) — created via CLI from the management account.

**CLAUDE (CLI flow — what was actually run):**

```bash
# 1. Enable CloudTrail as a trusted service so org trails are allowed
aws organizations enable-aws-service-access \
  --service-principal cloudtrail.amazonaws.com

# 2. Create the S3 bucket in us-east-2 (LocationConstraint required outside us-east-1)
aws s3api create-bucket \
  --bucket aws-cloudtrail-org-111111111111-us-east-2 \
  --region us-east-2 \
  --create-bucket-configuration LocationConstraint=us-east-2

# 3. Harden the bucket: PAB, versioning, SSE-S3, BucketOwnerEnforced (ACLs disabled)
aws s3api put-public-access-block \
  --bucket aws-cloudtrail-org-111111111111-us-east-2 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning \
  --bucket aws-cloudtrail-org-111111111111-us-east-2 \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket aws-cloudtrail-org-111111111111-us-east-2 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":false}]}'

aws s3api put-bucket-ownership-controls \
  --bucket aws-cloudtrail-org-111111111111-us-east-2 \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

# 4. Apply CloudTrail bucket policy (template at policies/cloudtrail-bucket-policy.json)
aws s3api put-bucket-policy \
  --bucket aws-cloudtrail-org-111111111111-us-east-2 \
  --policy file://docs/account-setup/policies/cloudtrail-bucket-policy.json

# 5. Create the trail (multi-region, org-wide, log file validation on)
aws cloudtrail create-trail \
  --name org-trail \
  --s3-bucket-name aws-cloudtrail-org-111111111111-us-east-2 \
  --is-multi-region-trail \
  --is-organization-trail \
  --enable-log-file-validation \
  --region us-east-2

# 6. Start logging
aws cloudtrail start-logging --name org-trail --region us-east-2
```

**Defaults that match the runbook spec:**

- Management events Read + Write: default event selector (`ReadWriteType=All`, `IncludeManagementEvents=true`)
- Data events: off (default — `DataResources=[]`)
- Insights events: off (default — none configured)
- CloudWatch Logs delivery: off (not configured — saves the per-event ingest cost)
- KMS: not used (SSE-S3 only)

**Bucket policy notes:**

- Bucket uses `BucketOwnerEnforced`, so ACLs are disabled. The classic
  `s3:x-amz-acl = bucket-owner-full-control` condition on the CloudTrail `PutObject`
  statement is omitted — including it would cause every CloudTrail delivery to fail.
- Two `PutObject` statements: one for `AWSLogs/<mgmt-account-id>/*` (events generated
  by the management account itself) and one for `AWSLogs/<org-id>/*` (events from
  member accounts, which CloudTrail writes under the org-id prefix).
- `aws:SourceArn` condition pins each statement to this specific trail, so a different
  trail accidentally pointed at the same bucket can't write to it.

**Verify:**

```bash
aws cloudtrail describe-trails --trail-name-list org-trail --region us-east-2 \
  --query 'trailList[0].[Name,IsOrganizationTrail,IsMultiRegionTrail,LogFileValidationEnabled]'
# Expected: [ "org-trail", true, true, true ]

aws cloudtrail get-trail-status --name org-trail --region us-east-2 \
  --query '[IsLogging,LatestDeliveryError]'
# Expected: [ true, null ]  (LatestDeliveryError stays null when delivery works)
```

---

## Phase 3 — Create the `networking-fun-dev` member account

- [x] Done (2026-05-25) — account `222222222222` created, moved into Workloads OU.
- [ ] **YOU still TODO:** click the "verify your account contact" email AWS sent to `zachary.gill+networking-fun-dev@hotmail.com`. Account works without it, but verification is required to close cleanly.

**DECISION:** Creating an account is **slow to fully reverse** (90-day closure delay) and
starts a billing relationship. Confirm before proceeding.

**CLAUDE:**

```bash
aws organizations create-account \
  --email "zachary.gill+networking-fun-dev@hotmail.com" \
  --account-name "networking-fun-dev" \
  --iam-user-access-to-billing DENY \
  --role-name OrganizationAccountAccessRole
```

Capture the `CreateAccountRequestId` and poll:

```bash
REQ_ID=<paste-request-id>
aws organizations describe-create-account-status --create-account-request-id "$REQ_ID"
```

When `State=SUCCEEDED`, capture the new `AccountId` (this becomes `<DEV_ACCOUNT_ID>` in
the rest of the runbook). Then move it to the Workloads OU:

```bash
DEV_ACCOUNT_ID=<paste-new-account-id>
WORKLOADS_OU_ID=<paste-from-phase-1>
ROOT_ID=$(aws organizations list-roots --query 'Roots[0].Id' --output text)

aws organizations move-account \
  --account-id "$DEV_ACCOUNT_ID" \
  --source-parent-id "$ROOT_ID" \
  --destination-parent-id "$WORKLOADS_OU_ID"
```

**Email verification:** AWS sends a "verify your account contact" email to
`zachary.gill+networking-fun-dev@hotmail.com`. Click through it before continuing. The
account is technically usable without verification, but verifying now avoids surprises
later (and is required to close the account cleanly).

---

## Phase 4 — Apply guardrails (SCPs + tag policy + budget)

- [x] SCP `workloads-baseline` (`p-XXXXXXXX`) attached to Workloads OU (2026-05-25)
- [x] Tag policy `require-standard-tags` (`p-XXXXXXXXXX`) attached to Workloads OU (2026-05-25)
- [x] $25/mo budget `networking-fun-dev-25usd` created via CLI in management account (2026-05-25)

**CLAUDE:** Attach the baseline SCP and tag policy to the Workloads OU.

1. Create + attach SCP:

   ```bash
   WORKLOADS_OU_ID=ou-XXXX-XXXXXXXX

   SCP_ID=$(aws organizations create-policy \
     --type SERVICE_CONTROL_POLICY \
     --name workloads-baseline \
     --description "Region lock, root deny, CloudTrail tamper-proofing, expensive-service deny" \
     --content file://docs/account-setup/policies/scp-workloads-baseline.json \
     --query 'Policy.PolicySummary.Id' --output text)
   echo "SCP_ID=$SCP_ID"

   aws organizations attach-policy --policy-id "$SCP_ID" --target-id "$WORKLOADS_OU_ID"

   # Verify
   aws organizations list-policies-for-target \
     --target-id "$WORKLOADS_OU_ID" --filter SERVICE_CONTROL_POLICY --output table
   ```

2. Create + attach tag policy:

   ```bash
   TAG_POLICY_ID=$(aws organizations create-policy \
     --type TAG_POLICY \
     --name require-standard-tags \
     --description "Enforce Project / Environment / ManagedBy tags" \
     --content file://docs/account-setup/policies/tag-policy.json \
     --query 'Policy.PolicySummary.Id' --output text)
   echo "TAG_POLICY_ID=$TAG_POLICY_ID"

   aws organizations attach-policy --policy-id "$TAG_POLICY_ID" --target-id "$WORKLOADS_OU_ID"
   ```

   Record the returned `SCP_ID` and `TAG_POLICY_ID` in the table at the top of this runbook.

**CLAUDE:** Create the $25/mo budget in the **management account** (consolidated billing)
scoped to the dev account. The budget JSON and notifications JSON match the same spec as
the console flow (Monthly cost / $25 / LinkedAccount filter / 50-80-100 ACTUAL + 100
FORECASTED → email).

```bash
cat > /tmp/budget.json <<'JSON'
{
  "BudgetName": "networking-fun-dev-25usd",
  "BudgetLimit": { "Amount": "25", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST",
  "CostFilters": { "LinkedAccount": ["222222222222"] },
  "CostTypes": {
    "IncludeTax": true, "IncludeSubscription": true, "UseBlended": false,
    "IncludeRefund": false, "IncludeCredit": false, "IncludeUpfront": true,
    "IncludeRecurring": true, "IncludeOtherSubscription": true,
    "IncludeSupport": true, "IncludeDiscount": true, "UseAmortized": false
  }
}
JSON

cat > /tmp/notifications.json <<'JSON'
[
  { "Notification": {"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":50,"ThresholdType":"PERCENTAGE"},
    "Subscribers": [{"SubscriptionType":"EMAIL","Address":"zachary.gill@hotmail.com"}] },
  { "Notification": {"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},
    "Subscribers": [{"SubscriptionType":"EMAIL","Address":"zachary.gill@hotmail.com"}] },
  { "Notification": {"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":100,"ThresholdType":"PERCENTAGE"},
    "Subscribers": [{"SubscriptionType":"EMAIL","Address":"zachary.gill@hotmail.com"}] },
  { "Notification": {"NotificationType":"FORECASTED","ComparisonOperator":"GREATER_THAN","Threshold":100,"ThresholdType":"PERCENTAGE"},
    "Subscribers": [{"SubscriptionType":"EMAIL","Address":"zachary.gill@hotmail.com"}] }
]
JSON

# Run from the management account profile (budgets live with consolidated billing)
aws budgets create-budget \
  --account-id 111111111111 \
  --budget file:///tmp/budget.json \
  --notifications-with-subscribers file:///tmp/notifications.json \
  --profile default

# Verify
aws budgets describe-budget --account-id 111111111111 \
  --budget-name networking-fun-dev-25usd --profile default
aws budgets describe-notifications-for-budget --account-id 111111111111 \
  --budget-name networking-fun-dev-25usd --profile default
```

**Verify guardrails work:** After Phase 6 (when you have a profile for the dev account),
this should be denied by the region-lock SCP:

```bash
aws ec2 describe-instances --region us-west-2 --profile networking-fun-dev
# Expected: AccessDenied — proves the SCP is attached
```

---

## Phase 5 — Identity Center permission sets + assignment

- [x] Done (2026-05-25)
- SSO instance: `arn:aws:sso:::instance/ssoins-XXXXXXXXXXXXXXXX`
- Identity Store: `d-XXXXXXXXXX`
- User: `zach-sso` (`00000000-0000-0000-0000-000000000000`)
- `NetworkingFunDevAdmin`: `arn:aws:sso:::permissionSet/ssoins-XXXXXXXXXXXXXXXX/ps-XXXXXXXXXXXXXXXX` (AdministratorAccess attached)
- `NetworkingFunDevReadOnly`: `arn:aws:sso:::permissionSet/ssoins-XXXXXXXXXXXXXXXX/ps-XXXXXXXXXXXXXXXX` (ReadOnlyAccess attached)
- Both assigned to user on dev account `222222222222`

**CLAUDE:** Two permission sets, both assigned to your user against the new account.

```bash
SSO_INSTANCE_ARN=$(aws sso-admin list-instances --region us-west-2 \
  --query 'Instances[0].InstanceArn' --output text)
IDENTITY_STORE_ID=$(aws sso-admin list-instances --region us-west-2 \
  --query 'Instances[0].IdentityStoreId' --output text)
USER_ID=$(aws identitystore list-users \
  --identity-store-id "$IDENTITY_STORE_ID" \
  --region us-west-2 \
  --filters "AttributePath=UserName,AttributeValue=<your-sso-username>" \
  --query 'Users[0].UserId' --output text)

DEV_ACCOUNT_ID=222222222222

# Admin permission set (4h sessions per project TTL)
ADMIN_PS_ARN=$(aws sso-admin create-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --name NetworkingFunDevAdmin \
  --description "Admin access to networking-fun-dev - 4h sessions" \
  --session-duration PT4H \
  --region us-west-2 \
  --query 'PermissionSet.PermissionSetArn' --output text)

aws sso-admin attach-managed-policy-to-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --permission-set-arn "$ADMIN_PS_ARN" \
  --managed-policy-arn arn:aws:iam::aws:policy/AdministratorAccess \
  --region us-west-2

# Read-only permission set (handy for Ralph and demos)
RO_PS_ARN=$(aws sso-admin create-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --name NetworkingFunDevReadOnly \
  --description "Read-only access to networking-fun-dev" \
  --session-duration PT4H \
  --region us-west-2 \
  --query 'PermissionSet.PermissionSetArn' --output text)

aws sso-admin attach-managed-policy-to-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --permission-set-arn "$RO_PS_ARN" \
  --managed-policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess \
  --region us-west-2

# Assign your user to both permission sets on the dev account
for PS_ARN in "$ADMIN_PS_ARN" "$RO_PS_ARN"; do
  aws sso-admin create-account-assignment \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --target-id "$DEV_ACCOUNT_ID" \
    --target-type AWS_ACCOUNT \
    --principal-id "$USER_ID" \
    --principal-type USER \
    --permission-set-arn "$PS_ARN" \
    --region us-west-2
done
```

**Note on `<your-sso-username>`:** if you don't know it offhand, list users:

```bash
aws identitystore list-users --identity-store-id "$IDENTITY_STORE_ID" --region us-west-2 \
  --query 'Users[*].[UserName,UserId,DisplayName]' --output table
```

---

## Phase 6 — Local AWS CLI profile

- [x] Done (2026-05-25) — profiles `networking-fun-dev` and `networking-fun-dev-ro` added to `~/.aws/config`; existing `zach-sso` SSO session covered both; region-lock test confirmed (us-west-2 deny via SCP `p-XXXXXXXX`, us-east-2 success).

**CLAUDE:** Append two new profiles to `~/.aws/config` (reusing the existing
`[sso-session zach-sso]` block so the login flow is shared):

```ini
[profile networking-fun-dev]
sso_session    = zach-sso
sso_account_id = 222222222222
sso_role_name  = NetworkingFunDevAdmin
region         = us-east-2

[profile networking-fun-dev-ro]
sso_session    = zach-sso
sso_account_id = 222222222222
sso_role_name  = NetworkingFunDevReadOnly
region         = us-east-2
```

Then log in (single login covers both new profiles via the shared sso-session):

```bash
aws sso login --profile networking-fun-dev
```

**Verify:**

```bash
aws sts get-caller-identity --profile networking-fun-dev
# Account: 222222222222
# Arn:     arn:aws:sts::222222222222:assumed-role/AWSReservedSSO_NetworkingFunDevAdmin_*/<your-sso-user>
```

---

## Phase 7 — Apply Terraform bootstrap in `networking-fun-dev`

- [x] Done (2026-05-25) — 8 resources created, state migrated to S3.
- State bucket: `tfstate-networking-fun-222222222222` (versioned, SSE-S3, PAB on, 90d non-current expiration)
- OIDC provider: `arn:aws:iam::222222222222:oidc-provider/token.actions.githubusercontent.com`
- GHA role: `arn:aws:iam::222222222222:role/gha-terraform` (4h sessions, AdministratorAccess). Trust originally scoped to `repo:gillzj00/networking-fun:*`; tightened 2026-05-26 to `ref:refs/heads/main` + `environment:production` (F-01 remediation).
- Outputs saved locally to `bootstrap-outputs.json` (gitignored).
- Backend block in `bootstrap/main.tf` now uncommented with the real bucket; subsequent runs use S3 directly.

**DECISION:** First `terraform apply` against the dev account. Creates: S3 state bucket,
GitHub OIDC provider, IAM role for GitHub Actions. All cheap (<$1/mo). Confirm before
proceeding.

**CLAUDE:**

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to confirm owner_email and github_repo

cp backend.hcl.example backend.hcl
# Edit backend.hcl: replace <DEV_ACCOUNT_ID> with the real ID.
# backend.hcl is gitignored.

export AWS_PROFILE=networking-fun-dev
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
```

The backend config is supplied at init time so the account ID stays out of version
control (F-12). Subsequent `terraform init` calls in the same working directory pick up
the saved `.terraform/terraform.tfstate` automatically.

Capture outputs:

```bash
terraform output -json > ../bootstrap-outputs.json
# Keep this locally; gha_role_arn will go into GitHub Actions secrets / workflow inputs.
```

For a from-scratch bootstrap (chicken-and-egg: state bucket doesn't exist yet), comment
out the `backend "s3" {}` block in `main.tf`, apply once with local state, then
uncomment and run `terraform init -backend-config=backend.hcl -migrate-state` to push
local state into the freshly-created bucket. After that, subsequent runs just need
`terraform init -backend-config=backend.hcl`.

---

## Phase 8 — End-to-end verification

- [x] Done (2026-05-25) — all checks green: SSO works, SCP region lock active (us-west-2 deny on `ec2:DescribeInstances`), state bucket PAB on, SSE-S3 + versioning on, OIDC provider exists, GHA role exists with `AdministratorAccess` and correct trust policy.

Confirm everything fits together:

```bash
# 1. SSO session works
aws sts get-caller-identity --profile networking-fun-dev

# 2. SCP region lock is active (this should FAIL)
aws ec2 describe-instances --region us-west-2 \
  --profile networking-fun-dev
# Expected: AccessDenied with "explicit deny in a service control policy"

# 3. State bucket exists and is private
aws s3api get-public-access-block \
  --bucket "tfstate-networking-fun-$(aws sts get-caller-identity \
    --profile networking-fun-dev --query Account --output text)" \
  --profile networking-fun-dev

# 4. OIDC provider exists
aws iam list-open-id-connect-providers \
  --profile networking-fun-dev

# 5. GHA role can be described
aws iam get-role --role-name gha-terraform \
  --profile networking-fun-dev
```

Then in a throwaway PR, add a workflow that assumes the OIDC role and runs
`aws sts get-caller-identity`. If it returns `arn:aws:sts::222222222222:assumed-role/gha-terraform/...`
you're done.

---

## Phase 9 — Delegate `labs.gillzhub.com` to the dev sub-account

- [ ] Done

**YOU.** One-time manual step. Adds the NS record in the parent
`gillzhub.com` zone (management account) that delegates the
`labs.gillzhub.com` subdomain to the child zone in the
`networking-fun-dev` sub-account.

Why this is manual instead of Terraform: the parent zone lives in the
management account, where IaC currently has no cross-account role. Adding
one for a single 4-line record means widening the trust surface of the
most privileged account in the org. The tradeoff isn't worth it for a
one-time, low-churn record — re-run this phase only if the child zone is
ever re-created with new nameservers.

### Prerequisites

- The `platform/` slice creating the child zone has been applied. Capture
  the output:
  ```bash
  cd platform
  terraform output labs_zone_name_servers
  ```
  You'll get four nameservers like `ns-123.awsdns-15.com.`,
  `ns-456.awsdns-22.net.`, etc.

### Steps

1. Sign into the **management account** Identity Center session.
2. Console → Route 53 → Hosted zones → `gillzhub.com` → **Create record**.
3. Record name: `labs` (full name will be `labs.gillzhub.com`).
4. Record type: `NS`.
5. TTL: `172800` (48 h — Route 53 default for NS records).
6. Value: paste the four nameservers from `labs_zone_name_servers`, one
   per line, including the trailing dots.
7. Routing policy: Simple. **Create records**.

### Verify

From any machine with public DNS:

```bash
dig labs.gillzhub.com NS +short
```

Expect the four child-zone nameservers above (not the parent zone's
nameservers). Propagation usually takes < 60 s but can take up to 5 min.

Once `dig` returns the expected nameservers, the
`enable_acm_validation = true` follow-up PR in `platform/` will be able
to drive the wildcard ACM cert to `ISSUED`. See
[`platform/README.md`](../../platform/README.md#dns-delegation-and-wildcard-acm).

---

## Cheatsheet

| Need to... | Run |
|---|---|
| Refresh SSO | `aws sso login --profile default` |
| Check session | `aws sts get-caller-identity --profile <profile>` |
| Add a new profile | append to `~/.aws/config` (see Phase 6 template) |
| Force destroy a lab env | `/lab destroy` comment on the PR (post-platform-deploy) |
| Read CloudTrail events | `aws cloudtrail lookup-events --region us-east-2` |

## Reversal notes

- **OU / SCP / tag policy:** detach + delete is fully reversible at any time.
- **CloudTrail org trail:** deletable; SCP blocks `StopLogging` but not the management account.
- **Member account:** can be closed from the management console (Organizations → account → Close). 90-day cooling-off period before the account ID is fully released.
- **Identity Center permission sets:** delete after removing assignments.
- **Bootstrap S3 bucket:** versioned — `terraform destroy` won't empty it. Manually empty + delete if you ever tear down.

## Deferred (not in this runbook)

These are the next-tier patterns to add when budget/time allows. Each is worth ~half a day:

- **Log Archive account** — dedicated account holding the org trail's S3 bucket.
- **Security Tooling account** — GuardDuty (delegated admin) + Security Hub.
- **AWS Config + conformance pack** — strong portfolio signal but ~$2-5/mo baseline.
- **Control Tower** — managed equivalent of everything above. Don't adopt until you have a second non-trivial account.
- **Backup vault** — IAM-locked snapshots if labs ever store stateful data.
