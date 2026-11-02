data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)
  account_id = data.aws_caller_identity.current.account_id
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.project_name
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets   = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i + 1)]  # 10.30.1.0/24, 10.30.2.0/24
  private_subnets  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i + 11)] # 10.30.11.0/24, 10.30.12.0/24
  database_subnets = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i + 21)] # 10.30.21.0/24, 10.30.22.0/24

  create_database_subnet_group = true

  # Lab cost setting: one NAT gateway for the whole VPC (prod: one per AZ).
  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_hostnames = true
  enable_dns_support   = true
}
