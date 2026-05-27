resource "aws_acm_certificate" "labs_wildcard" {
  #checkov:skip=CKV2_AWS_71:Wildcard is intentional. Lab vanity URLs are pr-<N>.labs.gillzhub.com, so per-env certs would require issuing+validating a fresh cert on every PR provision. PRD §6 requires a single wildcard owned by platform/.
  domain_name       = "*.${var.labs_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "labs_wildcard_validation" {
  for_each = {
    for dvo in aws_acm_certificate.labs_wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = aws_route53_zone.labs.zone_id
}

# Gated on parent-zone NS delegation being in place. The certificate above
# can be created at any time, but ACM can only mark it ISSUED after the
# validation CNAME resolves via the public DNS chain — which requires the
# manual cross-account NS record in gillzhub.com (see platform/README.md).
# Once delegation is verified with dig, set enable_acm_validation = true
# and re-apply to let Terraform block until the cert is ISSUED.
resource "aws_acm_certificate_validation" "labs_wildcard" {
  count = var.enable_acm_validation ? 1 : 0

  certificate_arn         = aws_acm_certificate.labs_wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.labs_wildcard_validation : record.fqdn]
}
