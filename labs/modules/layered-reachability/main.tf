# ---------- Lab #1: layered-reachability ----------
#
# Private-only VPC with one t4g.nano instance reachable through SSM via VPC
# interface endpoints. No IGW, no NAT — the happy-path lesson is "you don't
# need internet to manage instances if you have SSM endpoints." The three
# fault scenarios (nacl-deny-egress, missing-vpc-endpoint, dns-disabled)
# each break one layer; see scenarios.tf and labs/README.md.

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
  }

  # Per-scenario toggles. Each fault scenario flips exactly one layer so
  # the probe matrix points at a single cause. See labs/README.md for the
  # lesson tied to each scenario.
  scenario_flags = {
    "happy-path" = {
      vpc_dns             = true
      create_ssm_endpoint = true
      private_dns         = true
      deny_egress_nacl    = false
    }
    "nacl-deny-egress" = {
      vpc_dns             = true
      create_ssm_endpoint = true
      private_dns         = true
      deny_egress_nacl    = true
    }
    "missing-vpc-endpoint" = {
      vpc_dns             = true
      create_ssm_endpoint = false
      private_dns         = true
      deny_egress_nacl    = false
    }
    "dns-disabled" = {
      vpc_dns             = false
      create_ssm_endpoint = true
      private_dns         = false
      deny_egress_nacl    = false
    }
  }

  flags = local.scenario_flags[var.scenario]
}

# ---------- VPC + subnet + route table ----------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = local.flags.vpc_dns
  enable_dns_hostnames = local.flags.vpc_dns

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # Strip default ingress/egress so anything that accidentally lands on the
  # default SG cannot talk to anything. Lab SGs below are the only allowed paths.

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-default-locked"
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

# Separate subnet for the SSM interface endpoint ENIs. NACLs only filter
# traffic that crosses a subnet boundary, so the nacl-deny-egress scenario
# would be a no-op if the Lambda and the endpoints shared a subnet —
# packets between same-subnet ENIs never hit the NACL. Splitting them
# means Lambda→endpoint really does cross the subnet boundary and the
# deny-egress rule on the compute subnet can drop it.
resource "aws_subnet" "endpoints" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.endpoint_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-endpoints"
    Tier = "endpoints"
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

resource "aws_route_table_association" "endpoints" {
  subnet_id      = aws_subnet.endpoints.id
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
# The missing-vpc-endpoint scenario drops the `ssm` endpoint so the agent
# cannot reach the control plane; the other two stay so the failure is
# pinned to a single missing endpoint rather than a blanket teardown.
# The dns-disabled scenario keeps the endpoints but flips
# private_dns_enabled off, so the regional hostnames no longer resolve
# to the endpoint ENIs.

locals {
  endpoint_services = local.flags.create_ssm_endpoint ? toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
    ]) : toset([
    "ssmmessages",
    "ec2messages",
  ])
}

resource "aws_vpc_endpoint" "ssm_family" {
  for_each = local.endpoint_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.endpoints.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = local.flags.private_dns

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
