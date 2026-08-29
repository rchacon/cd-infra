terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 6.13 (not the ~> 5.0 every other root here still uses): the
      # aws_cognito_managed_login_branding resource cd-infra#31 adds can't
      # be read reliably on a user pool with more than one app client --
      # which this module's pool has (cd-webapp-prod + cd-webapp-dev, #29)
      # -- until provider v6.13.0's fix for
      # hashicorp/terraform-provider-aws#44188. The 6.13 floor is load-
      # bearing, not cosmetic: a bare ~> 6.0 would let `init` (without the
      # committed lock) or a lock regen resolve to a 6.0-6.12 provider
      # that still has the bug. No 5.x -> 6.x breaking changes touch any
      # resource in this module (Cognito/ACM/Amplify are all unaffected
      # per the v6 upgrade guide; the new per-resource `region` attribute
      # is optional and backward-compatible).
      version = "~> 6.13"
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

# Cognito Managed Login custom domains are backed by CloudFront, same as
# API Gateway's EDGE endpoints -- see ../cd-api/versions.tf's identical
# alias/comment. Confirmed via AWS's own aws_cognito_user_pool_domain docs,
# not just the API Gateway analogy. Used only by the auth.civicdog.com
# certificate resources below.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# civicdog.com's DNS stays at Cloudflare -- see ../amplify/versions.tf's
# identical comment for the full Google Workspace email reasoning. This
# provider only ever touches app.civicdog.com's own two records below.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
