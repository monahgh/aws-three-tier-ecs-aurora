output "app_url" {
  description = "Open this in a browser: CloudFront -> S3 (SPA) and /api/* -> ALB -> ECS."
  value       = "https://${aws_cloudfront_distribution.main.domain_name}"
}

output "alb_direct_url" {
  description = "Direct ALB URL: should NOT work (403 or timeout), proving the ALB is locked to CloudFront."
  value       = "http://${aws_lb.api.dns_name}/api/health"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "frontend_bucket" {
  value = aws_s3_bucket.frontend.id
}

output "aurora_writer_endpoint" {
  value = aws_rds_cluster.main.endpoint
}

output "aurora_reader_endpoint" {
  value = aws_rds_cluster.main.reader_endpoint
}

output "proxy_endpoint" {
  description = "RDS Proxy read/write endpoint (-> writer)."
  value       = aws_db_proxy.main.endpoint
}

output "proxy_read_only_endpoint" {
  description = "RDS Proxy READ_ONLY endpoint (-> reader)."
  value       = aws_db_proxy_endpoint.read_only.endpoint
}

output "db_secret_arn" {
  description = "RDS-managed master user secret."
  value       = local.db_secret_arn
}

output "ecs_cluster" {
  value = aws_ecs_cluster.main.name
}

output "bastion_instance_id" {
  description = "Connect: EC2 console -> this instance -> Connect -> Session Manager."
  value       = aws_instance.bastion.id
}

output "failover_log_group" {
  value = aws_cloudwatch_log_group.failover_logger.name
}
