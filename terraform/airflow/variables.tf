variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

# The bucket holding ../networking's and ../rds's state, needed to read
# their outputs (private_subnet_ids, airflow_security_group_id;
# rds_address, master_user_secret_arn, rds_kms_key_arn) via
# terraform_remote_state. Same account-specific-value problem as
# backend.hcl's bucket -- supply via a gitignored terraform.tfvars (see
# terraform/README.md), not a default here.
variable "state_bucket_name" {
  description = "S3 bucket holding Terraform state for the rest of terraform/ (../bootstrap's state_bucket_name output)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type running cd-etl + watchtower. t4g.small by default -- Airflow's webserver/scheduler/triggerer all run in one `airflow standalone` process, heavier than t4g.micro's 1GiB comfortably handles; try t4g.micro later if it proves sufficient (~$6/mo vs ~$12/mo)."
  type        = string
  default     = "t4g.small"
}

variable "github_repository_owner" {
  description = "GitHub org/user that owns cd-platform, used to build the GHCR image reference (ghcr.io/<owner>/cd-etl)."
  type        = string
  default     = "rchacon"
}

variable "congress_api_key" {
  description = "API key for api.congress.gov, stored in Secrets Manager and fetched by the instance at boot. Get one at https://api.congress.gov/sign-up/."
  type        = string
  sensitive   = true
}

variable "ghcr_pat" {
  description = "GitHub Personal Access Token scoped to `read:packages` only, used to authenticate GHCR image pulls (both cd-etl's and watchtower's). Stored in Secrets Manager and fetched by the instance at boot."
  type        = string
  sensitive   = true
}

variable "airflow_metadata_db_name" {
  description = "Name of the sibling database on RDS holding Airflow's own metadata (matches local dev's docker-compose.yml). Created once manually via `CREATE DATABASE` -- RDS has no docker-entrypoint-initdb.d equivalent -- see terraform/README.md."
  type        = string
  default     = "airflow_metadata"
}
