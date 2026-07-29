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
