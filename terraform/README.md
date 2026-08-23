# Terraform

AWS infrastructure for this repo, provisioned incrementally by component:
`bootstrap/` (state backend, one-time), `networking/` (#1), `rds/` (#2),
`airflow/` (#3), `cd-api/` (#4), `amplify/` (Hosting for the `cd-website`
repo's two apps), `cd-webapp/` (Amplify Hosting + Cognito for the customer
portal, `rchacon/cd-webapp`), `cd-server/` (ECS on EC2 + ALB for
`rchacon/cd-platform`'s `cd-server`, at `server.civicdog.com`),
`airflow-ecs/` (Airflow decomposed onto 4 ECS services, #22/#24 --
runs alongside `airflow/` until validated, see that directory's own
section for the cutover plan). See #5 for the overall AWS deployment
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
supplied via gitignored `backend.hcl`/`terraform.tfvars`. No GitHub PAT is
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

## `airflow-ecs/` -- Airflow decomposed onto ECS (EC2)

Decomposes `airflow/`'s single `airflow standalone` container into 4
independent ECS services (`scheduler`, `triggerer`, `dag-processor`,
`api-server`), each its own task definition, on a dedicated ECS cluster
(EC2 launch type, `t3.medium`) -- see `cd-infra#22`/`#24` for the incident
and reasoning (a subprocess dying silently inside `airflow standalone`
left the container looking "healthy" while the pipeline missed 5 days of
runs; ECS's per-service health-check-driven task replacement, not
process-exit-driven `restart:` policies, is what actually catches that
class of bug).

**Ran in parallel with `airflow/` until validated (`cd-infra#42`); its EC2
instance is being decommissioned now that it has been.** Both safely ran
concurrently against the same RDS `airflow_metadata` database (Airflow's
scheduler HA design exists precisely to let multiple scheduler processes
coexist without duplicate task execution) while validation was pending.
This module now also owns the KMS key and both Secrets Manager secrets
`airflow/` originally created (`aws_kms_key.airflow`, `congress_api_key`,
`cd_etl_app_db` -- moved via `terraform state mv`, not recreated, so the
live key/secret ARNs and the already-set `cd_etl_app` Postgres password
didn't change) -- but still doesn't touch `airflow/`'s EC2 instance
itself; that's destroyed as a separate, explicit step.

**No `cd-platform` change was needed for the migration-race problem
`#24` originally flagged.** `cd-etl/entrypoint.sh` runs `airflow db
migrate` and `alembic upgrade head` unconditionally, before even looking
at its arguments -- so 4 independent services naively sharing the image
would race migrations against RDS on every task start. Instead, the 4
long-running task definitions override `entryPoint` to `["airflow"]`,
bypassing `/entrypoint.sh` (and its migration block) entirely --
`airflow` is already on the image's own `PATH`. A 5th task definition
(`migrate`, not registered as a service) keeps the image's *default*
entrypoint with a `command = ["create-admin-user"]` override, so
migrations still run (unconditionally, as designed) and then it hits
`entrypoint.sh`'s dedicated `create-admin-user` subcommand
(`cd-platform#75`) instead of falling through to `airflow standalone`.

**That same `create-admin-user` invocation also provisions cd-etl's
Airflow admin account** (`cd-platform#74`/`#31` -- switched from
`SimpleAuthManager`'s auto-generated, plaintext-logged password to
`FabAuthManager`). The admin password is a Terraform-generated,
Secrets-Manager-held secret (`aws_secretsmanager_secret.airflow_admin_password`),
injected only into the `migrate` task -- the 4 long-running services
never provision the account themselves, only this one-shot task does,
idempotently (`users create` no-ops if the account exists, followed by
an unconditional `users reset-password`, so re-running this after
rotating the secret actually takes effect).

```bash
cd terraform/airflow-ecs
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "airflow-ecs/terraform.tfstate"
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

**Running the one-shot migration task** -- do this once right after the
first `apply` (the RDS schema is already current from `airflow/`'s own
instance, but this is still worth confirming end-to-end), and again after
any future `cd-etl` release:

```bash
aws ecs run-task \
  --cluster "$(terraform output -raw ecs_cluster_name)" \
  --task-definition "$(terraform output -raw migrate_task_definition_arn)" \
  --launch-type EC2

# Poll until it exits, then confirm exit code 0:
aws ecs describe-tasks --cluster "$(terraform output -raw ecs_cluster_name)" \
  --tasks <task-arn-from-run-task-output> \
  --query 'tasks[0].containers[0].exitCode'
```

**Debugging a service** -- `aws ecs execute-command` replaces the SSM
RunCommand + `docker exec` flow `airflow/` needs today:

```bash
aws ecs execute-command --cluster "$(terraform output -raw ecs_cluster_name)" \
  --task <task-arn> --container scheduler --interactive --command "/bin/sh"
```

**Logging into the UI** -- same SSM port-forward pattern as `airflow/`'s
own instance (`api-server` publishes a fixed host port 8080 for exactly
this), just against this module's container instance rather than
`airflow/`'s:

```bash
INSTANCE_ID=$(aws ecs list-container-instances --cluster "$(terraform output -raw ecs_cluster_name)" --query 'containerInstanceArns[0]' --output text | xargs -I{} aws ecs describe-container-instances --cluster "$(terraform output -raw ecs_cluster_name)" --container-instances {} --query 'containerInstances[0].ec2InstanceId' --output text)
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

Log in as `admin`, password from the Terraform-generated secret (never
printed by `terraform apply`/`plan` -- pull it explicitly, and only in a
private terminal):

```bash
aws secretsmanager get-secret-value \
  --secret-id "cd-platform/airflow-ecs/airflow-admin-password" \
  --query SecretString --output text
```

**One area of real uncertainty**: `AIRFLOW__CORE__EXECUTION_API_SERVER_URL`
(Airflow 3.x's Task Execution API -- how `scheduler`/`triggerer`/
`dag-processor` reach `api-server`) is set to
`http://api-server.airflow:8080/execution/` based on reading Airflow's
docs, not a confirmed-working value yet. If the scheduler/triggerer can't
reach `api-server`, check their CloudWatch Logs
(`/ecs/cd-platform-airflow`, streams prefixed `scheduler`/`triggerer`)
for the actual error and adjust the URL/config key in `main.tf`'s
`local.execution_api_server_url` accordingly -- same "real errors over
guessing" approach that resolved `cd-server`'s IAM gaps.

**Deploy automation isn't wired up yet** -- same gap as `cd-server`
(`cd-platform#71`): `cd-etl-deploy.yml` only builds and pushes to GHCR
today. A future `cd-platform` issue should add the migration `run-task`
+ `aws ecs update-service --force-new-deployment` (x3, for scheduler/
triggerer/dag-processor -- api-server too if its image ever changes)
steps on `cd-etl-v*` tag push.

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

### OpenAPI spec bucket (cd-website#1)

`cd-api` sits behind API Gateway with `api_key_required = true` on its one
catch-all proxy method -- confirmed against the *live* API Gateway, not
just this config, that there's no narrower per-path scoping -- so
`docs.civicdog.com` can't fetch `/openapi.json` live from `cd-api` without
exposing a key client-side. This directory provisions a small public S3
bucket (`aws_s3_bucket.openapi_spec`, SSE-S3 encrypted rather than a
customer-managed KMS key -- see the comment in `main.tf` for why a KMS key
would actively conflict with the bucket's whole point of being publicly
readable) and extends `cd-api-deploy`'s existing IAM role with `s3:PutObject`
scoped to the one expected key, rather than minting a second role a single
GitHub Actions job would have to juggle.

**No object is uploaded by Terraform** -- this directory only provisions
the bucket and the write permission. `cd-api-deploy.yml` (in
`cd-platform`) generates `openapi.json` from the FastAPI app and uploads
it here on every `cd-api-vX.X.X` release. `terraform output
openapi_spec_url` is the URL `cd-website`'s docs app OpenAPI viewer points
at.

### Custom domain: api.civicdog.com, /v1 base path

URL-path versioning (`/v1/...`), not a request header -- API Gateway REST
API v1 has no native way to route on a header value to a different
backend, while `aws_api_gateway_base_path_mapping` is first-class native
support for path versioning and needs zero `cd-api` application code
changes (the `v1` segment is a routing-layer construct, stripped before
reaching the Lambda, the same way the `prod` stage segment already is on
the existing execute-api URL).

`cd-api`'s REST API is EDGE-optimized (confirmed against the live
resource, not assumed), so the ACM certificate for `api.civicdog.com` has
to be requested in `us-east-1` specifically -- a second, aliased `aws`
provider exists in this directory just for that. DNS (validation record +
the final `api` CNAME to the CloudFront target) is managed via the
Cloudflare provider, needing its own `cloudflare_api_token`/
`cloudflare_zone_id` in `terraform.tfvars`, same as `../amplify`.

This is purely additive -- the existing execute-api URL keeps working
unchanged. Updating `cd-lookup`'s configured endpoint to actually use
`https://api.civicdog.com/v1` is a separate, later change.

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

## `amplify/` -- Amplify Hosting + Cloudflare DNS

Two AWS Amplify Hosting apps for the `cd-website` repo's two independent
Astro apps: `civicdog-site` (serves `apps/site`, deployed to
`civicdog.com`/`www.civicdog.com`) and `civicdog-docs` (serves `apps/docs`,
deployed to `docs.civicdog.com`). Both watch the same repo's `main` branch
and build independently via each app's own `amplify.yml`, selected through
the `AMPLIFY_MONOREPO_APP_ROOT` environment variable rather than a
Terraform-level `build_spec` override.

**`civicdog.com`'s DNS stays at Cloudflare** (where the domain is
registered) rather than migrating to Route53 -- the domain has an active
Google Workspace email integration (MX/SPF/DKIM records set up via
Cloudflare's one-click app) that isn't fully reproducible by hand, so this
module manages DNS via the Cloudflare Terraform provider instead, touching
only the specific records Amplify needs and never anything email-related.

**Two manual, one-time prerequisites this module can't do for you**, before
`terraform apply` will work:

1. **Authorize the AWS Amplify GitHub App** for `rchacon/cd-website` -- AWS
   Amplify console, start (and it's fine to then cancel) a "New app" flow,
   or Account settings -> GitHub connections -> Authorize. This is an
   account-level connection Terraform's `aws_amplify_app` resources rely on
   already existing; there's no way to script GitHub's OAuth consent step.
   **Getting the App authorized isn't sufficient on its own** -- it also
   has its own separate repository access list (GitHub -> Settings ->
   Installations -> the AWS Amplify app's configuration) that each
   individual repo needs added to explicitly. Confirmed the hard way on
   `cd-webapp/`'s setup: the App being authorized for the account didn't
   mean it could actually access a newly-added repo, and the resulting
   build failure (`Unable to assume specified IAM Role`) pointed
   nowhere near the real cause.
2. **Create a Cloudflare API token** scoped to `Zone:DNS:Edit` for the
   `civicdog.com` zone only (Cloudflare dashboard -> My Profile -> API
   Tokens -> Create Token -> "Edit zone DNS" template -- never the legacy
   account-wide Global API Key), and note the zone's ID from the dashboard's
   Overview tab.

```bash
cd terraform/amplify
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "amplify/terraform.tfstate"
region  = "us-west-2"
encrypt = true
EOF
cat > terraform.tfvars <<EOF
state_bucket_name    = "<state_bucket_name from bootstrap output>"
cloudflare_api_token = "<token from the Cloudflare API Tokens page>"
cloudflare_zone_id   = "<zone ID from the Cloudflare dashboard>"
EOF

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

**Apply this in two passes rather than all at once**, since it touches a
real, in-use domain (email included):

1. First, apply with the two `aws_amplify_domain_association` resources and
   the `cloudflare_record` resources commented out (or `terraform apply
   -target=aws_amplify_app.site -target=aws_amplify_app.docs
   -target=aws_amplify_branch.site_main -target=aws_amplify_branch.docs_main`).
   Confirm both apps build and deploy successfully to their default
   `terraform output site_default_domain` / `docs_default_domain`
   `*.amplifyapp.com` URLs -- this proves the GitHub App connection and
   `AMPLIFY_MONOREPO_APP_ROOT` build config actually work, with zero DNS
   risk.
2. Once that's confirmed, apply the rest. The new Cloudflare records are
   additive and don't touch the zone's existing MX/SPF/DKIM records, but
   doing this as a second, deliberate step keeps the blast radius small.

`aws_amplify_domain_association.site`/`.docs` are both created with
`wait_for_verification = false` -- their own `certificate_verification_dns_record`
and `sub_domain[*].dns_record` outputs are what the `cloudflare_record`
resources below them are built from, so the DNS they'd be waiting to see
doesn't exist yet at the moment they're created. Verification happens
asynchronously in AWS's backend once the Cloudflare records exist; check
actual status in the Amplify console (or a follow-up `terraform plan`)
rather than trusting `apply`'s exit code for these two resources.

After both passes, verify `civicdog.com`, `www.civicdog.com`, and
`docs.civicdog.com` all resolve over HTTPS to the right app, and --
critically -- send a test email to a `civicdog.com` address to confirm the
Google Workspace records were never touched.

## `cd-webapp/` -- Amplify Hosting + Cognito

`cd-webapp` is the customer portal (`rchacon/cd-webapp`, React + TypeScript
+ Vite -- a separate, dedicated repo, not part of `cd-website`'s monorepo)
where customers sign up for an API key, view their usage, and pay their
bill, deployed to `app.civicdog.com`. This directory provisions its
Amplify Hosting app/branch/domain association, its Cloudflare DNS records,
and a Cognito User Pool + App Client for customer auth -- unlike
`amplify/`'s two apps, `cd-webapp` has no
`AMPLIFY_MONOREPO_APP_ROOT`/`applications:` build spec wrapper, just a
plain single-app one, since it isn't sharing a repo with anything else.

Auth is AWS Cognito, not a self-rolled scheme, on the **Essentials** feature
plan (explicit in Terraform, not left to whatever AWS defaults new pools
to) -- Essentials is the minimum tier that unlocks **Managed Login**, the
brandable hosted sign-in/sign-up UI at `auth.civicdog.com`
(`aws_cognito_user_pool_domain`, `managed_login_version = 1`, not the
older/classic Hosted UI). `cd-webapp`'s App Client is a public client (no
secret; can't be kept confidential in a browser-delivered app) using the
OAuth2 Authorization Code grant -- the app redirects to
`auth.civicdog.com`, never calls Cognito's `InitiateAuth`/SRP APIs
directly, so `explicit_auth_flows` only needs `ALLOW_REFRESH_TOKEN_AUTH`
(silent session renewal). Email verification currently goes through
Cognito's own built-in ("`COGNITO_DEFAULT`") sending, which has a low daily
quota not meant for real signup volume -- move to SES before that becomes
a real constraint.

`auth.civicdog.com`'s ACM certificate is provisioned in `us-east-1`
regardless of `var.aws_region` -- Managed Login custom domains are
CloudFront-backed, same constraint as `cd-api/`'s `api.civicdog.com` and
`amplify/`'s Amplify-managed certs, requiring a second, aliased `aws`
provider block (`aws.us_east_1`) purely for this one certificate.

**Two manual, one-time prerequisites**, same requirements as `amplify/`'s:

1. **Authorize the AWS Amplify GitHub App** for `rchacon/cd-webapp` -- AWS
   Amplify console, same steps as `amplify/`'s prerequisite above. **This
   isn't just an AWS-side step**: confirmed the hard way (a real
   `terraform apply` succeeded, but the very first build then failed with
   `Unable to assume specified IAM Role` -- a red herring; nothing to do
   with IAM at all) -- the GitHub App install itself has its own
   repository access list (GitHub -> Settings -> Installations -> the AWS
   Amplify app's configuration), separate from AWS's own
   authorization/connection flow. `rchacon/cd-website` being on that list
   already doesn't cover `rchacon/cd-webapp` -- it has to be added
   explicitly, every time a new repo is wired up.
2. **Create a Cloudflare API token** scoped to `Zone:DNS:Edit` for the
   `civicdog.com` zone -- reuse the same token `amplify/` uses if you still
   have it (same scope, same zone), or generate a new one the same way
   (Cloudflare dashboard -> My Profile -> API Tokens -> "Edit zone DNS"
   template).

```bash
cd terraform/cd-webapp
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "cd-webapp/terraform.tfstate"
region  = "us-west-2"
encrypt = true
EOF
cat > terraform.tfvars <<EOF
state_bucket_name    = "<state_bucket_name from bootstrap output>"
github_access_token  = "<PAT, scope admin:repo_hook -- see amplify/'s section above for why one's needed at all>"
cloudflare_api_token = "<token from the Cloudflare API Tokens page>"
cloudflare_zone_id   = "<zone ID from the Cloudflare dashboard>"
EOF

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

**Apply this in two passes rather than all at once**, same reasoning as
`amplify/`'s two-pass note above -- it touches the live `civicdog.com` zone:

1. First, apply just the app/branch/Cognito-pool-and-client resources
   (e.g. `terraform apply -target=aws_amplify_app.cd_webapp
   -target=aws_amplify_branch.cd_webapp_main
   -target=aws_cognito_user_pool.cd_webapp
   -target=aws_cognito_user_pool_client.cd_webapp`). Confirm
   `terraform output cd_webapp_default_domain` builds and deploys
   successfully on its `*.amplifyapp.com` URL -- zero DNS risk. (Managed
   Login itself can't be end-to-end tested yet at this point -- its
   callback/logout URLs only point at `app.civicdog.com`, which doesn't
   resolve until step 2.)
2. Once confirmed, apply the rest: `app.civicdog.com`'s
   `aws_amplify_domain_association` + its two `cloudflare_record`s, and
   `auth.civicdog.com`'s ACM cert + validation + `aws_cognito_user_pool_domain`
   + its `cloudflare_record`. All of these are additive and don't touch the
   zone's existing MX/SPF/DKIM records, but a second deliberate step keeps
   the blast radius small regardless.

`aws_amplify_domain_association.cd_webapp` is created with
`wait_for_verification = false` -- same reason as `amplify/`'s two
associations (its own outputs are what the Cloudflare records are built
from, so the DNS it'd wait on doesn't exist yet at creation time).
Verification happens asynchronously; check the Amplify console or a
follow-up `terraform plan` rather than trusting `apply`'s exit code for
that one resource. `aws_cognito_user_pool_domain.cd_webapp`'s
`cloudflare_record` similarly can't be created until the domain resource
exists and returns its CloudFront distribution hostname -- confirm the
exact computed attribute name (`cloudfront_distribution` as written here)
against the installed `aws` provider version at plan time.

## `cd-server/` -- ECS (EC2) + ALB

`cd-server` (`rchacon/cd-platform`, FastAPI + Strawberry GraphQL backing
`cd-webapp`) runs as an ECS service on the **EC2 launch type** (not
Fargate -- cheaper for an always-on workload, same stance `cd-infra#24`
takes for Airflow's planned ECS decomposition), behind a public ALB at
`server.civicdog.com`. Provisions: a `t3.micro` ECS container instance
(launch template + ASG + capacity provider, single instance by default),
the ECS cluster/service/task definition, the ALB + target group +
HTTPS/HTTP-redirect listeners, `server.civicdog.com`'s ACM cert (regional,
`us-west-2` -- unlike `cd-api/`'s/`cd-webapp/`'s CloudFront-backed custom
domains, an ALB's cert has to be issued in the ALB's own region) and its
Cloudflare DNS records, and a GitHub OIDC deploy role (see below).

Reads `../networking`'s subnet/security-group outputs and `../cd-api`'s
`lambda_function_name` output -- `cd-server`'s production `LambdaApiClient`
invokes `cd-api`'s Lambda directly via `boto3`, not over HTTP, so the only
cross-component wiring needed is an IAM `lambda:InvokeFunction` grant
(this directory's task role), not network reachability.

Also reads `../rds`'s and `../cd-webapp`'s outputs (`cd-infra#48`) to wire
up `cd-server`'s `cd_customers` database and Cognito JWT verification:
the ECS EC2 instance's own `user-data` idempotently bootstraps the
`cd_customers` database and a scoped `cd_server_app` role against RDS
(RDS master credentials, used only transiently, same pattern as
`../airflow`'s), with that role's password held in its own Secrets
Manager secret and injected into the task definition via ECS's native
`secrets` block; `COGNITO_USER_POOL_ID`/`COGNITO_REGION`/
`COGNITO_CLIENT_IDS` come from `../cd-webapp`'s outputs as plain
(non-secret) environment variables. This does need network reachability,
unlike the Lambda wiring above -- `../networking`'s `rds`/`cd_server`
security groups were extended with a mutual Postgres ingress/egress rule.

```bash
cd terraform/cd-server
cat > backend.hcl <<EOF
bucket  = "<state_bucket_name from bootstrap output>"
key     = "cd-server/terraform.tfstate"
region  = "us-west-2"
encrypt = true
EOF
cat > terraform.tfvars <<EOF
state_bucket_name        = "<state_bucket_name from bootstrap output>"
github_oidc_provider_arn = "<github_oidc_provider_arn from bootstrap output>"
cloudflare_api_token     = "<token from the Cloudflare API Tokens page>"
cloudflare_zone_id       = "<zone ID from the Cloudflare dashboard>"
EOF

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

**No `cd-server` image has been published yet** -- as of this writing, no
`cd-server-v*` tag has ever been pushed in `cd-platform`, so
`ghcr.io/rchacon/cd-server` doesn't exist. The ECS service will apply
cleanly regardless, but its task will sit unable to start until an image
exists. Push a release (`cd-server-v0.1.0`, matching `cd-server/pyproject.toml`'s
current version, or whatever's current) either before or after `apply` --
`cd-server-deploy.yml` builds and pushes it to GHCR on that tag.

**Deploy automation isn't wired up yet.** This directory provisions a
GitHub OIDC role (`cd_server_deploy`, output as `cd_server_deploy_role_arn`)
scoped to `ecs:UpdateService`/`ecs:DescribeServices` on this one service,
but nothing in `cd-platform`'s `cd-server-deploy.yml` assumes it yet --
unlike Watchtower's GHCR-polling auto-restart on `../airflow`'s plain EC2
instance, ECS tasks don't self-detect a new `:latest` push. Until that
workflow step exists, roll out a new image manually:

```bash
aws ecs update-service --cluster cd-platform-cd-server \
  --service cd-platform-cd-server --force-new-deployment
```

## Validating without AWS credentials

`terraform fmt -check -recursive` and `terraform validate` (after
`terraform init -backend=false`) don't need real AWS credentials -- they
only check formatting and internal config consistency. `plan`/`apply` do
need credentials, since they call the AWS API.
