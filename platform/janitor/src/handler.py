"""Janitor Lambda — scans for expired AutoDelete-tagged resources.

v1 implementation is scanner-only: it identifies AWS resources in the local
region whose ``AutoDelete`` tag value is an ISO 8601 timestamp in the past,
emits structured logs, and publishes a ``ExpiredResourcesFound`` CloudWatch
metric. Actual destruction is deferred until ``labs/runtime/`` exists
(issue #8) and can be invoked via state-aware ``terraform destroy``. See
platform/README.md for the rationale.
"""

import json
import logging
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

METRIC_NAMESPACE = "NetworkingFun/Janitor"
TAG_KEY = "AutoDelete"


def lambda_handler(event, context):
    now = datetime.now(tz=timezone.utc)

    tagging = boto3.client("resourcegroupstaggingapi")
    cloudwatch = boto3.client("cloudwatch")

    expired = []
    invalid = []
    by_type: dict[str, int] = {}

    paginator = tagging.get_paginator("get_resources")
    for page in paginator.paginate(
        TagFilters=[{"Key": TAG_KEY}],
        ResourcesPerPage=100,
    ):
        for mapping in page.get("ResourceTagMappingList", []):
            arn = mapping["ResourceARN"]
            value = _tag_value(mapping.get("Tags", []), TAG_KEY)
            if value is None:
                continue
            expires_at = _parse_iso8601(value)
            if expires_at is None:
                invalid.append({"arn": arn, "value": value})
                continue
            if expires_at <= now:
                resource_type = _arn_to_type(arn)
                expired.append(
                    {"arn": arn, "expires_at": value, "type": resource_type}
                )
                by_type[resource_type] = by_type.get(resource_type, 0) + 1

    logger.info(
        json.dumps(
            {
                "event": "scan_complete",
                "expired_count": len(expired),
                "invalid_count": len(invalid),
                "by_type": by_type,
                "expired": expired,
                "invalid": invalid,
            }
        )
    )

    cloudwatch.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "ExpiredResourcesFound",
                "Value": len(expired),
                "Unit": "Count",
                "Timestamp": now,
            },
            {
                "MetricName": "InvalidAutoDeleteTags",
                "Value": len(invalid),
                "Unit": "Count",
                "Timestamp": now,
            },
        ],
    )

    return {
        "expired_count": len(expired),
        "invalid_count": len(invalid),
        "by_type": by_type,
    }


def _tag_value(tags, key):
    for tag in tags:
        if tag.get("Key") == key:
            return tag.get("Value")
    return None


def _parse_iso8601(value):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _arn_to_type(arn):
    # arn:aws:<service>:<region>:<account>:<type-and-id>
    parts = arn.split(":", 5)
    if len(parts) < 6:
        return "unknown"
    service = parts[2]
    resource_part = parts[5].split("/", 1)[0]
    return f"{service}/{resource_part}"
