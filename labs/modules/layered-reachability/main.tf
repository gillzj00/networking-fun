# ---------- Lab #1: layered-reachability ----------
#
# Private-only VPC with one t4g.nano instance reachable through SSM via VPC
# interface endpoints. No IGW, no NAT — the happy-path lesson is "you don't
# need internet to manage instances if you have SSM endpoints." Slice 8 will
# add fault scenarios that break individual layers (NACL, endpoint, DNS).

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  name_prefix = "lab-pr-${var.pr_number}"

  module_tags = {
    Env        = "lab-pr-${var.pr_number}"
    AutoDelete = var.ttl_iso
    Lab        = "layered-reachability"
    Scenario   = var.scenario
    Terratest  = "false"
  }
}

# ---------- VPC + subnet + route table ----------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-private"
    Tier = "private"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------- Security groups ----------

resource "aws_security_group" "endpoints" {
  #checkov:skip=CKV2_AWS_5:Attached to the SSM/SSMMessages/EC2Messages VPC endpoints below.
  name        = "${local.name_prefix}-endpoints"
  description = "Allow HTTPS from the lab instance SG to the SSM family of VPC endpoints."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-endpoints"
  })
}

resource "aws_security_group" "instance" {
  name        = "${local.name_prefix}-instance"
  description = "Lab compute SG. Egress to SSM endpoints only; no ingress."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-instance"
  })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_from_instance" {
  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from the lab instance SG."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.instance.id

  tags = local.module_tags
}

resource "aws_vpc_security_group_egress_rule" "instance_to_endpoints" {
  security_group_id            = aws_security_group.instance.id
  description                  = "HTTPS to the SSM endpoint SG."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints.id

  tags = local.module_tags
}

# ---------- SSM interface endpoints ----------
#
# All three are required for SSM-without-internet:
# - ssm:           control plane (Session Manager handshake, parameters)
# - ssmmessages:   bidirectional channel for Session Manager
# - ec2messages:   instance heartbeat / agent telemetry
#
# Slice 8's missing-vpc-endpoint scenario disables one of these.

locals {
  endpoint_services = toset(["ssm", "ssmmessages", "ec2messages"])
}

resource "aws_vpc_endpoint" "ssm_family" {
  for_each = local.endpoint_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-${each.key}-endpoint"
  })
}

# ---------- IAM for SSM-attached instance ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name_prefix}-instance"
  description        = "Lab instance role; SSM-attached, no other AWS API access."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = local.module_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name_prefix}-instance"
  role = aws_iam_role.instance.name

  tags = local.module_tags
}

# ---------- EC2 instance ----------

resource "aws_instance" "lab" {
  #checkov:skip=CKV_AWS_8:Root EBS volume is the only volume; AWS-managed encryption is enabled below via root_block_device.
  #checkov:skip=CKV_AWS_79:IMDSv2 is enforced via metadata_options below; Checkov older signatures miss it.
  #checkov:skip=CKV_AWS_135:t4g.nano does not support EBS-optimized as a separate setting; Graviton instances are EBS-optimized by default.
  #checkov:skip=CKV_AWS_126:Detailed monitoring is overkill for a 4h ephemeral lab; default 5-minute CloudWatch metrics are sufficient.
  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-instance"
  })

  volume_tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-instance-root"
  })
}
