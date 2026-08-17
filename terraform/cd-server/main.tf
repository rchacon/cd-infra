data "terraform_remote_state" "networking" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "networking/terraform.tfstate"
    region = var.aws_region
  }
}

# Only for cd_api's lambda_function_name output -- cd-server's
# LambdaApiClient calls that function directly via boto3, not over
# HTTP/VPC networking, so this is the one thing this module needs from
# ../cd-api's state.
data "terraform_remote_state" "cd_api" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "cd-api/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_lambda_function" "cd_api" {
  function_name = data.terraform_remote_state.cd_api.outputs.lambda_function_name
}

# --- KMS ------------------------------------------------------------------
#
data "aws_caller_identity" "current" {}

# Customer-managed key (rather than the AWS-managed default), used only for
# the ECS container instance's root EBS volume -- same defense-in-depth
# reasoning as every other customer-managed key in this repo (see
# CLAUDE.md), same flat ~$1/mo. Deliberately NOT used for the CloudWatch
# log group below: CloudWatch Logs needs an explicit KMS *key policy*
# grant for the logs service principal (not just an IAM identity policy),
# a real extra failure mode this module sidesteps by leaving the log group
# on CloudWatch's own default encryption instead.
#
# Needs an explicit key *policy* (not just an IAM identity policy on
# cd-terraform), confirmed the hard way on a real apply:
# aws_autoscaling_group.cd_server's instances failed to launch with
# "Client.InvalidKMSKey.InvalidState: The KMS key provided is in an
# incorrect state" -- the ASG launches instances under its own
# account-wide service-linked role (AWSServiceRoleForAutoScaling), not
# under cd-terraform, and that role has no KMS permissions of its own.
# AWS's default EBS KMS key has this access baked in implicitly; a
# customer-managed key needs it granted explicitly in the key's own
# policy, per AWS's documented "key policy requirements for encrypted
# EBS volumes with Auto Scaling" -- an IAM identity-side grant to the
# service-linked role isn't possible at all (it's AWS-managed, not
# something this project's IAM can attach a policy to).
data "aws_iam_policy_document" "cd_server_kms" {
  # Same "Enable IAM User Permissions" statement aws_kms_key would use by
  # default if `policy` were left unset -- included explicitly here since
  # supplying a custom policy replaces that default entirely, and losing
  # it would lock the account root/IAM out of managing this key going
  # forward.
  statement {
    sid       = "EnableIamUserPermissions"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowAutoScalingServiceLinkedRoleUse"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
  }

  statement {
    sid       = "AllowAutoScalingServiceLinkedRoleGrant"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "cd_server" {
  description             = "Encrypts the cd-server ECS container instance's root EBS volume."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cd_server_kms.json
}

resource "aws_kms_alias" "cd_server" {
  name          = "alias/cd-platform-cd-server"
  target_key_id = aws_kms_key.cd_server.key_id
}

# --- Logs -------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cd_server" {
  name              = "/ecs/cd-platform-cd-server"
  retention_in_days = 14

  tags = {
    Project = "cd-platform"
  }
}

# --- ECS cluster --------------------------------------------------------

resource "aws_ecs_cluster" "cd_server" {
  name = "cd-platform-cd-server"

  tags = {
    Project = "cd-platform"
  }
}

# --- EC2 container instance role -----------------------------------------
#
# The instance's own runtime role -- distinct from the cd-terraform
# deployer user's IAM policy (hand-managed in the AWS Console, per
# CLAUDE.md's IAM section).

data "aws_iam_policy_document" "ecs_instance_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_instance" {
  name               = "cd-platform-cd-server-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.ecs_instance_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# Lets the SSM Agent register this instance and support Session Manager
# sessions -- same "no public ingress, admin access via SSM only" posture
# as ../airflow's instance.
resource "aws_iam_role_policy_attachment" "ecs_instance_ssm" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Standard AWS-managed policy letting the ECS agent (running on this
# instance) register/deregister the container instance, discover its
# cluster, and report task/container state back to ECS.
resource "aws_iam_role_policy_attachment" "ecs_instance_ecs" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "cd-platform-cd-server-ecs-instance"
  role = aws_iam_role.ecs_instance.name
}

# --- Launch template + ASG -------------------------------------------------

# ECS-optimized AL2023 AMI -- ships with the ECS agent and Docker
# preinstalled, unlike ../airflow's plain AL2023 AMI (which needed Docker
# installed by hand in user-data). x86_64, not arm64/Graviton: matches
# ../airflow's precedent that cd-platform's GHA runners build amd64-only
# images (no `platforms:` set in cd-server-deploy.yml either).
#
# No ignore_changes needed here, unlike ../airflow's raw aws_instance
# (where `ami` is ForceNew and ../airflow/main.tf explicitly ignores it) --
# a launch template's image_id isn't ForceNew, it just publishes a new
# template version on every AMI update. The ASG below always launches
# against "$Latest", but existing instances aren't touched until they're
# next replaced (or an explicit instance refresh is run), so a new AMI
# build never shows as an unprompted replacement on a routine `plan`.
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_launch_template" "cd_server" {
  name_prefix   = "cd-platform-cd-server-"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  vpc_security_group_ids = [data.terraform_remote_state.networking.outputs.cd_server_security_group_id]

  # No Docker Compose/manual bootstrap needed here, unlike
  # ../airflow/templates/user-data.sh.tftpl -- the ECS-optimized AMI's
  # agent starts on boot and just needs to know which cluster to join.
  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.cd_server.name}" >> /etc/ecs/ecs.config
  EOF
  )

  # Enforces IMDSv2 -- same reasoning as ../airflow's instance (the AWS
  # provider defaults http_tokens to "optional", which still allows the
  # older, SSRF-exploitable IMDSv1 style of unauthenticated requests).
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted  = true
      kms_key_id = aws_kms_key.cd_server.arn
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Project = "cd-platform"
      Name    = "cd-platform-cd-server"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "cd_server" {
  name_prefix         = "cd-platform-cd-server-"
  vpc_zone_identifier = data.terraform_remote_state.networking.outputs.private_subnet_ids
  min_size            = var.instance_count
  max_size            = var.instance_count
  desired_capacity    = var.instance_count

  launch_template {
    id      = aws_launch_template.cd_server.id
    version = "$Latest"
  }

  # Required for the capacity provider's managed_termination_protection
  # below -- ECS, not the ASG's own scale-in policy, decides when an
  # instance can actually be terminated (only once it's drained of tasks).
  protect_from_scale_in = true

  lifecycle {
    create_before_destroy = true
  }
}

# --- ECS capacity provider -------------------------------------------------

resource "aws_ecs_capacity_provider" "cd_server" {
  name = "cd-platform-cd-server"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.cd_server.arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status          = "ENABLED"
      target_capacity = 100
    }
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_cluster_capacity_providers" "cd_server" {
  cluster_name       = aws_ecs_cluster.cd_server.name
  capacity_providers = [aws_ecs_capacity_provider.cd_server.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.cd_server.name
    weight            = 1
  }
}

# --- Task execution role (pulls the image, ships logs) ---------------------

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "cd-platform-cd-server-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# Covers CloudWatch Logs (CreateLogStream/PutLogEvents) for the awslogs
# driver below. Also covers ECR auth, unused here -- cd-server's image is
# pulled anonymously from GHCR (public package, same as cd-etl's), never
# ECR -- harmless if unneeded, same "grant the standard policy, don't
# hand-carve it" approach as ../cd-api's Lambda VPC policy attachment.
resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- Task role (the running container's own permissions) -------------------

resource "aws_iam_role" "task" {
  name               = "cd-platform-cd-server-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

data "aws_iam_policy_document" "task_permissions" {
  # The one runtime permission cd-server's LambdaApiClient actually needs
  # -- it invokes ../cd-api's Lambda directly via boto3, bypassing API
  # Gateway/network access entirely (see cd-platform's cd-server README).
  statement {
    sid       = "InvokeCdApiLambda"
    actions   = ["lambda:InvokeFunction"]
    resources = [data.aws_lambda_function.cd_api.arn]
  }

  # ECS Exec (enable_execute_command below) -- same "no more manual
  # instance-hopping to debug" rationale cd-infra#24 used for Airflow's
  # planned task roles.
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_permissions" {
  name   = "cd-platform-cd-server-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_permissions.json
}

# --- Task definition ---------------------------------------------------

# bridge networking (not awsvpc) -- avoids per-task ENI cost/churn, same
# choice cd-infra#24 makes for Airflow's planned task defs. hostPort = 0
# (dynamic mapping) rather than a fixed 8000 -- lets more tasks land on
# the same instance later without an SG/target-group rework; the ALB
# target group below (target_type = "instance") auto-tracks whatever port
# ECS actually assigns.
resource "aws_ecs_task_definition" "cd_server" {
  family                   = "cd-platform-cd-server"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "cd-server"
      image     = "ghcr.io/${var.github_repository_owner}/cd-server:latest"
      essential = true
      memory    = var.container_memory

      portMappings = [
        {
          containerPort = 8000
          hostPort      = 0
          protocol      = "tcp"
        }
      ]

      # CD_SERVER_ENVIRONMENT anything other than "local" picks
      # LambdaApiClient over HttpApiClient (see cd-server/src/cd/server/
      # settings.py) -- CD_API_BASE_URL is irrelevant in that mode.
      # GRAPHIQL_ENABLED is deliberately unset -- already off by default
      # in the production image (app.py/schema.py), unlike
      # docker-compose.yml's dev service which sets it to "true".
      environment = [
        { name = "CD_SERVER_ENVIRONMENT", value = "production" },
        { name = "CD_API_FUNCTION_NAME", value = data.aws_lambda_function.cd_api.function_name },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cd_server.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "cd-server"
        }
      }
    }
  ])

  tags = {
    Project = "cd-platform"
  }
}

# --- ALB --------------------------------------------------------------

resource "aws_lb" "cd_server" {
  name = "cd-platform-cd-server"
  # Public by design -- this is server.civicdog.com's front door, not an
  # internal asset accidentally exposed.
  #trivy:ignore:AWS-0053
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.terraform_remote_state.networking.outputs.alb_security_group_id]
  subnets            = data.terraform_remote_state.networking.outputs.public_subnet_ids

  # Strips non-conforming HTTP headers rather than passing them through to
  # the target -- guards against header-smuggling-style abuse.
  drop_invalid_header_fields = true

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_lb_target_group" "cd_server" {
  name        = "cd-platform-cd-server"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.terraform_remote_state.networking.outputs.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.cd_server.arn
  port              = 443
  protocol          = "HTTPS"
  # Explicit -- defaults to an outdated TLS policy otherwise (same
  # Trivy-caught reasoning as ../cd-api's API Gateway domain's
  # security_policy).
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = aws_acm_certificate_validation.server_domain.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cd_server.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.cd_server.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# --- ECS service ------------------------------------------------------

resource "aws_ecs_service" "cd_server" {
  name            = "cd-platform-cd-server"
  cluster         = aws_ecs_cluster.cd_server.id
  task_definition = aws_ecs_task_definition.cd_server.arn
  desired_count   = var.instance_count

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.cd_server.name
    weight            = 1
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.cd_server.arn
    container_name   = "cd-server"
    container_port   = 8000
  }

  # ECS-native replacement for docker exec via SSM RunCommand -- see the
  # task role's EcsExec permissions above.
  enable_execute_command = true

  # The service needs something to register with before it exists --
  # without this, Terraform could create the service before the listener
  # (and therefore the target group's association with a live ALB) is
  # ready.
  depends_on = [aws_lb_listener.https]

  tags = {
    Project = "cd-platform"
  }
}

# --- Custom domain: server.civicdog.com ------------------------------
#
# Unlike ../cd-api's/../cd-webapp's CloudFront-backed custom domains, an
# ALB is regional -- its ACM certificate is requested in var.aws_region
# directly (see versions.tf's comment), no us-east-1 provider alias
# needed. DNS validation + the final CNAME both go through Cloudflare,
# same pattern as ../cd-api's api.civicdog.com (main.tf:608-716).

resource "aws_acm_certificate" "server_domain" {
  domain_name       = var.server_domain_name
  validation_method = "DNS"

  tags = {
    Project = "cd-platform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# domain_validation_options is a set with one element here (one domain, no
# SANs) -- tolist(...)[0] is enough, same as ../cd-api's identical
# pattern.
locals {
  server_domain_validation = tolist(aws_acm_certificate.server_domain.domain_validation_options)[0]
}

# trimsuffix: AWS returns these as fully-qualified values with a trailing
# dot; Cloudflare doesn't store that as part of `content` -- same lesson
# as ../cd-api's/../amplify's ACM-adjacent DNS records.
resource "cloudflare_record" "server_domain_validation" {
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(local.server_domain_validation.resource_record_name, ".")
  type    = local.server_domain_validation.resource_record_type
  content = trimsuffix(local.server_domain_validation.resource_record_value, ".")
  ttl     = 300
  proxied = false
}

resource "aws_acm_certificate_validation" "server_domain" {
  certificate_arn         = aws_acm_certificate.server_domain.arn
  validation_record_fqdns = [cloudflare_record.server_domain_validation.hostname]
}

resource "cloudflare_record" "server_domain" {
  zone_id = var.cloudflare_zone_id
  name    = "server"
  type    = "CNAME"
  content = aws_lb.cd_server.dns_name
  ttl     = 300
  # Grey-cloud (DNS-only) -- same reasoning as every other civicdog.com
  # record in this repo: no benefit to stacking Cloudflare's proxy in
  # front of a resource that already terminates its own TLS (here, the
  # ALB's own ACM cert).
  proxied = false
}

# --- GitHub OIDC deploy role (for a future cd-server-deploy.yml step) ---
#
# Provisions the role only -- wiring `aws ecs update-service
# --force-new-deployment` into cd-platform's cd-server-deploy.yml on every
# cd-server-vX.X.X tag push is a cd-platform-side follow-up, out of scope
# here (cd-infra#24 calls out the same split for Airflow's case: Terraform
# provisions the infra, the deploy pipeline's own force-new-deployment
# step is a separate concern with its own owner).

data "aws_iam_policy_document" "cd_server_deploy_assume_role" {
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
      values   = ["repo:${var.github_repository_owner}@${var.github_owner_id}/cd-platform@${var.github_repo_id}:ref:refs/tags/cd-server-v*"]
    }
  }
}

resource "aws_iam_role" "cd_server_deploy" {
  name               = "cd-platform-cd-server-deploy"
  assume_role_policy = data.aws_iam_policy_document.cd_server_deploy_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

data "aws_iam_policy_document" "cd_server_deploy_permissions" {
  statement {
    actions = [
      "ecs:UpdateService",
      "ecs:DescribeServices",
    ]
    resources = [aws_ecs_service.cd_server.id]
  }
}

resource "aws_iam_role_policy" "cd_server_deploy" {
  name   = "cd-platform-cd-server-deploy"
  role   = aws_iam_role.cd_server_deploy.id
  policy = data.aws_iam_policy_document.cd_server_deploy_permissions.json
}
