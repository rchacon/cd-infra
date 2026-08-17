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

# Just one region -- unlike ../cd-api/../cd-webapp, this directory's ACM
# certificate doesn't need a us-east-1 alias. Those two are CloudFront-
# backed custom domains (API Gateway EDGE, Amplify/Cognito Managed Login),
# which require ACM certs in us-east-1 regardless of the resource's own
# region. An ALB is regional -- its certificate has to be issued in the
# same region as the ALB itself, which is var.aws_region here.
provider "aws" {
  region = var.aws_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
