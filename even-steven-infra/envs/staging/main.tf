terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # backend "s3" {}  # configure remote state when ready
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  default = "us-east-1"
}

# module "network"   { source = "../../modules/network" }
# module "database"  { source = "../../modules/database" }
# module "ecs"       { source = "../../modules/ecs-service" }
# module "frontend"  { source = "../../modules/frontend" }
