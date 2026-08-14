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
  description = "EC2 instance type running cd-etl + watchtower. x86_64 (t3.small), not arm64/Graviton -- cd-etl's GHCR image is amd64-only (confirmed on a real deploy), and this instance's AMI lookup (see main.tf) matches. t3.small by default -- Airflow's webserver/scheduler/triggerer all run in one `airflow standalone` process, heavier than t3.micro's 1GiB comfortably handles; try t3.micro later if it proves sufficient (~$7.50/mo vs ~$15/mo)."
  type        = string
  default     = "t3.small"
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

variable "airflow_metadata_db_name" {
  description = "Name of the sibling database on RDS holding Airflow's own metadata (matches local dev's docker-compose.yml). Created idempotently by the instance's first-boot bootstrap (RDS has no docker-entrypoint-initdb.d equivalent) -- see terraform/README.md."
  type        = string
  default     = "airflow_metadata"
}

variable "cd_etl_db_username" {
  description = "Postgres role cd-etl/Airflow connect as for ongoing runtime traffic -- scoped to its own databases, never the RDS master/superuser credentials (which are used only transiently, by the instance's boot-time bootstrap, to create this role and grant it access)."
  type        = string
  default     = "cd_etl_app"
}

variable "airflow_parallelism" {
  description = "AIRFLOW__CORE__PARALLELISM -- caps how many LocalExecutor worker subprocesses the scheduler spawns at startup. Default of 4 is sized for this instance's t3.small (2 vCPU/1.9GiB): Airflow's own default of 32 spawns 32 idle workers at ~130MB RSS each, over 4GB of baseline commitment alone, which OOM-killed a house_votes_etl task on 2026-08-14."
  type        = number
  default     = 4
}
