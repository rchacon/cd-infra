terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Partial configuration -- bucket/key/region are supplied via `terraform
  # init -backend-config=backend.hcl` (gitignored), using the
  # state_bucket_name output from ../bootstrap. Left empty here since the
  # bucket name is account-specific and shouldn't be hardcoded into
  # version-controlled config. `use_lockfile` (native S3 state locking,
  # Terraform >= 1.10) isn't account-specific, so it's set directly here
  # instead of routed through backend.hcl.
  backend "s3" {
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# civicdog.com's DNS stays at Cloudflare (see main.tf's top comment for why)
# -- this provider only ever touches the two subdomain/verification records
# below, never the domain's existing MX/SPF/DKIM records for its Google
# Workspace email.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
