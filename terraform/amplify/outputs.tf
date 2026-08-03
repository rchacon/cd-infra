output "site_app_id" {
  description = "Amplify app ID for civicdog-site."
  value       = aws_amplify_app.site.id
}

output "site_default_domain" {
  description = "civicdog-site's default *.amplifyapp.com URL -- useful for confirming a deploy works before the custom domain finishes verifying."
  value       = aws_amplify_app.site.default_domain
}

output "docs_app_id" {
  description = "Amplify app ID for civicdog-docs."
  value       = aws_amplify_app.docs.id
}

output "docs_default_domain" {
  description = "civicdog-docs's default *.amplifyapp.com URL -- useful for confirming a deploy works before the custom domain finishes verifying."
  value       = aws_amplify_app.docs.default_domain
}
