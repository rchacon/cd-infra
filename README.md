# CD-Infrastructure

Infrastructure as code for provisioning AWS resources for `cd-platform`. See
`terraform/README.md` for setup and usage of each `terraform/*` directory.

## Architecture

```mermaid
flowchart TB
    internet(("Internet"))
    cf[["Cloudflare DNS<br/>#19"]]
    apigw[["API Gateway<br/>#4"]]
    openapi[("openapi_spec S3<br/>#18, #21")]

    subgraph vpc["VPC -- 10.0.0.0/16 (networking/, #1)"]
        igw["Internet Gateway"]

        subgraph pub["Public subnets (2 AZs)"]
            nat["NAT Gateway"]
        end

        subgraph priv["Private subnets (2 AZs)"]
            rds_sg{{"rds SG"}}
            airflow_sg{{"airflow SG"}}
            lambda_sg{{"lambda SG"}}
            rds[("RDS Postgres<br/>#2")]
            airflow["Airflow EC2<br/>#3"]
            lambda["cd-api Lambda<br/>#4<br/>(+ RDS Proxy)"]
        end
    end

    internet --- igw
    igw --- pub
    internet -- "api.civicdog.com/v1" --> cf
    cf -- CNAME --> apigw
    internet -- "*.execute-api...amazonaws.com" --> apigw
    internet -- "GET openapi.json" --> openapi
    apigw -- invokes --> lambda

    rds -- protected by --> rds_sg
    airflow -- attaches to --> airflow_sg
    lambda -- attaches to --> lambda_sg

    airflow_sg -- "HTTPS :443" --> nat
    nat --> igw
    airflow_sg -- "Postgres :5432" --> rds_sg
    lambda_sg -- "Postgres :5432" --> rds_sg
```

RDS (#2), the Airflow EC2 instance (#3), and cd-api's Lambda + API Gateway
(#4) are all provisioned -- nothing left planned/dashed. RDS is encrypted
under its own customer-managed KMS key, single-AZ, reachable only from the
`airflow`/`lambda` security groups; its schema comes from `cd-etl`'s
container migrating itself on every start, run from the Airflow instance
-- the only durable path to reach RDS. The sibling `airflow_metadata`
database and a scoped least-privilege database role are both bootstrapped
automatically on the Airflow instance's first boot (RDS has no equivalent
to a Postgres init script), using the RDS master credentials only
transiently -- `cd-etl` connects as the scoped role, never the master
user. Documented in `terraform/README.md`. The Airflow instance itself has
no public ingress at all -- runs `cd-etl` + a `watchtower` sidecar polling
GHCR for new releases, and is reachable only via SSM Session Manager
(shell or port-forwarding to its UI), never a public IP.

cd-api's Lambda sits behind API Gateway (a static API key gates access for
now, a deliberate MVP stopgap) and reaches RDS through RDS Proxy -- omitted
as its own node above since it reuses the `lambda` security group entirely
(the `lambda_sg -- Postgres :5432 --> rds_sg` edge already covers it at the
network level), with its own scoped least-privilege database role
bootstrapped manually (not automatically, unlike `airflow/`'s -- Lambda has
no boot-time hook to run it from), documented in `terraform/README.md`.
`bootstrap/`'s S3 state bucket/KMS key/GitHub OIDC provider and every
component's own KMS key aren't part of this diagram -- they're supporting
resources, not part of the app's runtime traffic path.

`api.civicdog.com` (#19) is a Cloudflare-managed CNAME onto API Gateway's
custom domain (an ACM cert + `EDGE`/CloudFront endpoint), with `/v1`
URL-path versioning via `base_path_mapping` -- a friendlier alternate entry
point onto the exact same `apigw`/stage/Lambda as the raw
`*.execute-api...amazonaws.com` invoke URL, both shown above since either
still works. The `openapi_spec` S3 bucket (#18, its CORS config added in
#21) is unrelated to that request path entirely -- a separate,
publicly-readable bucket (SSE-S3, deliberately not a customer-managed KMS
key, since anonymous public `GetObject` is the whole point) serving
`openapi.json` for `cd-website`'s docs viewer at `docs.civicdog.com`.
`cd-api-deploy.yml`'s GitHub OIDC role is the only writer (`s3:PutObject`
scoped to that one key, on every `cd-api-vX.X.X` tag deploy) -- Terraform
only provisions the bucket, never uploads to it itself.
