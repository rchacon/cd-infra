output "instance_id" {
  description = "EC2 instance ID -- use with `aws ssm start-session --target` for a shell or port-forwarding session (see terraform/README.md)."
  value       = aws_instance.airflow.id
}

output "instance_private_ip" {
  description = "Private IP of the Airflow EC2 instance, for reference/debugging."
  value       = aws_instance.airflow.private_ip
}

output "congress_api_key_secret_arn" {
  description = "Secrets Manager ARN for CONGRESS_API_KEY. Consumed by ../airflow-ecs so its ECS tasks reuse this same secret rather than provisioning a duplicate."
  value       = aws_secretsmanager_secret.congress_api_key.arn
}

output "cd_etl_app_db_secret_arn" {
  description = "Secrets Manager ARN for cd_etl_app's DB credentials. Consumed by ../airflow-ecs, both directly (ECS secrets injection) and via a live data source read (to build its own derived connection-string secrets)."
  value       = aws_secretsmanager_secret.cd_etl_app_db.arn
}

output "airflow_kms_key_arn" {
  description = "ARN of this module's customer-managed KMS key. Consumed by ../airflow-ecs so its own derived secrets reuse this key instead of provisioning a second one for the same underlying credential material."
  value       = aws_kms_key.airflow.arn
}

output "airflow_kms_alias_arn" {
  description = "ARN of this module's KMS alias. Per CLAUDE.md's alias-ARN gotcha, ../airflow-ecs's task execution role needs this granted directly (no kms:AliasName condition key exists) alongside airflow_kms_key_arn above."
  value       = aws_kms_alias.airflow.arn
}
