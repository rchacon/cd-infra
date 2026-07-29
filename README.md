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
        end
    end

    subgraph future["Not yet provisioned"]
        rds[("RDS Postgres<br/>#2")]
        airflow["Airflow EC2<br/>#3"]
        lambda[["cd-api Lambda<br/>#4"]]
    end

    internet --- igw
    igw --- pub

    airflow -. attaches to .-> airflow_sg
    lambda -. attaches to .-> lambda_sg
    rds -. attaches to .-> rds_sg

    airflow_sg -- "HTTPS :443" --> internet
    airflow_sg -- "Postgres :5432" --> rds_sg
    lambda_sg -- "Postgres :5432" --> rds_sg

    classDef planned stroke-dasharray: 5 5
    class rds,airflow,lambda planned
```

Dashed nodes (RDS, Airflow EC2, cd-api's Lambda) aren't provisioned yet --
only their security groups exist so far, reserved by `networking/` for
whichever of #2/#3/#4 lands first. `bootstrap/`'s S3 state bucket and KMS
key aren't part of this diagram -- they hold Terraform's own state and sit
outside the VPC entirely, unrelated to the app's runtime traffic.
