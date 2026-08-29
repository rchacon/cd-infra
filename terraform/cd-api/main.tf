data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "networking/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "rds" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "rds/terraform.tfstate"
    region = var.aws_region
  }
}

# Customer-managed key (rather than the AWS-managed default) so reading
# cd_api_app's DB credentials or the Lambda's environment variables
# requires both Secrets Manager/Lambda access *and* kms:Decrypt on this
# specific key -- same defense-in-depth reasoning as every other
# customer-managed key in this repo (see CLAUDE.md). One shared key for
# both uses below rather than a second key, since they're both this
# component's own data at rest.
resource "aws_kms_key" "cd_api" {
  description             = "Encrypts cd-api's DB credentials secret and its Lambda's environment variables."
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "cd_api" {
  name          = "alias/cd-platform-cd-api"
  target_key_id = aws_kms_key.cd_api.key_id
}

# Least-privilege runtime credential for cd-api's Lambda -- mirrors
# ../airflow's cd_etl_app exactly. The RDS master/superuser credentials are
# never used by this component at all; this role is bootstrapped manually
# from the ../airflow instance (the only thing that can reach RDS), see
# terraform/README.md.
resource "random_password" "cd_api_app" {
  length = 32
  # No special characters -- this password gets embedded directly into a
  # SQL string literal by the manual bootstrap step (see terraform/README.md);
  # alphanumeric-only sidesteps SQL-quoting escaping entirely, same
  # reasoning as ../airflow's cd_etl_app password.
  special = false
}

resource "aws_secretsmanager_secret" "cd_api_app_db" {
  name       = "cd-platform/cd-api/cd-api-db-credentials"
  kms_key_id = aws_kms_key.cd_api.arn

  tags = {
    Project = "cd-platform"
  }
}

# Same {"username":..., "password":...} JSON shape as ../airflow's
# cd_etl_app secret and RDS's own master-user secret.
resource "aws_secretsmanager_secret_version" "cd_api_app_db" {
  secret_id = aws_secretsmanager_secret.cd_api_app_db.id
  secret_string = jsonencode({
    username = var.cd_api_db_username
    password = random_password.cd_api_app.result
  })
}

# --- RDS Proxy ---------------------------------------------------------

data "aws_iam_policy_document" "rds_proxy_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_proxy" {
  name               = "cd-platform-cd-api-rds-proxy"
  assume_role_policy = data.aws_iam_policy_document.rds_proxy_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# Per CLAUDE.md's alias-ARN gotcha: alias-scoped statements need the alias
# ARN directly in Resource (no kms:AliasName condition key exists), plus a
# separate grant on the underlying key -- both included here rather than
# relying on either alone.
data "aws_iam_policy_document" "rds_proxy_secrets" {
  statement {
    sid       = "ReadCdApiAppSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.cd_api_app_db.arn]
  }

  statement {
    sid     = "DecryptCdApiSecret"
    actions = ["kms:Decrypt"]
    resources = [
      aws_kms_key.cd_api.arn,
      aws_kms_alias.cd_api.arn,
    ]
  }
}

resource "aws_iam_role_policy" "rds_proxy" {
  name   = "cd-platform-cd-api-rds-proxy"
  role   = aws_iam_role.rds_proxy.id
  policy = data.aws_iam_policy_document.rds_proxy_secrets.json
}

# Reuses the same security group as the Lambda itself (rather than a new
# dedicated proxy SG) -- networking/main.tf's rds_from_lambda ingress rule
# on the rds SG already matches by SG membership regardless of which
# resource (Lambda or Proxy) actually originates the traffic, and the new
# lambda_from_lambda self-referencing rule there covers Lambda->Proxy.
resource "aws_db_proxy" "cd_api" {
  name                   = "cd-platform-cd-api"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = data.terraform_remote_state.networking.outputs.private_subnet_ids
  vpc_security_group_ids = [data.terraform_remote_state.networking.outputs.lambda_security_group_id]
  require_tls            = true

  # SECRETS auth (not IAM auth) is what lets cd-api/src/db.py stay
  # completely unchanged -- it already reads PGHOST/PGPORT/PGUSER/
  # PGPASSWORD/PGDATABASE from plain env vars via psycopg2.connect(). IAM
  # auth would need cd-api to generate its own auth tokens at runtime, a
  # code change this issue explicitly doesn't require. Authenticates as
  # cd_api_app (above), never the RDS master secret.
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.cd_api_app_db.arn
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_db_proxy_default_target_group" "cd_api" {
  db_proxy_name = aws_db_proxy.cd_api.name

  connection_pool_config {
    max_connections_percent = var.rds_proxy_max_connections_percent
  }
}

resource "aws_db_proxy_target" "cd_api" {
  db_proxy_name          = aws_db_proxy.cd_api.name
  target_group_name      = aws_db_proxy_default_target_group.cd_api.name
  db_instance_identifier = data.terraform_remote_state.rds.outputs.rds_instance_identifier
}

# --- Lambda -------------------------------------------------------------

# Trivial placeholder -- cd-platform#29's deploy workflow overwrites this
# with the real cd-api zip via `aws lambda update-function-code` on every
# cd-api-vX.X.X tag push. This Terraform resource only needs *some* valid
# initial code to exist; see the lifecycle block below for why a routine
# `terraform apply` won't revert a real deploy back to this.
data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/files/placeholder.zip"

  # Nested under cd/api/, matching cd-platform-cd-api-deploy.yml's real
  # build step post cd-platform#58 (`cp -r src/cd package/`) -- see #26.
  # app.py's own internal imports are now fully-qualified absolute imports
  # (`from cd.api.db import ...`), and the cd package sits directly at the
  # zip root, so this nesting resolves correctly under Lambda's
  # only-the-zip-root-is-on-sys.path constraint -- the same constraint
  # that required a flat layout before #58 (see #12). This has to match
  # the real deploy's structure, or the handler config below would be
  # right for the real code but wrong for this placeholder (or vice
  # versa), breaking the plan's own "aws lambda invoke against the
  # placeholder confirms wiring" verification step.
  source {
    filename = "cd/api/app.py"
    content  = <<-PY
      def handler(event, context):
          return {"statusCode": 200, "body": "cd-api placeholder -- see cd-platform#29 for the real deploy"}
    PY
  }
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "cd-platform-cd-api-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# Covers both VPC access (ENI create/describe/delete) and CloudWatch Logs
# (CreateLogGroup/Stream, PutLogEvents) -- one attachment, no second needed.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# For the CMK-encrypted environment variables below. Unverified whether
# this is actually required at runtime (Lambda's env-var decryption may be
# handled transparently via a deploy-time grant rather than needing the
# running function's own role) -- harmless if unneeded, confirm
# empirically at apply time rather than trusting either way.
data "aws_iam_policy_document" "lambda_kms" {
  statement {
    sid     = "DecryptEnvVars"
    actions = ["kms:Decrypt"]
    resources = [
      aws_kms_key.cd_api.arn,
      aws_kms_alias.cd_api.arn,
    ]
  }
}

resource "aws_iam_role_policy" "lambda_kms" {
  name   = "cd-platform-cd-api-lambda-kms"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_kms.json
}

# Bedrock embedding generation -- cd-platform#9 (semantic search over
# bills). GET /bills/search embeds the caller's free-text query via
# Titan Text Embeddings V2 directly via boto3 (IAM/role auth, no API
# key/secret to manage). Mirrors airflow-ecs/main.tf's
# task_bedrock_permissions grant for cd-etl's own task role -- same
# model, same account-agnostic/region-scoped-only foundation-model ARN.
data "aws_iam_policy_document" "lambda_bedrock_permissions" {
  statement {
    sid       = "InvokeTitanEmbeddings"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.aws_region}::foundation-model/amazon.titan-embed-text-v2:0"]
  }
}

resource "aws_iam_role_policy" "lambda_bedrock_permissions" {
  name   = "cd-platform-cd-api-lambda-bedrock"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_bedrock_permissions.json
}

resource "aws_lambda_function" "cd_api" {
  function_name = "cd-platform-cd-api"
  role          = aws_iam_role.lambda.arn
  # cd-platform/cd-api/src/cd/api/app.py's `handler = Mangum(app)`,
  # package-qualified ("cd.api.app.handler") since cd-platform#58 -- see
  # #26. app.py's sibling imports are now fully-qualified absolute imports
  # (`from cd.api.db import ...`), and the cd package sits directly at the
  # zip root, so this resolves correctly under Lambda's
  # only-the-zip-root-is-on-sys.path constraint (the same constraint that
  # required the old flat "app.handler" path pre-#58, see #12). The real,
  # merged cd-api-deploy.yml (`cp -r src/cd package/`) already builds its
  # zip this way.
  handler = "cd.api.app.handler"
  runtime = "python3.12"

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_size

  vpc_config {
    subnet_ids         = data.terraform_remote_state.networking.outputs.private_subnet_ids
    security_group_ids = [data.terraform_remote_state.networking.outputs.lambda_security_group_id]
  }

  kms_key_arn = aws_kms_key.cd_api.arn

  environment {
    variables = {
      PGHOST     = aws_db_proxy.cd_api.endpoint
      PGPORT     = "5432"
      PGUSER     = var.cd_api_db_username
      PGPASSWORD = random_password.cd_api_app.result
      PGDATABASE = "cd_platform"
    }
  }

  tags = {
    Project = "cd-platform"
  }

  # cd-platform#29's deploy workflow overwrites the real code out-of-band
  # via the Lambda API on every tag push -- ignore these two so a routine
  # `terraform apply` here never reverts a real deploy back to the
  # placeholder. Mirrors ../airflow/main.tf's `ignore_changes = [ami]` for
  # the identical "Terraform creates it, something else updates it
  # out-of-band" shape.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

# --- API Gateway (REST API v1) ------------------------------------------
#
# REST API (v1), not the cheaper/simpler HTTP API (v2): cd-platform#13
# requires the MVP static API key be "zero app code, purely disposable
# infra config" at the gateway layer. Only REST API v1's native
# aws_api_gateway_api_key/aws_api_gateway_usage_plan satisfies that --
# HTTP API v2 has no equivalent without a custom Lambda authorizer, which
# would itself be app code, just relocated.

resource "aws_api_gateway_rest_api" "cd_api" {
  name = "cd-platform-cd-api"

  tags = {
    Project = "cd-platform"
  }
}

# {proxy+} matches every sub-path (/members, etc); the separate root ANY
# method below handles "/" itself, which {proxy+} alone doesn't match --
# both needed per AWS's documented Lambda proxy-integration pattern.
resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.cd_api.id
  parent_id   = aws_api_gateway_rest_api.cd_api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy_any" {
  rest_api_id      = aws_api_gateway_rest_api.cd_api.id
  resource_id      = aws_api_gateway_resource.proxy.id
  http_method      = "ANY"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "proxy_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.cd_api.id
  resource_id             = aws_api_gateway_resource.proxy.id
  http_method             = aws_api_gateway_method.proxy_any.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cd_api.invoke_arn
}

resource "aws_api_gateway_method" "root_any" {
  rest_api_id      = aws_api_gateway_rest_api.cd_api.id
  resource_id      = aws_api_gateway_rest_api.cd_api.root_resource_id
  http_method      = "ANY"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "root_lambda" {
  rest_api_id             = aws_api_gateway_rest_api.cd_api.id
  resource_id             = aws_api_gateway_rest_api.cd_api.root_resource_id
  http_method             = aws_api_gateway_method.root_any.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.cd_api.invoke_arn
}

resource "aws_api_gateway_deployment" "cd_api" {
  rest_api_id = aws_api_gateway_rest_api.cd_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy_any.id,
      aws_api_gateway_integration.proxy_lambda.id,
      aws_api_gateway_method.root_any.id,
      aws_api_gateway_integration.root_lambda.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "cd_api" {
  rest_api_id   = aws_api_gateway_rest_api.cd_api.id
  deployment_id = aws_api_gateway_deployment.cd_api.id
  stage_name    = var.stage_name

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cd_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.cd_api.execution_arn}/*/*"
}

# Variable-driven so adding another key (e.g. a new customer) later is
# just a tfvars edit. All keys share one usage plan for now -- no per-key
# throttle/quota differentiation yet, that's cd-platform#13's real
# per-customer system's job. Per-key *usage tracking* doesn't need
# separate plans though: `aws apigateway get-usage --usage-plan-id <id>
# --key-id <id>` tracks consumption separately per key even when they
# share one plan's limits.
resource "aws_api_gateway_api_key" "keys" {
  for_each = toset(var.api_key_names)
  name     = "cd-platform-cd-api-${each.value}"

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_api_gateway_usage_plan" "cd_api" {
  name = "cd-platform-cd-api"

  api_stages {
    api_id = aws_api_gateway_rest_api.cd_api.id
    stage  = aws_api_gateway_stage.cd_api.stage_name
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_api_gateway_usage_plan_key" "keys" {
  for_each      = aws_api_gateway_api_key.keys
  key_id        = each.value.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.cd_api.id
}

# --- GitHub OIDC deploy role (for cd-platform#29) ------------------------
#
# The OIDC *provider* lives in ../bootstrap (an account-wide singleton);
# this is just the role that trusts it, scoped tightly to cd-platform's
# repo and the cd-api-vX.X.X tag pattern cd-platform#29's workflow
# triggers on.

data "aws_iam_policy_document" "cd_api_deploy_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository_owner}@${var.github_owner_id}/cd-platform@${var.github_repo_id}:ref:refs/tags/cd-api-v*"]
    }
  }
}

resource "aws_iam_role" "cd_api_deploy" {
  name               = "cd-platform-cd-api-deploy"
  assume_role_policy = data.aws_iam_policy_document.cd_api_deploy_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

data "aws_iam_policy_document" "cd_api_deploy_permissions" {
  statement {
    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionCode20150331v2",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
    ]
    resources = [aws_lambda_function.cd_api.arn]
  }
}

resource "aws_iam_role_policy" "cd_api_deploy" {
  name   = "cd-platform-cd-api-deploy"
  role   = aws_iam_role.cd_api_deploy.id
  policy = data.aws_iam_policy_document.cd_api_deploy_permissions.json
}

# --- OpenAPI spec bucket (cd-website#1) ----------------------------------
#
# cd-api sits behind API Gateway with api_key_required = true on its one
# catch-all proxy method (confirmed against the *live* API Gateway, not
# just this config -- there's no narrower per-path scoping), so
# docs.civicdog.com can't fetch /openapi.json live from cd-api without
# exposing a key client-side. This bucket is the publish target instead:
# cd-api-deploy.yml (a separate, future cd-platform change) will generate
# openapi.json from the FastAPI app and upload it here on every
# cd-api-vX.X.X release; docs.civicdog.com fetches the public URL directly.
# This module only provisions the bucket + the deploy role's write
# permission -- no object is uploaded by Terraform itself.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "openapi_spec" {
  bucket = "cd-platform-openapi-spec-${data.aws_caller_identity.current.account_id}"

  tags = {
    Project = "cd-platform"
  }
}

# Public access is via the bucket policy below only -- ACLs are never used,
# so block_public_acls/ignore_public_acls stay at their safe default (true).
# block_public_policy/restrict_public_buckets must be false, or the policy
# below would be rejected at apply time. Both ignores below are that same
# fact, not an oversight -- Trivy's defaults assume every bucket should
# block public access, which is wrong for a bucket whose entire purpose is
# public read.
# trivy:ignore:AWS-0087 public policy is the intended access path for this bucket
# trivy:ignore:AWS-0093 same -- this bucket is meant to be publicly readable
resource "aws_s3_bucket_public_access_block" "openapi_spec" {
  bucket = aws_s3_bucket.openapi_spec.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

# Bucket-wide (not scoped to one key) since this bucket's sole purpose is
# public docs artifacts -- nothing sensitive is ever meant to live here, so
# a bucket-wide read grant doesn't expose anything beyond what's intended.
data "aws_iam_policy_document" "openapi_spec_public_read" {
  statement {
    sid       = "PublicReadOpenApiSpecBucket"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.openapi_spec.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "openapi_spec" {
  bucket     = aws_s3_bucket.openapi_spec.id
  policy     = data.aws_iam_policy_document.openapi_spec_public_read.json
  depends_on = [aws_s3_bucket_public_access_block.openapi_spec]
}

# SSE-S3 (AES256), deliberately not a customer-managed KMS key like every
# other encrypted resource in this repo -- that pattern exists to require a
# *second*, specific grant (kms:Decrypt) beyond IAM/bucket-policy access
# before someone can read data, but this bucket's entire point is anonymous
# public readability. A KMS key here would either have to grant
# kms:Decrypt to everyone too (pointless) or actively break public GETs.
# trivy:ignore:AWS-0132 SSE-S3 is deliberate here, not a missing CMK -- see comment above
resource "aws_s3_bucket_server_side_encryption_configuration" "openapi_spec" {
  bucket = aws_s3_bucket.openapi_spec.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CORS so docs.civicdog.com's client-side fetch() of openapi.json passes its
# browser preflight (cd-website#1's Scalar viewer) -- curl/server-side
# fetches never hit this, only browsers enforce CORS, which is why the
# object being publicly readable wasn't enough on its own (cd-infra#20).
# AllowedHeaders is "*" and AllowedMethods is GET-only since this bucket
# serves one public, non-sensitive JSON file -- a wildcard on headers costs
# nothing here and avoids preflight rejections over incidental headers
# browsers may attach. "http://localhost:*" (a single wildcard, S3 CORS
# supports one per AllowedOrigin string) covers any local dev server port
# for the docs app rather than pinning to Astro's current default (4322).
resource "aws_s3_bucket_cors_configuration" "openapi_spec" {
  bucket = aws_s3_bucket.openapi_spec.id

  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = [
      "https://docs.civicdog.com",
      "http://localhost:*",
    ]
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

# Extends cd-api-deploy (above) rather than minting a second role -- it's
# already the identity cd-api-deploy.yml assumes via GitHub OIDC for
# cd-api-vX.X.X tag deploys, and a single GitHub Actions job can only
# cleanly assume one role. Scoped to the one expected key, unlike the
# public-read policy above -- writes are the security-sensitive direction
# here, reads are the whole point of the bucket.
data "aws_iam_policy_document" "cd_api_deploy_openapi_publish" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.openapi_spec.arn}/openapi.json"]
  }
}

resource "aws_iam_role_policy" "cd_api_deploy_openapi_publish" {
  name   = "cd-platform-cd-api-deploy-openapi-publish"
  role   = aws_iam_role.cd_api_deploy.id
  policy = data.aws_iam_policy_document.cd_api_deploy_openapi_publish.json
}

# --- Custom domain: api.civicdog.com, /v1 base path (cd-website versioning
# decision) ----------------------------------------------------------------
#
# URL-path versioning, not a request header: API Gateway REST API v1 has no
# native way to route on a header value to a different backend -- routing
# is resource-path + method only. base_path_mapping is first-class native
# support for exactly this, and needs zero cd-api application code changes
# (the "v1" segment is a routing-layer construct, stripped before reaching
# the Lambda -- the same way the "prod" stage segment already is on the
# existing execute-api URL, which is why cd-api's FastAPI routes are plain
# "/members" today, not "/prod/members"). Confirm this on the real apply
# rather than trusting the analogy blindly.

resource "aws_acm_certificate" "api_domain" {
  provider          = aws.us_east_1
  domain_name       = var.api_domain_name
  validation_method = "DNS"

  tags = {
    Project = "cd-platform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# domain_validation_options is a *set* (same unordered-block gotcha as
# amplify/'s sub_domain) -- there's only one element here (one domain, no
# SANs), so tolist(...)[0] is enough, no for+if filtering needed.
#
# api_base_path is the single source of truth for the "v1" segment --
# referenced by both the base_path_mapping below and outputs.tf's
# api_custom_domain_url, so the two can't drift out of sync the way two
# separate hardcoded "v1" literals could.
locals {
  api_domain_validation = tolist(aws_acm_certificate.api_domain.domain_validation_options)[0]
  api_base_path         = "v1"
}

# trimsuffix: same trailing-"." lesson from amplify/'s ACM-adjacent DNS
# records -- AWS returns these as fully-qualified values, Cloudflare
# doesn't store the trailing dot as part of `content`.
resource "cloudflare_record" "api_domain_validation" {
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(local.api_domain_validation.resource_record_name, ".")
  type    = local.api_domain_validation.resource_record_type
  content = trimsuffix(local.api_domain_validation.resource_record_value, ".")
  ttl     = 300
  proxied = false
}

# Unlike amplify/'s domain association, this doesn't need a
# wait_for_verification=false workaround -- the cert request and its
# validation are two separate resources with a normal dependency chain
# (cert -> Cloudflare record -> validation), so by the time this resource
# is created the DNS it needs to see already exists. No structural deadlock
# here the way there was there.
resource "aws_acm_certificate_validation" "api_domain" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.api_domain.arn
  validation_record_fqdns = [cloudflare_record.api_domain_validation.hostname]
}

resource "aws_api_gateway_domain_name" "cd_api" {
  domain_name     = var.api_domain_name
  certificate_arn = aws_acm_certificate_validation.api_domain.certificate_arn
  # Explicit -- defaults to an outdated TLS policy otherwise (caught by a
  # real Trivy finding, AWS-0005, not a guess).
  security_policy = "TLS_1_2"

  endpoint_configuration {
    types = ["EDGE"]
  }

  tags = {
    Project = "cd-platform"
  }

  # Matches aws_acm_certificate.api_domain's own lifecycle block above, and
  # for the same reason: domain_name is ForceNew, so without this a future
  # change to var.api_domain_name would destroy the live custom domain (and
  # its dependent base_path_mapping/CNAME) before creating the replacement
  # -- an avoidable outage window instead of a zero-downtime cutover.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_base_path_mapping" "cd_api_v1" {
  api_id      = aws_api_gateway_rest_api.cd_api.id
  stage_name  = aws_api_gateway_stage.cd_api.stage_name
  domain_name = aws_api_gateway_domain_name.cd_api.domain_name
  base_path   = local.api_base_path
}

resource "cloudflare_record" "api_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "api"
  type    = "CNAME"
  content = aws_api_gateway_domain_name.cd_api.cloudfront_domain_name
  ttl     = 300
  # Grey-cloud (DNS-only), same reasoning as amplify/'s records -- this is
  # already backed by CloudFront (API Gateway's EDGE endpoint), so stacking
  # Cloudflare's own proxy on top would be two CDNs in front of each other
  # for no benefit.
  proxied = false
}
