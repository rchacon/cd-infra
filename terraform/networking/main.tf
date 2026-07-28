locals {
  postgres_port = 5432
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "cd-platform"
  cidr = var.vpc_cidr

  azs = var.azs
  # Private subnets host RDS, the Airflow EC2 instance, and cd-api's Lambda.
  # Public subnets only host the NAT gateway(s) -- nothing else runs in them.
  private_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  public_subnets  = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 100)]

  enable_nat_gateway     = var.enable_nat_gateway
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = false

  # Needed for RDS/VPC-endpoint DNS resolution from within the VPC.
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "cd-platform-rds-"
  description = "Allow Postgres from the Airflow EC2 instance and cd-api's Lambda only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Postgres from the Airflow EC2 instance"
    from_port       = local.postgres_port
    to_port         = local.postgres_port
    protocol        = "tcp"
    security_groups = [aws_security_group.airflow.id]
  }

  ingress {
    description     = "Postgres from cd-api's Lambda"
    from_port       = local.postgres_port
    to_port         = local.postgres_port
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # No egress block: RDS only responds to the inbound connections allowed
  # above (security groups are stateful, so return traffic doesn't need its
  # own rule) and doesn't itself initiate outbound connections in this
  # setup. Terraform's aws_security_group manages egress authoritatively,
  # so omitting this block means no egress is allowed at all -- not AWS's
  # create-time default of allow-all.

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_security_group" "airflow" {
  name_prefix = "cd-platform-airflow-"
  description = "cd-etl's self-hosted Airflow EC2 instance -- reaches RDS, S3, and api.congress.gov"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "HTTPS to api.congress.gov, PyPI, and AWS APIs -- arbitrary internet destinations with no fixed IP ranges to scope to"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # Destinations (api.congress.gov, PyPI) aren't fixed IP ranges, so this
    # can't be narrowed further without VPC endpoints -- accepted for this
    # project's current stage.
    #trivy:ignore:AWS-0104
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "Postgres to RDS"
    from_port       = local.postgres_port
    to_port         = local.postgres_port
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_security_group" "lambda" {
  name_prefix = "cd-platform-lambda-"
  description = "cd-api's Lambda -- reaches RDS (via RDS Proxy, see #4)"
  vpc_id      = module.vpc.vpc_id

  egress {
    description     = "Postgres to RDS"
    from_port       = local.postgres_port
    to_port         = local.postgres_port
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}
