output "lambda_function_name" {
  description = "Name of the cd-api Lambda function."
  value       = aws_lambda_function.cd_api.function_name
}

output "api_gateway_invoke_url" {
  description = "Base invoke URL for the cd-api API Gateway stage."
  value       = aws_api_gateway_stage.cd_api.invoke_url
}

output "cd_api_app_db_password" {
  description = "cd_api_app's Terraform-generated Postgres password. Needed once for the manual DB-role bootstrap step (see terraform/README.md) -- pull via `terraform output -raw cd_api_app_db_password`, never store elsewhere."
  value       = random_password.cd_api_app.result
  sensitive   = true
}

output "openapi_spec_bucket_name" {
  description = "S3 bucket cd-api-deploy.yml (cd-platform) publishes openapi.json to."
  value       = aws_s3_bucket.openapi_spec.bucket
}

output "openapi_spec_url" {
  description = "Public HTTPS URL for the published OpenAPI spec -- what cd-website's docs app viewer will fetch."
  value       = "https://${aws_s3_bucket.openapi_spec.bucket}.s3.${var.aws_region}.amazonaws.com/openapi.json"
}

output "api_custom_domain_url" {
  description = "cd-api's custom domain base URL, v1 base path included."
  value       = "https://${aws_api_gateway_domain_name.cd_api.domain_name}/${local.api_base_path}"
}

output "origin_secret_arn" {
  description = "Secrets Manager ARN of the API Gateway -> cd-server origin secret. ../cd-server injects it as CD_API_ORIGIN_SECRET; no consumer needs the plaintext outside this stack."
  value       = aws_secretsmanager_secret.origin_secret.arn
}

output "kms_key_arn" {
  description = "cd-api's KMS key, which encrypts origin_secret -- ../cd-server's task execution role needs kms:Decrypt on it to resolve CD_API_ORIGIN_SECRET."
  value       = aws_kms_key.cd_api.arn
}
