# Terraform

AWS infrastructure for this repo, provisioned incrementally by component:
`bootstrap/` (state backend, one-time), `networking/` (#1), `rds/` (#2),
`airflow/` (#3), and eventually `cd-api/` (#4). See #5 for the overall AWS
deployment tracking issue.

See the root `README.md` for an architecture diagram of the VPC, security
groups, and planned compute resources.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.15
- AWS credentials for the target account, with permission to create the
  resources each directory defines (via environment variables, an AWS CLI
  profile, or SSO -- anything the AWS provider's standard credential chain
  picks up)

## `bootstrap/` -- one-time state backend setup

Creates the S3 bucket that holds every other directory's Terraform state
(state locking uses the S3 backend's native `use_lockfile`, so no separate
lock table is needed). Run once per AWS account, with local state (there's
nothing else yet to store *this* config's state in):

```bash
cd terraform/bootstrap
terraform init
terraform apply
terraform output
```

Note the `state_bucket_name` output -- every other `terraform/*` directory's
backend needs it (see below). This directory isn't touched again as part of
normal workflow once it's applied.

## `networking/` -- VPC, subnets, security groups

The shared network layer RDS (#2), the Airflow EC2 instance (#3), and
cd-api's Lambda (#4) all provision into.

Backend config is intentionally left empty in `versions.tf` (a bucket name
containing your AWS account ID shouldn't be hardcoded into version-controlled
files). Supply it via a gitignored `backend.hcl`:

```bash
cd terraform/networking
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "networking/terraform.tfstate"
region  = "us-west-2"
encrypt = true
EOF

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Defaults: `us-west-2`, VPC CIDR `10.0.0.0/16`, 2 AZs. NAT gateway is on
(`enable_nat_gateway = true`, one shared gateway rather than one per AZ --
cheaper, at the cost of a single point of failure -- see `variables.tf` to
change either) since `airflow/` (#3) needs outbound internet from its
private subnet. `airflow/`/`cd-api/` (#3/#4) read this state's outputs
(`vpc_id`, subnet IDs, security group IDs) via `terraform_remote_state`,
using the same `backend.hcl` pattern with a different `key`.

## `rds/` -- managed Postgres

A single-AZ RDS Postgres instance (plain RDS, not Aurora -- this project's
current scale doesn't need Aurora's read-replica/fast-failover story) in
`networking/`'s private subnets and RDS security group, with storage
encrypted under its own customer-managed KMS key and a master password
managed by RDS itself in Secrets Manager (never a Terraform-supplied
plaintext value).

Like `networking/`, backend config is supplied via a gitignored
`backend.hcl`, and it also needs `networking/`'s state bucket name -- the
same account-specific-value problem, supplied via a gitignored
`terraform.tfvars` instead of a variable default:

```bash
cd terraform/rds
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "rds/terraform.tfstate"
region  = "us-west-2"
encrypt = true
EOF
cat > terraform.tfvars <<EOF
state_bucket_name = "<state_bucket_name from bootstrap output>"
EOF

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

**Schema bootstrap is intentionally not part of this directory.** The RDS
security group only ever accepts connections from the `airflow`/`lambda`
security groups (#1), so there's no durable way to reach this instance
until `airflow/`'s EC2 instance exists inside the VPC. `cd-etl`'s own
schema migrations (`alembic upgrade head`) and Airflow's own metadata
migrations both run automatically, baked into the `cd-etl` container's
entrypoint on every start -- no manual step for either. The one exception
is the sibling `airflow_metadata` database itself, which needs a one-time
manual `CREATE DATABASE`, covered in `airflow/`'s section below.

## `airflow/` -- self-hosted Airflow on EC2

A small EC2 instance (`t4g.small` by default) running `cd-platform/cd-etl`'s
Docker image continuously, in `networking/`'s private subnets and `airflow`
security group. A sidecar `watchtower` container polls GHCR for new
`cd-etl-vX.X.X` releases and auto-updates -- CI only ever pushes to GHCR,
never touches this instance directly. Replaces MWAA (originally scoped,
~$358/mo for one lightweight daily DAG) at ~$6-12/mo for the EC2 instance
alone.

Like `rds/`, backend config and `networking/`'s state bucket name are
supplied via gitignored `backend.hcl`/`terraform.tfvars` -- this directory's
`terraform.tfvars` also needs one sensitive value, `congress_api_key` (from
[api.congress.gov](https://api.congress.gov/sign-up/)). No GitHub PAT is
needed: `cd-etl`'s GHCR package is public, so both its image pull and
watchtower's polling work anonymously.

```bash
cd terraform/airflow
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "airflow/terraform.tfstate"
region  = "us-west-2"
encrypt = true
EOF
cat > terraform.tfvars <<EOF
state_bucket_name = "<state_bucket_name from bootstrap output>"
congress_api_key  = "<your api.congress.gov key>"
EOF

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

**The one-time `CREATE DATABASE airflow_metadata;` step is manual, not
Terraform-managed** (mirrors `rds/`'s own precedent of leaving schema
bootstrap out of Terraform) -- RDS has no `docker-entrypoint-initdb.d`
equivalent to create this sibling database automatically, and this
instance is the only thing that can reach RDS at all (per its security
group). Run it once, right after `terraform apply`, via an SSM shell
session (see below) -- `cd-etl`'s container will fail to start (its
entrypoint's `airflow db migrate` needs that database to exist) until this
step is done.

**The Airflow UI (port 8080) has no public ingress, ever** -- access it via
SSM Session Manager port-forwarding, not a VPN (a VPN's per-subnet-
association billing alone would dwarf this project's entire AWS spend for
occasional admin access to one DAG's UI):

```bash
# Shell session (e.g. for the one-time CREATE DATABASE step, or `docker logs`):
aws ssm start-session --target "$(terraform output -raw instance_id)"

# Port-forward the Airflow UI to localhost:8080:
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

## Validating without AWS credentials

`terraform fmt -check -recursive` and `terraform validate` (after
`terraform init -backend=false`) don't need real AWS credentials -- they
only check formatting and internal config consistency. `plan`/`apply` do
need credentials, since they call the AWS API.
