output "cd_portal_app_id" {
  description = "Amplify app ID for cd-portal."
  value       = aws_amplify_app.cd_portal.id
}

output "cd_portal_default_domain" {
  description = "cd-portal's default *.amplifyapp.com URL -- useful for confirming a deploy works independent of DNS/domain-association status."
  value       = aws_amplify_app.cd_portal.default_domain
}

output "cd_portal_url" {
  description = "cd-portal's custom domain URL."
  value       = "https://portal.${var.domain_name}"
}

output "cognito_user_pool_id" {
  description = "cd-portal's Cognito User Pool ID -- consumed by cd-server's API Gateway COGNITO_USER_POOLS authorizer."
  value       = aws_cognito_user_pool.cd_portal.id
}

output "cognito_user_pool_arn" {
  description = "cd-portal's Cognito User Pool ARN -- consumed by cd-server's API Gateway authorizer (provider_arns)."
  value       = aws_cognito_user_pool.cd_portal.arn
}

output "cognito_user_pool_client_id" {
  description = "cd-portal's Cognito App Client ID -- consumed by the frontend's Amplify Auth config (also set directly as this app's own VITE_COGNITO_CLIENT_ID env var)."
  value       = aws_cognito_user_pool_client.cd_portal.id
}
