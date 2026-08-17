output "alb_dns_name" {
  description = "ALB's own DNS name -- what server.civicdog.com's CNAME points at."
  value       = aws_lb.cd_server.dns_name
}

output "ecs_cluster_name" {
  description = "ECS cluster name, for `aws ecs describe-services`/`aws ecs execute-command`."
  value       = aws_ecs_cluster.cd_server.name
}

output "ecs_service_name" {
  description = "ECS service name, for `aws ecs describe-services`/`aws ecs update-service`."
  value       = aws_ecs_service.cd_server.name
}

output "server_domain_url" {
  description = "cd-server's custom domain base URL."
  value       = "https://${var.server_domain_name}"
}

output "cd_server_deploy_role_arn" {
  description = "ARN of the GitHub OIDC deploy role -- what a future cd-server-deploy.yml step would assume to call ecs:UpdateService/DescribeServices (see main.tf's comment on why that workflow step isn't wired up yet)."
  value       = aws_iam_role.cd_server_deploy.arn
}
