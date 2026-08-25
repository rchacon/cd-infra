variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

# The bucket holding ../networking's, ../rds's, and ../airflow's state,
# needed to read their outputs via terraform_remote_state. Same
# account-specific-value problem as backend.hcl's bucket -- supply via a
# gitignored terraform.tfvars (see terraform/README.md), not a default
# here.
variable "state_bucket_name" {
  description = "S3 bucket holding Terraform state for the rest of terraform/ (../bootstrap's state_bucket_name output)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the ECS cluster's container instance. t3.medium by default -- bumped from ../airflow's t3.small since 4 independent processes no longer share one process's memory footprint, plus ECS agent + Service Connect sidecar overhead."
  type        = string
  default     = "t3.medium"
}

variable "github_repository_owner" {
  description = "GitHub org/user that owns cd-platform, used to build the GHCR image reference (ghcr.io/<owner>/cd-etl)."
  type        = string
  default     = "rchacon"
}

# ../bootstrap has no S3 backend at all (it's what creates the state
# bucket), so this can't be read via terraform_remote_state like
# state_bucket_name above -- copy the literal value from ../bootstrap's
# github_oidc_provider_arn output into a gitignored terraform.tfvars. Same
# pattern as ../cd-server/variables.tf's identical variable.
variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (../bootstrap's github_oidc_provider_arn output), used by airflow_deploy's IAM role trust policy."
  type        = string
}

# Same values ../cd-server/variables.tf already hardcodes as defaults --
# same repo (cd-platform), so the same immutable OIDC sub-claim IDs apply
# here too (see that file's comment for where these came from).
variable "github_owner_id" {
  description = "rchacon's numeric GitHub user ID, part of cd-platform's immutable OIDC sub claim."
  type        = string
  default     = "2160525"
}

variable "github_repo_id" {
  description = "cd-platform's numeric GitHub repository ID, part of its immutable OIDC sub claim."
  type        = string
  default     = "1309136464"
}

# Moved from ../airflow/variables.tf (cd-infra#42) alongside the
# congress_api_key secret it feeds -- get one at
# https://api.congress.gov/sign-up/.
variable "congress_api_key" {
  description = "API key for api.congress.gov, stored in Secrets Manager and fetched by the ECS instance at boot."
  type        = string
  sensitive   = true
}

# Same defaults as ../airflow/variables.tf's identical variables -- this
# module's launch template ports the same idempotent RDS bootstrap
# (airflow_metadata db + this role), so the values must match exactly or
# the bootstrap would create a second, divergent role/database.
variable "cd_etl_db_username" {
  description = "Postgres role cd-etl/Airflow connect as for ongoing runtime traffic. Must match ../airflow/variables.tf's value -- both modules' bootstraps target the same role."
  type        = string
  default     = "cd_etl_app"
}

variable "airflow_metadata_db_name" {
  description = "Name of the sibling database on RDS holding Airflow's own metadata. Must match ../airflow/variables.tf's value -- both modules' bootstraps target the same database."
  type        = string
  default     = "airflow_metadata"
}

variable "airflow_parallelism" {
  description = "AIRFLOW__CORE__PARALLELISM -- caps how many LocalExecutor worker subprocesses the scheduler spawns. See ../airflow/variables.tf's identical variable for the OOM incident that motivated capping this below Airflow's own default of 32."
  type        = number
  default     = 4
}
