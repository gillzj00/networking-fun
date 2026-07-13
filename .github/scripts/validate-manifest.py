#!/usr/bin/env python3
"""Validate .platform/manifest.yaml against the JSON Schema and emit
workflow-ready outputs.

Outputs (to $GITHUB_OUTPUT when present, else stdout):
  lab              normalised lab name
  scenario         normalised scenario name
  ttl              original ttl string (default 4h)
  ttl_seconds      parsed ttl as seconds (int, capped at 14400)
  ttl_iso          ISO 8601 UTC timestamp of (now + ttl), Z-suffixed
  notes            free-text note (may be empty)

Exit status:
  0  manifest valid, outputs written
  1  manifest invalid or missing — workflow MUST abort before AWS calls
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

TTL_MAX_SECONDS = 4 * 3600
TTL_DEFAULT = "4h"
TTL_UNITS = {"s": 1, "m": 60, "h": 3600}
TTL_RE = re.compile(r"^([1-9][0-9]*)(s|m|h)$")

# Per-lab scenario whitelist. The schema's `scenario` enum is the union;
# this narrows it per lab. With a single lab the sets currently coincide,
# but the split stays so a second lab (EKS is v2) slots in without
# restructuring.
SCENARIOS_BY_LAB = {
    "hello-fargate": {
        "happy-path",
        "sg-port-mismatch",
        "broken-task-execution-role",
        "bad-image-tag",
        "failing-health-check",
        "misconfigured-task-definition",
    },
}


def parse_ttl(value: str) -> int:
    match = TTL_RE.match(value)
    if not match:
        raise ValueError(f"ttl {value!r} does not match <int><s|m|h>")
    quantity = int(match.group(1))
    seconds = quantity * TTL_UNITS[match.group(2)]
    if seconds > TTL_MAX_SECONDS:
        raise ValueError(
            f"ttl {value!r} exceeds the 4h cap "
            f"(parsed as {seconds}s > {TTL_MAX_SECONDS}s)"
        )
    return seconds


def emit(outputs: dict[str, str]) -> None:
    sink = os.environ.get("GITHUB_OUTPUT")
    if sink:
        with open(sink, "a", encoding="utf-8") as fh:
            for key, val in outputs.items():
                fh.write(f"{key}={val}\n")
    else:
        for key, val in outputs.items():
            print(f"{key}={val}")


def fail(message: str) -> None:
    print(f"manifest validation failed: {message}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        default=".platform/manifest.yaml",
        help="Path to the manifest YAML (default: .platform/manifest.yaml)",
    )
    parser.add_argument(
        "--schema",
        default=".platform/manifest.schema.json",
        help="Path to the JSON Schema (default: .platform/manifest.schema.json)",
    )
    parser.add_argument(
        "--now",
        default=None,
        help="ISO 8601 timestamp to use as 'now' (testing hook).",
    )
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    schema_path = Path(args.schema)

    if not manifest_path.exists():
        fail(f"{manifest_path} not found")
    if not schema_path.exists():
        fail(f"{schema_path} not found")

    try:
        raw = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        fail(f"{manifest_path} is not valid YAML: {exc}")

    if not isinstance(raw, dict):
        fail(f"{manifest_path} must contain a YAML mapping")

    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema)
    errors = sorted(validator.iter_errors(raw), key=lambda e: list(e.path))
    if errors:
        for err in errors:
            location = "/".join(str(p) for p in err.path) or "<root>"
            print(f"  - {location}: {err.message}", file=sys.stderr)
        fail(f"{len(errors)} schema violation(s)")

    lab = raw["lab"]
    scenario = raw["scenario"]
    allowed = SCENARIOS_BY_LAB.get(lab)
    if allowed is None:
        # Caught by the schema enum; defensive guard against drift.
        fail(f"unknown lab {lab!r} (schema and validator are out of sync)")
    if scenario not in allowed:
        sorted_allowed = ", ".join(sorted(allowed))
        fail(
            f"scenario {scenario!r} is not valid for lab {lab!r}; "
            f"allowed scenarios for this lab: {sorted_allowed}"
        )

    ttl = raw.get("ttl", TTL_DEFAULT)
    try:
        ttl_seconds = parse_ttl(ttl)
    except ValueError as exc:
        fail(str(exc))

    now = (
        _dt.datetime.fromisoformat(args.now.replace("Z", "+00:00"))
        if args.now
        else _dt.datetime.now(_dt.timezone.utc)
    )
    expires = now + _dt.timedelta(seconds=ttl_seconds)
    ttl_iso = expires.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    emit(
        {
            "lab": raw["lab"],
            "scenario": raw["scenario"],
            "ttl": ttl,
            "ttl_seconds": str(ttl_seconds),
            "ttl_iso": ttl_iso,
            "notes": raw.get("notes", ""),
        }
    )

    print(
        f"manifest ok: lab={raw['lab']} scenario={raw['scenario']} "
        f"ttl={ttl} expires={ttl_iso}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
