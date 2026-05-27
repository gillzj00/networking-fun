# ---------- VPC Flow Logs ----------
#
# CloudWatch Logs destination so the PR comment can link directly into the
# log group. 1-day retention keeps cost negligible for ephemeral labs.

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_158:Portfolio lab; AWS-managed encryption is sufficient, customer KMS adds rotation burden disproportionate to value.
  #checkov:skip=CKV_AWS_338:1-day retention bounds cost for ephemeral lab logs.
  name              = "/networking-fun/lab/pr-${var.pr_number}/vpc-flow-logs"
  retention_in_days = var.flow_log_retention_days

  tags = local.module_tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name_prefix}-flow-logs"
  description        = "Role assumed by VPC Flow Logs to write into CloudWatch."
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json

  tags = local.module_tags
}

data "aws_iam_policy_document" "flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${local.name_prefix}-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs_write.json
}

resource "aws_flow_log" "vpc" {
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-flow-logs"
  })
}
