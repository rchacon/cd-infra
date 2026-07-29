# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Architecture

Terraform IaC for `cd-platform`'s AWS deployment, split out of that repo (see its own `#5` issue) into a dedicated repo. Provisioned incrementally by component: `bootstrap/` (state backend, one-time), `networking/` (VPC/subnets/security groups), `rds/` (managed Postgres), and eventually `airflow/` (self-hosted Airflow on EC2) and `cd-api/` (Lambda). See the root `README.md` for the architecture diagram, `terraform/README.md` for per-directory setup commands.

Each directory is its own Terraform root module with independent state (S3 backend, native `use_lockfile` locking, no DynamoDB table). Later directories read earlier ones' outputs via `terraform_remote_state`, using a gitignored `backend.hcl` for their own backend config and (where needed) a gitignored `terraform.tfvars` for the state bucket name -- both account-specific values that shouldn't be hardcoded into version-controlled `.tf` files. See `terraform/README.md` for the exact `backend.hcl`/`terraform.tfvars` contents to generate.

### Design decisions worth knowing before touching this repo

- **Security groups, not network ACLs, do all traffic control.** `networking/`'s three groups (`rds`, `airflow`, `lambda`) use standalone `aws_vpc_security_group_ingress_rule`/`egress_rule` resources rather than inline blocks -- required because `rds`'s ingress references `airflow`/`lambda` while their egress references `rds` right back, a mutual reference inline blocks can't express without a dependency cycle. The VPC module's default network ACL is explicitly *not* managed (`manage_default_network_acl = false`) -- adopting it would need `ec2:DescribeNetworkAcls`/`*NetworkAclEntry` IAM permissions for a resource this project doesn't otherwise use to enforce anything beyond what the security groups already do.
- **NAT gateway is off by default** (`enable_nat_gateway = false` in `networking/`) -- nothing needs outbound internet from a private subnet until `airflow/`'s EC2 instance actually requires it. Flip it on in whichever PR first needs it, not preemptively.
- **RDS (`rds/`) is plain `aws_db_instance`, single-AZ, not Aurora** -- matches this project's current scale (a few thousand rows today; `bills`/`bill_subjects`/`roll_call_votes` later per `cd-platform#9`). `engine_version` is major-version-only (`"16"`, matching `cd-platform`'s local-dev `postgres:16`) with `auto_minor_version_upgrade = true`, so AWS resolves the current minor automatically rather than a hardcoded value going stale.
- **RDS has no schema, deliberately.** Its security group only ever accepts connections from the `airflow`/`lambda` groups, so there's no durable way to reach it until the Airflow EC2 instance exists inside the VPC -- a temporary public-access window would only solve the *first* migration, not the second (`bills`, per `cd-platform#9`), so it's not worth building. Whichever PR stands up the Airflow EC2 instance is responsible for running `cd-platform/cd-etl`'s `alembic upgrade head` against it (either directly on that instance, or via an SSM port-forward tunnel through it) and creating the `airflow_metadata` database, as its first deploy step.
- **Every KMS key here is customer-managed, not the AWS-managed default** (the state bucket's key in `bootstrap/`, RDS storage's key in `rds/`) -- the point is requiring two independent grants (e.g. `s3:GetObject`/`rds` access *and* `kms:Decrypt` on that specific key) before someone can read the underlying data, rather than one over-broad IAM grant being sufficient on its own. Costs a flat ~$1/mo per key. If a new component needs its own KMS-encrypted resource, follow this pattern rather than defaulting to the AWS-managed key.
- **KMS alias operations need the alias ARN directly in `Resource`, not a `kms:AliasName` condition key** -- that condition key doesn't exist despite being a common assumption; alias-scoped IAM statements can't use condition keys at all, and alias operations independently need a separate statement granting usage on the underlying key resource too.

## IAM

The `cd-terraform` IAM user's policy is hand-managed in the AWS Console (not Terraform-managed), attached via a group, deliberately avoiding `AdministratorAccess`/`PowerUserAccess` (the latter excludes `iam:*`, which this project's future EC2/Lambda execution roles will need). It's been built up **empirically, one real `AccessDenied` error at a time** across `networking/` and `rds/` -- run `terraform plan`/`apply`, let AWS name the exact missing action, add it to the Console policy, retry. Don't try to pre-write a "complete" policy from memory or documentation; AWS's actual error messages are more reliable than guessing, and this project has been burned before by KMS-specific assumptions that turned out wrong (see the alias-ARN note above).

## Cost

With `enable_nat_gateway = false` (current default), the running total is roughly: `bootstrap/`'s KMS key (~$1/mo) + `rds/`'s KMS key (~$1/mo) + the `db.t4g.micro`/20GiB gp3 RDS instance (~$12-15/mo). VPC/subnets/route tables/IGW/security groups are free. NAT gateway (~$32-33/mo) only activates once a future PR needs outbound internet from a private subnet.

## Standing agreement on `terraform apply`

`terraform plan` freely. Always get explicit confirmation before `terraform apply` -- it creates real, billable AWS resources.

## Git conventions

PRs are merged with a merge commit (`gh pr merge --merge`), not squash or rebase -- preserves the individual commit history from the PR branch.

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
