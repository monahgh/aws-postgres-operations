data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-nat"
  }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-private-${count.index + 1}"
  }
}

resource "aws_subnet" "database" {
  count = length(var.database_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.project_name}-database-${count.index + 1}"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Workload server: no inbound rules at all. Admin access is SSM Session Manager,
# which needs only outbound HTTPS (through the NAT).
resource "aws_security_group" "workload" {
  name        = "${var.project_name}-workload-sg"
  description = "Workload server: no inbound, outbound only (SSM, RDS, AWS APIs)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "database" {
  name        = "${var.project_name}-database-sg"
  description = "PostgreSQL from the workload server only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from the workload server"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.workload.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Standard (non-minimal) AL2023 image published by AWS: includes the SSM agent.
# A name filter such as al2023-ami-*-x86_64 can also match the "minimal" images, which do not.
data "aws_ssm_parameter" "al2023_standard" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "workload" {
  ami                    = nonsensitive(data.aws_ssm_parameter.al2023_standard.value)
  instance_type          = var.workload_instance_type
  subnet_id              = aws_subnet.private[0].id
  vpc_security_group_ids = [aws_security_group.workload.id]
  iam_instance_profile   = aws_iam_instance_profile.workload.name

  # Recreate the instance whenever user data changes, so it always runs on first boot.
  user_data_replace_on_change = true

  # Start the SSM agent first so Session Manager works even if the package steps are slow.
  user_data = <<-EOT
    #!/bin/bash
    dnf install -y amazon-ssm-agent
    systemctl enable --now amazon-ssm-agent
    dnf install -y postgresql15 jq
  EOT

  tags = {
    Name = "${var.project_name}-workload"
  }
}

resource "aws_secretsmanager_secret" "db" {
  count = var.db_password == null ? 0 : 1

  name                    = var.db_secret_name
  recovery_window_in_days = 0

  tags = {
    Name = "${var.project_name}-db-credentials"
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  count = var.db_password == null ? 0 : 1

  secret_id = aws_secretsmanager_secret.db[0].id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
  })
}

data "aws_secretsmanager_secret" "db" {
  count = var.db_password == null ? 1 : 0
  name  = var.db_secret_name
}

data "aws_secretsmanager_secret_version" "db" {
  count     = var.db_password == null ? 1 : 0
  secret_id = data.aws_secretsmanager_secret.db[0].id
}

locals {
  db_credentials = try(
    jsondecode(aws_secretsmanager_secret_version.db[0].secret_string),
    jsondecode(data.aws_secretsmanager_secret_version.db[0].secret_string)
  )
  db_username_value = try(local.db_credentials.username, var.db_username)
  db_password_value = try(local.db_credentials.password, var.db_password)
}

resource "aws_db_subnet_group" "postgres" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.database[*].id

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "primary" {
  identifier              = "${var.project_name}-postgres-primary"
  engine                  = "postgres"
  engine_version          = "16"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  db_name                 = var.db_name
  username                = local.db_username_value
  password                = local.db_password_value
  db_subnet_group_name    = aws_db_subnet_group.postgres.name
  vpc_security_group_ids  = [aws_security_group.database.id]
  publicly_accessible     = false
  multi_az                = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  storage_encrypted       = true
  deletion_protection     = false
  apply_immediately       = true

  tags = {
    Name = "${var.project_name}-postgres-primary"
  }
}

resource "aws_db_instance" "read_replica" {
  identifier                 = "${var.project_name}-postgres-read-replica"
  instance_class             = var.db_instance_class
  replicate_source_db        = aws_db_instance.primary.arn
  db_subnet_group_name       = aws_db_subnet_group.postgres.name
  vpc_security_group_ids     = [aws_security_group.database.id]
  publicly_accessible        = false
  storage_encrypted          = true # inherited from the encrypted primary; must be explicit or Terraform plans a replacement
  backup_retention_period    = 0
  skip_final_snapshot        = true
  apply_immediately          = true
  auto_minor_version_upgrade = true

  tags = {
    Name = "${var.project_name}-postgres-read-replica"
  }
}
