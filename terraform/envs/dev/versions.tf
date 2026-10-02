terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "healthcare-staffing-tfstate-25faa1f2"
    key          = "envs/dev/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project     = "healthcare-staffing-lakehouse"
      ManagedBy   = "terraform"
      Stack       = "lakehouse"
      Environment = local.env
    }
  }
}
