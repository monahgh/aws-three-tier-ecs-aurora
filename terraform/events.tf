# RDS event subscription (cluster failover events) -> SNS -> Lambda that logs the
# failover timeline to CloudWatch Logs as structured JSON.

resource "aws_sns_topic" "rds_events" {
  name = "${var.project_name}-rds-events"
}

resource "aws_sns_topic_policy" "rds_events" {
  arn = aws_sns_topic.rds_events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowRdsEvents"
      Effect    = "Allow"
      Principal = { Service = "events.rds.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.rds_events.arn
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_db_event_subscription" "cluster_failover" {
  name             = "${var.project_name}-cluster-failover"
  sns_topic        = aws_sns_topic.rds_events.arn
  source_type      = "db-cluster"
  source_ids       = [aws_rds_cluster.main.cluster_identifier]
  event_categories = ["failover"]

  depends_on = [aws_sns_topic_policy.rds_events]
}

data "archive_file" "failover_logger" {
  type        = "zip"
  source_file = "${path.module}/../lambda/failover_logger.py"
  output_path = "${path.module}/build/failover_logger.zip"
}

resource "aws_iam_role" "failover_logger" {
  name = "${var.project_name}-failover-logger"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "failover_logger" {
  role       = aws_iam_role.failover_logger.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "failover_logger" {
  name              = "/aws/lambda/${var.project_name}-failover-logger"
  retention_in_days = 3
}

resource "aws_lambda_function" "failover_logger" {
  function_name    = "${var.project_name}-failover-logger"
  role             = aws_iam_role.failover_logger.arn
  runtime          = "python3.12"
  handler          = "failover_logger.handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.failover_logger.output_path
  source_code_hash = data.archive_file.failover_logger.output_base64sha256
  timeout          = 10

  depends_on = [aws_cloudwatch_log_group.failover_logger, aws_iam_role_policy_attachment.failover_logger]
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSns"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover_logger.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.rds_events.arn
}

resource "aws_sns_topic_subscription" "failover_logger" {
  topic_arn = aws_sns_topic.rds_events.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.failover_logger.arn

  depends_on = [aws_lambda_permission.sns]
}
