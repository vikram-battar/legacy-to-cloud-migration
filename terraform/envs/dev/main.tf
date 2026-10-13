# dev: cheap, single-AZ-leaning, no deletion protection.
# This is where every change lands first.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  # Use remote state in real life:
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "legacy-migration/dev/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "tfstate-locks"
  # }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "legacy-to-cloud-migration", Env = "dev" }
  }
}

module "vpc" {
  source = "../modules/vpc"
  name   = "legacymig-dev"
}

module "ecr" {
  source = "../modules/ecr"
  name   = "legacymig-dev"
}

module "alb" {
  source            = "../modules/alb"
  name              = "legacymig-dev"
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
}

module "ecs" {
  source             = "../modules/ecs"
  name               = "legacymig-dev"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  alb_sg_id          = module.alb.alb_sg_id
  target_group_arn   = module.alb.target_group_arn
  ecr_repository_url = module.ecr.repository_url
  image_tag          = var.image_tag
  db_endpoint        = module.rds.endpoint
  db_secret_arn      = module.rds.master_user_secret_arn
  desired_count      = 1
}

module "rds" {
  source             = "../modules/rds"
  name               = "legacymig-dev"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  ecs_sg_id          = module.ecs.ecs_sg_id
  # dev stays cheap: single AZ, no deletion protection
}

module "monitoring" {
  source                      = "../modules/monitoring"
  name                        = "legacymig-dev"
  ecs_service_name            = module.ecs.service_name
  ecs_cluster_name            = module.ecs.cluster_name
  alb_target_group_arn_suffix = "targetgroup/legacymig-dev-tg/aaaaaaaaaaaaaaaa"
}

variable "image_tag" {
  type        = string
  description = "Immutable image tag (git SHA) — set by the pipeline, never hand-edited"
}

output "alb_dns_name" {
  value       = module.alb.alb_dns_name
  description = "Hit this after deploy; /readyz should return 200"
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "rds_endpoint" {
  value       = module.rds.endpoint
  description = "Build DATABASE_URL from this: postgresql://<user>:<pass>@<endpoint>/inventory (creds in Secrets Manager)"
}
