terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Each environment has its own state. The settings come from config/<env>.backend.hcl,
  # which make init passes in.
  backend "s3" {}
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "healthcare-staffing-lakehouse"
      ManagedBy   = "terraform"
      Stack       = "lakehouse"
      Environment = var.env
    }
  }
}
