variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

# ../bootstrap has no S3 backend at all (it's what creates the state
# bucket), so this can't be read via terraform_remote_state -- copy the
# literal value from ../bootstrap's state_bucket_name output into a
# gitignored terraform.tfvars, same as every other module.
variable "state_bucket_name" {
  description = "S3 bucket holding Terraform state for the rest of terraform/ (../bootstrap's state_bucket_name output)."
  type        = string
}

# Scoped to "Zone:DNS:Edit" on the civicdog.com zone only (Cloudflare
# dashboard -> My Profile -> API Tokens -> Create Token -> "Edit zone DNS"
# template) -- never the legacy account-wide Global API Key. This is the
# only credential in this module that can touch civicdog.com's DNS, and it
# can only edit records, not read/change anything else about the account
# (billing, other zones, etc).
variable "cloudflare_api_token" {
  description = "Cloudflare API token scoped to Zone:DNS:Edit for the civicdog.com zone only."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for civicdog.com (Cloudflare dashboard -> Overview tab, right sidebar)."
  type        = string
}

# No default -- civicdog.com is registered outside AWS, so this can't be
# inferred from anything Terraform already manages.
variable "domain_name" {
  description = "The apex domain both Amplify apps' subdomains are provisioned under."
  type        = string
  default     = "civicdog.com"
}

variable "github_repository" {
  description = "GitHub repository URL both Amplify apps build from. Requires the AWS Amplify GitHub App to already be installed/authorized for this repo (one-time manual step, see terraform/README.md)."
  type        = string
  default     = "https://github.com/rchacon/cd-website"
}

# Confirmed via a real failed apply + AWS's own docs (Amplify user guide,
# "Setting up the Amplify GitHub App for CloudFormation, CLI, and SDK
# deployments"): CreateApp always requires a token, even with the GitHub
# App already installed and authorized -- the "zero-token" experience only
# exists inside the Console's own UI flow, which exchanges one internally
# behind the scenes. This token only needs the classic PAT scope
# `admin:repo_hook` -- it's used once at creation time purely to register
# Amplify's webhook, never to read/write repo contents (the GitHub App
# installation is what actually grants repo access).
variable "github_access_token" {
  description = "GitHub personal access token (classic), scope: admin:repo_hook only. One-time bootstrapping credential for CreateApp's webhook registration."
  type        = string
  sensitive   = true
}
