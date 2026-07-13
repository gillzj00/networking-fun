#!/usr/bin/env python3
"""HTTP probe for the container lab. Runs on the workflow runner after
terraform apply: waits for the per-PR ECS service to converge (or
definitively fail), then curls the task's public endpoint.

Emits a probe-matrix JSON document compatible with render-lab-comment.js:

  {
    "lab": "hello-fargate",
    "scenario": "...",
    "matched_expectation": true,
    "endpoint": "http://1.2.3.4:8080" | null,
    "results": [
      {"name", "expected", "passed", "matched_expectation", "detail", "duration_ms"},
      ...
    ]
  }

Checks fail *by design* in fault scenarios; the exit status reflects whether
reality matched the scenario's expectations, not whether checks passed.

Exit status:
  0  every check matched its expectation
  1  one or more checks did not match
  2  probe could not run (bad args, AWS CLI failure)
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

# expected outcome per check, per scenario
EXPECTATIONS = {
    "happy-path": {"task-running": True, "http-healthz": True, "http-root": True},
    "sg-port-mismatch": {"task-running": True, "http-healthz": False, "http-root": False},
    "broken-task-execution-role": {"task-running": False, "http-healthz": False, "http-root": False},
    "bad-image-tag": {"task-running": False, "http-healthz": False, "http-root": False},
    "failing-health-check": {"task-running": False, "http-healthz": False, "http-root": False},
    "misconfigured-task-definition": {"task-running": True, "http-healthz": False, "http-root": False},
}

HTTP_ATTEMPTS = 3
HTTP_TIMEOUT_S = 8
HTTP_RETRY_SLEEP_S = 5
POLL_INTERVAL_S = 10


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def aws(region: str, *args: str) -> dict:
    cmd = ["aws", "--region", region, "--output", "json", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        log(f"aws call failed: {' '.join(args)}\n{proc.stderr.strip()}")
        sys.exit(2)
    return json.loads(proc.stdout) if proc.stdout.strip() else {}


def latest_stopped_reason(region: str, cluster: str, service: str) -> str | None:
    stopped = aws(
        region, "ecs", "list-tasks",
        "--cluster", cluster, "--service-name", service,
        "--desired-status", "STOPPED",
    ).get("taskArns", [])
    if not stopped:
        return None
    tasks = aws(
        region, "ecs", "describe-tasks",
        "--cluster", cluster, "--tasks", *stopped[:5],
    ).get("tasks", [])
    if not tasks:
        return None
    task = max(tasks, key=lambda t: t.get("createdAt", ""))
    container_reasons = [c["reason"] for c in task.get("containers", []) if c.get("reason")]
    return container_reasons[0] if container_reasons else task.get("stoppedReason")


def task_public_ip(region: str, task: dict) -> str | None:
    eni_id = next(
        (d["value"]
         for a in task.get("attachments", [])
         for d in a.get("details", [])
         if d.get("name") == "networkInterfaceId"),
        None,
    )
    if not eni_id:
        return None
    enis = aws(
        region, "ec2", "describe-network-interfaces",
        "--network-interface-ids", eni_id,
    ).get("NetworkInterfaces", [])
    if not enis:
        return None
    return enis[0].get("Association", {}).get("PublicIp")


def wait_for_task(region: str, cluster: str, service: str, deadline_s: int) -> tuple[bool, str, dict | None]:
    """Poll until the service has a (healthy) RUNNING task, the deployment
    circuit-breaks, a task goes UNHEALTHY, or the deadline passes.

    Returns (passed, detail, running_task_or_None)."""
    task_def_arn = aws(
        region, "ecs", "describe-services",
        "--cluster", cluster, "--services", service,
    )["services"][0]["taskDefinition"]
    container_defs = aws(
        region, "ecs", "describe-task-definition",
        "--task-definition", task_def_arn,
    )["taskDefinition"]["containerDefinitions"]
    has_health_check = any(c.get("healthCheck") for c in container_defs)

    start = time.monotonic()
    while True:
        elapsed = int(time.monotonic() - start)

        deployment = aws(
            region, "ecs", "describe-services",
            "--cluster", cluster, "--services", service,
        )["services"][0]["deployments"][0]
        if deployment.get("rolloutState") == "FAILED":
            reason = latest_stopped_reason(region, cluster, service)
            detail = "deployment circuit breaker tripped"
            if reason:
                detail += f": {reason}"
            return False, detail, None

        running_arns = aws(
            region, "ecs", "list-tasks",
            "--cluster", cluster, "--service-name", service,
            "--desired-status", "RUNNING",
        ).get("taskArns", [])
        if running_arns:
            task = aws(
                region, "ecs", "describe-tasks",
                "--cluster", cluster, "--tasks", running_arns[0],
            )["tasks"][0]
            status = task.get("lastStatus")
            health = task.get("healthStatus", "UNKNOWN")
            log(f"t+{elapsed}s task={status} health={health}")
            if status == "RUNNING":
                if health == "UNHEALTHY":
                    return False, "task reached RUNNING but the container health check is failing", task
                if health == "HEALTHY" or not has_health_check:
                    return True, f"RUNNING after {elapsed}s", task
                # health check configured but not yet evaluated; keep polling
        else:
            log(f"t+{elapsed}s no running task yet")

        if elapsed >= deadline_s:
            reason = latest_stopped_reason(region, cluster, service)
            detail = f"no healthy running task after {deadline_s}s"
            if reason:
                detail += f" (last stopped task: {reason})"
            return False, detail, None
        time.sleep(POLL_INTERVAL_S)


def http_check(url: str, expect_body_prefix: str | None) -> tuple[bool, str, int]:
    last_detail = "no attempt made"
    duration_ms = 0
    for attempt in range(1, HTTP_ATTEMPTS + 1):
        start = time.monotonic()
        try:
            with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT_S) as resp:
                body = resp.read(512).decode("utf-8", errors="replace").strip()
                duration_ms = int((time.monotonic() - start) * 1000)
                if resp.status != 200:
                    last_detail = f"HTTP {resp.status}"
                elif expect_body_prefix and not body.startswith(expect_body_prefix):
                    last_detail = f"200 but unexpected body: {body[:120]}"
                else:
                    return True, f"200: {body[:120]}", duration_ms
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            duration_ms = int((time.monotonic() - start) * 1000)
            reason = getattr(exc, "reason", exc)
            last_detail = f"{reason} (attempt {attempt}/{HTTP_ATTEMPTS})"
        log(f"{url} attempt {attempt}/{HTTP_ATTEMPTS}: {last_detail}")
        if attempt < HTTP_ATTEMPTS:
            time.sleep(HTTP_RETRY_SLEEP_S)
    return False, last_detail, duration_ms


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--scenario", required=True, choices=sorted(EXPECTATIONS))
    parser.add_argument("--region", required=True)
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--deadline", type=int, default=300,
                        help="Seconds to wait for the service to converge or definitively fail.")
    parser.add_argument("--out", default="probe.json")
    args = parser.parse_args()

    expected = EXPECTATIONS[args.scenario]
    results = []

    wait_start = time.monotonic()
    task_ok, task_detail, task = wait_for_task(args.region, args.cluster, args.service, args.deadline)
    results.append({
        "name": "task-running",
        "expected": expected["task-running"],
        "passed": task_ok,
        "detail": task_detail,
        "duration_ms": int((time.monotonic() - wait_start) * 1000),
    })

    public_ip = task_public_ip(args.region, task) if task else None
    endpoint = f"http://{public_ip}:{args.port}" if public_ip else None
    if task and not public_ip:
        log("running task found but no public IP on its ENI")

    for name, path, body_prefix in (
        ("http-healthz", "/healthz", "ok"),
        ("http-root", "/", "hello from networking-fun"),
    ):
        if endpoint:
            passed, detail, duration_ms = http_check(endpoint + path, body_prefix)
        else:
            passed, detail, duration_ms = False, "skipped: no running task to probe", 0
        results.append({
            "name": name,
            "expected": expected[name],
            "passed": passed,
            "detail": detail,
            "duration_ms": duration_ms,
        })

    for row in results:
        row["matched_expectation"] = row["passed"] == row["expected"]
    matched = all(row["matched_expectation"] for row in results)

    report = {
        "lab": "hello-fargate",
        "scenario": args.scenario,
        "matched_expectation": matched,
        "endpoint": endpoint,
        "results": results,
    }
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
    print(json.dumps(report, indent=2))

    for row in results:
        marker = "" if row["matched_expectation"] else "  <-- MISMATCH"
        log(f"{row['name']}: expected={'pass' if row['expected'] else 'fail'} "
            f"actual={'pass' if row['passed'] else 'fail'}{marker}")
    log(f"scenario={args.scenario} matched_expectation={matched}")
    sys.exit(0 if matched else 1)


if __name__ == "__main__":
    main()
