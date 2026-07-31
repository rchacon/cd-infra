variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

# The bucket holding ../networking's and ../rds's state, needed to read
# their outputs (private_subnet_ids, lambda_security_group_id;
# rds_instance_identifier) via terraform_remote_state. Same
# account-specific-value problem as backend.hcl's bucket -- supply via a
# gitignored terraform.tfvars (see terraform/README.md), not a default
# here.
variable "state_bucket_name" {
  description = "S3 bucket holding Terraform state for the rest of terraform/ (../bootstrap's state_bucket_name output)."
  type        = string
}

# ../bootstrap has no S3 backend at all (it's what creates the state
# bucket), so this can't be read via terraform_remote_state like
# state_bucket_name above -- copy the literal value from ../bootstrap's
# github_oidc_provider_arn output into a gitignored terraform.tfvars.
variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (../bootstrap's github_oidc_provider_arn output), used by cd-api-deploy's IAM role trust policy."
  type        = string
}

variable "github_repository_owner" {
  description = "GitHub org/user that owns cd-platform, used to scope the deploy IAM role's trust policy to that repo."
  type        = string
  default     = "rchacon"
}

variable "cd_api_db_username" {
  description = "Postgres role cd-api's Lambda connects as (via RDS Proxy) for ongoing runtime traffic -- scoped to its own database, never the RDS master/superuser credentials. Bootstrapped manually (see terraform/README.md), not by Terraform."
  type        = string
  default     = "cd_api_app"
}

variable "api_key_names" {
  description = "Names of the API Gateway API keys to provision, all sharing one usage plan for now (no per-key throttle/quota differentiation yet -- that's cd-platform#13's real per-customer system). Add more by appending to this list."
  type        = list(string)
  default     = ["self"]
}

variable "stage_name" {
  description = "API Gateway deployment stage name."
  type        = string
  default     = "prod"
}

variable "lambda_memory_size" {
  description = "Lambda memory (MB). 256 is a reasonable default for a small FastAPI/Mangum app with no heavy compute."
  type        = number
  default     = 256
}

variable "lambda_timeout" {
  description = "Lambda timeout (seconds). Kept under API Gateway REST API's hard 29s integration timeout cap."
  type        = number
  default     = 25
}

variable "rds_proxy_max_connections_percent" {
  description = "Percent of RDS's max_connections the proxy's connection pool may use. Default 50 leaves headroom for cd_etl_app's direct connections from ../airflow, sharing the same small RDS instance."
  type        = number
  default     = 50
}
