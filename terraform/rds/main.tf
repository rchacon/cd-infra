data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "networking/terraform.tfstate"
    region = var.aws_region
  }
}

# Customer-managed key (rather than the AWS-managed default) so reading the
# instance's underlying storage requires both RDS access *and*
# kms:Decrypt on this specific key -- same defense-in-depth reasoning as
# ../bootstrap's state-bucket key, and the same flat ~$1/mo.
resource "aws_kms_key" "rds" {
  description             = "Encrypts the RDS instance's storage."
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds" {
  name          = "alias/cd-platform-rds"
  target_key_id = aws_kms_key.rds.key_id
}

resource "aws_db_subnet_group" "this" {
  name       = "cd-platform-rds"
  subnet_ids = data.terraform_remote_state.networking.outputs.private_subnet_ids

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_db_parameter_group" "this" {
  name   = "cd-platform-postgres16"
  family = "postgres16"

  tags = {
    Project = "cd-platform"
  }
}

# Schema and the airflow_metadata database (for cd-infra#3) are
# deliberately NOT bootstrapped here -- this security group only ever
# accepts connections from the airflow/lambda security groups, so there's
# no durable way to reach this instance until #3's EC2 instance exists
# inside the VPC. #3's own scope applies the initial Alembic migration (and
# creates airflow_metadata) as part of its first deploy.
resource "aws_db_instance" "this" {
  identifier = "cd-platform"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  db_name  = "cd_platform"
  username = var.master_username

  # RDS-managed password via Secrets Manager -- no password/password_wo set,
  # so it's never stored in Terraform state in plaintext. Encrypted under
  # our own KMS key (not the AWS-managed default) for the same reason the
  # storage above is.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.rds.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [data.terraform_remote_state.networking.outputs.rds_security_group_id]
  parameter_group_name   = aws_db_parameter_group.this.name

  multi_az                   = false
  publicly_accessible        = false
  auto_minor_version_upgrade = true

  # No production data yet -- revisit once real data exists.
  skip_final_snapshot = true

  tags = {
    Project = "cd-platform"
  }
}
