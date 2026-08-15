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
  # state_bucket_name output from ../bootstrap. Same pattern as every other
  # module -- see ../amplify/versions.tf.
  backend "s3" {
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# civicdog.com's DNS stays at Cloudflare -- see ../amplify/versions.tf's
# identical comment for the full Google Workspace email reasoning. This
# provider only ever touches portal.civicdog.com's own two records below.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
