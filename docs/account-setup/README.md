# networking-fun — AWS account setup runbook

**Purpose.** Convert the existing single management account (`111111111111`) into an
enterprise-shaped AWS Organization with a dedicated `networking-fun-dev` member account,
ready to receive the Terraform in [`bootstrap/`](../../bootstrap/).

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
| Budget cap | `$25` / month |
| Lab TTL | `4h` |

**How to read.** Phases are sequential. Each phase is tagged with one of:

- **YOU** — only you can do this (browser SSO, email verification, console clicks)
- **CLAUDE** — paste the phase header back into Claude and I'll run it
- **DECISION** — Claude pauses and waits for your explicit OK because the action is hard to reverse or has billing impact

Tick the checkbox at the start of each phase as you finish it.

> **Pre-public-flip TODO.** This file contains the management account ID. Before flipping
> the repo public at M1, move this file into a `.gitignore`d path or redact the IDs.

---

## Phase 0 — Refresh SSO and audit current state

- [ ] Done

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

- [ ] Done

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

- [ ] Done

**YOU:** Console-driven (the org-trail enablement step is friendlier in the console).

1. Open CloudTrail in `us-east-2` while logged in to the management account.
2. Trails → Create trail
   - Name: `org-trail`
   - Enable for all accounts in my organization: **YES**
   - Storage: new S3 bucket `aws-cloudtrail-org-111111111111-us-east-2`
   - Log file SSE: SSE-S3 (cheaper than KMS for this volume)
   - Log file validation: enabled
   - CloudWatch Logs: **disabled** (saves money; CloudTrail S3 alone is enough)
3. Events:
   - Management events: Read + Write
   - Data events: **off** (these are what blow up the bill)
   - Insights events: **off**

**Verify:**

```bash
aws cloudtrail list-trails --region us-east-2
aws cloudtrail describe-trails --trail-name-list org-trail --region us-east-2 \
  --query 'trailList[0].[Name,IsOrganizationTrail,IsMultiRegionTrail]'
```

Should return `org-trail, true, true`.

---

## Phase 3 — Create the `networking-fun-dev` member account

- [ ] Done

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

- [ ] Done

**CLAUDE:** Attach the baseline SCP and tag policy to the Workloads OU.

1. Create + attach SCP:

   ```bash
   WORKLOADS_OU_ID=<paste-from-phase-1>

   SCP_ID=$(aws organizations create-policy \
     --type SERVICE_CONTROL_POLICY \
     --name workloads-baseline \
     --description "Region lock, root deny, CloudTrail tamper-proofing" \
     --content file://docs/account-setup/policies/scp-workloads-baseline.json \
     --query 'Policy.PolicySummary.Id' --output text)

   aws organizations attach-policy --policy-id "$SCP_ID" --target-id "$WORKLOADS_OU_ID"
   ```

2. Create + attach tag policy:

   ```bash
   TAG_POLICY_ID=$(aws organizations create-policy \
     --type TAG_POLICY \
     --name require-standard-tags \
     --description "Enforce Project / Environment / ManagedBy tags" \
     --content file://docs/account-setup/policies/tag-policy.json \
     --query 'Policy.PolicySummary.Id' --output text)

   aws organizations attach-policy --policy-id "$TAG_POLICY_ID" --target-id "$WORKLOADS_OU_ID"
   ```

**YOU:** Create the $25/mo budget in the **management account** (consolidated billing).
Console is faster than CLI for this one.

1. Billing & Cost Management → Budgets → Create budget
   - Template: "Monthly cost budget"
   - Name: `networking-fun-dev-25usd`
   - Amount: `25` USD
   - Scope: Filter by `Linked Account = <DEV_ACCOUNT_ID>`
   - Alerts: 50%, 80%, 100% (actual) and 100% (forecasted) → notify `zachary.gill@hotmail.com`

**Verify guardrails work:** After Phase 6 (when you have a profile for the dev account),
this should be denied by the region-lock SCP:

```bash
aws ec2 describe-instances --region us-west-2 --profile networking-fun-dev
# Expected: AccessDenied — proves the SCP is attached
```

---

## Phase 5 — Identity Center permission sets + assignment

- [ ] Done

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

DEV_ACCOUNT_ID=<from-phase-3>

# Admin permission set (4h sessions per project TTL)
ADMIN_PS_ARN=$(aws sso-admin create-permission-set \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --name NetworkingFunDevAdmin \
  --description "Admin access to networking-fun-dev — 4h sessions" \
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

- [ ] Done

**CLAUDE:** Append two new profiles to `~/.aws/config` (reusing the existing
`[sso-session zach-sso]` block so the login flow is shared):

```ini
[profile networking-fun-dev]
sso_session    = zach-sso
sso_account_id = <DEV_ACCOUNT_ID>
sso_role_name  = NetworkingFunDevAdmin
region         = us-east-2

[profile networking-fun-dev-ro]
sso_session    = zach-sso
sso_account_id = <DEV_ACCOUNT_ID>
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
# Account: <DEV_ACCOUNT_ID>
# Arn:     arn:aws:sts::<DEV_ACCOUNT_ID>:assumed-role/AWSReservedSSO_NetworkingFunDevAdmin_*/<your-sso-user>
```

---

## Phase 7 — Apply Terraform bootstrap in `networking-fun-dev`

- [ ] Done

**DECISION:** First `terraform apply` against the dev account. Creates: S3 state bucket,
GitHub OIDC provider, IAM role for GitHub Actions. All cheap (<$1/mo). Confirm before
proceeding.

**CLAUDE:**

```bash
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to confirm owner_email and github_repo

export AWS_PROFILE=networking-fun-dev
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Capture outputs:

```bash
terraform output -json > ../bootstrap-outputs.json
# Keep this locally; gha_role_arn will go into GitHub Actions secrets / workflow inputs.
```

**Migrate state to S3** (one-time, after first apply):

```bash
# Uncomment the `backend "s3"` block at the top of bootstrap/main.tf,
# replacing <DEV_ACCOUNT_ID> with the real value.
terraform init -migrate-state
# Confirm "yes" when prompted. Local state file gets pushed into S3.
```

---

## Phase 8 — End-to-end verification

- [ ] Done

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
`aws sts get-caller-identity`. If it returns `arn:aws:sts::<DEV_ACCOUNT_ID>:assumed-role/gha-terraform/...`
you're done.

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
