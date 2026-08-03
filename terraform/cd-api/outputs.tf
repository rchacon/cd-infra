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
  description = "S3 bucket cd-api-deploy.yml (cd-platform, not yet implemented) publishes openapi.json to."
  value       = aws_s3_bucket.openapi_spec.bucket
}

output "openapi_spec_url" {
  description = "Public HTTPS URL for the published OpenAPI spec -- what cd-website's docs app viewer will fetch."
  value       = "https://${aws_s3_bucket.openapi_spec.bucket}.s3.${var.aws_region}.amazonaws.com/openapi.json"
}
