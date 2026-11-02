variable "aws_region" {
  description = "AWS region for the PostgreSQL lab. Use eu-central-1 by default."
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Project prefix used for naming resources."
  type        = string
  default     = "pgops-lab"
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets."
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets."
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "database_subnet_cidrs" {
  description = "CIDR blocks for the database subnets."
  type        = list(string)
  default     = ["10.20.21.0/24", "10.20.22.0/24"]
}

variable "workload_instance_type" {
  description = "EC2 instance type for the workload server."
  type        = string
  default     = "t3.micro"
}

variable "db_instance_class" {
  description = "RDS instance class for PostgreSQL."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for the PostgreSQL database. This can also be stored alongside the secret in AWS Secrets Manager."
  type        = string
  default     = "postgresadmin"
  sensitive   = true
}

variable "db_secret_name" {
  description = "Name of the AWS Secrets Manager secret that stores the PostgreSQL credentials."
  type        = string
  default     = "pgops-lab/postgres/password"
}

variable "db_password" {
  description = "Optional master password for the PostgreSQL database. Leave null to read it from the AWS Secrets Manager secret instead."
  type        = string
  default     = null
  sensitive   = true
}
