output "instance_id" {
  description = "EC2 instance ID -- use with `aws ssm start-session --target` for a shell or port-forwarding session (see terraform/README.md)."
  value       = aws_instance.airflow.id
}

output "instance_private_ip" {
  description = "Private IP of the Airflow EC2 instance, for reference/debugging."
  value       = aws_instance.airflow.private_ip
}
