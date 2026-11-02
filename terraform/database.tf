# Aurora PostgreSQL Serverless v2: one writer + one reader.

locals {
  cluster_id    = "${var.project_name}-aurora"
  db_secret_arn = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

data "aws_rds_engine_version" "aurora" {
  engine       = "aurora-postgresql"
  default_only = true
}

resource "aws_rds_cluster_parameter_group" "main" {
  name   = "${var.project_name}-aurora-pg"
  family = data.aws_rds_engine_version.aurora.parameter_group_family

  parameter {
    name  = "log_min_duration_statement"
    value = "250"
  }

  parameter {
    name  = "track_io_timing"
    value = "1"
  }

  parameter {
    name  = "log_autovacuum_min_duration"
    value = "0"
  }
}

# Created up front so Terraform owns the retention and destroy removes it.
resource "aws_cloudwatch_log_group" "aurora" {
  name              = "/aws/rds/cluster/${local.cluster_id}/postgresql"
  retention_in_days = 3
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = local.cluster_id
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned"
  engine_version     = data.aws_rds_engine_version.aurora.version_actual
  database_name      = var.db_name
  master_username    = var.db_username

  # RDS generates the password, stores and can rotate it in Secrets Manager.
  # It never appears in Terraform state.
  manage_master_user_password = true

  db_subnet_group_name            = module.vpc.database_subnet_group_name
  vpc_security_group_ids          = [aws_security_group.db.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name
  enabled_cloudwatch_logs_exports = ["postgresql"]

  storage_encrypted       = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }

  depends_on = [aws_cloudwatch_log_group.aurora]
}

resource "aws_rds_cluster_instance" "writer" {
  identifier                   = "${var.project_name}-aurora-1"
  cluster_identifier           = aws_rds_cluster.main.id
  instance_class               = "db.serverless"
  engine                       = aws_rds_cluster.main.engine
  engine_version               = aws_rds_cluster.main.engine_version
  db_subnet_group_name         = module.vpc.database_subnet_group_name
  publicly_accessible          = false
  performance_insights_enabled = true
  promotion_tier               = 0
  apply_immediately            = true
}

# Created after the writer, so the first instance is guaranteed to become the writer.
# After a failover the roles swap; the names are just labels.
resource "aws_rds_cluster_instance" "reader" {
  identifier                   = "${var.project_name}-aurora-2"
  cluster_identifier           = aws_rds_cluster.main.id
  instance_class               = "db.serverless"
  engine                       = aws_rds_cluster.main.engine
  engine_version               = aws_rds_cluster.main.engine_version
  db_subnet_group_name         = module.vpc.database_subnet_group_name
  publicly_accessible          = false
  performance_insights_enabled = true
  promotion_tier               = 1
  apply_immediately            = true

  depends_on = [aws_rds_cluster_instance.writer]
}
