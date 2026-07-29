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
            nat["NAT Gateway<br/>(off by default)"]
        end

        subgraph priv["Private subnets (2 AZs)"]
            rds_sg{{"rds SG"}}
            airflow_sg{{"airflow SG"}}
            lambda_sg{{"lambda SG"}}
            rds[("RDS Postgres<br/>#2 -- no schema yet")]
        end
    end

    subgraph future["Not yet provisioned"]
        airflow["Airflow EC2<br/>#3"]
        lambda[["cd-api Lambda<br/>#4"]]
    end

    internet --- igw
    igw --- pub

    rds -- protected by --> rds_sg
    airflow -. attaches to .-> airflow_sg
    lambda -. attaches to .-> lambda_sg

    airflow_sg -- "HTTPS :443" --> internet
    airflow_sg -- "Postgres :5432" --> rds_sg
    lambda_sg -- "Postgres :5432" --> rds_sg

    classDef planned stroke-dasharray: 5 5
    class airflow,lambda planned
```

RDS (#2) is provisioned -- encrypted under its own customer-managed KMS
key, single-AZ, reachable only from the `airflow`/`lambda` security groups
-- but has no schema yet: that's blocked on #3's Airflow EC2 instance
existing (the only durable path to actually reach it) to run the initial
Alembic migration. Dashed nodes (Airflow EC2, cd-api's Lambda) aren't
provisioned at all yet -- only their security groups exist so far.
`bootstrap/`'s S3 state bucket/KMS key and `rds/`'s own KMS key aren't part
of this diagram -- they're supporting resources, not part of the app's
runtime traffic path.
