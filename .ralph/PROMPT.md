# Ralph: do the next unit of networking-fun work

You are one iteration of a loop. Do ONE logical thing, then exit. The loop
will re-invoke you for the next one — do not try to do more than one.

Each iteration, in order:
1. **Phase 0** — sweep your own PRs and merge any that are green. If you merge one, exit.
2. **Phase 1** — pick one open issue and ship a PR. Exit.
3. If neither phase had work, print `no work` and exit 0.

---

## Phase 0: merge ready PRs

Autonomous merging is authorized for this loop per the "autonomous merge
loops" exception in `~/.claude/CLAUDE.md`.

1. List your open PRs:
   `gh pr list --author "@me" --state open --json number,title,isDraft,mergeStateStatus,reviewDecision --limit 30`
2. Skip drafts. Iterate the rest from lowest number up.
3. For each candidate `$PR`:
   a. **Wait for required checks**: `gh pr checks $PR --required --watch`
      - Exit 0 → checks passed. Continue.
      - Non-zero → a required check failed. Do NOT merge. Post one PR comment
        naming the failing job (`gh pr comment $PR --body "..."`), then move
        to the next candidate. Do not attempt to fix here — that's an issue
        for Phase 1 of a later iteration.
   b. **Confirm mergeability**: `gh pr view $PR --json mergeable,mergeStateStatus,reviewDecision`
      - `mergeable == "MERGEABLE"` and `mergeStateStatus` in {`CLEAN`, `HAS_HOOKS`, `UNSTABLE`} with required checks green → merge now:
        `gh pr merge $PR --squash --delete-branch`
      - Blocked only on review → enqueue auto-merge:
        `gh pr merge $PR --auto --squash --delete-branch`
      - Anything else (dirty, behind, blocked) → skip and move on.
   c. Print one line: `PR #$PR merged` or `PR #$PR queued for auto-merge` or `PR #$PR skipped: <reason>`.
   d. **If you merged or queued a PR, exit now.** One logical thing per iteration.
4. If you reach the end of the list with no merge action, fall through to Phase 1.

### Merge hard rules
- Never `--admin` or any branch-protection override.
- Never re-run failed CI hoping it'll pass.
- Never merge a PR you didn't author.
- If the same PR is stuck on the same failing check across two iterations, stop touching it — it needs a human.

---

## Phase 1: ship one issue

### 1. Pick an issue

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
- Only if every open issue has a concrete ineligibility reason, print `no work` and exit 0.

### 2. Branch

- `git fetch origin && git checkout main && git pull --ff-only`
- New branch: `issue-<N>-<short-slug>`

### 3. Implement

- Read the issue body and any files / ADRs it references.
- Decompose into independent pieces. Dispatch sub-agents in parallel where the
  work is genuinely independent (Explore for research, general-purpose for
  multi-file edits). Do NOT serialize work that could run concurrently.
- Make small, focused commits as you go — one logical change per commit.
  No "Co-Authored-By", no conventional-commit prefixes unless the repo uses them.

### 4. Verify

- Run whatever the repo defines: `terraform validate`, `terraform fmt -check`,
  `tflint`, tests, linters. If a check fails, fix the root cause — never bypass.
- For infra changes that touch real AWS state, stop at `terraform plan` and
  include the plan output in the PR body. Do not `apply` from Ralph.

### 5. PR

- Push the branch.
- `gh pr create` with:
  - Title: short, describes the change (not the process).
  - Body: 1-paragraph summary + test plan + `Closes #<N>`.
  - `--reviewer gillzj00`
- No mention of Claude / AI / automated tooling anywhere.

### 6. Exit

Print the PR URL on its own line and stop. The outer loop handles the next
iteration. Do NOT pick up another issue in this run.

---

## Hard rules (apply to both phases)

- Never `terraform apply`, never force-push, never edit `main` directly.
- Never commit secrets. If you find one, stop and surface it.
- If you get stuck (ambiguous spec, missing access, failing check you can't
  fix), comment on the issue or PR describing what you need and exit 0. The
  loop will move on.
