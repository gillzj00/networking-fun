# `container-lab` — per-PR Fargate lab

One task definition and one Fargate service per PR, running the `hello`
image on the shared platform infrastructure (`lab-network` VPC and the
`networking-fun-labs` cluster, both owned by `platform/`). The module
discovers that infrastructure with data sources, so it needs nothing from
platform state — only that `platform/` has been applied.

Each scenario injects exactly one deliberate misconfiguration. Everything
else stays correct, so the probe isolates a single failure mode:

| scenario | fault | symptom |
|---|---|---|
| `happy-path` | none | task runs, HTTP checks pass |
| `sg-port-mismatch` | SG admits port 80; app listens on 8080 | task runs, HTTP times out |
| `broken-task-execution-role` | execution role missing ECR permissions | task never starts (`ResourceInitializationError`) |
| `bad-image-tag` | task definition pins a tag that does not exist | task never starts (`CannotPullContainerError`) |
| `failing-health-check` | `CMD-SHELL` health check in a scratch image (no shell) | task starts, goes `UNHEALTHY`, deployment circuit-breaks |
| `misconfigured-task-definition` | `PORT=9090` env moves the app off the SG'd port | task runs healthy, nothing answers on 8080 |

Cost: the task is the only billable resource (~1.2 cents/hr while a PR is
open). Fault scenarios that cannot stabilise trip the deployment circuit
breaker instead of relaunching doomed tasks until the TTL. Destroy-on-close
and the `AutoDelete` tag (stamped by `labs/runtime/` default tags) cover
teardown.
