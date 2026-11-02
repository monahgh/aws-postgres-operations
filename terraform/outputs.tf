output "vpc_id" {
  description = "ID of the lab VPC."
  value       = aws_vpc.main.id
}

output "workload_private_ip" {
  description = "Private IP of the workload EC2 instance."
  value       = aws_instance.workload.private_ip
}

output "database_endpoint" {
  description = "Primary PostgreSQL endpoint."
  value       = aws_db_instance.primary.address
}

output "read_replica_endpoint" {
  description = "Read replica endpoint."
  value       = aws_db_instance.read_replica.address
}

output "lab_bucket" {
  description = "S3 bucket holding the lab scripts, SQL files and dblab.env."
  value       = aws_s3_bucket.lab.id
}

output "workload_bootstrap_command" {
  description = "Run once in a Session Manager shell on the workload server."
  value       = "sudo aws s3 sync --region ${var.aws_region} s3://${aws_s3_bucket.lab.id} /opt/dblab && sudo bash /opt/dblab/scripts/setup_workload.sh"
}
