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
  name         = "civicdog-site"
  repository   = var.github_repository
  access_token = var.github_access_token
  platform     = "WEB"

  # AMPLIFY_MONOREPO_APP_ROOT alone isn't enough -- confirmed via a real
  # failed build ("Monorepo spec provided without \"applications\" key"):
  # setting it puts Amplify into monorepo mode, but it then requires the
  # build spec itself to use the `applications:` wrapper below, matching
  # apps/site/amplify.yml's actual frontend config -- it does not
  # auto-discover a plain amplify.yml inside the app root the way a
  # non-monorepo app would.
  environment_variables = {
    AMPLIFY_MONOREPO_APP_ROOT = "apps/site"
  }

  build_spec = <<-YAML
    version: 1
    applications:
      - appRoot: apps/site
        frontend:
          phases:
            preBuild:
              commands:
                - npm ci
            build:
              commands:
                - npm run build
          artifacts:
            baseDirectory: dist
            files:
              - '**/*'
          cache:
            paths:
              - node_modules/**/*
  YAML

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
  name         = "civicdog-docs"
  repository   = var.github_repository
  access_token = var.github_access_token
  platform     = "WEB"

  environment_variables = {
    AMPLIFY_MONOREPO_APP_ROOT = "apps/docs"
  }

  # See aws_amplify_app.site's build_spec comment above -- same fix, mirrors
  # apps/docs/amplify.yml's frontend config.
  build_spec = <<-YAML
    version: 1
    applications:
      - appRoot: apps/docs
        frontend:
          phases:
            preBuild:
              commands:
                - npm ci
            build:
              commands:
                - npm run build
          artifacts:
            baseDirectory: dist
            files:
              - '**/*'
          cache:
            paths:
              - node_modules/**/*
  YAML

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
# plain, loosely-documented strings rather than structured objects.
# Confirmed against real `terraform apply` output (not just the docs, which
# undersold this): BOTH are the same 3-field, space-delimited shape --
# "<name-or-empty> <TYPE> <VALUE>" -- e.g. `"docs CNAME xyz.cloudfront.net"`
# for a "docs" sub_domain, or `" CNAME xyz.cloudfront.net"` (leading space,
# empty name) for the apex. Deliberately NOT trimspace()'d before splitting
# -- trimming would eat that meaningful leading space on the empty-name
# case, collapsing it to 2 fields instead of 3 and silently shifting every
# other case's fields over by one (confirmed the hard way: produced
# `type = "www"` / `type = "docs"` errors from Cloudflare on the first real
# apply). Index [0] is the name (unused here -- each resource below sets
# `name` explicitly), [1] is the record type, [2] is the value.
#
# `sub_domain` is a *set* of objects (unordered, no numeric index), not a
# list -- `for`+`if` picks out the specific block by its known `prefix`
# instead of indexing by position (also confirmed via a real
# `terraform validate` failure).

locals {
  # docs.certificate_verification_dns_record is intentionally unused -- see
  # the comment on cloudflare_record.site_cert_verification below.
  site_cert_verification = split(" ", aws_amplify_domain_association.site.certificate_verification_dns_record)

  site_apex_record = split(" ", [for sd in aws_amplify_domain_association.site.sub_domain : sd.dns_record if sd.prefix == ""][0])
  site_www_record  = split(" ", [for sd in aws_amplify_domain_association.site.sub_domain : sd.dns_record if sd.prefix == "www"][0])
  docs_sub_record  = split(" ", [for sd in aws_amplify_domain_association.docs.sub_domain : sd.dns_record if sd.prefix == "docs"][0])
}

# site's and docs' domain associations both validate ownership of the same
# root (civicdog.com), so ACM issues the *same* validation CNAME for both --
# confirmed via two real applies: docs_cert_verification (as a separate
# resource) first failed with "DNS record ... already exists" against the
# record this one had just created, and after switching to
# allow_overwrite = true, failed again ("didn't find an exact match") on
# what looks like the provider's own overwrite-lookup normalizing the
# trailing "." on `name` differently than what's actually stored. Simplest
# correct fix: there is only one real record here, so there's only one
# Terraform resource for it -- both domain associations' verification is
# satisfied by this single record, nothing references docs' identical
# certificate_verification_dns_record separately.
resource "cloudflare_record" "site_cert_verification" {
  zone_id = var.cloudflare_zone_id
  name    = local.site_cert_verification[0]
  type    = local.site_cert_verification[1]
  # trimsuffix: AWS returns this as a fully-qualified value with a trailing
  # "." that Cloudflare doesn't store as part of `content`.
  content = trimsuffix(local.site_cert_verification[2], ".")
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "site_apex" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = local.site_apex_record[1]
  content = trimsuffix(local.site_apex_record[2], ".")
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
  type    = local.site_www_record[1]
  content = trimsuffix(local.site_www_record[2], ".")
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "docs_sub" {
  zone_id = var.cloudflare_zone_id
  name    = "docs"
  type    = local.docs_sub_record[1]
  content = trimsuffix(local.docs_sub_record[2], ".")
  ttl     = 300
  proxied = false
}
