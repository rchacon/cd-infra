# One-time bootstrap: creates the S3 bucket that holds Terraform's OWN
# state for every other terraform/ directory in this repo (networking/,
# rds/, airflow/, cd-api/). State locking uses the S3 backend's native
# `use_lockfile` (Terraform >= 1.10), so no separate DynamoDB table is
# needed. Applied once, with local state -- there's nothing else yet to
# store this config's own state in. Not touched again as part of normal
# day-to-day workflow once it exists -- the GitHub OIDC provider below
# (added for #4) is a rare, deliberate exception: another account-wide
# singleton that belongs here for the same reason the state bucket does.

terraform {
  required_version = ">= 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# Bucket name includes the account ID since S3 bucket names must be
# globally unique across every AWS account, not just this one.
resource "aws_s3_bucket" "terraform_state" {
  bucket = "cd-platform-terraform-state-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Customer-managed key (rather than SSE-S3) so reading state requires both
# s3:GetObject *and* kms:Decrypt on this key -- an IAM mistake that
# over-grants one of the two isn't enough on its own to leak state
# contents, and decrypts get their own CloudTrail trail tied to this key.
resource "aws_kms_key" "terraform_state" {
  description             = "Encrypts the Terraform state bucket."
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/cd-platform-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Account-wide singleton (only one OIDC provider can exist per unique
# provider URL per account) -- lets GitHub Actions workflows assume an IAM
# role via short-lived tokens instead of long-lived AWS keys stored as
# GitHub secrets. First consumer is #4's cd-api-deploy IAM role
# (rchacon/cd-platform#29), but this provider itself is reusable by any
# future component's deploy workflow. thumbprint_list is intentionally
# omitted -- confirmed optional in the current AWS provider version, and
# hardcoding a thumbprint value here is exactly the kind of fragile,
# silently-staleable assumption this project has been burned by before
# (see the KMS alias-ARN note elsewhere in CLAUDE.md).
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Confirmed on a real apply: Terraform's schema requires a scheme in
  # `url` (validation rejects a bare hostname), but AWS strips it and
  # returns the bare hostname on read regardless -- this provider version
  # doesn't suppress that diff, causing a perpetual (and pointless, since
  # nothing depends on this resource) destroy/recreate plan without this.
  lifecycle {
    ignore_changes = [url]
  }
}

# Account-wide singleton, same rationale as the OIDC provider above --
# added to answer "what's actually generating this AWS bill/usage"
# questions (e.g. a KMS free-tier warning) via CloudTrail Event history,
# CloudWatch metrics, and Cost Explorer. Deliberately a SEPARATE role
# rather than adding these actions to the cd-terraform deployer user's own
# policy: that policy is hand-managed in the Console and built up
# empirically, one real AccessDenied error at a time, against what
# `terraform apply` actually needs (see CLAUDE.md's IAM section) --
# broadening it preemptively for unrelated read-only investigation work
# would defeat that discipline. Trusts the account root rather than a
# specific principal so any current or future in-account identity can opt
# in by adding a single `sts:AssumeRole` statement scoped to this role's
# ARN to its own policy, without this trust policy ever needing to change.
data "aws_iam_policy_document" "observability_readonly_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "observability_readonly" {
  name               = "cd-platform-observability-readonly"
  assume_role_policy = data.aws_iam_policy_document.observability_readonly_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# resources = ["*"] on all three statements isn't an over-grant -- none of
# these three read APIs support resource-level ARN scoping at all (a real
# AWS constraint, confirmed against each action's own IAM reference page,
# not an assumption). Kept to exactly the read-only actions this role's
# stated purpose needs, nothing broader (no *:Describe*/*:List* catch-all).
data "aws_iam_policy_document" "observability_readonly" {
  statement {
    sid = "CloudTrailReadOnly"
    actions = [
      "cloudtrail:LookupEvents",
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrailStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid = "CloudWatchReadOnly"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
    ]
    resources = ["*"]
  }

  # Cost Explorer additionally needs "IAM access to billing information"
  # enabled account-wide (root account -> Account -> IAM Access to Billing
  # Information) before ce:* actions work for ANY IAM identity, regardless
  # of policy -- a well-known AWS gotcha, not something this policy alone
  # can grant. If ce:GetCostAndUsage still 403s after assuming this role,
  # check that setting first before adding more IAM actions.
  statement {
    sid = "CostExplorerReadOnly"
    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
      "ce:GetDimensionValues",
      "ce:GetTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "observability_readonly" {
  name   = "cd-platform-observability-readonly"
  role   = aws_iam_role.observability_readonly.id
  policy = data.aws_iam_policy_document.observability_readonly.json
}
