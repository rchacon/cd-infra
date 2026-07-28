# Terraform

AWS infrastructure for this repo, provisioned incrementally by component:
`bootstrap/` (state backend, one-time), `networking/` (#1),
and eventually `rds/` (#2), `airflow/` (#3), `cd-api/` (#4). See #5 for the
overall AWS deployment tracking issue.

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

Defaults: `us-west-2`, VPC CIDR `10.0.0.0/16`, 2 AZs. NAT gateway is off
(`enable_nat_gateway = false`) until #2/#3/#4 actually need outbound internet
from a private subnet -- flip it on (one shared gateway by default, cheaper
than one per AZ at the cost of a single point of failure -- see
`variables.tf` for how to change either) in whichever of those PRs lands
first. Future `rds/`/`airflow/`/`cd-api/` directories (#2/#3/#4) will read
this state's outputs
(`vpc_id`, subnet IDs, security group IDs) via `terraform_remote_state`,
using the same `backend.hcl` pattern with a different `key`.

## Validating without AWS credentials

`terraform fmt -check -recursive` and `terraform validate` (after
`terraform init -backend=false`) don't need real AWS credentials -- they
only check formatting and internal config consistency. `plan`/`apply` do
need credentials, since they call the AWS API.
