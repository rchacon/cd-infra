output "cd_webapp_app_id" {
  description = "Amplify app ID for cd-webapp."
  value       = aws_amplify_app.cd_webapp.id
}

# The bare app-id domain (aws_amplify_app.cd_webapp.default_domain alone,
# e.g. "d21n7yzhk4t7yl.amplifyapp.com") 404s -- confirmed the hard way,
# after ~10 minutes chasing a phantom CloudFront propagation issue.
# Amplify's actual per-branch URL always needs the branch name prefixed
# (https://<branch>.<app-id>.amplifyapp.com/); this output includes it so
# `terraform output` hands back something directly usable instead of a
# domain suffix that silently needs manual completion.
output "cd_webapp_default_domain" {
  description = "cd-webapp's default, directly-navigable *.amplifyapp.com URL for the main branch -- useful for confirming a deploy works independent of DNS/domain-association status."
  value       = "https://${aws_amplify_branch.cd_webapp_main.branch_name}.${aws_amplify_app.cd_webapp.default_domain}"
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
  description = "cd-webapp-prod's Cognito App Client ID -- used to build the Managed Login authorize URL (also set directly as this app's own VITE_COGNITO_CLIENT_ID env var)."
  value       = aws_cognito_user_pool_client.cd_webapp_prod.id
}

output "cognito_dev_client_id" {
  description = "cd-webapp-dev's Cognito App Client ID -- for local development against http://localhost:5183/callback, sharing the same User Pool as prod."
  value       = aws_cognito_user_pool_client.cd_webapp_dev.id
}

output "cognito_domain_url" {
  description = "Cognito Managed Login's custom domain URL -- the /login, /signup, /oauth2/authorize etc. endpoints customers get redirected to."
  value       = "https://${var.cognito_domain_name}"
}
