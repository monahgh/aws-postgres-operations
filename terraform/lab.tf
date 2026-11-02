# Lab bucket: ships ../scripts and ../sql to the workload server.
# On the instance: aws s3 sync s3://<bucket> /opt/dblab (see output workload_bootstrap_command).

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "lab" {
  bucket        = "${var.project_name}-files-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-files"
  }
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket = aws_s3_bucket.lab.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  lab_files = merge(
    { for f in fileset("${path.module}/../scripts", "*.sh") : "scripts/${f}" => "${path.module}/../scripts/${f}" },
    { for f in fileset("${path.module}/../sql", "*.sql") : "sql/${f}" => "${path.module}/../sql/${f}" },
  )
}

resource "aws_s3_object" "lab_files" {
  for_each = local.lab_files

  bucket       = aws_s3_bucket.lab.id
  key          = each.key
  source       = each.value
  etag         = filemd5(each.value)
  content_type = "text/plain"
}

# Settings every script reads, so nothing is hardcoded on the instance.
resource "aws_s3_object" "lab_env" {
  bucket       = aws_s3_bucket.lab.id
  key          = "dblab.env"
  content_type = "text/plain"
  content      = <<-EOT
    DBLAB_REGION=${var.aws_region}
    DBLAB_BUCKET=${aws_s3_bucket.lab.id}
    PRIMARY_ID=${aws_db_instance.primary.identifier}
    REPLICA_ID=${aws_db_instance.read_replica.identifier}
    SECRET_ID=${var.db_secret_name}
    DB_NAME=${var.db_name}
    VALIDATE_PREFIX=${var.project_name}-validate
  EOT
}
