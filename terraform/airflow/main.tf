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
# CONGRESS_API_KEY requires both Secrets Manager access *and* kms:Decrypt
# on this specific key -- same defense-in-depth reasoning as
# ../bootstrap's state-bucket key and ../rds's storage key, and the same
# flat ~$1/mo.
resource "aws_kms_key" "airflow" {
  description             = "Encrypts CONGRESS_API_KEY in Secrets Manager."
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "airflow" {
  name          = "alias/cd-platform-airflow"
  target_key_id = aws_kms_key.airflow.key_id
}

resource "aws_secretsmanager_secret" "congress_api_key" {
  name       = "cd-platform/airflow/congress-api-key"
  kms_key_id = aws_kms_key.airflow.arn

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_secretsmanager_secret_version" "congress_api_key" {
  secret_id     = aws_secretsmanager_secret.congress_api_key.id
  secret_string = var.congress_api_key
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
      aws_secretsmanager_secret.congress_api_key.arn,
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
      aws_kms_key.airflow.arn,
      aws_kms_alias.airflow.arn,
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

# Always resolves to AWS's current AL2023 arm64 build (matching t4g's
# Graviton architecture) -- no AMI ID goes stale in version control, and
# what actually matters functionally is the user_data below, not the exact
# base AMI.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "airflow" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = data.terraform_remote_state.networking.outputs.private_subnet_ids[0]
  vpc_security_group_ids = [data.terraform_remote_state.networking.outputs.airflow_security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.airflow.name

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region                  = var.aws_region
    congress_api_key_secret_arn = aws_secretsmanager_secret.congress_api_key.arn
    rds_master_secret_arn       = data.terraform_remote_state.rds.outputs.master_user_secret_arn
    rds_address                 = data.terraform_remote_state.rds.outputs.rds_address
    airflow_metadata_db_name    = var.airflow_metadata_db_name
    ghcr_image                  = "ghcr.io/${var.github_repository_owner}/cd-etl"
  })
  # Without this, Terraform only runs user_data on first boot -- editing the
  # template and re-applying would silently no-op against an
  # already-running instance. Forcing a replacement is the more predictable
  # behavior here, at the cost of a brief downtime window on every
  # user-data edit -- acceptable for a single once-a-day batch job with no
  # live traffic to preserve.
  user_data_replace_on_change = true

  tags = {
    Project = "cd-platform"
    Name    = "cd-platform-airflow"
  }
}
