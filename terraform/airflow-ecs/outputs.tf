output "ecs_cluster_name" {
  description = "ECS cluster name, for `aws ecs describe-services`/`run-task`/`execute-command`."
  value       = aws_ecs_cluster.airflow.name
}

output "migrate_task_definition_arn" {
  description = "Task definition ARN for the one-shot migration task -- pass to `aws ecs run-task` (see terraform/README.md)."
  value       = aws_ecs_task_definition.migrate.arn
}

output "scheduler_service_name" {
  description = "ECS service name for the scheduler."
  value       = aws_ecs_service.scheduler.name
}

output "triggerer_service_name" {
  description = "ECS service name for the triggerer."
  value       = aws_ecs_service.triggerer.name
}

output "dag_processor_service_name" {
  description = "ECS service name for the dag-processor."
  value       = aws_ecs_service.dag_processor.name
}

output "api_server_service_name" {
  description = "ECS service name for the api-server."
  value       = aws_ecs_service.api_server.name
}

output "log_group_name" {
  description = "CloudWatch log group all 5 task definitions ship to (distinguished by awslogs-stream-prefix per component)."
  value       = aws_cloudwatch_log_group.airflow_ecs.name
}
