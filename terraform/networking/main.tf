locals {
  # Shared by all three security groups below -- factored out so a future
  # egress-hardening change only needs to happen in one place.
  allow_all_egress = {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
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
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.airflow.id]
  }

  ingress {
    description     = "Postgres from cd-api's Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  dynamic "egress" {
    for_each = [local.allow_all_egress]
    content {
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

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

  dynamic "egress" {
    for_each = [local.allow_all_egress]
    content {
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
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

  dynamic "egress" {
    for_each = [local.allow_all_egress]
    content {
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}
