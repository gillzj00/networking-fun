# Ralph: complete the next networking-fun issue

You are one iteration of a loop. Pick ONE open issue, ship it, exit. The
loop will re-invoke you for the next one — do not try to do more than one.

## 1. Pick an issue

- `gh issue list --state open --json number,title,labels,assignees --limit 30`
- Evaluate each issue **independently**. Skip an issue only if one of these is
  true *of that issue itself*:
  - It is already assigned to someone.
  - It has a `blocked` / `wip` / `needs-triage` / `hitl` label.
  - It has its own open PR (a PR whose body contains `Closes #<this-issue-N>`
    or `Fixes #<this-issue-N>`). Check with:
    `gh issue view <N> --json closedByPullRequestsReferences --jq '[.closedByPullRequestsReferences[] | select(.state=="OPEN")] | length'`
    — a result > 0 means skip *this* issue.
- An open PR that closes a *different* issue does NOT block this one. Do not
  apply transitive "the team is busy with PR #X" reasoning. Other open PRs
  are irrelevant to your eligibility check.
- `hitl` means "human-in-the-loop required" — e.g. Loom recordings, decisions
  you can't make from a fresh context.
- Prefer issues labelled `ready`. If none, fall back to the lowest open number.
- If you are about to print "no work", first list every open issue and the
  *specific* reason it's ineligible (one of the bullet criteria above). If you
  cannot name a specific reason for each, you have an eligible issue — pick it.
- Only if every open issue has a concrete ineligibility reason, print "no work" and exit 0.

## 2. Branch

- `git fetch origin && git checkout main && git pull --ff-only`
- New branch: `issue-<N>-<short-slug>`

## 3. Implement

- Read the issue body and any files / ADRs it references.
- Decompose into independent pieces. Dispatch sub-agents in parallel where the
  work is genuinely independent (Explore for research, general-purpose for
  multi-file edits). Do NOT serialize work that could run concurrently.
- Make small, focused commits as you go — one logical change per commit.
  No "Co-Authored-By", no conventional-commit prefixes unless the repo uses them.

## 4. Verify

- Run whatever the repo defines: `terraform validate`, `terraform fmt -check`,
  `tflint`, tests, linters. If a check fails, fix the root cause — never bypass.
- For infra changes that touch real AWS state, stop at `terraform plan` and
  include the plan output in the PR body. Do not `apply` from Ralph.

## 5. PR

- Push the branch.
- `gh pr create` with:
  - Title: short, describes the change (not the process).
  - Body: 1-paragraph summary + test plan + `Closes #<N>`.
  - `--reviewer gillzj00`
- No mention of Claude / AI / automated tooling anywhere.

## 6. Exit

Print the PR URL on its own line and stop. The outer loop handles the next
iteration. Do NOT pick up another issue in this run.

## Hard rules

- Never `terraform apply`, never force-push, never merge a PR, never edit
  `main` directly.
- Never commit secrets. If you find one, stop and surface it.
- If you get stuck (ambiguous spec, missing access, failing check you can't
  fix), comment on the issue describing what you need and exit 0. The loop
  will move on.
