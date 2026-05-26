# ---------- Janitor Lambda ----------
#
# Scheduled scanner that finds AWS resources whose `AutoDelete` tag is an
# ISO 8601 timestamp in the past. v1 is scanner-only — see handler.py and
# platform/README.md for why destruction is deferred until labs/runtime/
# exists (issue #8).

data "archive_file" "janitor" {
  type        = "zip"
  source_dir  = "${path.module}/janitor/src"
  output_path = "${path.module}/janitor.zip"
}

data "aws_iam_policy_document" "janitor_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "janitor" {
  name               = "platform-janitor"
  description        = "Execution role for the platform janitor Lambda."
  assume_role_policy = data.aws_iam_policy_document.janitor_assume.json
}

resource "aws_iam_role_policy_attachment" "janitor_basic_execution" {
  role       = aws_iam_role.janitor.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "janitor_scanner" {
  statement {
    sid    = "ReadResourceTags"
    effect = "Allow"

    actions = [
      "tag:GetResources",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "PublishMetrics"
    effect = "Allow"

    actions = ["cloudwatch:PutMetricData"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["NetworkingFun/Janitor"]
    }
  }
}

resource "aws_iam_role_policy" "janitor_scanner" {
  name   = "platform-janitor-scanner"
  role   = aws_iam_role.janitor.id
  policy = data.aws_iam_policy_document.janitor_scanner.json
}

resource "aws_cloudwatch_log_group" "janitor" {
  #checkov:skip=CKV_AWS_158:Portfolio lab; CloudWatch-managed encryption is sufficient, customer KMS adds rotation burden disproportionate to value.
  #checkov:skip=CKV_AWS_338:1-day retention bounds cost for an idle scanner that runs every 15 minutes; longer retention adds spend with no debugging value.
  name              = "/aws/lambda/platform-janitor"
  retention_in_days = var.janitor_log_retention_days
}

resource "aws_lambda_function" "janitor" {
  #checkov:skip=CKV_AWS_115:Reserved concurrent execution unnecessary for a single-tenant scanner triggered on a 15-minute schedule.
  #checkov:skip=CKV_AWS_116:DLQ omitted; CloudWatch error alarm + EventBridge built-in retries are sufficient for an idempotent scanner.
  #checkov:skip=CKV_AWS_117:Scanner only calls public AWS APIs (Resource Groups Tagging, CloudWatch). VPC attachment would add ENI cost with no security benefit.
  #checkov:skip=CKV_AWS_173:No sensitive env vars set; AWS-managed encryption on the empty config is sufficient.
  #checkov:skip=CKV_AWS_272:Code-signing config disproportionate for a portfolio Lambda built from source in this repo.
  #checkov:skip=CKV_AWS_50:X-Ray tracing not needed for a single-step scanner; structured logs + the ExpiredResourcesFound metric cover observability.
  #checkov:skip=CKV_AWS_363:Lambda runtime is python3.12, the current latest-major; pinned intentionally.
  filename         = data.archive_file.janitor.output_path
  source_code_hash = data.archive_file.janitor.output_base64sha256
  function_name    = "platform-janitor"
  description      = "Scans for expired AutoDelete-tagged resources; v1 scanner-only."
  role             = aws_iam_role.janitor.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256

  depends_on = [
    aws_cloudwatch_log_group.janitor,
    aws_iam_role_policy_attachment.janitor_basic_execution,
  ]
}

# ---------- EventBridge schedule (every 15 minutes) ----------

resource "aws_cloudwatch_event_rule" "janitor" {
  name                = "platform-janitor-schedule"
  description         = "Invoke the platform janitor Lambda every 15 minutes."
  schedule_expression = var.janitor_schedule_expression
}

resource "aws_cloudwatch_event_target" "janitor" {
  rule      = aws_cloudwatch_event_rule.janitor.name
  target_id = "platform-janitor"
  arn       = aws_lambda_function.janitor.arn
}

resource "aws_lambda_permission" "janitor_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.janitor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.janitor.arn
}

# ---------- Alerts ----------

resource "aws_sns_topic" "alerts" {
  name              = "platform-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.owner_email
}

resource "aws_cloudwatch_metric_alarm" "janitor_errors" {
  alarm_name          = "platform-janitor-errors"
  alarm_description   = "Janitor Lambda invocation errors over a 15-minute window."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 900
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.janitor.function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}
