# ---------- Static lab network ----------
#
# One long-lived, free VPC for the container labs: public subnets, an IGW,
# and no NAT gateway. Fargate tasks get public IPs so they can pull from ECR
# over the internet without paying for NAT or interface endpoints. This
# replaces the ephemeral per-PR VPCs that kept hitting the 5-VPC quota.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "lab" {
  cidr_block           = var.lab_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "lab-network"
  }
}

resource "aws_default_security_group" "lab" {
  vpc_id = aws_vpc.lab.id

  # Strip default ingress/egress so anything that accidentally lands on the
  # default SG cannot talk to anything. Service SGs are the only allowed paths.

  tags = {
    Name = "lab-network-default-locked"
  }
}

resource "aws_subnet" "lab_public" {
  count = length(var.lab_public_subnet_cidrs)

  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.lab_public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "lab-network-public-${data.aws_availability_zones.available.names[count.index]}"
    Tier = "public"
  }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "lab-network-igw"
  }
}

resource "aws_route_table" "lab_public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name = "lab-network-public-rt"
  }
}

resource "aws_route_table_association" "lab_public" {
  count = length(aws_subnet.lab_public)

  subnet_id      = aws_subnet.lab_public[count.index].id
  route_table_id = aws_route_table.lab_public.id
}

# ---------- VPC Flow Logs ----------
#
# Same pattern as the lab modules: CloudWatch destination, 1-day retention.
# Near-zero cost while the network idles at zero running tasks.

resource "aws_cloudwatch_log_group" "lab_flow_logs" {
  #checkov:skip=CKV_AWS_158:Portfolio lab; AWS-managed encryption is sufficient, customer KMS adds rotation burden disproportionate to value.
  #checkov:skip=CKV_AWS_338:1-day retention bounds cost for lab traffic logs.
  name              = "/networking-fun/platform/lab-network-flow-logs"
  retention_in_days = var.lab_flow_log_retention_days
}

data "aws_iam_policy_document" "lab_flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lab_flow_logs" {
  name               = "lab-network-flow-logs"
  description        = "Role assumed by VPC Flow Logs to write into CloudWatch."
  assume_role_policy = data.aws_iam_policy_document.lab_flow_logs_assume.json
}

data "aws_iam_policy_document" "lab_flow_logs_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.lab_flow_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lab_flow_logs" {
  name   = "lab-network-flow-logs"
  role   = aws_iam_role.lab_flow_logs.id
  policy = data.aws_iam_policy_document.lab_flow_logs_write.json
}

resource "aws_flow_log" "lab" {
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.lab_flow_logs.arn
  iam_role_arn         = aws_iam_role.lab_flow_logs.arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.lab.id

  tags = {
    Name = "lab-network-flow-logs"
  }
}
