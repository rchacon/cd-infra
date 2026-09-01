variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

# The bucket holding ../networking's and ../cd-api's state, needed to read
# their outputs (subnet/security-group ids; cd-api's Lambda function name)
# via terraform_remote_state. Same account-specific-value problem as
# backend.hcl's bucket -- supply via a gitignored terraform.tfvars (see
# terraform/README.md), not a default here.
variable "state_bucket_name" {
  description = "S3 bucket holding Terraform state for the rest of terraform/ (../bootstrap's state_bucket_name output)."
  type        = string
}

# ../bootstrap has no S3 backend at all (it's what creates the state
# bucket), so this can't be read via terraform_remote_state like
# state_bucket_name above -- copy the literal value from ../bootstrap's
# github_oidc_provider_arn output into a gitignored terraform.tfvars.
variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (../bootstrap's github_oidc_provider_arn output), used by cd-server-deploy's IAM role trust policy."
  type        = string
}

variable "github_repository_owner" {
  description = "GitHub org/user that owns cd-platform, used to scope the deploy IAM role's trust policy to that repo."
  type        = string
  default     = "rchacon"
}

# Same values ../cd-api/variables.tf already hardcodes as defaults -- same
# repo (cd-platform), so the same immutable OIDC sub-claim IDs apply here.
# See that file's comment for where these came from
# (`gh api repos/rchacon/cd-platform --jq '.owner.id, .id'`).
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

# Same two variables ../cd-api/../amplify already have -- this module
# needs its own Cloudflare access too, for server.civicdog.com's DNS
# validation and CNAME record. Scoped to Zone:DNS:Edit for the
# civicdog.com zone only.
variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to Zone:DNS:Edit for the civicdog.com zone only."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for civicdog.com (Cloudflare dashboard -> Overview tab, right sidebar)."
  type        = string
}

variable "server_domain_name" {
  description = "Custom domain for cd-server's ALB."
  type        = string
  default     = "server.civicdog.com"
}

variable "instance_type" {
  description = "EC2 instance type for the ECS cluster's container instance(s). t3.small (cd-infra#67): a surge deploy briefly runs two 400 MiB service tasks plus (during a release) a 400 MiB one-shot migrate task, alongside the ECS agent -- ~1.3 GiB, which a t3.micro's ~916 MiB registerable memory can't hold. The app itself is a thin FastAPI service that fit fine on t3.micro before rolling deploys."
  type        = string
  default     = "t3.small"
}

variable "instance_count" {
  description = "Number of EC2 container instances (and the ECS service's desired task count). 1 by default -- same single-instance posture as ../airflow today."
  type        = number
  default     = 1
}

variable "container_memory" {
  description = "Hard memory limit (MB) for cd-server's container. 400 leaves room on a 2GB t3.small for a second (surge) task, a one-shot migrate task during a release, and the ECS agent."
  type        = number
  default     = 400
}

# Matches cd-server/src/cd/server/settings.py's own PGDATABASE default --
# keeping this default in sync means a real deployment never needs an
# explicit override.
variable "cd_customers_db_name" {
  description = "Name of the sibling database on RDS holding cd-server's own customer data. Created idempotently by the ECS instance's first-boot bootstrap (RDS has no docker-entrypoint-initdb.d equivalent), same pattern as ../airflow's airflow_metadata_db_name."
  type        = string
  default     = "cd_customers"
}

variable "cd_server_db_username" {
  description = "Postgres role cd-server connects as for ongoing runtime traffic -- scoped to cd_customers only, never the RDS master/superuser credentials (used only transiently, by the instance's boot-time bootstrap, to create this role and grant it access). Same pattern as ../airflow's cd_etl_db_username."
  type        = string
  default     = "cd_server_app"
}
