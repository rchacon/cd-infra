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

  # Flat at the zip root, matching cd-platform-cd-api-deploy.yml's real,
  # merged build step (`cp src/*.py package/`) -- see #12. app.py's own
  # sibling imports (`from db import ...` etc.) are absolute, so they only
  # resolve if those modules sit alongside it in the same importable
  # location; a src/-nested layout only lets `import src.app` succeed, not
  # app.py's own internal imports once inside it. This has to match the
  # real deploy's structure, or the handler config below would be right
  # for the real code but wrong for this placeholder (or vice versa),
  # breaking the plan's own "aws lambda invoke against the placeholder
  # confirms wiring" verification step.
  source {
    filename = "app.py"
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

resource "aws_lambda_function" "cd_api" {
  function_name = "cd-platform-cd-api"
  role          = aws_iam_role.lambda.arn
  # cd-platform/cd-api/src/app.py's `handler = Mangum(app)`, but flat
  # ("app.handler") not "src.app.handler" -- see #12. app.py's sibling
  # imports are absolute (`from db import ...` etc.), so they only resolve
  # if those modules are flat alongside it, not nested under src/; the
  # real, merged cd-api-deploy.yml (`cp src/*.py package/`, confirmed via
  # its own `from app import handler` sanity-check step) already builds
  # its zip this way.
  handler = "app.handler"
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
      values   = ["repo:${var.github_repository_owner}/cd-platform:ref:refs/tags/cd-api-v*"]
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
