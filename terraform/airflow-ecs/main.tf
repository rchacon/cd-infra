# Every "scheduler"/"triggerer"/"dag-processor"/"api-server" container
# below sets entryPoint = ["airflow"], bypassing cd-etl's image
# ENTRYPOINT ["/entrypoint.sh"] entirely -- confirmed via cd-platform's
# actual entrypoint.sh that it runs `airflow db migrate` and `alembic
# upgrade head` *unconditionally*, before even looking at its arguments.
# Without this override, all 4 independent ECS services would race those
# migrations against RDS on every task start/restart. `airflow` is
# already on PATH (the image's own ENV sets
# PATH=/app/.venv/bin:${PATH}), so this needs no cd-platform-side change.
# The one task definition that *should* run migrations
# (aws_ecs_task_definition.migrate, below) deliberately keeps the
# image's default entrypoint instead.

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

# Only for its 5 new outputs (congress_api_key_secret_arn,
# cd_etl_app_db_secret_arn, airflow_kms_key_arn/_alias_arn,
# instance_private_ip is unused) -- this module reuses ../airflow's
# existing secrets/KMS key for the same underlying RDS role rather than
# provisioning duplicates. ../airflow's own EC2 instance keeps running
# unaffected throughout -- this module only reads its state, never
# writes to it.
data "terraform_remote_state" "airflow" {
  backend = "s3"
  config = {
    bucket = var.state_bucket_name
    key    = "airflow/terraform.tfstate"
    region = var.aws_region
  }
}

# --- Derived connection-string secrets -------------------------------
#
# Live read of ../airflow's existing cd_etl_app credentials (created
# there, not here) -- used only to interpolate the two connection
# strings below, never stored in this module's own state beyond what
# Terraform already tracks for any resource attribute.
data "aws_secretsmanager_secret_version" "cd_etl_app_db" {
  secret_id = data.terraform_remote_state.airflow.outputs.cd_etl_app_db_secret_arn
}

locals {
  cd_etl_app_db_creds = jsondecode(data.aws_secretsmanager_secret_version.cd_etl_app_db.secret_string)

  # Safe to interpolate directly with no URL-encoding -- ../airflow/main.tf's
  # random_password.cd_etl_app is special = false (alphanumeric-only),
  # unlike a general RDS-managed password. db name ("cd_platform") matches
  # ../rds/main.tf's aws_db_instance.this db_name, same as
  # ../airflow/templates/user-data.sh.tftpl's identical connection string.
  airflow_conn_congressional_postgres = "postgresql://${local.cd_etl_app_db_creds.username}:${local.cd_etl_app_db_creds.password}@${data.terraform_remote_state.rds.outputs.rds_address}:5432/cd_platform"
  airflow_metadata_sql_alchemy_conn   = "postgresql+psycopg2://${local.cd_etl_app_db_creds.username}:${local.cd_etl_app_db_creds.password}@${data.terraform_remote_state.rds.outputs.rds_address}:5432/${var.airflow_metadata_db_name}"
}

# Reuses ../airflow's existing KMS key (via remote state) rather than
# provisioning a second one -- this is the same underlying credential
# material, just precomputed into ready-to-inject connection strings so
# ECS's native `secrets` block can hand them to containers directly,
# without ../airflow/templates/user-data.sh.tftpl's boot-time
# env-var-assembly script (this module has no equivalent script at all --
# see templates/user-data.sh.tftpl, which only does the RDS bootstrap and
# ECS cluster registration).
# recovery_window_in_days = 0 on all 3 secrets in this module (below too)
# -- confirmed the hard way that AWS's default 30-day soft-delete window
# blocks recreating a same-named secret in one apply
# (InvalidRequestException: "already scheduled for deletion"), a real
# problem for a module still under active iteration. None of these hold
# hand-entered, irreplaceable data -- all 3 are either derived connection
# strings or a freshly Terraform-generated password, trivially
# regenerable from their real sources (RDS, random_password) -- so the
# 30-day recovery safety net isn't worth the recreate friction here.
resource "aws_secretsmanager_secret" "airflow_conn_congressional_postgres" {
  name                    = "cd-platform/airflow-ecs/airflow-conn-congressional-postgres"
  kms_key_id              = data.terraform_remote_state.airflow.outputs.airflow_kms_key_arn
  recovery_window_in_days = 0

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_secretsmanager_secret_version" "airflow_conn_congressional_postgres" {
  secret_id     = aws_secretsmanager_secret.airflow_conn_congressional_postgres.id
  secret_string = local.airflow_conn_congressional_postgres
}

resource "aws_secretsmanager_secret" "airflow_metadata_sql_alchemy_conn" {
  name                    = "cd-platform/airflow-ecs/airflow-metadata-sql-alchemy-conn"
  kms_key_id              = data.terraform_remote_state.airflow.outputs.airflow_kms_key_arn
  recovery_window_in_days = 0

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_secretsmanager_secret_version" "airflow_metadata_sql_alchemy_conn" {
  secret_id     = aws_secretsmanager_secret.airflow_metadata_sql_alchemy_conn.id
  secret_string = local.airflow_metadata_sql_alchemy_conn
}

# Durable FabAuthManager admin credential (cd-platform#74/#31,
# cd-platform#75) -- replaces SimpleAuthManager's auto-generated,
# plaintext-logged password that didn't survive container/task
# replacement. Provisioned once via the migrate task's `create-admin-user`
# invocation below (cd-etl/entrypoint.sh's dedicated hook, built
# specifically for this) -- idempotent (`users create` no-ops if the
# account exists, followed by an unconditional `users reset-password`),
# so re-running it after a password rotation here (a new secret version)
# actually takes effect, unlike a one-time `users create` alone would.
resource "random_password" "airflow_admin" {
  length = 32
  # No special characters -- passed as a literal CLI argument
  # (`--password "$AIRFLOW_ADMIN_PASSWORD"`) by entrypoint.sh's
  # create_admin_user(), same "sidestep shell-quoting entirely" reasoning
  # as ../airflow/main.tf's cd_etl_app password.
  special = false
}

resource "aws_secretsmanager_secret" "airflow_admin_password" {
  name                    = "cd-platform/airflow-ecs/airflow-admin-password"
  kms_key_id              = data.terraform_remote_state.airflow.outputs.airflow_kms_key_arn
  recovery_window_in_days = 0

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_secretsmanager_secret_version" "airflow_admin_password" {
  secret_id     = aws_secretsmanager_secret.airflow_admin_password.id
  secret_string = random_password.airflow_admin.result
}

# --- ECS cluster + Service Connect ------------------------------------
#
# HTTP namespace (not a private DNS namespace) -- Service Connect's own
# requirement, not tied to the VPC directly. Gives scheduler/triggerer/
# dag-processor a stable "api-server.airflow" DNS name for Task
# Execution API traffic, confirmed free (no Cloud Map namespace/
# registration charge -- only the small per-task sidecar proxy, already
# inside the t3.medium budget).
resource "aws_service_discovery_http_namespace" "airflow" {
  name        = "airflow"
  description = "ECS Service Connect namespace for cd-platform-airflow's services."

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_cluster" "airflow" {
  name = "cd-platform-airflow"

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.airflow.arn
  }

  tags = {
    Project = "cd-platform"
  }
}

# --- EC2 container instance role ---------------------------------------
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
  name               = "cd-platform-airflow-ecs-instance"
  assume_role_policy = data.aws_iam_policy_document.ecs_instance_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# Same first-boot bootstrap as ../airflow's instance role
# (../airflow/main.tf's airflow_instance policy) -- this instance ports
# the identical idempotent airflow_metadata/cd_etl_app bootstrap into its
# own templates/user-data.sh.tftpl, so it needs the same RDS-master-secret
# read + KMS decrypt access, plus read access to the existing cd_etl_app
# secret (to fetch its already-set password for the ALTER ROLE statement).
data "aws_iam_policy_document" "ecs_instance_bootstrap" {
  statement {
    sid     = "ReadBootstrapSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      data.terraform_remote_state.rds.outputs.master_user_secret_arn,
      data.terraform_remote_state.airflow.outputs.cd_etl_app_db_secret_arn,
    ]
  }

  statement {
    sid       = "DecryptRdsMasterSecret"
    actions   = ["kms:Decrypt"]
    resources = [data.terraform_remote_state.rds.outputs.rds_kms_key_arn]
  }

  # Per CLAUDE.md's alias-ARN gotcha: alias-scoped statements need the
  # alias ARN directly in Resource (no kms:AliasName condition key
  # exists), plus a separate grant on the underlying key.
  statement {
    sid     = "DecryptAirflowSecrets"
    actions = ["kms:Decrypt"]
    resources = [
      data.terraform_remote_state.airflow.outputs.airflow_kms_key_arn,
      data.terraform_remote_state.airflow.outputs.airflow_kms_alias_arn,
    ]
  }
}

resource "aws_iam_role_policy" "ecs_instance_bootstrap" {
  name   = "cd-platform-airflow-ecs-instance-bootstrap"
  role   = aws_iam_role.ecs_instance.id
  policy = data.aws_iam_policy_document.ecs_instance_bootstrap.json
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
# cluster, and report task/container state back to ECS. New vs.
# ../airflow's instance role -- that instance runs plain Docker Compose,
# never the ECS agent.
resource "aws_iam_role_policy_attachment" "ecs_instance_ecs" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "cd-platform-airflow-ecs-instance"
  role = aws_iam_role.ecs_instance.name
}

# --- Launch template + ASG -------------------------------------------------

# Same SSM-parameter/AMI pattern as ../cd-server/main.tf -- ships with
# the ECS agent and Docker preinstalled, unlike ../airflow's plain AL2023
# AMI. x86_64, not arm64/Graviton -- cd-etl's GHCR image is amd64-only
# (same confirmed precedent as ../airflow's own AMI choice).
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

resource "aws_launch_template" "airflow" {
  name_prefix   = "cd-platform-airflow-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  # Reuses ../networking's existing airflow security group as-is -- no
  # networking/ changes needed for this module at all. Its egress rules
  # (443 to internet, 5432 to RDS) already cover everything this instance
  # needs; same-host bridge-mode inter-container traffic never crosses
  # the SG boundary regardless.
  vpc_security_group_ids = [data.terraform_remote_state.networking.outputs.airflow_security_group_id]

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region               = var.aws_region
    rds_master_secret_arn    = data.terraform_remote_state.rds.outputs.master_user_secret_arn
    cd_etl_app_db_secret_arn = data.terraform_remote_state.airflow.outputs.cd_etl_app_db_secret_arn
    rds_address              = data.terraform_remote_state.rds.outputs.rds_address
    airflow_metadata_db_name = var.airflow_metadata_db_name
    cd_etl_db_username       = var.cd_etl_db_username
    ecs_cluster_name         = aws_ecs_cluster.airflow.name
  }))

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Deliberately no customer-managed kms_key_id here (default EBS
  # encryption instead) -- reusing ../airflow's existing key would need
  # that key's policy extended with an AWSServiceRoleForAutoScaling
  # grant (the same Client.InvalidKMSKey.InvalidState gotcha ../cd-server's
  # KMS key hit -- see its main.tf), and touching a second live module's
  # key policy for this new module is more blast radius than it's worth.
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      encrypted = true
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Project = "cd-platform"
      Name    = "cd-platform-airflow-ecs"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "airflow" {
  name_prefix         = "cd-platform-airflow-ecs-"
  vpc_zone_identifier = data.terraform_remote_state.networking.outputs.private_subnet_ids
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1

  launch_template {
    id      = aws_launch_template.airflow.id
    version = "$Latest"
  }

  # Required for the capacity provider's managed_termination_protection
  # below -- ECS, not the ASG's own scale-in policy, decides when an
  # instance can actually be terminated (only once it's drained of
  # tasks).
  protect_from_scale_in = true

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ecs_capacity_provider" "airflow" {
  name = "cd-platform-airflow"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.airflow.arn
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

resource "aws_ecs_cluster_capacity_providers" "airflow" {
  cluster_name       = aws_ecs_cluster.airflow.name
  capacity_providers = [aws_ecs_capacity_provider.airflow.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.airflow.name
    weight            = 1
  }
}

# --- Task execution role (pulls the image, ships logs, resolves secrets) --

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
  name               = "cd-platform-airflow-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# Covers CloudWatch Logs (CreateLogStream/PutLogEvents) for the awslogs
# driver below. Also covers ECR auth, unused here -- cd-etl's image is
# pulled anonymously from GHCR (public package), never ECR -- harmless
# if unneeded, same reasoning as ../cd-server's identical attachment.
resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The task execution role (not the task role) is what resolves each
# container definition's `secrets` block at task launch -- needs read
# access to all 5 secrets referenced below (2 reused from ../airflow, 3
# new ones provisioned in this module) plus decrypt on the KMS key
# protecting all of them.
data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    sid     = "ReadAirflowSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      data.terraform_remote_state.airflow.outputs.congress_api_key_secret_arn,
      data.terraform_remote_state.airflow.outputs.cd_etl_app_db_secret_arn,
      aws_secretsmanager_secret.airflow_conn_congressional_postgres.arn,
      aws_secretsmanager_secret.airflow_metadata_sql_alchemy_conn.arn,
      aws_secretsmanager_secret.airflow_admin_password.arn,
    ]
  }

  statement {
    sid     = "DecryptAirflowSecrets"
    actions = ["kms:Decrypt"]
    resources = [
      data.terraform_remote_state.airflow.outputs.airflow_kms_key_arn,
      data.terraform_remote_state.airflow.outputs.airflow_kms_alias_arn,
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "cd-platform-airflow-ecs-task-execution-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

# --- Task role (the running containers' own permissions) -----------------

resource "aws_iam_role" "task" {
  name               = "cd-platform-airflow-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = {
    Project = "cd-platform"
  }
}

# ECS Exec -- replaces today's SSM-RunCommand-plus-`docker exec` debugging
# flow with `aws ecs execute-command` directly against a task.
data "aws_iam_policy_document" "task_exec_permissions" {
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

resource "aws_iam_role_policy" "task_exec_permissions" {
  name   = "cd-platform-airflow-ecs-task-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec_permissions.json
}

# --- Logs ----------------------------------------------------------------

resource "aws_cloudwatch_log_group" "airflow_ecs" {
  name              = "/ecs/cd-platform-airflow"
  retention_in_days = 14

  tags = {
    Project = "cd-platform"
  }
}

# --- Task definitions ------------------------------------------------

locals {
  cd_etl_image = "ghcr.io/${var.github_repository_owner}/cd-etl:latest"

  # Airflow 3.x's Task Execution API -- scheduler/triggerer/dag-processor
  # all call back to api-server over this URL. The exact config key and
  # URL path are the one area of real uncertainty in this module -- worth
  # confirming against real scheduler/api-server logs on first apply (see
  # terraform/README.md's airflow-ecs/ section).
  execution_api_server_url = "http://api-server.${aws_service_discovery_http_namespace.airflow.name}:8080/execution/"

  airflow_metadata_conn_secret = {
    name      = "AIRFLOW__DATABASE__SQL_ALCHEMY_CONN"
    valueFrom = aws_secretsmanager_secret.airflow_metadata_sql_alchemy_conn.arn
  }
}

resource "aws_ecs_task_definition" "scheduler" {
  family                   = "cd-platform-airflow-scheduler"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name       = "scheduler"
      image      = local.cd_etl_image
      essential  = true
      entryPoint = ["airflow"]
      command    = ["scheduler"]
      # var.airflow_parallelism (4) LocalExecutor worker subprocesses at
      # ~130MB RSS each (../airflow/variables.tf's own measured figure)
      # is already ~520MB before counting the scheduler daemon's own
      # baseline (Python interpreter, DAG parsing/caching, Airflow core)
      # -- 512MB would OOM-kill this container under real load. Plenty of
      # headroom on t3.medium (4GiB) to size generously; tune down later
      # if real CloudWatch metrics show room to.
      memory = 1024

      # Only the scheduler needs CONGRESS_API_KEY/
      # AIRFLOW_CONN_CONGRESSIONAL_POSTGRES -- under LocalExecutor, DAG
      # task subprocesses (the only place either is actually read) are
      # spawned by the scheduler process specifically, not by triggerer/
      # dag-processor/api-server.
      environment = [
        { name = "AIRFLOW__CORE__PARALLELISM", value = tostring(var.airflow_parallelism) },
        { name = "AIRFLOW__CORE__EXECUTION_API_SERVER_URL", value = local.execution_api_server_url },
      ]

      secrets = [
        local.airflow_metadata_conn_secret,
        { name = "AIRFLOW_CONN_CONGRESSIONAL_POSTGRES", valueFrom = aws_secretsmanager_secret.airflow_conn_congressional_postgres.arn },
        { name = "CONGRESS_API_KEY", valueFrom = data.terraform_remote_state.airflow.outputs.congress_api_key_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.airflow_ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "scheduler"
        }
      }
    }
  ])

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_task_definition" "triggerer" {
  family                   = "cd-platform-airflow-triggerer"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name       = "triggerer"
      image      = local.cd_etl_image
      essential  = true
      entryPoint = ["airflow"]
      command    = ["triggerer"]
      # No documented measurement this is sized against (unlike
      # scheduler's parallelism-based figure) -- a conservative starting
      # point with headroom on t3.medium's budget, tune via CloudWatch
      # metrics once this is running real workloads.
      memory = 512

      environment = [
        { name = "AIRFLOW__CORE__EXECUTION_API_SERVER_URL", value = local.execution_api_server_url },
      ]

      secrets = [local.airflow_metadata_conn_secret]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.airflow_ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "triggerer"
        }
      }
    }
  ])

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_task_definition" "dag_processor" {
  family                   = "cd-platform-airflow-dag-processor"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name       = "dag-processor"
      image      = local.cd_etl_image
      essential  = true
      entryPoint = ["airflow"]
      command    = ["dag-processor"]
      # No documented measurement this is sized against. dag-processor
      # parses and serializes every DAG file on each scan cycle, so it's
      # more memory-sensitive than a truly idle process -- same
      # conservative-starting-point reasoning as triggerer's identical
      # bump, tune via CloudWatch metrics once running real workloads.
      memory = 512

      environment = [
        { name = "AIRFLOW__CORE__EXECUTION_API_SERVER_URL", value = local.execution_api_server_url },
      ]

      secrets = [local.airflow_metadata_conn_secret]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.airflow_ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "dag-processor"
        }
      }
    }
  ])

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_task_definition" "api_server" {
  family                   = "cd-platform-airflow-api-server"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name       = "api-server"
      image      = local.cd_etl_image
      essential  = true
      entryPoint = ["airflow"]
      command    = ["api-server"]
      memory     = 512

      # Fixed host port (not dynamic mapping, unlike ../cd-server's
      # ALB-fronted task) -- same zero-public-ingress posture as today,
      # reachable only via SSM port-forward to the instance (see
      # terraform/README.md's existing airflow/ section for the exact
      # command). `name` here is what service_connect_configuration's
      # `service.port_name` (below) references.
      portMappings = [
        {
          name          = "api-server"
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        }
      ]

      secrets = [local.airflow_metadata_conn_secret]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.airflow_ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api-server"
        }
      }
    }
  ])

  tags = {
    Project = "cd-platform"
  }
}

# One-shot migration + admin-provisioning task -- deliberately NOT
# registered as a service. Keeps the image's default ENTRYPOINT (no
# entryPoint override), so entrypoint.sh's unconditional `airflow db
# migrate` + `alembic upgrade head` actually run; `command =
# ["create-admin-user"]` hits entrypoint.sh's dedicated
# `create-admin-user` subcommand (cd-platform#75) after that, which
# idempotently provisions/resets the FabAuthManager admin account (see
# cd-platform#74/#31 -- replaces SimpleAuthManager's auto-generated,
# plaintext-logged password) instead of falling through to `airflow
# standalone` (entrypoint.sh's `if [ "$#" -eq 0 ]` branch, which the 4
# long-running services also never reach -- their entryPoint override
# skips entrypoint.sh entirely, so only this task ever provisions the
# admin account). Invoked ad hoc via `aws ecs run-task` (see
# terraform/README.md) -- wiring this into cd-etl's deploy pipeline is a
# follow-up cd-platform issue, not built here.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "cd-platform-airflow-migrate"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "migrate"
      image     = local.cd_etl_image
      essential = true
      command   = ["create-admin-user"]
      memory    = 256

      # PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE are for cd-etl's own
      # alembic migration (a separate connection mechanism from Airflow's
      # own AIRFLOW__DATABASE__SQL_ALCHEMY_CONN -- see
      # ../airflow/templates/user-data.sh.tftpl's identical comment on
      # this). Only this task needs them -- the 4 long-running services
      # never run alembic at all, since their entryPoint override skips
      # entrypoint.sh entirely.
      environment = [
        { name = "PGHOST", value = data.terraform_remote_state.rds.outputs.rds_address },
        { name = "PGPORT", value = "5432" },
        { name = "PGDATABASE", value = "cd_platform" },
      ]

      secrets = [
        local.airflow_metadata_conn_secret,
        { name = "PGUSER", valueFrom = "${data.terraform_remote_state.airflow.outputs.cd_etl_app_db_secret_arn}:username::" },
        { name = "PGPASSWORD", valueFrom = "${data.terraform_remote_state.airflow.outputs.cd_etl_app_db_secret_arn}:password::" },
        { name = "AIRFLOW_ADMIN_PASSWORD", valueFrom = aws_secretsmanager_secret.airflow_admin_password.arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.airflow_ecs.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "migrate"
        }
      }
    }
  ])

  tags = {
    Project = "cd-platform"
  }
}

# --- ECS services --------------------------------------------------------
#
# 4 separate services, not 1 service running 4 containers -- bundling
# would couple all 4 components' restart/replacement together and defeat
# the entire point of this decomposition (#22/#24).
#
# All 4 set deployment_minimum_healthy_percent = 0 /
# deployment_maximum_percent = 100 -- ECS's own defaults (100/200) try to
# run the new task *alongside* the old one during a rolling deployment,
# which this single-instance ASG (min_size = max_size = 1) can't
# accommodate: api-server's fixed hostPort 8080 can't be bound twice on
# one host, and even the 3 host-portless services would need double their
# steady-state memory momentarily available on the same one instance.
# Either way, the new task gets stuck unable to start and the deployment
# never completes. 0/100 replaces that with a plain stop-then-start (a
# brief gap during deploys, acceptable for a batch/scheduled system with
# no live request traffic to preserve zero-downtime for).

resource "aws_ecs_service" "scheduler" {
  name                               = "cd-platform-airflow-scheduler"
  cluster                            = aws_ecs_cluster.airflow.id
  task_definition                    = aws_ecs_task_definition.scheduler.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.airflow.name
    weight            = 1
  }

  # Client-only -- resolves api-server's Service Connect alias below via
  # the cluster's service_connect_defaults namespace, doesn't advertise
  # itself.
  service_connect_configuration {
    enabled = true
  }

  enable_execute_command = true

  # Terraform's implicit dependency graph only follows the
  # capacity_provider_strategy reference above to the capacity provider
  # object itself, not to the separate resource that actually associates
  # it with the cluster (PutClusterCapacityProviders) -- without this
  # explicit depends_on (same on all 4 services below), a fresh apply can
  # race the service create ahead of that association and fail with
  # "InvalidParameterException: The specified capacity provider ... is
  # not associated with the cluster".
  depends_on = [aws_ecs_cluster_capacity_providers.airflow]

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_service" "triggerer" {
  name                               = "cd-platform-airflow-triggerer"
  cluster                            = aws_ecs_cluster.airflow.id
  task_definition                    = aws_ecs_task_definition.triggerer.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.airflow.name
    weight            = 1
  }

  service_connect_configuration {
    enabled = true
  }

  enable_execute_command = true
  depends_on             = [aws_ecs_cluster_capacity_providers.airflow]

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_service" "dag_processor" {
  name                               = "cd-platform-airflow-dag-processor"
  cluster                            = aws_ecs_cluster.airflow.id
  task_definition                    = aws_ecs_task_definition.dag_processor.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.airflow.name
    weight            = 1
  }

  service_connect_configuration {
    enabled = true
  }

  enable_execute_command = true
  depends_on             = [aws_ecs_cluster_capacity_providers.airflow]

  tags = {
    Project = "cd-platform"
  }
}

resource "aws_ecs_service" "api_server" {
  name                               = "cd-platform-airflow-api-server"
  cluster                            = aws_ecs_cluster.airflow.id
  task_definition                    = aws_ecs_task_definition.api_server.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.airflow.name
    weight            = 1
  }

  # Advertises itself as "api-server" (-> api-server.airflow, the
  # cluster's namespace) on port 8080 -- what the other 3 services'
  # client-only configuration above resolves for Task Execution API
  # traffic.
  service_connect_configuration {
    enabled = true

    service {
      port_name      = "api-server"
      discovery_name = "api-server"

      client_alias {
        port = 8080
      }
    }
  }

  enable_execute_command = true
  depends_on             = [aws_ecs_cluster_capacity_providers.airflow]

  tags = {
    Project = "cd-platform"
  }
}
