terraform {
  required_version = ">=1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Local state, one file per account: state/<env>.tfstate (git-ignored), set by make bootstrap.
  backend "local" {}
}


provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "healthcare-staffing-lakehouse"
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}
