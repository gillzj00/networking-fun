"""Lab connectivity probe.

Invoked synchronously by the lab-provision workflow after `terraform apply`.
Runs a fixed matrix of reachability checks from inside the lab VPC and
returns a structured JSON result that the workflow renders into the PR
comment.

Two lab shapes are supported via the LAB env var:

  - layered-reachability  (default): single-instance SSM-reachability
    matrix. Each probe is a self-contained Python check that runs in
    the Lambda's own VPC ENI.

  - three-tier-segmentation: multi-instance N×N connectivity matrix.
    The Lambda fans out via SSM RunCommand to every tier instance and
    asks each to `nc -zv -w 5 <peer-ip> <peer-port>`. Pass/fail comes
    from the run-command exit code on the source instance, so the
    source SG and source-subnet NACL contribute to the result the way
    they would for any real traffic from that tier.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import time
from typing import Callable

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

REGION = os.environ["AWS_REGION"]
SCENARIO = os.environ.get("SCENARIO", "happy-path")
LAB = os.environ.get("LAB", "layered-reachability")

_BOTO_CFG = Config(
    retries={"max_attempts": 2, "mode": "standard"},
    connect_timeout=5,
    read_timeout=10,
)

SSM = boto3.client("ssm", region_name=REGION, config=_BOTO_CFG)


# ============================================================
# Lab #1: layered-reachability
# ============================================================

TARGET_INSTANCE_ID = os.environ.get("TARGET_INSTANCE_ID", "")


def _check_dns_ssm() -> tuple[bool, str]:
    """Resolve the regional SSM endpoint via VPC DNS."""
    hostname = f"ssm.{REGION}.amazonaws.com"
    try:
        addr = socket.gethostbyname(hostname)
    except socket.gaierror as exc:
        return False, f"resolve {hostname}: {exc}"
    return True, f"{hostname} -> {addr}"


def _check_dns_public() -> tuple[bool, str]:
    """Resolve a generic AWS-hosted public hostname; happy-path expects this to fail (no IGW/NAT) but DNS resolution itself should still work because VPC DNS is on."""
    hostname = "aws.amazon.com"
    try:
        addr = socket.gethostbyname(hostname)
    except socket.gaierror as exc:
        return False, f"resolve {hostname}: {exc}"
    return True, f"{hostname} -> {addr}"


def _check_ssm_api() -> tuple[bool, str]:
    """Call ssm:DescribeInstanceInformation through the VPC endpoint."""
    try:
        resp = SSM.describe_instance_information(MaxResults=20)
    except (BotoCoreError, ClientError) as exc:
        return False, f"ssm:DescribeInstanceInformation: {exc}"
    instances = resp.get("InstanceInformationList", [])
    return True, f"saw {len(instances)} instance(s)"


def _check_instance_registered() -> tuple[bool, str]:
    """Confirm the lab instance is registered with SSM (the manageable target)."""
    if not TARGET_INSTANCE_ID:
        return False, "TARGET_INSTANCE_ID not set"
    try:
        resp = SSM.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [TARGET_INSTANCE_ID]}],
        )
    except (BotoCoreError, ClientError) as exc:
        return False, f"ssm:DescribeInstanceInformation: {exc}"
    matches = resp.get("InstanceInformationList", [])
    if not matches:
        return False, f"{TARGET_INSTANCE_ID} not registered yet"
    status = matches[0].get("PingStatus", "unknown")
    return status == "Online", f"PingStatus={status}"


LAYERED_PROBES: dict[str, tuple[str, Callable[[], tuple[bool, str]]]] = {
    "dns_ssm_endpoint": (
        "Resolve ssm.<region>.amazonaws.com via VPC DNS",
        _check_dns_ssm,
    ),
    "dns_public_hostname": (
        "Resolve a public hostname (DNS works even without internet egress)",
        _check_dns_public,
    ),
    "ssm_api_reachable": (
        "Call ssm:DescribeInstanceInformation through the SSM VPC endpoint",
        _check_ssm_api,
    ),
    "instance_registered_with_ssm": (
        "Confirm the lab instance has checked in with SSM (PingStatus=Online)",
        _check_instance_registered,
    ),
}

LAYERED_EXPECTED: dict[str, dict[str, bool]] = {
    "happy-path": {name: True for name in LAYERED_PROBES},
    # NACL denies all egress at the subnet boundary. DNS to the VPC
    # resolver is intra-subnet and unaffected, so name resolution still
    # works; anything that has to leave the subnet (the SSM endpoint
    # ENIs are reached over TCP/443) is dropped statelessly.
    "nacl-deny-egress": {
        "dns_ssm_endpoint": True,
        "dns_public_hostname": True,
        "ssm_api_reachable": False,
        "instance_registered_with_ssm": False,
    },
    # The `ssm` interface endpoint is removed; ssmmessages/ec2messages
    # still exist. ssm.<region>.amazonaws.com falls through to public
    # DNS (returns a public IP that the private subnet cannot route to),
    # so DNS resolution still appears to succeed but every call to the
    # control plane fails. Net: the agent cannot register.
    "missing-vpc-endpoint": {
        "dns_ssm_endpoint": True,
        "dns_public_hostname": True,
        "ssm_api_reachable": False,
        "instance_registered_with_ssm": False,
    },
    # VPC DNS support is off, so the Amazon-provided resolver returns
    # nothing. Every check that goes through `gethostbyname` or any AWS
    # SDK call (which has to resolve an endpoint) fails.
    "dns-disabled": {
        "dns_ssm_endpoint": False,
        "dns_public_hostname": False,
        "ssm_api_reachable": False,
        "instance_registered_with_ssm": False,
    },
}


def _run_layered_reachability() -> list[dict]:
    results = []
    for name, (description, fn) in LAYERED_PROBES.items():
        check_start = time.time()
        try:
            passed, detail = fn()
        except Exception as exc:  # noqa: BLE001
            passed, detail = False, f"unexpected error: {exc}"
        expected = LAYERED_EXPECTED.get(SCENARIO, {}).get(name, True)
        results.append(
            {
                "name": name,
                "description": description,
                "source": "probe",
                "destination": "ssm-control-plane",
                "port": None,
                "passed": passed,
                "expected": expected,
                "matched_expectation": passed == expected,
                "detail": detail,
                "duration_ms": int((time.time() - check_start) * 1000),
            }
        )
    return results


# ============================================================
# Lab #2: three-tier-segmentation
# ============================================================

# Expected pass/fail for each (scenario, source, destination) triple.
# Source rows / destination columns are the three tiers; the cell is
# True when traffic in that direction should succeed on the
# destination tier's service port.
THREE_TIER_EXPECTED: dict[str, dict[str, dict[str, bool]]] = {
    # happy-path: chained SG-to-SG references.
    #   web SG accepts 0.0.0.0/0:443     → app/db can also reach web:443
    #   app SG accepts web-sg:8080       → only web reaches app:8080
    #   db  SG accepts app-sg:5432       → only app reaches db:5432
    "happy-path": {
        "web": {"app": True, "db": False},
        "app": {"web": True, "db": True},
        "db": {"web": True, "app": False},
    },
    # cidr-instead-of-sg: db SG accepts the VPC CIDR on 5432 instead of
    # the app-sg reference. web→db is now reachable (blast radius).
    "cidr-instead-of-sg": {
        "web": {"app": True, "db": True},
        "app": {"web": True, "db": True},
        "db": {"web": True, "app": False},
    },
    # nacl-stateless-return: db subnet egress NACL denies 32768-60999,
    # so the SYN-ACK from db back to app's ephemeral port is dropped.
    # SG (stateful) allowed it; NACL (stateless) doesn't see the
    # connection state. db→web:443 still works because the response
    # port is 443 (allowed), not the ephemeral range.
    "nacl-stateless-return": {
        "web": {"app": True, "db": False},
        "app": {"web": True, "db": False},
        "db": {"web": True, "app": False},
    },
    # missing-chain-link: app SG omits the web-sg:8080 ingress rule,
    # so web→app fails one hop in even though SG-to-SG chaining is
    # otherwise present.
    "missing-chain-link": {
        "web": {"app": False, "db": False},
        "app": {"web": True, "db": True},
        "db": {"web": True, "app": False},
    },
}


def _three_tier_targets() -> dict[str, dict[str, object]]:
    """Map tier -> {instance_id, private_ip, port} from env vars.

    The probe module sets TIER_TARGETS_JSON to a JSON-encoded mapping
    so a single env var carries everything the matrix needs.
    """
    raw = os.environ.get("TIER_TARGETS_JSON", "")
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except (TypeError, ValueError):
        return {}


def _wait_for_command(command_id: str, instance_id: str, deadline: float) -> tuple[int, str]:
    """Poll ssm:GetCommandInvocation until the command finishes or the deadline passes.

    Returns (exit_code, status). exit_code is the OS exit code reported
    by RunCommand (0 = pass); status is the SSM Status string ("Success",
    "Failed", "TimedOut", "Pending", "InProgress", "Cancelled",
    "Cancelling", "Delivery Timed Out", "Execution Timed Out").
    """
    while True:
        try:
            inv = SSM.get_command_invocation(CommandId=command_id, InstanceId=instance_id)
        except SSM.exceptions.InvocationDoesNotExist:
            if time.time() > deadline:
                return -1, "invocation-not-found"
            time.sleep(2)
            continue
        except (BotoCoreError, ClientError) as exc:
            return -1, f"GetCommandInvocation: {exc}"
        status = inv.get("Status", "Unknown")
        if status not in ("Pending", "InProgress", "Delayed"):
            return int(inv.get("ResponseCode", -1)), status
        if time.time() > deadline:
            return -1, f"timeout-while-{status}"
        time.sleep(2)


def _ssm_run(instance_id: str, command: str, timeout_s: int = 30) -> tuple[bool, str]:
    """Run a one-liner on an SSM-managed instance and return (passed, detail).

    Passed is True iff the command exited 0. Detail summarises the SSM
    status and any error captured along the way.
    """
    try:
        send = SSM.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [command]},
            TimeoutSeconds=timeout_s,
            CloudWatchOutputConfig={"CloudWatchOutputEnabled": False},
        )
    except (BotoCoreError, ClientError) as exc:
        return False, f"ssm:SendCommand: {exc}"
    command_id = send["Command"]["CommandId"]
    deadline = time.time() + timeout_s + 10
    exit_code, status = _wait_for_command(command_id, instance_id, deadline)
    return exit_code == 0, f"exit={exit_code} status={status}"


def _run_three_tier_segmentation() -> list[dict]:
    targets = _three_tier_targets()
    results = []
    tiers = ["web", "app", "db"]

    if not targets:
        return [
            {
                "name": "configuration",
                "description": "TIER_TARGETS_JSON env var missing or unparseable",
                "source": "probe",
                "destination": "(none)",
                "port": None,
                "passed": False,
                "expected": True,
                "matched_expectation": False,
                "detail": "set TIER_TARGETS_JSON to a JSON map of tier -> {instance_id, private_ip, port}",
                "duration_ms": 0,
            }
        ]

    expected_table = THREE_TIER_EXPECTED.get(SCENARIO, {})

    for source in tiers:
        source_meta = targets.get(source) or {}
        source_instance = source_meta.get("instance_id")
        for destination in tiers:
            if source == destination:
                continue
            dst_meta = targets.get(destination) or {}
            dst_ip = dst_meta.get("private_ip")
            dst_port = dst_meta.get("port")
            check_start = time.time()
            expected = expected_table.get(source, {}).get(destination, True)

            if not source_instance or not dst_ip or not dst_port:
                results.append(
                    {
                        "name": f"{source}_to_{destination}",
                        "description": f"TCP {source} -> {destination}:{dst_port} via nc",
                        "source": source,
                        "destination": destination,
                        "port": dst_port,
                        "passed": False,
                        "expected": expected,
                        "matched_expectation": False,
                        "detail": "missing target metadata",
                        "duration_ms": int((time.time() - check_start) * 1000),
                    }
                )
                continue

            # `nc -zv -w 5` reports exit 0 on a successful TCP connect.
            # Capture nc's exit code BEFORE running anything else, then
            # surface the output for diagnostics, then exit with the
            # captured code so SSM RunCommand reflects the actual TCP
            # result (otherwise the trailing `cat` masks nc's status and
            # every probe reports success).
            command = (
                f"nc -zv -w 5 {dst_ip} {int(dst_port)} >/tmp/nc.out 2>&1; "
                f"rc=$?; echo exit=$rc; cat /tmp/nc.out; exit $rc"
            )
            passed, detail = _ssm_run(source_instance, command, timeout_s=30)
            results.append(
                {
                    "name": f"{source}_to_{destination}",
                    "description": f"TCP {source} -> {destination}:{dst_port} via nc",
                    "source": source,
                    "destination": destination,
                    "port": dst_port,
                    "passed": passed,
                    "expected": expected,
                    "matched_expectation": passed == expected,
                    "detail": detail,
                    "duration_ms": int((time.time() - check_start) * 1000),
                }
            )

    return results


# ============================================================
# Entrypoint
# ============================================================


def handler(event, context):  # noqa: ARG001 - lambda signature
    start = time.time()
    if LAB == "three-tier-segmentation":
        results = _run_three_tier_segmentation()
    else:
        results = _run_layered_reachability()

    summary = {
        "lab": LAB,
        "scenario": SCENARIO,
        "target_instance_id": TARGET_INSTANCE_ID,
        "all_passed": all(r["passed"] for r in results),
        "matched_expectation": all(r["matched_expectation"] for r in results),
        "total_duration_ms": int((time.time() - start) * 1000),
        "results": results,
    }
    LOG.info(json.dumps(summary))
    return summary
