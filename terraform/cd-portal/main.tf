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
# confidential anyway. ALLOW_USER_SRP_AUTH (not ALLOW_USER_PASSWORD_AUTH)
# so the password itself is never sent to Cognito's API, only a
# zero-knowledge proof of it -- ALLOW_REFRESH_TOKEN_AUTH lets the app renew
# a session without re-prompting for credentials.
resource "aws_cognito_user_pool_client" "cd_portal" {
  name         = "cd-platform-cd-portal-web"
  user_pool_id = aws_cognito_user_pool.cd_portal.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
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

# No aws_amplify_domain_association / Cloudflare records yet -- deliberately
# staged the same way terraform/README.md already documents for
# ../amplify/: apps/branches first (confirm the *.amplifyapp.com URL
# below), domain association + DNS as a separate follow-up apply, since
# that step touches the live civicdog.com zone.
