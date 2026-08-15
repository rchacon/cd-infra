output "cd_webapp_app_id" {
  description = "Amplify app ID for cd-webapp."
  value       = aws_amplify_app.cd_webapp.id
}

output "cd_webapp_default_domain" {
  description = "cd-webapp's default *.amplifyapp.com URL -- useful for confirming a deploy works independent of DNS/domain-association status."
  value       = aws_amplify_app.cd_webapp.default_domain
}

output "cd_webapp_url" {
  description = "cd-webapp's custom domain URL."
  value       = "https://app.${var.domain_name}"
}

output "cognito_user_pool_id" {
  description = "cd-webapp's Cognito User Pool ID -- consumed by cd-server's API Gateway COGNITO_USER_POOLS authorizer."
  value       = aws_cognito_user_pool.cd_webapp.id
}

output "cognito_user_pool_arn" {
  description = "cd-webapp's Cognito User Pool ARN -- consumed by cd-server's API Gateway authorizer (provider_arns)."
  value       = aws_cognito_user_pool.cd_webapp.arn
}

output "cognito_user_pool_client_id" {
  description = "cd-webapp's Cognito App Client ID -- used to build the Managed Login authorize URL (also set directly as this app's own VITE_COGNITO_CLIENT_ID env var)."
  value       = aws_cognito_user_pool_client.cd_webapp.id
}

output "cognito_domain_url" {
  description = "Cognito Managed Login's custom domain URL -- the /login, /signup, /oauth2/authorize etc. endpoints customers get redirected to."
  value       = "https://${var.cognito_domain_name}"
}
