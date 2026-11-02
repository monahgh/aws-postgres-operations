# IAM role for the workload server: Session Manager access (no SSH),
# read the DB secret, inspect RDS, and read/write CloudWatch metrics.

locals {
  db_secret_arn = try(aws_secretsmanager_secret.db[0].arn, data.aws_secretsmanager_secret.db[0].arn)
  rds_arn_base  = "arn:aws:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}"
}

resource "aws_iam_role" "workload" {
  name = "${var.project_name}-workload-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "workload_ssm" {
  role       = aws_iam_role.workload.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "workload_lab" {
  name = "${var.project_name}-workload-lab"
  role = aws_iam_role.workload.id

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
        Sid    = "InspectRdsAndMetrics"
        Effect = "Allow"
        Action = [
          "rds:Describe*",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadLabBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.lab.arn, "${aws_s3_bucket.lab.arn}/*"]
      },
      {
        # backup_validate.sh: snapshot the primary and restore it to a temp instance
        Sid      = "BackupValidationCreate"
        Effect   = "Allow"
        Action   = ["rds:CreateDBSnapshot", "rds:RestoreDBInstanceFromDBSnapshot", "rds:AddTagsToResource"]
        Resource = "*"
      },
      {
        # Deletes are limited to resources named <project>-validate-*
        Sid    = "BackupValidationCleanup"
        Effect = "Allow"
        Action = ["rds:DeleteDBInstance", "rds:DeleteDBSnapshot"]
        Resource = [
          "${local.rds_arn_base}:db:${var.project_name}-validate-*",
          "${local.rds_arn_base}:snapshot:${var.project_name}-validate-*"
        ]
      },
      {
        # failover_test.sh: reboot with failover, primary only
        Sid      = "FailoverTest"
        Effect   = "Allow"
        Action   = ["rds:RebootDBInstance"]
        Resource = aws_db_instance.primary.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "workload" {
  name = "${var.project_name}-workload-profile"
  role = aws_iam_role.workload.name
}
