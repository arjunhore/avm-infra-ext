output "acm_certificate_arn" {
  description = "The ARN of the ACM certificate."
  value       = module.acm_certificate.acm_certificate_arn
}

output "web_acl_cloudfront_arn" {
  description = "The ARN of the WAFv2 Web ACL."
  value       = aws_wafv2_web_acl.web_acl_cloudfront.arn
}
