locals {
  postgres_port = 5432
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "cd-platform"
  cidr = var.vpc_cidr

  azs = var.azs
  # Private subnets host RDS, the Airflow EC2 instance, cd-api's Lambda,
  # and (../cd-server) the ECS EC2 instance running cd-server. Public
  # subnets host the NAT gateway(s) and (../cd-server) the ALB fronting
  # server.civicdog.com -- the first other thing to live there.
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

resource "aws_security_group" "alb" {
  name_prefix = "cd-platform-alb-"
  description = "cd-server public ALB -- server.civicdog.com"
  vpc_id      = module.vpc.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_security_group" "cd_server" {
  name_prefix = "cd-platform-cd-server-"
  description = "ECS EC2 instance running cd-server -- reachable only from the ALB"
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

# Egress counterpart to lambda_from_lambda's ingress rule above -- egress
# is evaluated on the traffic's source and ingress on its destination
# independently, so sharing one SG between Lambda and #4's RDS Proxy
# doesn't implicitly cover both directions; each needs its own explicit
# self-referencing rule.
resource "aws_vpc_security_group_egress_rule" "lambda_to_lambda" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "Postgres to RDS Proxy, from cd-api Lambda itself (same SG)"
  from_port                    = local.postgres_port
  to_port                      = local.postgres_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

# --- ../cd-server: ALB + ECS EC2 instance -----------------------------
#
# Same "zero inline rules" split as rds/airflow/lambda above -- alb's
# egress references cd_server, cd_server's ingress references alb right
# back.

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet -- server.civicdog.com"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet, redirected to HTTPS by the listener"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# Dynamic host port range, not a fixed 8000 -- the ECS task uses dynamic
# port mapping (hostPort = 0) so more tasks can land on the same instance
# later without an SG change. Covers Docker's/ECS's default ephemeral
# range.
resource "aws_vpc_security_group_egress_rule" "alb_to_cd_server" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Dynamic host port range, to the cd-server ECS instance"
  from_port                    = 32768
  to_port                      = 65535
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.cd_server.id
}

resource "aws_vpc_security_group_ingress_rule" "cd_server_from_alb" {
  security_group_id            = aws_security_group.cd_server.id
  description                  = "Dynamic host port range, from the ALB"
  from_port                    = 32768
  to_port                      = 65535
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

# GHCR image pulls, the Census geocoder API, Lambda's regional HTTPS
# endpoint (cd-server's LambdaApiClient), and SSM -- arbitrary internet
# destinations with no fixed IP ranges to scope to, same reasoning as
# airflow_https's egress rule above.
resource "aws_vpc_security_group_egress_rule" "cd_server_https" {
  security_group_id = aws_security_group.cd_server.id
  description       = "HTTPS to GHCR, the Census geocoder, AWS APIs (Lambda invoke, SSM)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  #trivy:ignore:AWS-0104
  cidr_ipv4 = "0.0.0.0/0"
}
