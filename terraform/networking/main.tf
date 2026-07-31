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

  # All traffic control in this project happens via the security groups
  # below, not network ACLs -- leave the default ACL (already allow-all on a
  # fresh VPC) unmanaged rather than granting the IAM permissions needed to
  # own it (CreateNetworkAclEntry/DeleteNetworkAclEntry/ReplaceNetworkAclEntry).
  manage_default_network_acl = false

  tags = {
    Project = "cd-platform"
  }
}

# Groups are declared with zero inline ingress/egress blocks -- every rule
# below lives in its own aws_vpc_security_group_*_rule resource instead.
# rds's ingress references airflow/lambda, while airflow/lambda's egress
# references rds right back; inline blocks can't express that mutual
# reference (Terraform would need to create both groups' full rule sets in
# the same API call as each group itself, which is a real dependency
# cycle). Separate rule resources break the cycle: all three groups get
# created first (they don't reference each other), then the rules attach
# afterward. Terraform still strips AWS's create-time default allow-all
# egress on each group regardless of this split, so nothing here ends up
# with unintended open egress by default.
resource "aws_security_group" "rds" {
  name_prefix = "cd-platform-rds-"
  description = "Allow Postgres from the Airflow EC2 instance and cd-api Lambda only"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_security_group" "airflow" {
  name_prefix = "cd-platform-airflow-"
  description = "cd-etl self-hosted Airflow EC2 instance -- reaches RDS, S3, and api.congress.gov"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_security_group" "lambda" {
  name_prefix = "cd-platform-lambda-"
  description = "cd-api Lambda -- reaches RDS (via RDS Proxy, see #4)"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_airflow" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from the Airflow EC2 instance"
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.airflow.id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "Postgres from cd-api Lambda"
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

# #4's RDS Proxy reuses this same lambda SG (rather than a new dedicated
# one) so the rds_from_lambda rule above already covers proxy->RDS traffic
# -- but custom (non-default) security groups don't implicitly allow
# same-SG traffic, so Lambda->Proxy still needs this explicit
# self-referencing rule.
resource "aws_vpc_security_group_ingress_rule" "lambda_from_lambda" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "Postgres to RDS Proxy, from cd-api Lambda itself (same SG)"
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

# rds has no egress rules at all: it only responds to the inbound
# connections allowed above (security groups are stateful, so return
# traffic doesn't need its own rule) and doesn't itself initiate outbound
# connections in this setup.

resource "aws_vpc_security_group_egress_rule" "airflow_https" {
  security_group_id = aws_security_group.airflow.id
  description       = "HTTPS to api.congress.gov, PyPI, and AWS APIs -- arbitrary internet destinations with no fixed IP ranges to scope to"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  # Destinations (api.congress.gov, PyPI) aren't fixed IP ranges, so this
  # can't be narrowed further without VPC endpoints -- accepted for this
  # project's current stage.
  #trivy:ignore:AWS-0104
  cidr_ipv4 = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "airflow_to_rds" {
  security_group_id            = aws_security_group.airflow.id
  description                  = "Postgres to RDS"
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds.id
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_rds" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "Postgres to RDS"
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.rds.id
}
