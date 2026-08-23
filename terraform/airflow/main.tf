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

# cd-infra#42: the KMS key and both secrets below moved to ../airflow-ecs
# (via `terraform state mv`, still the same live AWS resources) since it's
# the one that still needs them going forward. Referenced here only via
# read-only data lookups (by name/alias, not by owning the resource) --
# this instance and its supporting IAM are being decommissioned, so these
# just need to resolve correctly one last time for a clean `terraform
# destroy`, not stay reusable long-term.
data "aws_kms_alias" "airflow" {
  name = "alias/cd-platform-airflow"
}

data "aws_secretsmanager_secret" "congress_api_key" {
  name = "cd-platform/airflow/congress-api-key"
}

data "aws_secretsmanager_secret" "cd_etl_app_db" {
  name = "cd-platform/airflow/cd-etl-db-credentials"
}

data "aws_iam_policy_document" "airflow_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "airflow" {
  name               = "cd-platform-airflow-ec2"
  assume_role_policy = data.aws_iam_policy_document.airflow_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_iam_instance_profile" "airflow" {
  name = "cd-platform-airflow-ec2"
  role = aws_iam_role.airflow.name
}

# This is the EC2 instance's own runtime role -- distinct from the
# cd-terraform deployer user's IAM policy (hand-managed in the AWS Console,
# built up empirically per CLAUDE.md's IAM section). The instance needs
# these permissions at boot regardless of who runs `terraform apply`.
data "aws_iam_policy_document" "airflow_instance" {
  statement {
    sid     = "ReadSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      data.aws_secretsmanager_secret.congress_api_key.arn,
      data.aws_secretsmanager_secret.cd_etl_app_db.arn,
      data.terraform_remote_state.rds.outputs.master_user_secret_arn,
    ]
  }

  # Per CLAUDE.md's alias-ARN gotcha: alias-scoped statements need the
  # alias ARN directly in Resource (no kms:AliasName condition key exists),
  # plus a separate grant on the underlying key -- both included here
  # rather than relying on either alone.
  statement {
    sid     = "DecryptAirflowSecrets"
    actions = ["kms:Decrypt"]
    resources = [
      data.aws_kms_alias.airflow.target_key_arn,
      data.aws_kms_alias.airflow.arn,
    ]
  }

  statement {
    sid       = "DecryptRdsMasterSecret"
    actions   = ["kms:Decrypt"]
    resources = [data.terraform_remote_state.rds.outputs.rds_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "airflow_instance" {
  name   = "cd-platform-airflow-ec2"
  role   = aws_iam_role.airflow.id
  policy = data.aws_iam_policy_document.airflow_instance.json
}

# Lets the SSM Agent (preinstalled on Amazon Linux 2023) register this
# instance and support Session Manager sessions/port-forwarding -- the only
# way to reach the Airflow UI (port 8080) or a shell on this instance,
# since it has no public ingress at all (see networking/'s airflow security
# group, which defines zero ingress rules).
resource "aws_iam_role_policy_attachment" "airflow_ssm" {
  role       = aws_iam_role.airflow.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# x86_64, not arm64/Graviton -- confirmed on a real deploy that cd-etl's
# GHCR image is amd64-only (cd-platform's cd-etl-deploy.yml builds on
# ubuntu-latest with no `platforms:` set, so it only ever produces
# linux/amd64), and Docker won't run a mismatched-architecture image
# without QEMU emulation set up, which this instance doesn't have. Not
# worth making cd-platform's build multi-arch just to reclaim Graviton's
# ~$3/mo edge on a single small instance.
#
# Resolves to AWS's current AL2023 x86_64 build at first apply -- no AMI ID
# goes stale in version control. Only read once, though (see the
# instance's lifecycle.ignore_changes below): re-resolving this on every
# plan would otherwise show an unprompted instance replacement each time
# AWS publishes a new build, since `ami` is a ForceNew attribute.
data "aws_ssm_parameter" "al2023_x86_64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "airflow" {
  ami                    = data.aws_ssm_parameter.al2023_x86_64.value
  instance_type          = var.instance_type
  subnet_id              = data.terraform_remote_state.networking.outputs.private_subnet_ids[0]
  vpc_security_group_ids = [data.terraform_remote_state.networking.outputs.airflow_security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.airflow.name

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region                  = var.aws_region
    congress_api_key_secret_arn = data.aws_secretsmanager_secret.congress_api_key.arn
    cd_etl_app_db_secret_arn    = data.aws_secretsmanager_secret.cd_etl_app_db.arn
    rds_master_secret_arn       = data.terraform_remote_state.rds.outputs.master_user_secret_arn
    rds_address                 = data.terraform_remote_state.rds.outputs.rds_address
    airflow_metadata_db_name    = var.airflow_metadata_db_name
    cd_etl_db_username          = var.cd_etl_db_username
    ghcr_image                  = "ghcr.io/${var.github_repository_owner}/cd-etl"
    airflow_parallelism         = var.airflow_parallelism
  })
  # Without this, Terraform only runs user_data on first boot -- editing the
  # template and re-applying would silently no-op against an
  # already-running instance. Forcing a replacement is the more predictable
  # behavior here, at the cost of a brief downtime window on every
  # user-data edit -- acceptable for a single once-a-day batch job with no
  # live traffic to preserve.
  user_data_replace_on_change = true

  # Ignore subsequent AMI changes after first creation -- otherwise every
  # AWS-published AL2023 arm64 build would show as an unprompted
  # replacement on a routine `plan`, since `ami` is ForceNew. Bump this
  # deliberately (temporarily remove the ignore, or taint the instance)
  # when an AMI update is actually wanted.
  lifecycle {
    ignore_changes = [ami]
  }

  # Enforces IMDSv2 (session-token-authenticated instance metadata calls) --
  # the AWS provider defaults http_tokens to "optional", which still allows
  # the older, SSRF-exploitable IMDSv1 style of unauthenticated requests.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Reuses the same customer-managed KMS key as the Secrets Manager secret
  # above, rather than the AWS-managed default -- consistent with this
  # project's KMS pattern (see CLAUDE.md), at no extra cost since the key
  # already exists.
  root_block_device {
    encrypted  = true
    kms_key_id = data.aws_kms_alias.airflow.target_key_arn
  }

  tags = {
    Project = "cd-platform"
    Name    = "cd-platform-airflow"
  }
}
