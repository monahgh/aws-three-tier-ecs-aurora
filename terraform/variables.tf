variable "aws_region" {
  description = "AWS region for the lab."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Name prefix for all resources and the Project tag."
  type        = string
  default     = "three-tier-lab"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (project 1 uses 10.20.0.0/16)."
  type        = string
  default     = "10.30.0.0/16"
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Aurora master username. The password is generated and stored by RDS in Secrets Manager."
  type        = string
  default     = "appadmin"
}

variable "aurora_min_acu" {
  description = "Aurora Serverless v2 minimum capacity (ACUs)."
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Aurora Serverless v2 maximum capacity (ACUs)."
  type        = number
  default     = 4
}

variable "api_image" {
  description = "Public Node.js image for the API. The code is injected at startup."
  type        = string
  default     = "public.ecr.aws/docker/library/node:22-alpine"
}

variable "loadgen_image" {
  description = "Public PostgreSQL image, used only for its pgbench/psql clients."
  type        = string
  default     = "public.ecr.aws/docker/library/postgres:17-alpine"
}

variable "loadgen_count" {
  description = "Number of pgbench load-generator tasks. Set to 0 to stop the load."
  type        = number
  default     = 1
}

variable "loadgen_rate" {
  description = "pgbench target transactions per second (rate limit)."
  type        = number
  default     = 30
}

variable "loadgen_extra_flags" {
  description = "Extra pgbench flags, e.g. \"-M prepared\" to demonstrate RDS Proxy session pinning."
  type        = string
  default     = ""
}

variable "bastion_instance_type" {
  description = "Instance type for the SSM-only bastion (ARM/Graviton)."
  type        = string
  default     = "t4g.micro"
}
