output "rds_endpoint" {
  description = "RDS instance endpoint (host:port). Consumed by #3 (Airflow EC2) and #4 (cd-api Lambda)."
  value       = aws_db_instance.this.endpoint
}

output "rds_address" {
  description = "RDS instance hostname only (no port)."
  value       = aws_db_instance.this.address
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret ARN holding the RDS-managed master password."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "rds_kms_key_arn" {
  description = "ARN of the KMS key encrypting both RDS storage and the master-user secret above. Consumed by #3 (Airflow EC2) so its instance role can be granted kms:Decrypt on this specific key."
  value       = aws_kms_key.rds.arn
}

output "rds_instance_identifier" {
  description = "RDS instance identifier. Consumed by #4 (cd-api) for aws_db_proxy_target's db_instance_identifier."
  value       = aws_db_instance.this.identifier
}
