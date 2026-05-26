resource "aws_route53_zone" "labs" {
  #checkov:skip=CKV2_AWS_38:DNSSEC adds KMS key + signing config + KSK rotation operational burden for a portfolio lab subdomain that does not transact value. Deferred to a later slice if needed.
  #checkov:skip=CKV2_AWS_39:Query logging adds a CloudWatch log group + CMK + steady cost for a low-traffic dev zone. Can land in a later platform-observability slice without blocking the slice 4 delegation flow.
  name    = var.labs_domain
  comment = "Delegated zone for ephemeral lab environments. Parent gillzhub.com zone lives in the management account."
}
