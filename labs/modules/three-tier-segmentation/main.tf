# ---------- Lab #2: three-tier-segmentation ----------
#
# Canonical web/app/db topology built around chained SG-to-SG references.
# Happy path: web SG accepts 443 from anywhere (simulated ALB), app SG
# accepts 8080 from web SG, db SG accepts 5432 from app SG. The probe
# Lambda fans out via SSM RunCommand to every tier instance and produces
# an N×N connectivity matrix; the PR comment renders the grid coloured
# by per-scenario expectations.
#
# Fault scenarios (see scenarios.tf and labs/README.md):
#   - cidr-instead-of-sg:  db SG allows the VPC CIDR instead of app-sg.
#                          Probes still pass, but web→db now succeeds —
#                          the lesson is blast radius.
#   - nacl-stateless-return: custom NACL on the db subnet denies the
#                          ephemeral return port range outbound. SG
#                          (stateful) says yes to app→db:5432; NACL
#                          (stateless) drops the SYN-ACK back to app.
#   - missing-chain-link:  app SG omits the 8080 ingress from web SG.
#                          web→app fails one hop in.

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
  tiers       = ["web", "app", "db"]

  module_tags = {
    Env        = "lab-pr-${var.pr_number}"
    AutoDelete = var.ttl_iso
    Lab        = "three-tier-segmentation"
    Scenario   = var.scenario
    Terratest  = "false"
  }

  # Per-scenario toggles. Each fault scenario flips exactly one layer so
  # the probe matrix points at a single cause. happy-path is all-on.
  scenario_flags = {
    "happy-path" = {
      db_inbound_by_cidr      = false
      db_subnet_stateless_acl = false
      app_inbound_from_web    = true
    }
    "cidr-instead-of-sg" = {
      db_inbound_by_cidr      = true
      db_subnet_stateless_acl = false
      app_inbound_from_web    = true
    }
    "nacl-stateless-return" = {
      db_inbound_by_cidr      = false
      db_subnet_stateless_acl = true
      app_inbound_from_web    = true
    }
    "missing-chain-link" = {
      db_inbound_by_cidr      = false
      db_subnet_stateless_acl = false
      app_inbound_from_web    = false
    }
  }

  flags = local.scenario_flags[var.scenario]

  # Application listening ports per tier. The probe matrix tests every
  # (source, destination) pair at the destination tier's port.
  tier_ports = {
    web = 443
    app = 8080
    db  = 5432
  }
}

# ---------- VPC + per-tier subnets + route table ----------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # Strip default ingress/egress; lab SGs below are the only allowed paths.

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-default-locked"
  })
}

resource "aws_subnet" "tier" {
  for_each = toset(local.tiers)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.subnet_cidrs[each.key]
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-${each.key}"
    Tier = each.key
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-private-rt"
  })
}

resource "aws_route_table_association" "tier" {
  for_each = aws_subnet.tier

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ---------- Per-tier SGs (chained via SG-to-SG references in rules) ----------

resource "aws_security_group" "tier" {
  #checkov:skip=CKV2_AWS_5:Attached via aws_instance.tier's vpc_security_group_ids; checkov's static analysis doesn't trace SG attachment through for_each.
  for_each = toset(local.tiers)

  name        = "${local.name_prefix}-${each.key}-sg"
  description = "${each.key} tier SG."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-${each.key}-sg"
    Tier = each.key
  })
}

resource "aws_security_group" "endpoints" {
  #checkov:skip=CKV2_AWS_5:Attached to the SSM/SSMMessages/EC2Messages VPC endpoints below.
  name        = "${local.name_prefix}-endpoints-sg"
  description = "SG for SSM family VPC endpoints. Accepts 443 from every tier SG and the probe SG."
  vpc_id      = aws_vpc.this.id

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-endpoints-sg"
  })
}

# ---------- Ingress rules ----------

# Web tier — simulated public ingress on 443.
resource "aws_vpc_security_group_ingress_rule" "web_inbound" {
  #checkov:skip=CKV_AWS_260:Web tier deliberately accepts 0.0.0.0/0:443 to simulate ALB ingress. No public IPs; practical exposure stays VPC-internal.
  security_group_id = aws_security_group.tier["web"].id
  description       = "Simulated ALB ingress on 443."
  ip_protocol       = "tcp"
  from_port         = local.tier_ports.web
  to_port           = local.tier_ports.web
  cidr_ipv4         = "0.0.0.0/0"

  tags = local.module_tags
}

# App tier — chained from web SG. The missing-chain-link scenario omits
# this rule so web→app:8080 fails one hop in.
resource "aws_vpc_security_group_ingress_rule" "app_inbound_from_web" {
  count = local.flags.app_inbound_from_web ? 1 : 0

  security_group_id            = aws_security_group.tier["app"].id
  description                  = "App tier inbound 8080 from web SG (chained)."
  ip_protocol                  = "tcp"
  from_port                    = local.tier_ports.app
  to_port                      = local.tier_ports.app
  referenced_security_group_id = aws_security_group.tier["web"].id

  tags = local.module_tags
}

# DB tier — happy-path uses chained reference to the app SG; the
# cidr-instead-of-sg scenario swaps in a VPC-CIDR allow instead, which
# accidentally also lets web reach the DB.
resource "aws_vpc_security_group_ingress_rule" "db_inbound_from_app" {
  count = local.flags.db_inbound_by_cidr ? 0 : 1

  security_group_id            = aws_security_group.tier["db"].id
  description                  = "DB tier inbound 5432 from app SG (chained)."
  ip_protocol                  = "tcp"
  from_port                    = local.tier_ports.db
  to_port                      = local.tier_ports.db
  referenced_security_group_id = aws_security_group.tier["app"].id

  tags = local.module_tags
}

resource "aws_vpc_security_group_ingress_rule" "db_inbound_by_cidr" {
  count = local.flags.db_inbound_by_cidr ? 1 : 0

  security_group_id = aws_security_group.tier["db"].id
  description       = "DB tier inbound 5432 from the VPC CIDR (over-broad; lets web reach db)."
  ip_protocol       = "tcp"
  from_port         = local.tier_ports.db
  to_port           = local.tier_ports.db
  cidr_ipv4         = var.vpc_cidr

  tags = local.module_tags
}

# Endpoint SG inbound — accept HTTPS from every tier SG. The probe SG
# is added by the probe module via var.endpoint_security_group_id.
resource "aws_vpc_security_group_ingress_rule" "endpoints_from_tier" {
  for_each = aws_security_group.tier

  security_group_id            = aws_security_group.endpoints.id
  description                  = "HTTPS from ${each.key} tier SG."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = each.value.id

  tags = local.module_tags
}

# ---------- Egress rules ----------
#
# Each tier SG egresses to the SSM endpoint SG (SSM agent + RunCommand)
# and to every other tier SG on the destination tier's service port.
# Egress is broad enough that the probe matrix only exposes ingress,
# NACL, or chain-link failures — never an egress-side restriction.

resource "aws_vpc_security_group_egress_rule" "tier_to_endpoints" {
  for_each = aws_security_group.tier

  security_group_id            = each.value.id
  description                  = "HTTPS to the SSM endpoint SG (control plane)."
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.endpoints.id

  tags = local.module_tags
}

resource "aws_vpc_security_group_egress_rule" "tier_to_peer" {
  for_each = {
    for pair in setproduct(local.tiers, local.tiers) :
    "${pair[0]}_to_${pair[1]}" => { src = pair[0], dst = pair[1] }
    if pair[0] != pair[1]
  }

  security_group_id            = aws_security_group.tier[each.value.src].id
  description                  = "Egress from ${each.value.src} SG to ${each.value.dst} SG on ${each.value.dst} service port."
  ip_protocol                  = "tcp"
  from_port                    = local.tier_ports[each.value.dst]
  to_port                      = local.tier_ports[each.value.dst]
  referenced_security_group_id = aws_security_group.tier[each.value.dst].id

  tags = local.module_tags
}

# ---------- SSM interface endpoints ----------

locals {
  endpoint_services = toset(["ssm", "ssmmessages", "ec2messages"])
}

resource "aws_vpc_endpoint" "ssm_family" {
  for_each = local.endpoint_services

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.tier["app"].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-${each.key}-endpoint"
  })
}

# ---------- IAM for SSM-attached instances ----------

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

# ---------- EC2 instances (one per tier) ----------

resource "aws_instance" "tier" {
  #checkov:skip=CKV_AWS_8:Root EBS volume only; AWS-managed encryption enabled below.
  #checkov:skip=CKV_AWS_79:IMDSv2 enforced via metadata_options.
  #checkov:skip=CKV_AWS_135:t4g.nano is EBS-optimized by default.
  #checkov:skip=CKV_AWS_126:Detailed monitoring overkill for 4h ephemeral lab.
  for_each = aws_subnet.tier

  ami                         = data.aws_ami.al2023_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = each.value.id
  vpc_security_group_ids      = [aws_security_group.tier[each.key].id]
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
    Name = "${local.name_prefix}-${each.key}"
    Tier = each.key
  })

  volume_tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-${each.key}-root"
  })
}
