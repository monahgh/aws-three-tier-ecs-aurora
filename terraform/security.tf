# Security groups. Lab shortcut: the proxy and the database accept 5432 from the whole VPC
# CIDR. Production would reference the source security groups instead.

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "ALB: HTTP only from CloudFront origin-facing IPs"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_security_group" "ecs" {
  name        = "${var.project_name}-ecs"
  description = "Fargate tasks: API port from the ALB only"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs.id
  description                  = "API port from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "proxy" {
  name        = "${var.project_name}-proxy"
  description = "RDS Proxy: PostgreSQL from the VPC"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_vpc" {
  security_group_id = aws_security_group.proxy.id
  description       = "PostgreSQL from the VPC (lab shortcut)"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "aws_security_group" "db" {
  name        = "${var.project_name}-db"
  description = "Aurora: PostgreSQL from the VPC"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_vpc" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from the VPC (lab shortcut)"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "aws_security_group" "bastion" {
  name        = "${var.project_name}-bastion"
  description = "SSM-only bastion: no inbound rules"
  vpc_id      = module.vpc.vpc_id
}

# All groups: unrestricted outbound (NAT for AWS APIs, image pulls, npm; 5432 inside the VPC).
resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    alb     = aws_security_group.alb.id
    ecs     = aws_security_group.ecs.id
    proxy   = aws_security_group.proxy.id
    db      = aws_security_group.db.id
    bastion = aws_security_group.bastion.id
  }

  security_group_id = each.value
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
