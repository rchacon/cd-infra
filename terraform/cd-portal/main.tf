# --- Cognito: customer auth for the portal + cd-server's API -------------
#
# Email as the sign-in identifier (not a separate username) -- simplest
# model for a customer-facing portal where there's no reason to have both.
# Auto-verifies email via Cognito's own built-in ("COGNITO_DEFAULT") email
# sending -- fine for this stage's volume, but that path has a low daily
# send quota not meant for real production traffic; move to SES before
# meaningful signup volume, same kind of MVP-stopgap flag as ../cd-api/'s
# static API key.
resource "aws_cognito_user_pool" "cd_portal" {
  name = "cd-platform-cd-portal"

  # Explicit rather than relying on the provider/AWS default (which is
  # ESSENTIALS for new pools as of this writing anyway) -- spelled out here
  # so a future AWS default change can't silently move this pool to a
  # different tier/price point. Essentials, not Lite, since Managed Login
  # (below) needs it -- Lite's cheaper per-MAU rate doesn't include it.
  user_pool_tier = "ESSENTIALS"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = var.cognito_password_minimum_length
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  # Email is the sign-in identifier, so a customer must be able to prove
  # ownership of it to ever recover a lost password -- REQUIRED (Cognito's
  # only two options here) is the correct choice, not a stricter-than-needed
  # default.
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = {
    Project = "cd-platform"
  }
}

# Public client -- no secret, since this is called directly from the
# browser (cd-portal's React app), where a client secret can't be kept
# confidential anyway. Login goes through Managed Login (below) via the
# OAuth2 Authorization Code grant -- the app redirects to
# auth.civicdog.com, never calls InitiateAuth/SRP directly, so only
# ALLOW_REFRESH_TOKEN_AUTH is needed here (to renew a session silently
# without a full re-login).
resource "aws_cognito_user_pool_client" "cd_portal" {
  name         = "cd-platform-cd-portal-web"
  user_pool_id = aws_cognito_user_pool.cd_portal.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Authorization Code grant, not Implicit -- the code exchange happens
  # over a direct HTTPS call from the app to Cognito's /oauth2/token
  # endpoint, so tokens are never exposed in a browser URL/history the way
  # Implicit's fragment-based response is.
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  # Only the custom-domain URL -- NOT also the Amplify default *.amplifyapp.com
  # domain: referencing aws_amplify_app.cd_portal.default_domain here would
  # create a cycle, since the app's own environment_variables below already
  # reference this client's id (confirmed the hard way, via a real
  # `terraform validate` cycle error). Managed Login therefore can't be
  # end-to-end tested until app.civicdog.com's domain association (above)
  # has verified -- add the *.amplifyapp.com URL back as a manually
  # -maintained second callback/logout entry later if that staging gap
  # turns out to matter. /callback is a placeholder path; confirm it
  # matches whatever route cd-portal's own router actually implements once
  # that code exists.
  callback_urls = ["https://app.${var.domain_name}/callback"]
  logout_urls   = ["https://app.${var.domain_name}/"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

# --- Cognito Managed Login: auth.civicdog.com -----------------------------

resource "aws_acm_certificate" "cognito_domain" {
  provider          = aws.us_east_1
  domain_name       = var.cognito_domain_name
  validation_method = "DNS"

  tags = {
    Project = "cd-platform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_record" "cognito_domain_validation" {
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(tolist(aws_acm_certificate.cognito_domain.domain_validation_options)[0].resource_record_name, ".")
  type    = tolist(aws_acm_certificate.cognito_domain.domain_validation_options)[0].resource_record_type
  content = trimsuffix(tolist(aws_acm_certificate.cognito_domain.domain_validation_options)[0].resource_record_value, ".")
  ttl     = 300
  proxied = false
}

resource "aws_acm_certificate_validation" "cognito_domain" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cognito_domain.arn
  validation_record_fqdns = [cloudflare_record.cognito_domain_validation.hostname]
}

# managed_login_version = 1 opts into Managed Login (the newer, brandable
# hosted UI) rather than 0 (the classic Hosted UI) -- both are available on
# Essentials, but Managed Login is what was actually asked for and is the
# non-deprecated path going forward.
resource "aws_cognito_user_pool_domain" "cd_portal" {
  domain          = var.cognito_domain_name
  certificate_arn = aws_acm_certificate_validation.cognito_domain.certificate_arn
  user_pool_id    = aws_cognito_user_pool.cd_portal.id

  managed_login_version = 1
}

# cloudfront_distribution: the domain name of the CloudFront distribution
# Cognito provisions for this custom domain -- confirm this exact attribute
# name against the installed aws provider version at plan time (an older
# provider generation exposed this as cloudfront_distribution_arn, an ARN
# rather than a hostname, which wouldn't work directly as a CNAME target).
resource "cloudflare_record" "cognito_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "auth"
  type    = "CNAME"
  content = aws_cognito_user_pool_domain.cd_portal.cloudfront_distribution
  ttl     = 300
  # Grey-cloud, same reasoning as every other CloudFront-backed record in
  # this repo (already backed by CloudFront; stacking Cloudflare's proxy on
  # top is two CDNs for no benefit and risks breaking domain verification).
  proxied = false
}

# --- Amplify: cd-portal's React frontend ----------------------------------
#
# A dedicated, non-monorepo repo -- unlike ../amplify/'s two cd-website
# apps, cd-portal has no AMPLIFY_MONOREPO_APP_ROOT/`applications:` wrapper
# to deal with, just a plain single-app build_spec. Confirmed against the
# real repo's package.json: Vite + React + TypeScript, `npm run build` runs
# `tsc -b && vite build`, output directory is Vite's default `dist`.
resource "aws_amplify_app" "cd_portal" {
  name         = "cd-portal"
  repository   = var.github_repository
  access_token = var.github_access_token
  platform     = "WEB"

  # VITE_-prefixed names are required for Vite to expose these to
  # client-side code (https://vite.dev/guide/env-and-mode) -- anything
  # without that prefix is invisible to the built bundle, not just
  # unconventional. cd-server's URL isn't set here yet -- that Lambda/API
  # Gateway doesn't exist yet (see terraform/README.md's cd-portal/
  # section for the follow-up apply once ../cd-server/ is provisioned).
  environment_variables = {
    VITE_COGNITO_USER_POOL_ID = aws_cognito_user_pool.cd_portal.id
    VITE_COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.cd_portal.id
    VITE_COGNITO_DOMAIN       = var.cognito_domain_name
    VITE_AWS_REGION           = var.aws_region
  }

  build_spec = <<-YAML
    version: 1
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

  # SPA fallback rewrite -- there's both an unauthenticated experience
  # (public pages) and an authenticated one on app.civicdog.com, plus
  # Managed Login's own /callback redirect target, all handled by
  # client-side routing inside the one built bundle. Without this, Amplify
  # Hosting only serves exact-match files -- any direct navigation or
  # refresh on a client-side route (including the OAuth callback) 404s
  # instead of falling through to index.html for React Router to handle.
  # 404-200 (not a real redirect) so the browser's URL bar/history stays on
  # the originally-requested path.
  custom_rule {
    source = "/<*>"
    target = "/index.html"
    status = "404-200"
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_amplify_branch" "cd_portal_main" {
  app_id      = aws_amplify_app.cd_portal.id
  branch_name = "main"

  enable_auto_build = true
  stage             = "PRODUCTION"

  tags = {
    Project = "cd-platform"
  }
}

# wait_for_verification = false: same reasoning as ../amplify/'s two
# domain associations -- this resource's own certificate_verification_dns_
# record/sub_domain[*].dns_record outputs are what the cloudflare_record
# resources below are built from, so the DNS being verified against
# doesn't exist yet at the moment this is created. Verification happens
# asynchronously; check actual status via the Amplify console or a
# follow-up `terraform plan`, not apply's exit code for this one resource.
resource "aws_amplify_domain_association" "cd_portal" {
  app_id                = aws_amplify_app.cd_portal.id
  domain_name           = var.domain_name
  wait_for_verification = false

  sub_domain {
    branch_name = aws_amplify_branch.cd_portal_main.branch_name
    prefix      = "app"
  }
}

# --- Cloudflare DNS records ------------------------------------------------
#
# Same 3-field "<name-or-empty> <TYPE> <VALUE>" shape for both
# certificate_verification_dns_record and dns_record, and the same
# not-trimspace()'d split(" ", ...) parsing -- see ../amplify/main.tf's
# detailed comment on this for the full story (confirmed there against a
# real apply). sub_domain is a single-element set here (only "app"), so
# tolist(...)[0] is enough -- no for+if filtering needed the way
# ../amplify/'s multi-prefix "site" app needs.
locals {
  cd_portal_cert_verification = split(" ", aws_amplify_domain_association.cd_portal.certificate_verification_dns_record)
  cd_portal_sub_record        = split(" ", tolist(aws_amplify_domain_association.cd_portal.sub_domain)[0].dns_record)
}

resource "cloudflare_record" "cd_portal_cert_verification" {
  zone_id = var.cloudflare_zone_id
  name    = local.cd_portal_cert_verification[0]
  type    = local.cd_portal_cert_verification[1]
  # trimsuffix: AWS returns this as a fully-qualified value with a trailing
  # "." that Cloudflare doesn't store as part of `content`.
  content = trimsuffix(local.cd_portal_cert_verification[2], ".")
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "cd_portal_sub" {
  zone_id = var.cloudflare_zone_id
  name    = "app"
  type    = local.cd_portal_sub_record[1]
  content = trimsuffix(local.cd_portal_sub_record[2], ".")
  ttl     = 300
  # Grey-cloud (DNS-only) -- Amplify already fronts this with its own
  # CloudFront distribution and manages its own ACM certificate; stacking
  # Cloudflare's proxy on top would be two CDNs in front of each other for
  # no benefit, and would likely break Amplify's own domain verification
  # besides. Same reasoning as ../amplify/'s records.
  proxied = false
}
