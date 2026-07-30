# CD-Infrastructure

Infrastructure as code for provisioning AWS resources for `cd-platform`. See
`terraform/README.md` for setup and usage of each `terraform/*` directory.

## Architecture

```mermaid
flowchart TB
    internet(("Internet"))

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
        end
    end

    subgraph future["Not yet provisioned"]
        lambda[["cd-api Lambda<br/>#4"]]
    end

    internet --- igw
    igw --- pub

    rds -- protected by --> rds_sg
    airflow -- attaches to --> airflow_sg
    lambda -. attaches to .-> lambda_sg

    airflow_sg -- "HTTPS :443" --> internet
    airflow_sg -- "Postgres :5432" --> rds_sg
    lambda_sg -- "Postgres :5432" --> rds_sg

    classDef planned stroke-dasharray: 5 5
    class lambda planned
```

RDS (#2) and the Airflow EC2 instance (#3) are both provisioned. RDS is
encrypted under its own customer-managed KMS key, single-AZ, reachable
only from the `airflow`/`lambda` security groups; its schema (and Airflow's
own metadata database) come from `cd-etl`'s container migrating itself on
every start, run from the Airflow instance -- the only durable path to
reach RDS. The Airflow instance itself has no public ingress at all --
runs `cd-etl` + a `watchtower` sidecar polling GHCR for new releases, and
is reachable only via SSM Session Manager (shell or port-forwarding to its
UI), never a public IP. The dashed node (cd-api's Lambda) isn't provisioned
yet -- only its security group exists so far. `bootstrap/`'s S3 state
bucket/KMS key and `rds/`'s/`airflow/`'s own KMS keys aren't part of this
diagram -- they're supporting resources, not part of the app's runtime
traffic path.
