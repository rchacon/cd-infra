# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

Terraform IaC for `cd-platform`'s AWS deployment, split out of that repo (see its own `#5` issue) into a dedicated repo. Provisioned incrementally by component: `bootstrap/` (state backend, one-time), `networking/` (VPC/subnets/security groups), `rds/` (managed Postgres), `airflow/` (self-hosted Airflow on EC2, running `cd-etl`'s container via GHCR + Watchtower), and eventually `cd-api/` (Lambda). See the root `README.md` for the architecture diagram, `terraform/README.md` for per-directory setup commands.

Each directory is its own Terraform root module with independent state (S3 backend, native `use_lockfile` locking, no DynamoDB table). Later directories read earlier ones' outputs via `terraform_remote_state`, using a gitignored `backend.hcl` for their own backend config and (where needed) a gitignored `terraform.tfvars` for the state bucket name -- both account-specific values that shouldn't be hardcoded into version-controlled `.tf` files. See `terraform/README.md` for the exact `backend.hcl`/`terraform.tfvars` contents to generate.

### Design decisions worth knowing before touching this repo

- **Security groups, not network ACLs, do all traffic control.** `networking/`'s three groups (`rds`, `airflow`, `lambda`) use standalone `aws_vpc_security_group_ingress_rule`/`egress_rule` resources rather than inline blocks -- required because `rds`'s ingress references `airflow`/`lambda` while their egress references `rds` right back, a mutual reference inline blocks can't express without a dependency cycle. The VPC module's default network ACL is explicitly *not* managed (`manage_default_network_acl = false`) -- adopting it would need `ec2:DescribeNetworkAcls`/`*NetworkAclEntry` IAM permissions for a resource this project doesn't otherwise use to enforce anything beyond what the security groups already do.
- **NAT gateway is on by default** (`enable_nat_gateway = true` in `networking/`, one shared gateway via `single_nat_gateway = true`) -- flipped on once `airflow/`'s EC2 instance actually needed outbound internet (GHCR image pulls, package installs, SSM). It stayed off from `networking/`'s initial PR through `rds/`'s, per this project's "flip it on in whichever PR first needs it, not preemptively" policy.
- **RDS (`rds/`) is plain `aws_db_instance`, single-AZ, not Aurora** -- matches this project's current scale (a few thousand rows today; `bills`/`bill_subjects`/`roll_call_votes` later per `cd-platform#9`). `engine_version` is major-version-only (`"16"`, matching `cd-platform`'s local-dev `postgres:16`) with `auto_minor_version_upgrade = true`, so AWS resolves the current minor automatically rather than a hardcoded value going stale.
- **RDS's schema migrations are not Terraform-managed.** `cd-etl`'s own `alembic upgrade head` and Airflow's own metadata migrations both run automatically, baked into the `cd-etl` container's entrypoint on every start (per `cd-platform#26`) -- no manual step for either. The one exception: RDS has no `docker-entrypoint-initdb.d` equivalent, so the sibling `airflow_metadata` database itself needs a one-time manual `CREATE DATABASE airflow_metadata;`, run from the `airflow/` EC2 instance (the only thing that can reach RDS, per its security group) via an SSM session, before `airflow/`'s container can start successfully.
- **`airflow/`'s EC2 instance runs Docker only -- no `uv`/Python/git installed on it.** `cd-etl`'s image (published to GHCR, not ECR, so CI never needs AWS credentials) bundles the DAG code and both sets of migrations; a sidecar `watchtower` container polls GHCR's `latest` tag and auto-restarts `cd-etl` on new releases, so deploys never touch this instance directly. `cd-etl`'s GHCR package is public, so both the image pull and watchtower's polling work anonymously -- no GitHub PAT/`docker login` needed (verified directly: an unauthenticated token exchange against `ghcr.io` for `rchacon/cd-etl` still resolves the manifest).
- **Two separate IAM surfaces exist for `airflow/`: the instance's own runtime role (Terraform-managed) and the `cd-terraform` deployer user's policy (Console-managed, empirical, per the IAM section below).** The instance role needs `secretsmanager:GetSecretValue`/`kms:Decrypt` to fetch its own secrets and the RDS master password at boot, plus `AmazonSSMManagedInstanceCore` for Session Manager access -- these are defined in `airflow/main.tf` since the instance needs them regardless of who's deploying. The deployer user's policy is the one built up empirically against real `AccessDenied` errors.
- **The Airflow UI (port 8080) has no public ingress, ever** -- the `airflow` security group defines zero ingress rules. Access is via SSM Session Manager port-forwarding (`aws ssm start-session ... --document-name AWS-StartPortForwardingSession`), not a VPN -- AWS Client VPN's per-subnet-association billing (~$72/mo) alone would dwarf this project's entire AWS spend for occasional admin access to one DAG's UI.
- **Every KMS key here is customer-managed, not the AWS-managed default** (the state bucket's key in `bootstrap/`, RDS storage's key in `rds/`) -- the point is requiring two independent grants (e.g. `s3:GetObject`/`rds` access *and* `kms:Decrypt` on that specific key) before someone can read the underlying data, rather than one over-broad IAM grant being sufficient on its own. Costs a flat ~$1/mo per key. If a new component needs its own KMS-encrypted resource, follow this pattern rather than defaulting to the AWS-managed key.
- **KMS alias operations need the alias ARN directly in `Resource`, not a `kms:AliasName` condition key** -- that condition key doesn't exist despite being a common assumption; alias-scoped IAM statements can't use condition keys at all, and alias operations independently need a separate statement granting usage on the underlying key resource too.

## IAM

The `cd-terraform` IAM user's policy is hand-managed in the AWS Console (not Terraform-managed), attached via a group, deliberately avoiding `AdministratorAccess`/`PowerUserAccess` (the latter excludes `iam:*`, which this project's future EC2/Lambda execution roles will need). It's been built up **empirically, one real `AccessDenied` error at a time** across `networking/` and `rds/` -- run `terraform plan`/`apply`, let AWS name the exact missing action, add it to the Console policy, retry. Don't try to pre-write a "complete" policy from memory or documentation; AWS's actual error messages are more reliable than guessing, and this project has been burned before by KMS-specific assumptions that turned out wrong (see the alias-ARN note above).

## Cost

With `enable_nat_gateway = true` (current default, since `airflow/`), the running total is roughly: `bootstrap/`'s KMS key (~$1/mo) + `rds/`'s KMS key (~$1/mo) + the `db.t4g.micro`/20GiB gp3 RDS instance (~$12-15/mo) + the single shared NAT gateway (~$32-33/mo) + `airflow/`'s KMS key (~$1/mo) + its `t4g.small` EC2 instance (~$12/mo). VPC/subnets/route tables/IGW/security groups are free.

## Standing agreement on `terraform apply`

`terraform plan` freely. Always get explicit confirmation before `terraform apply` -- it creates real, billable AWS resources.

## Git conventions

PRs are merged with a merge commit (`gh pr merge --merge`), not squash or rebase -- preserves the individual commit history from the PR branch. After merging, delete the branch both locally and remotely (`gh pr merge --merge --delete-branch` does both in one step).

When addressing review comments on an open PR, break the fixes up into separate commits along logical lines (one commit per distinct issue/fix, not one commit for everything) rather than a single catch-all commit, and reply to each review comment on GitHub referencing the specific commit hash that addressed it (e.g. "Fixed in `abc1234`.") -- keeps the review thread traceable to the exact change that resolved it, rather than a generic "addressed" reply pointing at the whole PR.

## Commands

See `terraform/README.md` for the full per-directory setup (backend.hcl/terraform.tfvars generation, init/plan/apply). Quick reference, validating without AWS credentials (same checks CI runs):

```bash
terraform fmt -check -recursive terraform/
for dir in $(find terraform -name '*.tf' -printf '%h\n' | sort -u); do
  terraform -chdir="$dir" init -backend=false -input=false
  terraform -chdir="$dir" validate
done
```

CI (`.github/workflows/terraform-checks.yml`) runs `fmt`/`validate` (directory-discovery based, so new `terraform/*` directories are picked up automatically) plus a Trivy IaC security scan on every PR.
