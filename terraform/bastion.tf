# SSM-only bastion (no SSH, no inbound rules) for psql labs and the failover test.
# Lessons from project 1 applied: standard AL2023 image from the AWS SSM parameter
# (includes the SSM agent), instance profile attached at launch, agent started first.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# Lab bucket: ships ../scripts and dblab.env to the bastion at boot.
resource "aws_s3_bucket" "lab" {
  bucket        = "${var.project_name}-files-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket = aws_s3_bucket.lab.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "lab_scripts" {
  for_each = fileset("${path.module}/../scripts", "*.sh")

  bucket       = aws_s3_bucket.lab.id
  key          = "scripts/${each.value}"
  source       = "${path.module}/../scripts/${each.value}"
  etag         = filemd5("${path.module}/../scripts/${each.value}")
  content_type = "text/plain"
}

resource "aws_s3_object" "lab_env" {
  bucket       = aws_s3_bucket.lab.id
  key          = "dblab.env"
  content_type = "text/plain"
  content      = <<-EOT
    DBLAB_REGION=${var.aws_region}
    DBLAB_BUCKET=${aws_s3_bucket.lab.id}
    CLUSTER_ID=${aws_rds_cluster.main.cluster_identifier}
    WRITER_ENDPOINT=${aws_rds_cluster.main.endpoint}
    READER_ENDPOINT=${aws_rds_cluster.main.reader_endpoint}
    PROXY_ENDPOINT=${aws_db_proxy.main.endpoint}
    PROXY_RO_ENDPOINT=${aws_db_proxy_endpoint.read_only.endpoint}
    SECRET_ARN=${local.db_secret_arn}
    DB_NAME=${var.db_name}
  EOT
}

resource "aws_iam_role" "bastion" {
  name = "${var.project_name}-bastion"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bastion_lab" {
  name = "lab"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = local.db_secret_arn
      },
      {
        Sid      = "ReadLabBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.lab.arn, "${aws_s3_bucket.lab.arn}/*"]
      },
      {
        Sid      = "InspectRdsAndMetrics"
        Effect   = "Allow"
        Action   = ["rds:Describe*", "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics"]
        Resource = "*"
      },
      {
        Sid      = "FailoverTest"
        Effect   = "Allow"
        Action   = "rds:FailoverDBCluster"
        Resource = aws_rds_cluster.main.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project_name}-bastion"
  role = aws_iam_role.bastion.name
}

resource "aws_instance" "bastion" {
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023_arm64.value)
  instance_type          = var.bastion_instance_type
  subnet_id              = module.vpc.private_subnets[0]
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    dnf install -y amazon-ssm-agent
    systemctl enable --now amazon-ssm-agent
    for v in 17 16 15; do dnf install -y "postgresql$v" && break; done
    dnf install -y jq
    mkdir -p /opt/dblab
    aws s3 sync --region ${var.aws_region} s3://${aws_s3_bucket.lab.id} /opt/dblab
    chmod +x /opt/dblab/scripts/*.sh
    cp /opt/dblab/scripts/dblab_profile.sh /etc/profile.d/dblab.sh
  EOT

  tags = {
    Name = "${var.project_name}-bastion"
  }

  depends_on = [aws_s3_object.lab_scripts, aws_s3_object.lab_env, aws_iam_role_policy.bastion_lab]
}
