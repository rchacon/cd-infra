variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "vpc_cidr must be at least a /24 -- this module carves out /24 subnets from it."
  }
}

variable "azs" {
  description = "Availability zones to spread subnets across. RDS Multi-AZ requires at least 2."
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b"]

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least 2 AZs are required for RDS Multi-AZ."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one per AZ. Cheaper (~$32/mo vs ~$64/mo), at the cost of a single point of failure if that AZ has an outage -- reasonable for this project's current stage."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Provision NAT gateway(s) for the private subnets. Off by default -- nothing needs outbound internet from a private subnet until #2/#3/#4 (RDS, the Airflow EC2 instance, cd-api's Lambda) actually exist, so this stays false until whichever of those lands first."
  type        = bool
  default     = false
}
