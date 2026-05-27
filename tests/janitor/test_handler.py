"""Unit tests for the janitor Lambda handler.

The handler scans the Resource Groups Tagging API, picks resources whose
``AutoDelete`` ISO 8601 tag is in the past, logs them, and publishes a
CloudWatch metric. Everything below mocks both AWS clients so the test
runs in under a second without any AWS credentials.

The destroy path itself is deferred (per platform/README.md "v1:
scanner-only") — these tests assert the *detection* and *reporting*
contract the destroy path will read from.
"""

from datetime import datetime, timedelta, timezone
from unittest.mock import MagicMock, patch

import pytest

import handler  # provided by conftest.py adding platform/janitor/src to sys.path


PAST = (datetime.now(tz=timezone.utc) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
FUTURE = (datetime.now(tz=timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _tagging_page(*resources):
    return {"ResourceTagMappingList": list(resources)}


def _resource(arn, tag_value):
    return {
        "ResourceARN": arn,
        "Tags": [{"Key": handler.TAG_KEY, "Value": tag_value}],
    }


@pytest.fixture
def mocked_clients():
    tagging = MagicMock()
    cloudwatch = MagicMock()

    def fake_client(name, *args, **kwargs):
        return {
            "resourcegroupstaggingapi": tagging,
            "cloudwatch": cloudwatch,
        }[name]

    with patch.object(handler.boto3, "client", side_effect=fake_client):
        yield tagging, cloudwatch


def test_expired_tag_is_detected_and_metric_emitted(mocked_clients):
    tagging, cloudwatch = mocked_clients
    expired_arn = "arn:aws:ec2:us-east-2:123456789012:instance/i-expired"
    fresh_arn = "arn:aws:ec2:us-east-2:123456789012:instance/i-fresh"

    paginator = MagicMock()
    paginator.paginate.return_value = iter(
        [_tagging_page(_resource(expired_arn, PAST), _resource(fresh_arn, FUTURE))]
    )
    tagging.get_paginator.return_value = paginator

    result = handler.lambda_handler({}, None)

    assert result["expired_count"] == 1
    assert result["invalid_count"] == 0
    assert result["by_type"] == {"ec2/instance": 1}

    cloudwatch.put_metric_data.assert_called_once()
    kwargs = cloudwatch.put_metric_data.call_args.kwargs
    assert kwargs["Namespace"] == handler.METRIC_NAMESPACE
    metrics = {m["MetricName"]: m["Value"] for m in kwargs["MetricData"]}
    assert metrics == {"ExpiredResourcesFound": 1, "InvalidAutoDeleteTags": 0}


def test_fresh_tag_is_not_listed_or_counted(mocked_clients):
    tagging, cloudwatch = mocked_clients
    paginator = MagicMock()
    paginator.paginate.return_value = iter(
        [
            _tagging_page(
                _resource("arn:aws:ec2:us-east-2:123456789012:vpc/vpc-abc", FUTURE),
                _resource("arn:aws:ec2:us-east-2:123456789012:subnet/subnet-xyz", FUTURE),
            )
        ]
    )
    tagging.get_paginator.return_value = paginator

    result = handler.lambda_handler({}, None)

    assert result["expired_count"] == 0
    assert result["by_type"] == {}
    metrics = {m["MetricName"]: m["Value"] for m in cloudwatch.put_metric_data.call_args.kwargs["MetricData"]}
    assert metrics["ExpiredResourcesFound"] == 0


def test_unparseable_tag_value_is_counted_separately(mocked_clients):
    tagging, cloudwatch = mocked_clients
    paginator = MagicMock()
    paginator.paginate.return_value = iter(
        [
            _tagging_page(
                _resource("arn:aws:s3:::tfstate-networking-fun-abc", "not-an-iso8601-string"),
                _resource("arn:aws:ec2:us-east-2:123456789012:instance/i-expired", PAST),
            )
        ]
    )
    tagging.get_paginator.return_value = paginator

    result = handler.lambda_handler({}, None)

    assert result["expired_count"] == 1
    assert result["invalid_count"] == 1
    metrics = {m["MetricName"]: m["Value"] for m in cloudwatch.put_metric_data.call_args.kwargs["MetricData"]}
    assert metrics["InvalidAutoDeleteTags"] == 1


def test_pagination_iterates_all_pages(mocked_clients):
    tagging, cloudwatch = mocked_clients
    paginator = MagicMock()
    paginator.paginate.return_value = iter(
        [
            _tagging_page(_resource("arn:aws:ec2:us-east-2:1:instance/i-1", PAST)),
            _tagging_page(_resource("arn:aws:ec2:us-east-2:1:instance/i-2", PAST)),
            _tagging_page(_resource("arn:aws:ec2:us-east-2:1:instance/i-3", FUTURE)),
        ]
    )
    tagging.get_paginator.return_value = paginator

    result = handler.lambda_handler({}, None)

    assert result["expired_count"] == 2
    assert result["by_type"] == {"ec2/instance": 2}


def test_arn_parsing_extracts_service_and_type():
    assert handler._arn_to_type("arn:aws:ec2:us-east-2:1:vpc/vpc-abc") == "ec2/vpc"
    assert handler._arn_to_type("arn:aws:s3:::my-bucket") == "s3/my-bucket"
    assert handler._arn_to_type("malformed") == "unknown"


def test_iso8601_parser_handles_z_suffix_and_offsets():
    assert handler._parse_iso8601("2026-01-02T03:04:05Z") is not None
    assert handler._parse_iso8601("2026-01-02T03:04:05+00:00") is not None
    assert handler._parse_iso8601("not-a-date") is None
    assert handler._parse_iso8601(None) is None
