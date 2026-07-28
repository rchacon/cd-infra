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
