# ---------- Lab connectivity probe ----------
#
# Lambda deployed inside the lab VPC. Synchronously invoked by the
# lab-provision workflow after `terraform apply`; result is rendered into
# the PR comment matrix and written to CloudWatch Logs.

locals {
  name_prefix = "lab-pr-${var.pr_number}-probe"
  module_tags = merge(var.tags, {
    Component  = "probe"
    AutoDelete = var.ttl_iso
  })
}

data "archive_file" "probe" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/probe.zip"
}

# ---------- IAM ----------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "probe" {
  name               = local.name_prefix
  description        = "Execution role for the lab connectivity probe Lambda."
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = local.module_tags
}

resource "aws_iam_role_policy_attachment" "basic_execution" {
  role       = aws_iam_role.probe.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.probe.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "probe" {
  statement {
    sid    = "DescribeSsmInstances"
    effect = "Allow"

    actions = [
      "ssm:DescribeInstanceInformation",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "probe" {
  name   = local.name_prefix
  role   = aws_iam_role.probe.id
  policy = data.aws_iam_policy_document.probe.json
}

# ---------- Networking ----------

resource "aws_security_group" "probe" {
  name        = local.name_prefix
  description = "Probe Lambda SG; egress to SSM endpoints only."
  vpc_id      = var.vpc_id

  tags = local.module_tags
}

resource "aws_vpc_security_group_egress_rule" "probe_to_endpoints" {
  security_group_id            = aws_security_group.probe.id
  description                  = "HTTPS to the SSM endpoint SG."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = var.endpoint_security_group_id

  tags = local.module_tags
}

# Allow probe SG -> endpoint SG so SSM endpoint accepts the probe's HTTPS calls.
resource "aws_vpc_security_group_ingress_rule" "endpoints_from_probe" {
  security_group_id            = var.endpoint_security_group_id
  description                  = "HTTPS from the probe Lambda SG."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.probe.id

  tags = local.module_tags
}

# ---------- Lambda ----------

resource "aws_cloudwatch_log_group" "probe" {
  #checkov:skip=CKV_AWS_158:Portfolio lab; AWS-managed encryption is sufficient.
  #checkov:skip=CKV_AWS_338:1-day retention bounds cost for ephemeral lab logs.
  name              = "/aws/lambda/${local.name_prefix}"
  retention_in_days = var.log_retention_days

  tags = local.module_tags
}

resource "aws_lambda_function" "probe" {
  #checkov:skip=CKV_AWS_115:Single-tenant ephemeral lab probe; reserved concurrency adds quota overhead with no benefit.
  #checkov:skip=CKV_AWS_116:Synchronous invocation only; DLQ is unused.
  #checkov:skip=CKV_AWS_117:VPC config is set explicitly below.
  #checkov:skip=CKV_AWS_173:No KMS-encrypted env vars; values are non-secret VPC/instance IDs.
  #checkov:skip=CKV_AWS_272:Code signing disproportionate for a single-tenant lab probe.
  #checkov:skip=CKV_AWS_50:X-Ray adds runtime cost with no value for a connectivity probe.
  #checkov:skip=CKV_AWS_363:Runtime pinned to python3.12; AWS guarantees patching for managed runtimes.
  function_name    = local.name_prefix
  description      = "Connectivity probe for the layered-reachability lab."
  role             = aws_iam_role.probe.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.probe.output_path
  source_code_hash = data.archive_file.probe.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      TARGET_INSTANCE_ID = var.target_instance_id
      SCENARIO           = var.scenario
    }
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.probe.id]
  }

  tags = local.module_tags

  depends_on = [
    aws_cloudwatch_log_group.probe,
    aws_iam_role_policy_attachment.basic_execution,
    aws_iam_role_policy_attachment.vpc_access,
  ]
}
