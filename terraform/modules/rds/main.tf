variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ecs_sg_id" {
  type        = string
  description = "Security group of the ECS tasks, allowed to reach the DB"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = false
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "RDS: Postgres only from ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ecs_sg_id]
  }

  tags = { Name = "${var.name}-rds-sg" }
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name}-dbsubnet"
  subnet_ids = var.private_subnet_ids
  tags       = { Name = "${var.name}-dbsubnet" }
}

resource "aws_db_instance" "main" {
  identifier             = "${var.name}-postgres"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage
  storage_encrypted      = true
  db_name                = "inventory"
  username               = "inventory"
  manage_master_user_password = true # password in Secrets Manager, never in tfstate
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = var.multi_az
  deletion_protection    = var.deletion_protection
  backup_retention_period = 7
  skip_final_snapshot    = !var.deletion_protection

  tags = { Name = "${var.name}-postgres" }
}

output "endpoint" {
  value = aws_db_instance.main.endpoint
}

output "master_user_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}
