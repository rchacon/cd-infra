# Terraform

AWS infrastructure for this repo, provisioned incrementally by component:
`bootstrap/` (state backend, one-time), `networking/` (#1), `rds/` (#2),
`airflow/` (#3), `cd-api/` (#4). See #5 for the overall AWS deployment
tracking issue.

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
normal workflow once it's applied -- **the one deliberate exception is
`cd-api/` (#4)'s GitHub OIDC provider**, an account-wide singleton added
here later for the same reason the state bucket is. Re-apply this
directory once (from whichever machine holds its local `terraform.tfstate`
-- there's no S3 backend to apply it from elsewhere) to pick that up, then
note the new `github_oidc_provider_arn` output for `cd-api/`'s
`terraform.tfvars` (see below).

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

A small EC2 instance (`t3.small` by default, x86_64 -- cd-etl's GHCR image is
amd64-only) running `cd-platform/cd-etl`'s
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

**`airflow_metadata` and a least-privilege database role are bootstrapped
automatically on first boot**, not by Terraform itself -- RDS has no
`docker-entrypoint-initdb.d` equivalent, and this instance is the only
thing that can reach RDS at all (per its security group), so `user-data`
runs an idempotent `psql` bootstrap using the RDS master/superuser
credentials to (1) create the `airflow_metadata` database and (2) create
(or update the password of) a scoped `cd_etl_db_username` role, granted
access to both `cd_platform` and `airflow_metadata` only. `cd-etl`'s
container connects as that scoped role, never the RDS master user -- the
master credentials are used only transiently, at boot, for this bootstrap.

**The Airflow UI (port 8080) has no public ingress, ever** -- access it via
SSM Session Manager port-forwarding, not a VPN (a VPN's per-subnet-
association billing alone would dwarf this project's entire AWS spend for
occasional admin access to one DAG's UI):

```bash
# Shell session (e.g. for `docker logs`, or re-running the bootstrap by hand):
aws ssm start-session --target "$(terraform output -raw instance_id)"

# Port-forward the Airflow UI to localhost:8080:
aws ssm start-session --target "$(terraform output -raw instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

## `cd-api/` -- Lambda + API Gateway

Runs `cd-platform/cd-api` (a FastAPI app, already Lambda-ready via
`handler = Mangum(app)`) on Lambda behind an API Gateway REST API, in
`networking/`'s private subnets and `lambda` security group. RDS Proxy
sits between Lambda and RDS (`aws_db_proxy`, reusing the `lambda` security
group) so Lambda's per-invocation connection model can't exhaust RDS's
`max_connections` -- Lambda connects to the proxy with plain
`PGHOST`/`PGUSER`/`PGPASSWORD` env vars (`SECRETS` auth mode), so
`cd-api/src/db.py` needs no code change at all. Auth is a static API
Gateway API key (`var.api_key_names`, one shared usage plan) -- a
deliberate MVP stopgap per `cd-platform#13`, replaced later by that
issue's real per-customer system.

**This directory needs `bootstrap/`'s new `github_oidc_provider_arn`
output** (see above) copied manually into its `terraform.tfvars` --
`bootstrap/` has no S3 backend, so this can't flow through
`terraform_remote_state` like `networking/`'s or `rds/`'s outputs do.

```bash
cd terraform/cd-api
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "cd-api/terraform.tfstate"
region  = "us-west-2"
encrypt = true
EOF
cat > terraform.tfvars <<EOF
state_bucket_name        = "<state_bucket_name from bootstrap output>"
github_oidc_provider_arn = "<github_oidc_provider_arn from bootstrap output>"
EOF

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

**The `cd_api_app` database role is bootstrapped manually, not by
Terraform** (mirrors `rds/`'s and `airflow/`'s own precedent) -- Lambda has
no "runs once at boot" hook the way EC2's `user-data` does, and building
one would mean adding actual `cd-api` app code just for this. Unlike
`airflow/`'s `cd_etl_app` (which owns the tables it creates via its own
migrations), `cd_api_app` is a read-only *consumer* of tables `cd_etl_app`
owns -- `cd-api` never writes (confirmed against `cd-api/src/db.py`: one
`SELECT`, nothing else), so its grants are `SELECT`-only, and since
database/schema-level grants don't cascade to another role's existing
tables, it needs an explicit `GRANT SELECT ON ALL TABLES` plus
`ALTER DEFAULT PRIVILEGES FOR ROLE cd_etl_app` so tables `cd_etl_app`
creates *later* (future migrations) are covered too, not just the ones
that already exist at bootstrap time. `ALTER DEFAULT PRIVILEGES FOR ROLE`
can only be run by that role itself or a member of it -- confirmed on a
real apply that even RDS's master user (`rds_superuser`, not a true
Postgres `SUPERUSER`) needs an explicit `GRANT "cd_etl_app" TO` itself
first, or it fails with `permission denied to change default privileges`.
Run once, right after `terraform apply`, from a directory holding both
this and `../rds`/`../airflow`'s outputs:

```bash
CD_API_APP_PASSWORD="$(terraform output -raw cd_api_app_db_password)"
RDS_SECRET_ARN="$(terraform -chdir=../rds output -raw master_user_secret_arn)"
RDS_ADDRESS="$(terraform -chdir=../rds output -raw rds_address)"
AIRFLOW_INSTANCE_ID="$(terraform -chdir=../airflow output -raw instance_id)"

# Write the bootstrap script locally, with the values above already
# substituted in -- avoids nesting shell-quoting through SSM's own JSON
# parameter encoding. Same idempotent \gexec pattern airflow/'s bootstrap
# already validated works (sidesteps bash expanding an unescaped `$$` in a
# heredoc to its own PID, which would corrupt Postgres's DO $$ ... $$
# dollar-quoting).
cat > /tmp/cd-api-db-bootstrap.sh <<SCRIPT
RDS_SECRET=\$(aws secretsmanager get-secret-value --query SecretString --output text --secret-id ${RDS_SECRET_ARN})
RDS_USER=\$(echo "\$RDS_SECRET" | jq -r .username)
RDS_PASS=\$(echo "\$RDS_SECRET" | jq -r .password)
export PGPASSWORD="\$RDS_PASS"
psql -h ${RDS_ADDRESS} -U "\$RDS_USER" -d cd_platform -v ON_ERROR_STOP=1 <<-SQL
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', 'cd_api_app', '${CD_API_APP_PASSWORD}')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cd_api_app')\\gexec
ALTER ROLE "cd_api_app" WITH PASSWORD '${CD_API_APP_PASSWORD}';
GRANT CONNECT ON DATABASE "cd_platform" TO "cd_api_app";
GRANT USAGE ON SCHEMA public TO "cd_api_app";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "cd_api_app";
GRANT "cd_etl_app" TO "\$RDS_USER";
ALTER DEFAULT PRIVILEGES FOR ROLE cd_etl_app IN SCHEMA public GRANT SELECT ON TABLES TO "cd_api_app";
SQL
SCRIPT

# jq turns the script's lines into the JSON array send-command expects,
# rather than hand-nesting shell escaping inside a JSON string.
jq -Rsc '{commands: (split("\n") | map(select(length > 0)))}' \
  /tmp/cd-api-db-bootstrap.sh > /tmp/cd-api-db-bootstrap-params.json

aws ssm send-command \
  --instance-ids "$AIRFLOW_INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters file:///tmp/cd-api-db-bootstrap-params.json
# Confirm with: aws ssm get-command-invocation --command-id <id> --instance-id "$AIRFLOW_INSTANCE_ID"

rm /tmp/cd-api-db-bootstrap.sh /tmp/cd-api-db-bootstrap-params.json
unset CD_API_APP_PASSWORD
```

Both temp files contain the plaintext password -- delete them once
confirmed. The password also transiently appears in SSM's command history
for this one-time step -- accepted, same as reading it requires its own
IAM grant few identities have.

**The Lambda ships with a placeholder body until `cd-platform#29`'s deploy
workflow runs at least once** -- this directory only provisions the
*infrastructure* (Lambda, API Gateway, RDS Proxy, the GitHub OIDC role
that workflow assumes); the real `cd-api` code arrives via
`aws lambda update-function-code` from that separate repo's pipeline, not
from a `terraform apply` here.

### Rotating an API Gateway API key

`var.api_key_names` is a list specifically so rotation is a plain Terraform
change -- no manual console work, no `terraform import`, and zero downtime.
`aws_api_gateway_api_key`'s `value` attribute is sensitive in the AWS
provider, so `terraform plan`/`apply` output never shows the plaintext
value even if someone else runs it on your behalf -- the only step below
that touches the real value is step 3, and it has to be run somewhere
private (not piped through a shared session/chat).

1. Add a new, distinct key name alongside the existing one(s) in
   `terraform.tfvars` (a dated suffix keeps rotation history
   self-documenting):

   ```hcl
   api_key_names = ["self", "self-2026-08"]
   ```

2. Plan and apply -- expect exactly one new `aws_api_gateway_api_key` +
   one new `aws_api_gateway_usage_plan_key`, nothing else changing:

   ```bash
   cd terraform/cd-api
   terraform plan
   terraform apply
   ```

3. Fetch the new key's value **privately** -- this is the only step that
   ever touches the plaintext. Either the AWS Console (API Gateway -> API
   Keys -> the new key -> "Show"), or:

   ```bash
   aws apigateway get-api-key --api-key <new-key-id> --include-value
   ```

   run in a terminal that isn't a shared/logged session.

4. Cut over whatever client/integration was using the old key to the new
   value. The old key keeps working throughout this step -- no downtime.

5. Once the cutover is confirmed working, remove the old name from
   `terraform.tfvars`:

   ```hcl
   api_key_names = ["self-2026-08"]
   ```

6. Plan and apply again -- expect exactly one `aws_api_gateway_api_key` +
   one `aws_api_gateway_usage_plan_key` being destroyed (the retired key):

   ```bash
   terraform plan
   terraform apply
   ```

## Validating without AWS credentials

`terraform fmt -check -recursive` and `terraform validate` (after
`terraform init -backend=false`) don't need real AWS credentials -- they
only check formatting and internal config consistency. `plan`/`apply` do
need credentials, since they call the AWS API.
