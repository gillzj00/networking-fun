"""Lab connectivity probe.

Invoked synchronously by the lab-provision workflow after `terraform apply`.
Runs a fixed matrix of reachability checks from inside the lab VPC and
returns a structured JSON result that the workflow renders into the PR
comment.

The probe is deliberately dumb: each check is a self-contained function
that returns (pass/fail, detail). New scenarios (slice 8) extend the
matrix by adding entries to PROBES.
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
TARGET_INSTANCE_ID = os.environ["TARGET_INSTANCE_ID"]
SCENARIO = os.environ.get("SCENARIO", "happy-path")

SSM = boto3.client(
    "ssm",
    region_name=REGION,
    config=Config(retries={"max_attempts": 2, "mode": "standard"}, connect_timeout=5, read_timeout=5),
)


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


# Each probe: name -> (description, callable). All run regardless of pass/fail.
PROBES: dict[str, tuple[str, Callable[[], tuple[bool, str]]]] = {
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


# happy-path expects every probe to pass.
EXPECTED_RESULTS: dict[str, dict[str, bool]] = {
    "happy-path": {name: True for name in PROBES},
}


def handler(event, context):  # noqa: ARG001 - lambda signature
    start = time.time()
    results = []
    for name, (description, fn) in PROBES.items():
        check_start = time.time()
        try:
            passed, detail = fn()
        except Exception as exc:  # noqa: BLE001 - report any failure
            passed, detail = False, f"unexpected error: {exc}"
        expected = EXPECTED_RESULTS.get(SCENARIO, {}).get(name, True)
        results.append(
            {
                "name": name,
                "description": description,
                "passed": passed,
                "expected": expected,
                "matched_expectation": passed == expected,
                "detail": detail,
                "duration_ms": int((time.time() - check_start) * 1000),
            }
        )

    summary = {
        "scenario": SCENARIO,
        "target_instance_id": TARGET_INSTANCE_ID,
        "all_passed": all(r["passed"] for r in results),
        "matched_expectation": all(r["matched_expectation"] for r in results),
        "total_duration_ms": int((time.time() - start) * 1000),
        "results": results,
    }
    LOG.info(json.dumps(summary))
    return summary
