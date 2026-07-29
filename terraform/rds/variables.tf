variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

# The bucket holding ../networking's state, needed to read its outputs
# (private_subnet_ids, rds_security_group_id) via terraform_remote_state.
# Same account-specific-value problem as backend.hcl's bucket -- supply via
# a gitignored terraform.tfvars (see terraform/README.md), not a default
# here.
variable "state_bucket_name" {
  description = "S3 bucket holding Terraform state for the rest of terraform/ (../bootstrap's state_bucket_name output)."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class. Cheapest Graviton burstable class by default -- this project's current data volume (a few thousand rows) doesn't need more; resize later by changing this and re-applying."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB. 20 is RDS Postgres's minimum and plenty for this project's current scale."
  type        = number
  default     = 20
}

variable "engine_version" {
  description = "Postgres major version only (e.g. \"16\") -- with auto_minor_version_upgrade on, AWS resolves this to its current latest minor automatically rather than pinning a minor version that can go stale. Matches docker-compose.yml's local-dev postgres:16 image, and clears the pgvector 15.2+ floor from cd-platform#9."
  type        = string
  default     = "16"
}

variable "master_username" {
  description = "RDS master username."
  type        = string
  default     = "cd_user"
}
