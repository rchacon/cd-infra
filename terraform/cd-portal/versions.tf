terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial configuration -- bucket/key/region are supplied via `terraform
  # init -backend-config=backend.hcl` (gitignored), using the
  # state_bucket_name output from ../bootstrap. Same pattern as every other
  # module -- see ../amplify/versions.tf.
  backend "s3" {
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# No cloudflare provider yet -- this module doesn't touch DNS until the
# domain-association follow-up (see terraform/README.md's cd-portal/
# section), same staged-apply approach ../amplify/ already documents.
