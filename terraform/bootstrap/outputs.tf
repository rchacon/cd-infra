# This value is what every other terraform/ directory's gitignored
# backend.hcl should reference -- Terraform backend blocks can't reference
# other resources/outputs, so this is documentation of the literal value to
# copy into backend.hcl, not something consumed programmatically. Do NOT
# put this directly in a versions.tf backend "s3" {} block -- that file is
# version-controlled and the bucket name is account-specific.

output "state_bucket_name" {
  description = "S3 bucket holding Terraform state for the rest of terraform/."
  value       = aws_s3_bucket.terraform_state.bucket
}

# Same "copy the literal value, don't consume programmatically" caveat as
# state_bucket_name above -- bootstrap/ has no S3 backend at all (it's what
# creates the bucket), so this can't be read via terraform_remote_state
# either. Copy into cd-api/'s gitignored terraform.tfvars.
output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider. Consumed by #4 (cd-api)'s deploy IAM role trust policy, and reusable by any future component's deploy workflow."
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

# Not consumed by any other terraform/ directory -- this is purely for a
# human to add a scoped `sts:AssumeRole` statement (Resource = this ARN)
# to cd-terraform's own Console-managed policy (see CLAUDE.md's IAM
# section), then assume it on demand, e.g.:
#   aws sts assume-role --role-arn <this> --role-session-name observability
output "observability_readonly_role_arn" {
  description = "ARN of the read-only CloudTrail/CloudWatch/Cost Explorer role, for investigating AWS usage/billing questions. Not usable until an identity's own policy grants it sts:AssumeRole on this ARN."
  value       = aws_iam_role.observability_readonly.arn
}
