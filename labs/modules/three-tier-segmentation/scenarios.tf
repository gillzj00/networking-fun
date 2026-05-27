# ---------- Scenario-specific resources ----------
#
# Only the resources that exist for *some* scenarios live here. The
# scenario toggles themselves are in `flags` in main.tf so the SG rules
# stay co-located with the SGs they belong to.

# ---------- nacl-stateless-return ----------
#
# Custom NACL on the db subnet. Ingress is wide open so the SSM agent
# on the db instance and inbound app→db:5432 traffic both work. Egress
# explicitly allows 443 (SSM control plane, plus db→web:443), 5432
# (peer DB, unused), and 8080 (db→app), but DENIES the Linux ephemeral
# port range 32768-60999 outbound — which is exactly where TCP
# responses to inbound connections from app and web land.
#
# Result: app→db:5432 SYN reaches db; db's SYN-ACK back to app:<eph>
# is dropped at the subnet boundary. SG (stateful) said yes; NACL
# (stateless) drops the return. Canonical AWS networking gotcha.

resource "aws_network_acl" "db_subnet" {
  count = local.flags.db_subnet_stateless_acl ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = [aws_subnet.tier["db"].id]

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-db-stateless"
  })
}

resource "aws_network_acl_rule" "db_ingress_allow_all" {
  #checkov:skip=CKV_AWS_229:Lab scenario; the db subnet has no IGW or public IPs so internet ingress is structurally impossible. Ingress is wide to isolate the demo on egress.
  #checkov:skip=CKV_AWS_230:Same as CKV_AWS_229.
  #checkov:skip=CKV_AWS_231:Same as CKV_AWS_229.
  #checkov:skip=CKV_AWS_232:Same as CKV_AWS_229.
  #checkov:skip=CKV_AWS_352:Same as CKV_AWS_229.
  count = local.flags.db_subnet_stateless_acl ? 1 : 0

  network_acl_id = aws_network_acl.db_subnet[0].id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

# Egress: allow specific service ports (so db's outbound to SSM and
# its outbound TCP-connects to web/app still work) and DENY the Linux
# ephemeral range. The egress port for a response packet is the
# *destination* of that packet — i.e. the requesting peer's ephemeral
# source port. Blocking 32768-60999 outbound therefore drops responses
# to peers but leaves db's own client-initiated traffic intact.

resource "aws_network_acl_rule" "db_egress_allow_https" {
  count = local.flags.db_subnet_stateless_acl ? 1 : 0

  network_acl_id = aws_network_acl.db_subnet[0].id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = 443
  to_port        = 443
}

resource "aws_network_acl_rule" "db_egress_allow_web_port" {
  count = local.flags.db_subnet_stateless_acl ? 1 : 0

  network_acl_id = aws_network_acl.db_subnet[0].id
  rule_number    = 110
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.tier_ports.web
  to_port        = local.tier_ports.web
}

resource "aws_network_acl_rule" "db_egress_allow_app_port" {
  count = local.flags.db_subnet_stateless_acl ? 1 : 0

  network_acl_id = aws_network_acl.db_subnet[0].id
  rule_number    = 120
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.tier_ports.app
  to_port        = local.tier_ports.app
}

resource "aws_network_acl_rule" "db_egress_allow_db_port" {
  count = local.flags.db_subnet_stateless_acl ? 1 : 0

  network_acl_id = aws_network_acl.db_subnet[0].id
  rule_number    = 130
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
  from_port      = local.tier_ports.db
  to_port        = local.tier_ports.db
}

resource "aws_network_acl_rule" "db_egress_deny_ephemeral" {
  count = local.flags.db_subnet_stateless_acl ? 1 : 0

  network_acl_id = aws_network_acl.db_subnet[0].id
  rule_number    = 200
  egress         = true
  protocol       = "tcp"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
  from_port      = 32768
  to_port        = 60999
}
