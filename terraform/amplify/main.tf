# civicdog.com's DNS is hosted at Cloudflare (where the domain is
# registered), not Route53 -- the domain has an active Google Workspace
# email integration (MX/SPF/DKIM records set up via Cloudflare's one-click
# app) that isn't fully visible/reproducible by hand, so migrating DNS
# hosting elsewhere risked silently breaking email for no real benefit.
# This module never reads or touches those records: it only ever creates
# the two new subdomain + certificate-verification records Amplify needs,
# via the Cloudflare provider below.

# --- civicdog-site (civicdog.com, www.civicdog.com) ----------------------

resource "aws_amplify_app" "site" {
  name       = "civicdog-site"
  repository = var.github_repository
  platform   = "WEB"

  # Monorepo support: no access_token/oauth_token set here on purpose --
  # this relies on the AWS Amplify GitHub App already being authorized for
  # this repo at the account level (one-time manual step, see
  # terraform/README.md). AMPLIFY_MONOREPO_APP_ROOT tells Amplify which
  # subdirectory to build from and where to find that app's own
  # amplify.yml; no build_spec override needed here as a result.
  environment_variables = {
    AMPLIFY_MONOREPO_APP_ROOT = "apps/site"
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_amplify_branch" "site_main" {
  app_id      = aws_amplify_app.site.id
  branch_name = "main"

  enable_auto_build = true
  stage             = "PRODUCTION"

  tags = {
    Project = "cd-platform"
  }
}

# wait_for_verification = false: this resource's own outputs
# (certificate_verification_dns_record, sub_domain[*].dns_record) are what
# the Cloudflare records below are built from, so the records this
# association needs to verify against don't exist yet at the moment this
# resource itself is created -- waiting here would deadlock (or just time
# out) against DNS that hasn't been created yet. Verification happens
# asynchronously in AWS's backend once the Cloudflare records exist; check
# actual status via the Amplify console or a follow-up `terraform plan`
# rather than trusting apply's exit code alone for this one resource.
resource "aws_amplify_domain_association" "site" {
  app_id                = aws_amplify_app.site.id
  domain_name           = var.domain_name
  wait_for_verification = false

  sub_domain {
    branch_name = aws_amplify_branch.site_main.branch_name
    prefix      = ""
  }

  sub_domain {
    branch_name = aws_amplify_branch.site_main.branch_name
    prefix      = "www"
  }
}

# --- civicdog-docs (docs.civicdog.com) ------------------------------------

resource "aws_amplify_app" "docs" {
  name       = "civicdog-docs"
  repository = var.github_repository
  platform   = "WEB"

  environment_variables = {
    AMPLIFY_MONOREPO_APP_ROOT = "apps/docs"
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_amplify_branch" "docs_main" {
  app_id      = aws_amplify_app.docs.id
  branch_name = "main"

  enable_auto_build = true
  stage             = "PRODUCTION"

  tags = {
    Project = "cd-platform"
  }
}

# Same domain_name as the site app's association above -- Amplify allows
# multiple apps to each claim different subdomain prefixes under one root
# domain via separate aws_amplify_domain_association resources; this one
# only ever claims the "docs" prefix; the site app's association above owns
# "" and "www".
resource "aws_amplify_domain_association" "docs" {
  app_id                = aws_amplify_app.docs.id
  domain_name           = var.domain_name
  wait_for_verification = false

  sub_domain {
    branch_name = aws_amplify_branch.docs_main.branch_name
    prefix      = "docs"
  }
}

# --- Cloudflare DNS records -----------------------------------------------
#
# Amplify's dns_record/certificate_verification_dns_record outputs are
# plain, loosely-documented strings rather than structured objects:
#   - sub_domain[*].dns_record: space-prefixed "<TYPE> <VALUE>" (the record
#     *name* is the known subdomain prefix, so it's not included).
#   - certificate_verification_dns_record: "<NAME> <TYPE> <VALUE>" (the
#     record name here is ACM-generated, so it has to be included).
# Confirmed against a real `terraform validate`: `sub_domain` is a *set* of
# objects (unordered, no numeric index), not a list -- `for`+`if` picks out
# the specific block by its known `prefix` instead of indexing by position.

locals {
  site_cert_verification = split(" ", trimspace(aws_amplify_domain_association.site.certificate_verification_dns_record))
  docs_cert_verification = split(" ", trimspace(aws_amplify_domain_association.docs.certificate_verification_dns_record))

  site_apex_record = split(" ", trimspace([for sd in aws_amplify_domain_association.site.sub_domain : sd.dns_record if sd.prefix == ""][0]))
  site_www_record  = split(" ", trimspace([for sd in aws_amplify_domain_association.site.sub_domain : sd.dns_record if sd.prefix == "www"][0]))
  docs_sub_record  = split(" ", trimspace([for sd in aws_amplify_domain_association.docs.sub_domain : sd.dns_record if sd.prefix == "docs"][0]))
}

resource "cloudflare_record" "site_cert_verification" {
  zone_id = var.cloudflare_zone_id
  name    = local.site_cert_verification[0]
  type    = local.site_cert_verification[1]
  content = local.site_cert_verification[2]
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "docs_cert_verification" {
  zone_id = var.cloudflare_zone_id
  name    = local.docs_cert_verification[0]
  type    = local.docs_cert_verification[1]
  content = local.docs_cert_verification[2]
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "site_apex" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = local.site_apex_record[0]
  content = local.site_apex_record[1]
  ttl     = 300
  # Grey-cloud (DNS-only), deliberately not proxied through Cloudflare --
  # Amplify already fronts this with its own CloudFront distribution and
  # manages its own ACM certificate; stacking Cloudflare's proxy on top
  # would mean two CDNs in front of each other for no benefit, and would
  # likely break Amplify's own domain verification besides.
  proxied = false
}

resource "cloudflare_record" "site_www" {
  zone_id = var.cloudflare_zone_id
  name    = "www"
  type    = local.site_www_record[0]
  content = local.site_www_record[1]
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "docs_sub" {
  zone_id = var.cloudflare_zone_id
  name    = "docs"
  type    = local.docs_sub_record[0]
  content = local.docs_sub_record[1]
  ttl     = 300
  proxied = false
}
