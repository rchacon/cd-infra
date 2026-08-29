# ../cd-server's domain, for VITE_CD_SERVER_URL below -- cd-server (ECS +
# ALB) is now fully provisioned and live (cd-infra#38), unlike when this
# module was first written (see that env var's own comment, below, for
# the stale "doesn't exist yet" reasoning this replaces).
data "terraform_remote_state" "cd_server" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "cd-server/terraform.tfstate"
    region = var.aws_region
  }
}

# Safe rename (not a destroy/recreate) for the already-live prod client,
# split out from a single "cd_webapp" client into prod/dev pair below.
moved {
  from = aws_cognito_user_pool_client.cd_webapp
  to   = aws_cognito_user_pool_client.cd_webapp_prod
}

# --- Cognito: customer auth for the portal + cd-server's API -------------
#
# Email as the sign-in identifier (not a separate username) -- simplest
# model for a customer-facing portal where there's no reason to have both.
# Auto-verifies email via Cognito's own built-in ("COGNITO_DEFAULT") email
# sending -- fine for this stage's volume, but that path has a low daily
# send quota not meant for real production traffic; move to SES before
# meaningful signup volume, same kind of MVP-stopgap flag as ../cd-api/'s
# static API key.
resource "aws_cognito_user_pool" "cd_webapp" {
  name = "cd-platform-cd-webapp"

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

# Two public clients, one per environment, sharing this one User Pool --
# no secret on either, since both are called directly from a browser
# (cd-webapp's React app, whether deployed or running locally), where a
# client secret can't be kept confidential anyway. Login goes through
# Managed Login (below) via the OAuth2 Authorization Code grant -- the app
# redirects to auth.civicdog.com, never calls InitiateAuth/SRP directly,
# so only ALLOW_REFRESH_TOKEN_AUTH is needed on either client (to renew a
# session silently without a full re-login). Deliberately not a second
# User Pool -- keeps one shared user directory/password policy/Managed
# Login config, at the cost of local dev signups landing in the same
# directory production customers will use; revisit if that pollution
# becomes a real problem.
resource "aws_cognito_user_pool_client" "cd_webapp_prod" {
  name         = "cd-webapp-prod"
  user_pool_id = aws_cognito_user_pool.cd_webapp.id

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
  # domain: referencing aws_amplify_app.cd_webapp.default_domain here would
  # create a cycle, since the app's own environment_variables below already
  # reference this client's id (confirmed the hard way, via a real
  # `terraform validate` cycle error). Managed Login therefore can't be
  # end-to-end tested until app.civicdog.com's domain association (above)
  # has verified -- add the *.amplifyapp.com URL back as a manually
  # -maintained second callback/logout entry later if that staging gap
  # turns out to matter. /callback is confirmed correct against the real
  # app's router (cd-webapp#3's src/auth/config.ts builds
  # `${window.location.origin}/callback`), not a placeholder anymore.
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

# http://localhost is Cognito's one documented exception to callback_urls
# otherwise needing HTTPS -- confirm the port here still matches whatever
# cd-webapp's own `npm run dev` actually binds to (Vite's own default is
# 5173, not 5183 -- this assumes cd-webapp's dev server config overrides
# it) if local login stops working after any dev-server config change.
resource "aws_cognito_user_pool_client" "cd_webapp_dev" {
  name         = "cd-webapp-dev"
  user_pool_id = aws_cognito_user_pool.cd_webapp.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  callback_urls = ["http://localhost:5183/callback"]
  logout_urls   = ["http://localhost:5183/"]

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
resource "aws_cognito_user_pool_domain" "cd_webapp" {
  domain          = var.cognito_domain_name
  certificate_arn = aws_acm_certificate_validation.cognito_domain.certificate_arn
  user_pool_id    = aws_cognito_user_pool.cd_webapp.id

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
  content = aws_cognito_user_pool_domain.cd_webapp.cloudfront_distribution
  ttl     = 300
  # Grey-cloud, same reasoning as every other CloudFront-backed record in
  # this repo (already backed by CloudFront; stacking Cloudflare's proxy on
  # top is two CDNs for no benefit and risks breaking domain verification).
  proxied = false
}

# Managed Login branding for auth.civicdog.com (cd-infra#31) -- replaces
# AWS's unstyled default login/signup/forgot-password pages with
# cd-webapp's navy/blue brand.
#
# for_each over BOTH app clients: Cognito ties a branding style to a
# (user pool, client) pair, and cd-webapp-dev's local-dev login
# (http://localhost:5183) should look identical to prod's. The settings
# document and assets are byte-for-byte identical between the two;
# Cognito just stores its own copy of the assets per style (~0.5MB each,
# well under the 1MB-per-asset cap).
#
# Requires the provider at >= v6.13.0 -- see versions.tf's comment on why
# this module (alone) is on hashicorp/aws ~> 6.13. Also requires
# aws_cognito_user_pool_domain.cd_webapp's managed_login_version = 1
# (set above).
resource "aws_cognito_managed_login_branding" "cd_webapp" {
  for_each = {
    prod = aws_cognito_user_pool_client.cd_webapp_prod.id
    dev  = aws_cognito_user_pool_client.cd_webapp_dev.id
  }

  user_pool_id = aws_cognito_user_pool.cd_webapp.id
  client_id    = each.value

  # The civicdog wordmark, shown centered above the sign-in form. Source
  # of truth is cd-webapp's own repo (public/logo/civicdog-logo-transparent.png,
  # 1200x800 RGBA) -- copied into assets/ here rather than referenced
  # across repos.
  asset {
    category   = "FORM_LOGO"
    color_mode = "LIGHT"
    extension  = "PNG"
    bytes      = filebase64("${path.module}/assets/civicdog-logo-transparent.png")
  }

  # Browser-tab favicon. Managed Login's FAVICON_* categories only accept
  # ICO or SVG, so this .ico was generated from cd-webapp's 512x512
  # public/logo/civicdog-mark.png with:
  #   python3 -c "from PIL import Image; \
  #     Image.open('civicdog-mark.png').save( \
  #       'civicdog-favicon.ico', sizes=[(16,16),(32,32),(48,48),(64,64)])"
  asset {
    category   = "FAVICON_ICO"
    color_mode = "LIGHT"
    extension  = "ICO"
    bytes      = filebase64("${path.module}/assets/civicdog-favicon.ico")
  }

  # A full light-mode style document. Colors are "rrggbbaa" hex (no '#').
  # cd-webapp is light-only (its index.css sets `color-scheme: light` and
  # defines no dark palette), so `colorSchemeMode` is LIGHT and every
  # `darkMode` block is deliberately omitted -- Cognito keeps its own
  # defaults for anything not specified here.
  #
  # Brand tokens, from cd-webapp/src/index.css's @theme block (itself
  # mirrored from cd-website):
  #   navy-900 #0a2246 -> 0a2246ff  headings, input labels, primary-button
  #                                 hover/active, link hover, IdP-button
  #                                 hover/active border+text
  #   navy-800 #123159 -> 123159ff  body / description text
  #   blue-600 #1f5488 -> 1f5488ff  primary-button bg, links, secondary-
  #                                 button border+text, selected control
  #   blue-500 #27619c -> 27619cff  focus ring
  # Neutral greys and the semantic status/alert colors (error/success/
  # warning) are left at AWS's Cloudscape defaults -- they aren't brand
  # colors.
  settings = jsonencode({
    categories = {
      auth = {
        authMethodOrder = [[
          { display = "BUTTON", type = "FEDERATED" },
          { display = "INPUT", type = "USERNAME_PASSWORD" },
        ]]
        federation = {
          interfaceStyle = "BUTTON_LIST"
          order          = []
        }
      }
      # displayGraphics = false: no decorative side illustration -- matches
      # cd-webapp's flat-white aesthetic. Form centered on the page.
      form = {
        displayGraphics     = false
        instructions        = { enabled = false }
        languageSelector    = { enabled = false }
        location            = { horizontal = "CENTER", vertical = "CENTER" }
        sessionTimerDisplay = "NONE"
      }
      # No page header/footer chrome -- the login card sits on plain white.
      global = {
        colorSchemeMode = "LIGHT"
        pageFooter      = { enabled = false }
        pageHeader      = { enabled = false }
        spacingDensity  = "REGULAR"
      }
      signUp = {
        acceptanceElements = [{ enforcement = "NONE", textKey = "en" }]
      }
    }

    componentClasses = {
      buttons = { borderRadius = 8.0 }
      divider = { lightMode = { borderColor = "ebebf0ff" } }
      dropDown = {
        borderRadius = 8.0
        lightMode = {
          defaults = { itemBackgroundColor = "ffffffff" }
          hover = {
            itemBackgroundColor = "f4f4f4ff"
            itemBorderColor     = "7d8998ff"
            itemTextColor       = "0a2246ff"
          }
          match = {
            itemBackgroundColor = "414d5cff"
            itemTextColor       = "1f5488ff"
          }
        }
      }
      focusState = { lightMode = { borderColor = "27619cff" } }
      idpButtons = { icons = { enabled = true } }
      input = {
        borderRadius = 8.0
        lightMode = {
          defaults         = { backgroundColor = "ffffffff", borderColor = "7d8998ff" }
          placeholderColor = "5f6b7aff"
        }
      }
      inputDescription = { lightMode = { textColor = "5f6b7aff" } }
      inputLabel       = { lightMode = { textColor = "0a2246ff" } }
      link = {
        lightMode = {
          defaults = { textColor = "1f5488ff" }
          hover    = { textColor = "0a2246ff" }
        }
      }
      optionControls = {
        lightMode = {
          defaults = { backgroundColor = "ffffffff", borderColor = "7d8998ff" }
          selected = { backgroundColor = "1f5488ff", foregroundColor = "ffffffff" }
        }
      }
      # Semantic status colors -- AWS defaults, not brand.
      statusIndicator = {
        lightMode = {
          error   = { backgroundColor = "fff7f7ff", borderColor = "d91515ff", indicatorColor = "d91515ff" }
          pending = { indicatorColor = "AAAAAAAA" }
          success = { backgroundColor = "f2fcf3ff", borderColor = "037f0cff", indicatorColor = "037f0cff" }
          warning = { backgroundColor = "fffce9ff", borderColor = "8d6605ff", indicatorColor = "8d6605ff" }
        }
      }
    }

    components = {
      alert = {
        borderRadius = 12.0
        lightMode    = { error = { backgroundColor = "fff7f7ff", borderColor = "d91515ff" } }
      }
      # Only an .ico asset is shipped.
      favicon = { enabledTypes = ["ICO"] }
      form = {
        backgroundImage = { enabled = false }
        borderRadius    = 8.0
        lightMode       = { backgroundColor = "ffffffff", borderColor = "c6c6cdff" }
        # Turns on the FORM_LOGO asset above.
        logo = {
          enabled       = true
          formInclusion = "IN"
          location      = "CENTER"
          position      = "TOP"
        }
      }
      idpButton = {
        custom = {}
        standard = {
          lightMode = {
            active   = { backgroundColor = "d3e7f9ff", borderColor = "0a2246ff", textColor = "0a2246ff" }
            defaults = { backgroundColor = "ffffffff", borderColor = "424650ff", textColor = "424650ff" }
            hover    = { backgroundColor = "f2f8fdff", borderColor = "0a2246ff", textColor = "0a2246ff" }
          }
        }
      }
      # No page-background image asset -- plain white.
      pageBackground = {
        image     = { enabled = false }
        lightMode = { color = "ffffffff" }
      }
      # Header/footer are disabled at the category level above; these keep
      # AWS's defaults so the document round-trips cleanly.
      pageFooter = {
        backgroundImage = { enabled = false }
        lightMode       = { background = { color = "fafafaff" }, borderColor = "d5dbdbff" }
        logo            = { enabled = false, location = "START" }
      }
      pageHeader = {
        backgroundImage = { enabled = false }
        lightMode       = { background = { color = "fafafaff" }, borderColor = "d5dbdbff" }
        logo            = { enabled = false, location = "START" }
      }
      pageText = {
        lightMode = {
          bodyColor        = "123159ff"
          descriptionColor = "123159ff"
          headingColor     = "0a2246ff"
        }
      }
      phoneNumberSelector = { displayType = "TEXT" }
      primaryButton = {
        lightMode = {
          active   = { backgroundColor = "0a2246ff", textColor = "ffffffff" }
          defaults = { backgroundColor = "1f5488ff", textColor = "ffffffff" }
          disabled = { backgroundColor = "ffffffff", borderColor = "ffffffff" }
          hover    = { backgroundColor = "0a2246ff", textColor = "ffffffff" }
        }
      }
      secondaryButton = {
        lightMode = {
          active   = { backgroundColor = "d3e7f9ff", borderColor = "0a2246ff", textColor = "0a2246ff" }
          defaults = { backgroundColor = "ffffffff", borderColor = "1f5488ff", textColor = "1f5488ff" }
          hover    = { backgroundColor = "f2f8fdff", borderColor = "0a2246ff", textColor = "0a2246ff" }
        }
      }
    }
  })
}

# --- Amplify: cd-webapp's React frontend ----------------------------------
#
# A dedicated, non-monorepo repo -- unlike ../amplify/'s two cd-website
# apps, cd-webapp has no AMPLIFY_MONOREPO_APP_ROOT/`applications:` wrapper
# to deal with, just a plain single-app build_spec. Confirmed against the
# real repo's package.json: Vite + React + TypeScript, `npm run build` runs
# `tsc -b && vite build`, output directory is Vite's default `dist`.
#
# A build against this app failed with "Unable to assume specified IAM
# Role" before even cloning the repo, despite no role being configured
# anywhere on the app (confirmed via the Amplify console's own IAM roles
# page -- both "Service role" and "Compute role" showed "No ... role
# set"). ../amplify/'s two older apps (created 2026-08-04) don't show
# this. Tried adding an explicit iam_service_role_arn with AWS's
# AdministratorAccess-Amplify managed policy, but that policy is
# account-wide administrative access (not scoped per-app, includes IAM
# actions) designed for Amplify Gen 1's full-stack backend deployment role
# -- far broader than a static-hosting-only app like this one needs.
# Reverted; still unresolved -- needs a narrower fix (a minimally-scoped
# service role, or whatever the actual AWS-side cause turns out to be)
# before the first real build can succeed.
resource "aws_amplify_app" "cd_webapp" {
  name         = "civicdog-webapp"
  repository   = var.github_repository
  access_token = var.github_access_token
  platform     = "WEB"

  # VITE_-prefixed names are required for Vite to expose these to
  # client-side code (https://vite.dev/guide/env-and-mode) -- anything
  # without that prefix is invisible to the built bundle, not just
  # unconventional.
  #
  # Only client_id/domain for Cognito -- cd-webapp#3's hand-rolled OAuth2
  # flow talks directly to Managed Login's HTTP endpoints (/login,
  # /oauth2/token, /logout) and only needs those two to build its URLs. No
  # region or user pool ID: those only matter for direct Cognito Identity
  # Provider API calls (e.g. the AWS SDK or Amplify's Auth module), which
  # this implementation deliberately avoids -- confirmed unused across
  # every file in that PR before removing them here.
  #
  # VITE_CD_SERVER_URL was missing entirely until cd-infra#39 -- cd-webapp
  # fell back to its localhost:8000 dev default in production until then
  # (confirmed live in the deployed bundle). Vite inlines VITE_* vars at
  # *build* time, not runtime, so setting this alone doesn't retroactively
  # fix an already-built bundle -- a new Amplify build has to run after
  # this applies (redeploy the branch, or push a no-op commit) for the new
  # value to actually land.
  environment_variables = {
    VITE_COGNITO_CLIENT_ID = aws_cognito_user_pool_client.cd_webapp_prod.id
    VITE_COGNITO_DOMAIN    = var.cognito_domain_name
    VITE_CD_SERVER_URL     = "${data.terraform_remote_state.cd_server.outputs.server_domain_url}/graphql"
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
  #
  # NOT the plain "/<*>" -> "/index.html" 404-200 pattern -- confirmed
  # broken in production (#33): Amplify/CloudFront's edge does its own
  # trailing-slash "clean URL" normalization (301 /callback -> /callback/)
  # *before* the 404-200 condition is evaluated, and that redirected
  # variant isn't reliably caught, so the request fell through to a raw
  # 404 instead of ever reaching index.html -- broke the OAuth callback
  # specifically. This unconditional regex rewrite (AWS's own documented
  # SPA-routing fix) matches any path without a recognized static-file
  # extension and rewrites to index.html unconditionally -- no dependency
  # on origin 404 behavior, no intermediate redirect to dodge.
  #
  # "webp" added to AWS's own documented extension list -- confirmed
  # broken in production without it: cd-webapp's landing-page logo is a
  # <picture> element with a .webp <source> (PNG <img> fallback), and the
  # webp request was getting caught by this rule and rewritten to
  # index.html (text/html instead of an actual image) since webp isn't in
  # AWS's example list at all, silently breaking that image while the png
  # fallback still worked -- exactly the kind of gap this unconditional
  # rule needs to be exhaustive about, unlike the old 404-200 rule it
  # replaced.
  custom_rule {
    source = "</^[^.]+$|\\.(?!(css|gif|ico|jpg|js|png|txt|svg|woff|ttf|map|json|webp)$)([^.]+$)/>"
    target = "/index.html"
    status = "200"
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_amplify_branch" "cd_webapp_main" {
  app_id      = aws_amplify_app.cd_webapp.id
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
resource "aws_amplify_domain_association" "cd_webapp" {
  app_id                = aws_amplify_app.cd_webapp.id
  domain_name           = var.domain_name
  wait_for_verification = false

  sub_domain {
    branch_name = aws_amplify_branch.cd_webapp_main.branch_name
    prefix      = "app"
  }
}

# --- Cloudflare DNS records ------------------------------------------------
#
# Same 3-field "<name-or-empty> <TYPE> <VALUE>" shape for
# certificate_verification_dns_record and dns_record, and the same
# not-trimspace()'d split(" ", ...) parsing -- see ../amplify/main.tf's
# detailed comment on this for the full story (confirmed there against a
# real apply). sub_domain is a single-element set here (only "app"), so
# tolist(...)[0] is enough -- no for+if filtering needed the way
# ../amplify/'s multi-prefix "site" app needs.
#
# No cloudflare_record for aws_amplify_domain_association.cd_webapp's own
# certificate_verification_dns_record -- confirmed via a real apply that
# it's identical to (and already satisfied by) ../amplify/'s existing
# root-domain validation record for civicdog.com (ACM reuses one
# validation CNAME per apex domain across multiple cert requests, same
# reasoning already documented in ../amplify/main.tf for its site/docs
# apps sharing one record within that module -- this is the same pattern,
# just crossing module/state boundaries this time). Terraform tried to
# create a second, duplicate record for it and Cloudflare rejected it
# ("DNS record already exists"); the domain association still verified
# successfully using the pre-existing record, so nothing needs creating
# here at all.
locals {
  cd_webapp_sub_record = split(" ", tolist(aws_amplify_domain_association.cd_webapp.sub_domain)[0].dns_record)
}

resource "cloudflare_record" "cd_webapp_sub" {
  zone_id = var.cloudflare_zone_id
  name    = "app"
  type    = local.cd_webapp_sub_record[1]
  content = trimsuffix(local.cd_webapp_sub_record[2], ".")
  ttl     = 300
  # Grey-cloud (DNS-only) -- Amplify already fronts this with its own
  # CloudFront distribution and manages its own ACM certificate; stacking
  # Cloudflare's proxy on top would be two CDNs in front of each other for
  # no benefit, and would likely break Amplify's own domain verification
  # besides. Same reasoning as ../amplify/'s records.
  proxied = false
}
