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

variable "github_repository" {
  description = "GitHub repository URL the cd-portal Amplify app builds from. Requires the AWS Amplify GitHub App to already be installed/authorized for this repo (one-time manual step, see terraform/README.md) -- confirmed working for ../amplify/'s cd-website apps, not yet confirmed for this new repo."
  type        = string
  default     = "https://github.com/rchacon/cd-portal"
}

# See ../amplify/variables.tf's identical variable for the full "why a
# token is required even with the GitHub App already installed" story --
# same one-time CreateApp-webhook-registration-only credential, scope
# admin:repo_hook. Reuses the same PAT ../amplify/ uses if it has admin
# rights on rchacon/cd-portal too; otherwise this needs its own token.
variable "github_access_token" {
  description = "GitHub personal access token (classic), scope: admin:repo_hook only. One-time bootstrapping credential for CreateApp's webhook registration."
  type        = string
  sensitive   = true
}

# Cognito's own default password policy already requires this shape --
# spelled out explicitly here (rather than relying on the provider's
# implicit default) so it's visible in one place without cross-referencing
# AWS docs.
variable "cognito_password_minimum_length" {
  description = "Minimum password length enforced by the cd-portal Cognito User Pool."
  type        = number
  default     = 8
}
