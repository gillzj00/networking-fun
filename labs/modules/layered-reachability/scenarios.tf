# ---------- Scenario-specific resources ----------
#
# Each fault scenario flips exactly one layer. The toggles live in the
# `flags` local in main.tf; this file owns the resources that only exist
# for some scenarios.

# ---------- nacl-deny-egress ----------
#
# Custom NACL on the private subnet that allows everything inbound but
# denies everything outbound. SGs (stateful) still permit egress to the
# SSM endpoints, but the subnet boundary NACL (stateless) drops outbound
# packets — so the SSM agent and the probe Lambda fail to talk to the
# control plane even though the SGs say yes. Canonical "NACLs are
# stateless and operate independently of SGs" lesson.

resource "aws_network_acl" "deny_egress" {
  count = local.flags.deny_egress_nacl ? 1 : 0

  vpc_id     = aws_vpc.this.id
  subnet_ids = [aws_subnet.private.id]

  tags = merge(local.module_tags, {
    Name = "${local.name_prefix}-deny-egress"
  })
}

resource "aws_network_acl_rule" "ingress_allow_all" {
  #checkov:skip=CKV_AWS_229:Lab scenario deliberately allows ingress to isolate the egress-denied failure mode. Subnet has no IGW or public IPs so internet ingress is structurally impossible.
  #checkov:skip=CKV_AWS_230:Same as CKV_AWS_229; intentional for the nacl-deny-egress demo.
  #checkov:skip=CKV_AWS_231:Same as CKV_AWS_229; intentional for the nacl-deny-egress demo.
  #checkov:skip=CKV_AWS_232:Same as CKV_AWS_229; intentional for the nacl-deny-egress demo.
  #checkov:skip=CKV_AWS_352:Same as CKV_AWS_229; intentional for the nacl-deny-egress demo.
  count = local.flags.deny_egress_nacl ? 1 : 0

  network_acl_id = aws_network_acl.deny_egress[0].id
  rule_number    = 100
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

resource "aws_network_acl_rule" "egress_deny_all" {
  count = local.flags.deny_egress_nacl ? 1 : 0

  network_acl_id = aws_network_acl.deny_egress[0].id
  rule_number    = 100
  egress         = true
  protocol       = "-1"
  rule_action    = "deny"
  cidr_block     = "0.0.0.0/0"
}
