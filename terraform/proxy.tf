# RDS Proxy: connection pooling in front of Aurora.
# Default endpoint = read/write (writer). Extra endpoint = READ_ONLY (reader).

resource "aws_iam_role" "proxy" {
  name = "${var.project_name}-rds-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "proxy" {
  name = "read-db-secret"
  role = aws_iam_role.proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = local.db_secret_arn
      },
      {
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = "*"
        Condition = { StringEquals = { "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com" } }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "proxy" {
  name              = "/aws/rds/proxy/${var.project_name}-proxy"
  retention_in_days = 3
}

resource "aws_db_proxy" "main" {
  name                   = "${var.project_name}-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.proxy.id]
  require_tls            = true
  idle_client_timeout    = 1800

  auth {
    auth_scheme               = "SECRETS"
    iam_auth                  = "DISABLED"
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    secret_arn                = local.db_secret_arn
    description               = "Aurora master user (RDS-managed secret)"
  }

  depends_on = [aws_cloudwatch_log_group.proxy, aws_iam_role_policy.proxy]
}

# Default pool settings: max connections 100% of max_connections, borrow timeout 120 s.
resource "aws_db_proxy_default_target_group" "main" {
  db_proxy_name = aws_db_proxy.main.name
}

resource "aws_db_proxy_target" "main" {
  db_proxy_name         = aws_db_proxy.main.name
  target_group_name     = aws_db_proxy_default_target_group.main.name
  db_cluster_identifier = aws_rds_cluster.main.cluster_identifier

  depends_on = [aws_rds_cluster_instance.writer, aws_rds_cluster_instance.reader]
}

resource "aws_db_proxy_endpoint" "read_only" {
  db_proxy_name          = aws_db_proxy.main.name
  db_proxy_endpoint_name = "${var.project_name}-ro"
  vpc_subnet_ids         = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.proxy.id]
  target_role            = "READ_ONLY"

  depends_on = [aws_db_proxy_target.main]
}
